(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2016.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

open Tezos_context
open Script
open Script_typed_ir

(* ---- Error definitions ---------------------------------------------------*)

(* Auxiliary types for error documentation *)
type namespace = Type_namespace | Constant_namespace | Instr_namespace
type kind = Int_kind | String_kind | Prim_kind | Seq_kind
type type_map = (int * (Script.expr list * Script.expr list)) list

(* Structure errors *)
type error += Invalid_arity of Script.location * string * int * int
type error += Invalid_namespace of Script.location * string * namespace * namespace
type error += Invalid_primitive of Script.location * string list * string
type error += Invalid_case of Script.location * string
type error += Invalid_kind of Script.location * kind list * kind

(* Instruction typing errors *)
type error += Fail_not_in_tail_position of Script.location
type error += Undefined_binop : Script.location * string * _ ty * _ ty -> error
type error += Undefined_unop : Script.location * string * _ ty -> error
type error += Bad_return : Script.location * _ stack_ty * _ ty -> error
type error += Bad_stack : Script.location * string * int * _ stack_ty -> error
type error += Unmatched_branches : Script.location * _ stack_ty * _ stack_ty -> error
type error += Transfer_in_lambda of Script.location
type error += Bad_stack_length
type error += Bad_stack_item of int

(* Value typing errors *)
type error += Invalid_constant : Script.location * Script.expr * _ ty -> error
type error += Invalid_contract of Script.location * Contract.t
type error += Comparable_type_expected : Script.location * _ ty -> error
type error += Inconsistent_types : _ ty * _ ty -> error

(* Toplevel errors *)
type error += Ill_typed_data : string option * Script.expr * _ ty -> error
type error += Ill_formed_type of string option * Script.expr
type error += Ill_typed_contract : Script.expr * _ ty * _ ty * _ ty * type_map -> error
type error += Unordered_map_keys of Script.location * Script.expr
type error += Unordered_set_values of Script.location * Script.expr
type error += Duplicate_map_keys of Script.location * Script.expr
type error += Duplicate_set_values of Script.location * Script.expr

(* ---- Error helpers -------------------------------------------------------*)

let location = function
  | Prim (loc, _, _, _)
  | Int (loc, _)
  | String (loc, _)
  | Seq (loc, _, _) -> loc

let kind = function
  | Int _ -> Int_kind
  | String _ -> String_kind
  | Prim _ -> Prim_kind
  | Seq _ -> Seq_kind

let namespace name =
  let is_lower = function  '_' | 'a'..'z' -> true | _ -> false in
  let is_upper = function  '_' | 'A'..'Z' -> true | _ -> false in
  let rec for_all a b f =
    Compare.Int.(a > b) || f a && for_all (a + 1) b f in
  let len = String.length name in
  if Compare.Int.(len = 0)
  || Compare.Char.(String.get name 0 = '_') then
    None
  else if is_upper (String.get name 0)
  && for_all 1 (len - 1) (fun i -> is_upper (String.get name i)) then
    Some Instr_namespace
  else if is_upper (String.get name 0)
       && for_all 1 (len - 1) (fun i -> is_lower (String.get name i)) then
    Some Constant_namespace
  else if is_lower (String.get name 0)
       && for_all 1 (len - 1) (fun i -> is_lower (String.get name i)) then
    Some Type_namespace
  else
    None

let unexpected expr exp_kinds exp_ns exp_prims =
  match expr with
  | Int (loc, _) -> Invalid_kind (loc, Prim_kind :: exp_kinds, Int_kind)
  | String (loc, _ ) -> Invalid_kind (loc, Prim_kind :: exp_kinds, String_kind)
  | Seq (loc, _, _) -> Invalid_kind (loc, Prim_kind :: exp_kinds, Seq_kind)
  | Prim (loc, name, _, _) ->
      match namespace name, exp_ns with
      | None, _ ->
          Invalid_case (loc, name)
      | Some Type_namespace, Type_namespace
      | Some Instr_namespace, Instr_namespace
      | Some Constant_namespace, Constant_namespace ->
          Invalid_primitive (loc, exp_prims, name)
      | Some ns, _ ->
          Invalid_namespace (loc, name, exp_ns, ns)

let check_kind kinds expr =
  let kind = kind expr in
  if List.mem kind kinds then
    return ()
  else
    let loc = location expr in
    fail (Invalid_kind (loc, kinds, kind))

(* ---- Sets and Maps -------------------------------------------------------*)

let compare_comparable
  : type a. a comparable_ty -> a -> a -> int
  = fun kind x y -> match kind with
    | String_key -> Compare.String.compare x y
    | Bool_key -> Compare.Bool.compare x y
    | Tez_key -> Tez.compare x y
    | Key_hash_key -> Ed25519.Public_key_hash.compare x y
    | Int_key ->
               let res = (Script_int.compare x y) in
        if Compare.Int.(res = 0) then 0
        else if Compare.Int.(res > 0) then 1
        else -1

    | Nat_key ->
               let res = (Script_int.compare x y) in
        if Compare.Int.(res = 0) then 0
        else if Compare.Int.(res > 0) then 1
        else -1

    | Timestamp_key -> Timestamp.compare x y

let empty_set
  : type a. a comparable_ty -> a set
  = fun ty ->
    let module OPS = Set.Make (struct
        type t = a
        let compare = compare_comparable ty
      end) in
    (module struct
      type elt = a
      module OPS = OPS
      let boxed = OPS.empty
    end)

let set_update
  : type a. a -> bool -> a set -> a set
  = fun v b (module Box) ->
    (module struct
      type elt = a
      module OPS = Box.OPS
      let boxed =
        if b then
          Box.OPS.add v Box.boxed
        else
          Box.OPS.remove v Box.boxed
    end)

let set_mem
  : type elt. elt -> elt set -> bool
  = fun v (module Box) ->
    Box.OPS.mem v Box.boxed

let set_fold
  : type elt acc. (elt -> acc -> acc) -> elt set -> acc -> acc
  = fun f (module Box) ->
    Box.OPS.fold f Box.boxed

let set_size
  : type elt. elt set -> Script_int.n Script_int.num =
  fun (module Box) ->
    Script_int.(abs (of_int (Box.OPS.cardinal Box.boxed)))

let map_key_ty
  : type a b. (a, b) map -> a comparable_ty
  = fun (module Box) -> Box.key_ty

let empty_map
  : type a b. a comparable_ty -> (a, b) map
  = fun ty ->
    let module OPS = Map.Make (struct
        type t = a
        let compare = compare_comparable ty
      end) in
    (module struct
      type key = a
      type value = b
      let key_ty = ty
      module OPS = OPS
      let boxed = OPS.empty
    end)

let map_get
  : type key value. key -> (key, value) map -> value option
  = fun k (module Box) ->
    try Some (Box.OPS.find k Box.boxed) with Not_found -> None

let map_update
  : type a b. a -> b option -> (a, b) map -> (a, b) map
  = fun k v (module Box) ->
    (module struct
      type key = a
      type value = b
      let key_ty = Box.key_ty
      module OPS = Box.OPS
      let boxed =
        match v with
        | Some v -> Box.OPS.add k v Box.boxed
        | None -> Box.OPS.remove k Box.boxed
    end)

let map_mem
  : type key value. key -> (key, value) map -> bool
  = fun k (module Box) ->
    Box.OPS.mem k Box.boxed

let map_fold
  : type key value acc. (key -> value -> acc -> acc) -> (key, value) map -> acc -> acc
  = fun f (module Box) ->
    Box.OPS.fold f Box.boxed

let map_size
  : type key value. (key, value) map -> Script_int.n Script_int.num =
  fun (module Box) ->
    Script_int.(abs (of_int (Box.OPS.cardinal Box.boxed)))

(* ---- Unparsing (Typed IR -> Untyped epressions) --------------------------*)

let ty_of_comparable_ty
  : type a. a comparable_ty -> a ty = function
  | Int_key -> Int_t
  | Nat_key -> Nat_t
  | String_key -> String_t
  | Tez_key -> Tez_t
  | Bool_key -> Bool_t
  | Key_hash_key -> Key_hash_t
  | Timestamp_key -> Timestamp_t

let unparse_comparable_ty
  : type a. a comparable_ty -> Script.expr = function
  | Int_key -> Prim (-1, "int", [], None)
  | Nat_key -> Prim (-1, "nat", [], None)
  | String_key -> Prim (-1, "string", [], None)
  | Tez_key -> Prim (-1, "tez", [], None)
  | Bool_key -> Prim (-1, "bool", [], None)
  | Key_hash_key -> Prim (-1, "key_hash", [], None)
  | Timestamp_key -> Prim (-1, "timestamp", [], None)

let rec unparse_ty
  : type a. a ty -> Script.expr = function
  | Unit_t -> Prim (-1, "unit", [], None)
  | Int_t -> Prim (-1, "int", [], None)
  | Nat_t -> Prim (-1, "nat", [], None)
  | String_t -> Prim (-1, "string", [], None)
  | Tez_t -> Prim (-1, "tez", [], None)
  | Bool_t -> Prim (-1, "bool", [], None)
  | Key_hash_t -> Prim (-1, "key_hash", [], None)
  | Key_t -> Prim (-1, "key", [], None)
  | Timestamp_t -> Prim (-1, "timestamp", [], None)
  | Signature_t -> Prim (-1, "signature", [], None)
  | Contract_t (utl, utr) ->
      let tl = unparse_ty utl in
      let tr = unparse_ty utr in
      Prim (-1, "contract", [ tl; tr ], None)
  | Pair_t (utl, utr) ->
      let tl = unparse_ty utl in
      let tr = unparse_ty utr in
      Prim (-1, "pair", [ tl; tr ], None)
  | Union_t (utl, utr) ->
      let tl = unparse_ty utl in
      let tr = unparse_ty utr in
      Prim (-1, "or", [ tl; tr ], None)
  | Lambda_t (uta, utr) ->
      let ta = unparse_ty uta in
      let tr = unparse_ty utr in
      Prim (-1, "lambda", [ ta; tr ], None)
  | Option_t ut ->
      let t = unparse_ty ut in
      Prim (-1, "option", [ t ], None)
  | List_t ut ->
      let t = unparse_ty ut in
      Prim (-1, "list", [ t ], None)
  | Set_t ut ->
      let t = unparse_comparable_ty ut in
      Prim (-1, "set", [ t ], None)
  | Map_t (uta, utr) ->
      let ta = unparse_comparable_ty uta in
      let tr = unparse_ty utr in
      Prim (-1, "map", [ ta; tr ], None)

let rec unparse_data
  : type a. a ty -> a -> Script.expr
  = fun ty a -> match ty, a with
    | Unit_t, () ->
        Prim (-1, "Unit", [], None)
    | Int_t, v ->
        Int (-1, Script_int.to_string v)
    | Nat_t, v ->
        Int (-1, Script_int.to_string v)
    | String_t, s ->
        String (-1, s)
    | Bool_t, true ->
        Prim (-1, "True", [], None)
    | Bool_t, false ->
        Prim (-1, "False", [], None)
    | Timestamp_t, t ->
        String (-1, Timestamp.to_notation t)
    | Contract_t _, (_, _, c)  ->
        String (-1, Contract.to_b58check c)
    | Signature_t, s ->
        let text =
          Hex_encode.hex_encode
            (MBytes.to_string (Data_encoding.Binary.to_bytes Ed25519.Signature.encoding s)) in
        String (-1, text)
    | Tez_t, v ->
        String (-1, Tez.to_string v)
    | Key_t, k ->
        String (-1, Ed25519.Public_key.to_b58check k)
    | Key_hash_t, k ->
        String (-1, Ed25519.Public_key_hash.to_b58check k)
    | Pair_t (tl, tr), (l, r) ->
        let l = unparse_data tl l in
        let r = unparse_data tr r in
        Prim (-1, "Pair", [ l; r ], None)
    | Union_t (tl, _), L l ->
        let l = unparse_data tl l in
        Prim (-1, "Left", [ l ], None)
    | Union_t (_, tr), R r ->
        let r = unparse_data tr r in
        Prim (-1, "Right", [ r ], None)
    | Option_t t, Some v ->
        let v = unparse_data t v in
        Prim (-1, "Some", [ v ], None)
    | Option_t _, None ->
        Prim (-1, "None", [], None)
    | List_t t, items ->
        let items = List.map (unparse_data t) items in
        Prim (-1, "List", items, None)
    | Set_t t, set ->
        let t = ty_of_comparable_ty t in
        let items =
          set_fold
            (fun item acc ->
               unparse_data t item :: acc )
            set [] in
        Prim (-1, "Set", List.rev items, None)
    | Map_t (kt, vt), map ->
        let kt = ty_of_comparable_ty kt in
        let items =
          map_fold (fun k v acc ->
              Prim (-1, "Item",
                    [ unparse_data kt k;
                      unparse_data vt v ],
                   None)
              :: acc)
            map [] in
        Prim (-1, "Map", List.rev items, None)
    | Lambda_t _, Lam (_, original_code) ->
        original_code

(* ---- Equality witnesses --------------------------------------------------*)

type ('ta, 'tb) eq = Eq : 'same * 'same -> ('same, 'same) eq

let eq
  : type t. t -> t -> (t, t) eq tzresult
  = fun ta tb -> Ok (Eq (ta, tb))

(* TODO: shall we allow operations to compare nats and ints ? *)
let comparable_ty_eq
  : type ta tb.
    ta comparable_ty -> tb comparable_ty ->
    (ta comparable_ty, tb comparable_ty) eq tzresult
  = fun ta tb -> match ta, tb with
    | Int_key, Int_key -> eq ta tb
    | Nat_key, Nat_key -> eq ta tb
    | String_key, String_key -> eq ta tb
    | Tez_key, Tez_key -> eq ta tb
    | Bool_key, Bool_key -> eq ta tb
    | Key_hash_key, Key_hash_key -> eq ta tb
    | Timestamp_key, Timestamp_key -> eq ta tb
    | _, _ -> error (Inconsistent_types (ty_of_comparable_ty ta, ty_of_comparable_ty tb))

let rec ty_eq
  : type ta tb. ta ty -> tb ty -> (ta ty, tb ty) eq tzresult
  = fun ta tb ->
    match ta, tb with
    | Unit_t, Unit_t -> eq ta tb
    | Int_t, Int_t -> eq ta tb
    | Nat_t, Nat_t -> eq ta tb
    | Key_t, Key_t -> eq ta tb
    | Key_hash_t, Key_hash_t -> eq ta tb
    | String_t, String_t -> eq ta tb
    | Signature_t, Signature_t -> eq ta tb
    | Tez_t, Tez_t -> eq ta tb
    | Timestamp_t, Timestamp_t -> eq ta tb
    | Bool_t, Bool_t -> eq ta tb
    | Map_t (tal, tar), Map_t (tbl, tbr) ->
        (comparable_ty_eq tal tbl >>? fun (Eq _) ->
         ty_eq tar tbr >>? fun (Eq _) ->
         (eq ta tb : (ta ty, tb ty) eq tzresult)) |>
        record_trace (Inconsistent_types (ta, tb))
    | Set_t ea, Set_t eb ->
        (comparable_ty_eq ea eb >>? fun (Eq _) ->
         (eq ta tb : (ta ty, tb ty) eq tzresult)) |>
        record_trace (Inconsistent_types (ta, tb))
    | Pair_t (tal, tar), Pair_t (tbl, tbr) ->
        (ty_eq tal tbl >>? fun (Eq _) ->
         ty_eq tar tbr >>? fun (Eq _) ->
         (eq ta tb : (ta ty, tb ty) eq tzresult)) |>
        record_trace (Inconsistent_types (ta, tb))
    | Union_t (tal, tar), Union_t (tbl, tbr) ->
        (ty_eq tal tbl >>? fun (Eq _) ->
         ty_eq tar tbr >>? fun (Eq _) ->
         (eq ta tb : (ta ty, tb ty) eq tzresult)) |>
        record_trace (Inconsistent_types (ta, tb))
    | Lambda_t (tal, tar), Lambda_t (tbl, tbr) ->
        (ty_eq tal tbl >>? fun (Eq _) ->
         ty_eq tar tbr >>? fun (Eq _) ->
         (eq ta tb : (ta ty, tb ty) eq tzresult)) |>
        record_trace (Inconsistent_types (ta, tb))
    | Contract_t (tal, tar), Contract_t (tbl, tbr) ->
        (ty_eq tal tbl >>? fun (Eq _) ->
         ty_eq tar tbr >>? fun (Eq _) ->
         (eq ta tb : (ta ty, tb ty) eq tzresult)) |>
        record_trace (Inconsistent_types (ta, tb))
    | Option_t tva, Option_t tvb ->
        (ty_eq tva tvb >>? fun (Eq _) ->
         (eq ta tb : (ta ty, tb ty) eq tzresult)) |>
        record_trace (Inconsistent_types (ta, tb))
    | List_t tva, List_t tvb ->
        (ty_eq tva tvb >>? fun (Eq _) ->
         (eq ta tb : (ta ty, tb ty) eq tzresult)) |>
        record_trace (Inconsistent_types (ta, tb))
    | _, _ -> error (Inconsistent_types (ta, tb))

let rec stack_ty_eq
  : type ta tb. int -> ta stack_ty -> tb stack_ty ->
    (ta stack_ty, tb stack_ty) eq tzresult = fun lvl ta tb ->
  match ta, tb with
  | Item_t (tva, ra), Item_t (tvb, rb) ->
      ty_eq tva tvb |>
      record_trace (Bad_stack_item lvl) >>? fun  (Eq _) ->
      stack_ty_eq (lvl + 1) ra rb >>? fun (Eq _) ->
      (eq ta tb : (ta stack_ty, tb stack_ty) eq tzresult)
  | Empty_t, Empty_t -> eq ta tb
  | _, _ -> error Bad_stack_length

(* ---- Type checker resuls -------------------------------------------------*)

type 'bef judgement =
  | Typed : ('bef, 'aft) descr -> 'bef judgement
  | Failed : { descr : 'aft. 'aft stack_ty -> ('bef, 'aft) descr } -> 'bef judgement

(* ---- Type checker (Untyped expressions -> Typed IR) ----------------------*)

type ('t, 'f, 'b) branch =
  { branch : 'r. ('t, 'r) descr -> ('f, 'r) descr -> ('b, 'r) descr } [@@unboxed]

let merge_branches
  : type bef a b. int -> a judgement -> b judgement ->
    (a, b, bef) branch ->
    bef judgement tzresult Lwt.t
  = fun loc btr bfr { branch } ->
    match btr, bfr with
    | Typed ({ aft = aftbt } as dbt), Typed ({ aft = aftbf } as dbf) ->
        trace
          (Unmatched_branches (loc, aftbt, aftbf))
          (Lwt.return (stack_ty_eq 1 aftbt aftbf)) >>=? fun (Eq _) ->
        return (Typed (branch dbt dbf))
    | Failed { descr = descrt }, Failed { descr = descrf } ->
        let descr ret =
          branch (descrt ret) (descrf ret) in
        return (Failed { descr })
    | Typed dbt, Failed { descr = descrf } ->
        return (Typed (branch dbt (descrf dbt.aft)))
    | Failed { descr = descrt }, Typed dbf ->
        return (Typed (branch (descrt dbf.aft) dbf))

type ex_comparable_ty = Ex_comparable_ty : 'a comparable_ty -> ex_comparable_ty
type ex_ty = Ex_ty : 'a ty -> ex_ty
type ex_stack_ty = Ex_stack_ty : 'a stack_ty -> ex_stack_ty

let rec parse_comparable_ty : Script.expr -> ex_comparable_ty tzresult = function
  | Prim (_, "int", [], _) -> ok (Ex_comparable_ty Int_key)
  | Prim (_, "nat", [], _) -> ok (Ex_comparable_ty Nat_key)
  | Prim (_, "string", [], _) -> ok (Ex_comparable_ty String_key)
  | Prim (_, "tez", [], _) -> ok (Ex_comparable_ty Tez_key)
  | Prim (_, "bool", [], _) -> ok (Ex_comparable_ty Bool_key)
  | Prim (_, "key_hash", [], _) -> ok (Ex_comparable_ty Key_hash_key)
  | Prim (_, "timestamp", [], _) -> ok (Ex_comparable_ty Timestamp_key)
  | Prim (loc, ("int" | "nat"
               | "string" | "tez" | "bool"
               | "key" | "timestamp" as prim), l, _) ->
      error (Invalid_arity (loc, prim, 0, List.length l))
  | Prim (loc, ("pair" | "or" | "set" | "map"
               | "list" | "option"  | "lambda"
               | "unit" | "signature"  | "contract"), _, _) as expr ->
      parse_ty expr >>? fun (Ex_ty ty) ->
      error (Comparable_type_expected (loc, ty))
  | expr ->
      error @@ unexpected expr [] Type_namespace
        [ "int" ; "nat" ;
          "string" ; "tez" ; "bool" ;
          "key" ; "key_hash" ; "timestamp" ]

and parse_ty : Script.expr -> ex_ty tzresult = function
  | Prim (_, "unit", [], _) -> ok (Ex_ty Unit_t)
  | Prim (_, "int", [], _) -> ok (Ex_ty (Int_t))
  | Prim (_, "nat", [], _) -> ok (Ex_ty (Nat_t))
  | Prim (_, "string", [], _) -> ok (Ex_ty String_t)
  | Prim (_, "tez", [], _) -> ok (Ex_ty Tez_t)
  | Prim (_, "bool", [], _) -> ok (Ex_ty Bool_t)
  | Prim (_, "key", [], _) -> ok (Ex_ty Key_t)
  | Prim (_, "key_hash", [], _) -> ok (Ex_ty Key_hash_t)
  | Prim (_, "timestamp", [], _) -> ok (Ex_ty Timestamp_t)
  | Prim (_, "signature", [], _) -> ok (Ex_ty Signature_t)
  | Prim (_, "contract", [ utl; utr ], _) ->
      parse_ty utl >>? fun (Ex_ty tl) ->
      parse_ty utr >>? fun (Ex_ty tr) ->
      ok (Ex_ty (Contract_t (tl, tr)))
  | Prim (_, "pair", [ utl; utr ], _) ->
      parse_ty utl >>? fun (Ex_ty tl) ->
      parse_ty utr >>? fun (Ex_ty tr) ->
      ok (Ex_ty (Pair_t (tl, tr)))
  | Prim (_, "or", [ utl; utr ], _) ->
      parse_ty utl >>? fun (Ex_ty tl) ->
      parse_ty utr >>? fun (Ex_ty tr) ->
      ok (Ex_ty (Union_t (tl, tr)))
  | Prim (_, "lambda", [ uta; utr ], _) ->
      parse_ty uta >>? fun (Ex_ty ta) ->
      parse_ty utr >>? fun (Ex_ty tr) ->
      ok (Ex_ty (Lambda_t (ta, tr)))
  | Prim (_, "option", [ ut ], _) ->
      parse_ty ut >>? fun (Ex_ty t) ->
      ok (Ex_ty (Option_t t))
  | Prim (_, "list", [ ut ], _) ->
      parse_ty ut >>? fun (Ex_ty t) ->
      ok (Ex_ty (List_t t))
  | Prim (_, "set", [ ut ], _) ->
      parse_comparable_ty ut >>? fun (Ex_comparable_ty t) ->
      ok (Ex_ty (Set_t t))
  | Prim (_, "map", [ uta; utr ], _) ->
      parse_comparable_ty uta >>? fun (Ex_comparable_ty ta) ->
      parse_ty utr >>? fun (Ex_ty tr) ->
      ok (Ex_ty (Map_t (ta, tr)))
  | Prim (loc, ("pair" | "or" | "set" | "map"
               | "list" | "option"  | "lambda"
               | "unit" | "signature"  | "contract"
               | "int" | "nat"
               | "string" | "tez" | "bool"
               | "key" | "key_hash" | "timestamp" as prim), l, _) ->
      error (Invalid_arity (loc, prim, 0, List.length l))
  | expr ->
      error @@ unexpected expr [] Type_namespace
        [ "pair" ; "or" ; "set" ; "map" ;
          "list" ; "option"  ; "lambda" ;
          "unit" ; "signature"  ; "contract" ;
          "int" ; "nat" ;
          "string" ; "tez" ; "bool" ;
          "key" ; "key_hash" ; "timestamp" ]

let comparable_ty_of_ty
  : type a. int -> a ty -> a comparable_ty tzresult
  = fun loc ty -> match ty with
    | Int_t -> ok Int_key
    | Nat_t -> ok Nat_key
    | String_t -> ok String_key
    | Tez_t -> ok Tez_key
    | Bool_t -> ok Bool_key
    | Key_hash_t -> ok Key_hash_key
    | Timestamp_t -> ok Timestamp_key
    | ty -> error (Comparable_type_expected (loc, ty))

let rec unparse_stack
  : type a. a stack_ty -> Script.expr list
  = function
    | Empty_t -> []
    | Item_t (ty, rest) -> unparse_ty ty :: unparse_stack rest

let rec parse_data
  : type a.
    ?type_logger: (int * (Script.expr list * Script.expr list) -> unit) ->
    context -> a ty -> Script.expr -> a tzresult Lwt.t
  = fun ?type_logger ctxt ty script_data ->
    let error () =
      Invalid_constant (location script_data, script_data, ty) in
    let traced body =
      trace (error ()) body in
    match ty, script_data with
    (* Unit *)
    | Unit_t, Prim (_, "Unit", [], _) -> return ()
    | Unit_t, Prim (loc, "Unit", l, _) ->
        traced (fail (Invalid_arity (loc, "Unit", 0, List.length l)))
    | Unit_t, expr ->
        traced (fail (unexpected expr [] Constant_namespace [ "Unit" ]))
    (* Booleans *)
    | Bool_t, Prim (_, "True", [], _) -> return true
    | Bool_t, Prim (_, "False", [], _) -> return false
    | Bool_t, Prim (loc, ("True" | "False" as c), l, _) ->
        traced (fail (Invalid_arity (loc, c, 0, List.length l)))
    | Bool_t, expr ->
        traced (fail (unexpected expr [] Constant_namespace [ "True" ; "False" ]))
    (* Strings *)
    | String_t, String (_, v) -> return v
    | String_t, expr ->
        traced (fail (Invalid_kind (location expr, [ String_kind ], kind expr)))
    (* Integers *)
    | Int_t, Int (_, v) ->
        begin match Script_int.of_string v with
          | None -> fail (error ())
          | Some v -> return v
        end
    | Nat_t, Int (_, v) ->
        begin match Script_int.of_string v with
          | None -> fail (error ())
          | Some v ->
              if Compare.Int.(Script_int.compare v Script_int.zero >= 0) then
                return (Script_int.abs v)
              else fail (error ())
        end
    | Int_t, expr ->
        traced (fail (Invalid_kind (location expr, [ Int_kind ], kind expr)))
    | Nat_t, expr ->
        traced (fail (Invalid_kind (location expr, [ Int_kind ], kind expr)))
    (* Tez amounts *)
    | Tez_t, String (_, v) -> begin try
          match Tez.of_string v with
          | None -> raise Exit
          | Some tez -> return tez
        with _ ->
          fail @@ error ()
      end
    | Tez_t, expr ->
        traced (fail (Invalid_kind (location expr, [ String_kind ], kind expr)))
    (* Timestamps *)
    | Timestamp_t, (Int (_, v)) -> begin
        match (Timestamp.of_seconds v) with
        | Some v -> return v
        | None -> fail (error ())
      end
    | Timestamp_t, String (_, s) -> begin try
          match Timestamp.of_notation s with
          | Some v -> return v
          | None -> fail (error ())
        with _ -> fail (error ())
      end
    | Timestamp_t, expr ->
        traced (fail (Invalid_kind (location expr, [ String_kind ; Int_kind ], kind expr)))
    (* IDs *)
    | Key_t, String (_, s) ->
        begin
          try
            return (Ed25519.Public_key.of_b58check_exn s)
          with _ -> fail (error ())
        end
    | Key_t, expr ->
        traced (fail (Invalid_kind (location expr, [ String_kind ], kind expr)))
    | Key_hash_t, String (_, s) ->
        begin
          try
            return (Ed25519.Public_key_hash.of_b58check_exn s)
          with _ -> fail (error ()) end
    | Key_hash_t, expr ->
        traced (fail (Invalid_kind (location expr, [ String_kind ], kind expr)))
    (* Signatures *)
    | Signature_t, String (_, s) -> begin try
          match Data_encoding.Binary.of_bytes
                  Ed25519.Signature.encoding
                  (MBytes.of_string (Hex_encode.hex_decode s)) with
          | Some s -> return s
          | None -> raise Not_found
        with _ ->
          fail (error ())
      end
    | Signature_t, expr ->
        traced (fail (Invalid_kind (location expr, [ String_kind ], kind expr)))
    (* Contracts *)
    | Contract_t (ty1, ty2), String (loc, s) ->
        traced @@
        (Lwt.return (Contract.of_b58check s)) >>=? fun c ->
        parse_contract ctxt ty1 ty2 loc c >>=? fun _ ->
        return (ty1, ty2, c)
    | Contract_t _, expr ->
        traced (fail (Invalid_kind (location expr, [ String_kind ], kind expr)))
    (* Pairs *)
    | Pair_t (ta, tb), Prim (_, "Pair", [ va; vb ], _) ->
        traced @@
        parse_data ?type_logger ctxt ta va >>=? fun va ->
        parse_data ?type_logger ctxt tb vb >>=? fun vb ->
        return (va, vb)
    | Pair_t _, Prim (loc, "Pair", l, _) ->
        fail @@ Invalid_arity (loc, "Pair", 2, List.length l)
    | Pair_t _, expr ->
        traced (fail (unexpected expr [] Constant_namespace [ "Pair" ]))
    (* Unions *)
    | Union_t (tl, _), Prim (_, "Left", [ v ], _) ->
        traced @@
        parse_data ?type_logger ctxt tl v >>=? fun v ->
        return (L v)
    | Union_t _, Prim (loc, "Left", l, _) ->
        fail @@ Invalid_arity (loc, "Left", 1, List.length l)
    | Union_t (_, tr), Prim (_, "Right", [ v ], _) ->
        traced @@
        parse_data ?type_logger ctxt tr v >>=? fun v ->
        return (R v)
    | Union_t _, Prim (loc, "Right", l, _) ->
        fail @@ Invalid_arity (loc, "Right", 1, List.length l)
    | Union_t _, expr ->
        traced (fail (unexpected expr [] Constant_namespace [ "Left" ; "Right" ]))
    (* Lambdas *)
    | Lambda_t (ta, tr), (Seq _ as script_instr) ->
        traced @@
        parse_lambda ?type_logger ctxt ta tr script_instr
    | Lambda_t _, expr ->
        traced (fail (Invalid_kind (location expr, [ Seq_kind ], kind expr)))
    (* Options *)
    | Option_t t, Prim (_, "Some", [ v ], _) ->
        traced @@
        parse_data ?type_logger ctxt t v >>=? fun v ->
        return (Some v)
    | Option_t _, Prim (loc, "Some", l, _) ->
        fail @@ Invalid_arity (loc, "Some", 1, List.length l)
    | Option_t _, Prim (_, "None", [], _) ->
        return None
    | Option_t _, Prim (loc, "None", l, _) ->
        fail @@ Invalid_arity (loc, "None", 0, List.length l)
    | Option_t _, expr ->
        traced (fail (unexpected expr [] Constant_namespace [ "Some" ; "None" ]))
    (* Lists *)
    | List_t t, Prim (_, "List", vs, _) ->
        traced @@
        fold_right_s
          (fun v rest ->
             parse_data ?type_logger ctxt t v >>=? fun v ->
             return (v :: rest))
          vs []
    | List_t _, expr ->
        traced (fail (unexpected expr [] Constant_namespace [ "List" ]))
    (* Sets *)
    | Set_t t, (Prim (loc, "Set", vs, _) as expr) ->
        fold_left_s
          (fun (last_value, set) v ->
             parse_comparable_data ?type_logger ctxt t v >>=? fun v ->
             begin match last_value with
              | Some value ->
                  if Compare.Int.(0 <= (compare_comparable t value v))
                  then
                    if Compare.Int.(0 = (compare_comparable t value v))
                    then fail (Duplicate_set_values (loc, expr))
                    else fail (Unordered_set_values (loc, expr))
                  else return ()
              | None -> return ()
             end >>=? fun () -> 
             return (Some v, set_update v true set))
          (None, empty_set t) vs >>|? snd |> traced
    | Set_t _, expr ->
        traced (fail (unexpected expr [] Constant_namespace [ "Set" ]))
    (* Maps *)
    | Map_t (tk, tv), (Prim (loc, "Map", vs, _) as expr) ->
        (fold_left_s
          (fun (last_value, map) -> function
             | Prim (_, "Item", [ k; v ], _) ->
                 parse_comparable_data ?type_logger ctxt tk k >>=? fun k ->
                 parse_data ?type_logger ctxt tv v >>=? fun v ->
                 begin match last_value with
                  | Some value ->
                      if Compare.Int.(0 <= (compare_comparable tk value k))
                      then
                        if Compare.Int.(0 = (compare_comparable tk value k))
                        then fail (Duplicate_map_keys (loc, expr))
                        else fail (Unordered_map_keys (loc, expr))
                      else return ()
                  | None -> return ()
                 end >>=? fun () ->
                 return (Some k, map_update k (Some v) map)
             | Prim (loc, "Item", l, _) ->
                 fail @@ Invalid_arity (loc, "Item", 2, List.length l)
             | Prim (loc, name, _, _) ->
                 fail @@ Invalid_primitive (loc, [ "Item" ], name)
             | Int _ | String _ | Seq _ ->
                 fail (error ()))
          (None, empty_map tk) vs) >>|? snd |> traced
    | Map_t _, expr ->
        traced (fail (unexpected expr [] Constant_namespace [ "Map" ]))

and parse_comparable_data
  : type a. ?type_logger:(int * (Script.expr list * Script.expr list) -> unit) ->
    context -> a comparable_ty -> Script.expr -> a tzresult Lwt.t
  = fun ?type_logger ctxt ty script_data ->
    parse_data ?type_logger ctxt (ty_of_comparable_ty ty) script_data

and parse_lambda
  : type arg ret storage. context ->
    ?storage_type: storage ty ->
    ?type_logger: (int * (Script.expr list * Script.expr list) -> unit) -> 
   arg ty -> ret ty -> Script.expr -> (arg, ret) lambda tzresult Lwt.t =
  fun ctxt ?storage_type ?type_logger arg ret script_instr ->
    parse_instr ctxt ?storage_type ?type_logger
      script_instr (Item_t (arg, Empty_t)) >>=? function
    | Typed ({ loc ; aft = (Item_t (ty, Empty_t) as stack_ty) } as descr) ->
        trace
          (Bad_return (loc, stack_ty, ret))
          (Lwt.return (ty_eq ty ret)) >>=? fun (Eq _) ->
        return (Lam (descr, script_instr) : (arg, ret) lambda)
    | Typed { loc ; aft = stack_ty } ->
        fail (Bad_return (loc, stack_ty, ret))
    | Failed { descr } ->
        return (Lam (descr (Item_t (ret, Empty_t)), script_instr) : (arg, ret) lambda)

and parse_instr
  : type bef storage. context ->
    ?storage_type: storage ty ->
    ?type_logger: (int * (Script.expr list * Script.expr list) -> unit) ->
    Script.expr -> bef stack_ty -> bef judgement tzresult Lwt.t =
  fun ctxt ?storage_type ?type_logger script_instr stack_ty ->
    let return : bef judgement -> bef judgement tzresult Lwt.t = return in
    let check_item check loc name n m =
      trace (Bad_stack (loc, name, m, stack_ty)) @@
      trace (Bad_stack_item n) @@
      Lwt.return check in
    let check_item_ty exp got loc n =
      check_item (ty_eq exp got) loc n in
    let typed loc annot (instr, aft) =
      begin match type_logger with
        | Some log -> log (loc, (unparse_stack stack_ty, unparse_stack aft))
        | None -> ()
      end ;
      Typed { loc ; instr ; bef = stack_ty ; aft ; annot } in
    match script_instr, stack_ty with
    (* stack ops *)
    | Prim (loc, "DROP", [], annot),
      Item_t (_, rest) ->
        return (typed loc annot (Drop, rest))
    | Prim (loc, "DUP", [], annot),
      Item_t (v, rest) ->
        return (typed loc annot (Dup, Item_t (v, Item_t (v, rest))))
    | Prim (loc, "SWAP", [], annot),
      Item_t (v,  Item_t (w, rest)) ->
        return (typed loc annot (Swap, Item_t (w, Item_t (v, rest))))
    | Prim (loc, "PUSH", [ t ; d ], annot),
      stack ->
        (Lwt.return (parse_ty t)) >>=? fun (Ex_ty t) ->
        parse_data ?type_logger ctxt t d >>=? fun v ->
        return (typed loc annot (Const v, Item_t (t, stack)))
    | Prim (loc, "UNIT", [], annot),
      stack ->
        return (typed loc annot (Const (), Item_t (Unit_t, stack)))
    (* options *)
    | Prim (loc, "SOME", [], annot),
      Item_t (t, rest) ->
        return (typed loc annot (Cons_some, Item_t (Option_t t, rest)))
    | Prim (loc, "NONE", [ t ], annot),
      stack ->
        (Lwt.return (parse_ty t)) >>=? fun (Ex_ty t) ->
        return (typed loc annot (Cons_none t, Item_t (Option_t t, stack)))
    | Prim (loc, "IF_NONE", [ bt ; bf ], annot),
      (Item_t (Option_t t, rest) as bef) ->
        check_kind [ Seq_kind ] bt >>=? fun () ->
        check_kind [ Seq_kind ] bf >>=? fun () ->
        parse_instr ?storage_type ?type_logger ctxt bt rest >>=? fun btr ->
        parse_instr ?storage_type ?type_logger ctxt bf (Item_t (t, rest)) >>=? fun bfr ->
        let branch ibt ibf =
          { loc ; instr = If_none (ibt, ibf) ; bef ; aft = ibt.aft ; annot } in
        merge_branches loc btr bfr { branch }
    (* pairs *)
    | Prim (loc, "PAIR", [], annot),
      Item_t (a, Item_t (b, rest)) ->
        return (typed loc annot (Cons_pair, Item_t (Pair_t(a, b), rest)))
    | Prim (loc, "CAR", [], annot),
      Item_t (Pair_t (a, _), rest) ->
        return (typed loc annot (Car, Item_t (a, rest)))
    | Prim (loc, "CDR", [], annot),
      Item_t (Pair_t (_, b), rest) ->
        return (typed loc annot (Cdr, Item_t (b, rest)))
    (* unions *)
    | Prim (loc, "LEFT", [ tr ], annot),
      Item_t (tl, rest) ->
        (Lwt.return (parse_ty tr)) >>=? fun (Ex_ty tr) ->
        return (typed loc annot (Left, Item_t (Union_t (tl, tr), rest)))
    | Prim (loc, "RIGHT", [ tl ], annot),
      Item_t (tr, rest) ->
        (Lwt.return (parse_ty tl)) >>=? fun (Ex_ty tl) ->
        return (typed loc annot (Right, Item_t (Union_t (tl, tr), rest)))
    | Prim (loc, "IF_LEFT", [ bt ; bf ], annot),
      (Item_t (Union_t (tl, tr), rest) as bef) ->
        check_kind [ Seq_kind ] bt >>=? fun () ->
        check_kind [ Seq_kind ] bf >>=? fun () ->
        parse_instr ?storage_type ?type_logger ctxt bt (Item_t (tl, rest)) >>=? fun btr ->
        parse_instr ?storage_type ?type_logger ctxt bf (Item_t (tr, rest)) >>=? fun bfr ->
        let branch ibt ibf =
          { loc ; instr = If_left (ibt, ibf) ; bef ; aft = ibt.aft ; annot } in
        merge_branches loc btr bfr { branch }
    (* lists *)
    | Prim (loc, "NIL", [ t ], annot),
      stack ->
        (Lwt.return (parse_ty t)) >>=? fun (Ex_ty t) ->
        return (typed loc annot (Nil, Item_t (List_t t, stack)))
    | Prim (loc, "CONS", [], annot),
      Item_t (tv, Item_t (List_t t, rest)) ->
        check_item_ty tv t loc "CONS" 1 2 >>=? fun (Eq _) ->
        return (typed loc annot (Cons_list, Item_t (List_t t, rest)))
    | Prim (loc, "IF_CONS", [ bt ; bf ], annot),
      (Item_t (List_t t, rest) as bef) ->
        check_kind [ Seq_kind ] bt >>=? fun () ->
        check_kind [ Seq_kind ] bf >>=? fun () ->
        parse_instr ?storage_type ?type_logger ctxt bt (Item_t (t, Item_t (List_t t, rest))) >>=? fun btr ->
        parse_instr ?storage_type ?type_logger ctxt bf rest >>=? fun bfr ->
        let branch ibt ibf =
          { loc ; instr = If_cons (ibt, ibf) ; bef ; aft = ibt.aft ; annot } in
        merge_branches loc btr bfr { branch }
    | Prim (loc, "MAP", [], annot),
      Item_t (Lambda_t (param, ret), Item_t (List_t elt, rest)) ->
        check_item_ty elt param loc "MAP" 2 2 >>=? fun (Eq _) ->
        return (typed loc annot (List_map, Item_t (List_t ret, rest)))
    | Prim (loc, "REDUCE", [], annot),
      Item_t (Lambda_t (Pair_t (pelt, pr), r),
              Item_t (List_t elt, Item_t (init, rest))) ->
        check_item_ty r pr loc "REDUCE" 1 3 >>=? fun (Eq _) ->
        check_item_ty elt pelt loc "REDUCE" 2 3 >>=? fun (Eq _) ->
        check_item_ty init r loc "REDUCE" 3 3 >>=? fun (Eq _) ->
        return (typed loc annot (List_reduce, Item_t (r, rest)))
    (* sets *)
    | Prim (loc, "EMPTY_SET", [ t ], annot),
      rest ->
        (Lwt.return (parse_comparable_ty t)) >>=? fun (Ex_comparable_ty t) ->
        return (typed loc annot (Empty_set t, Item_t (Set_t t, rest)))
    | Prim (loc, "MAP", [], annot),
      Item_t (Lambda_t (param, ret), Item_t (Set_t elt, rest)) ->
        let elt = ty_of_comparable_ty elt in
        (Lwt.return (comparable_ty_of_ty loc ret)) >>=? fun ret ->
        check_item_ty elt param loc "MAP" 1 2 >>=? fun (Eq _) ->
        return (typed loc annot (Set_map ret, Item_t (Set_t ret, rest)))
    | Prim (loc, "REDUCE", [], annot),
      Item_t (Lambda_t (Pair_t (pelt, pr), r),
              Item_t (Set_t elt, Item_t (init, rest))) ->
        let elt = ty_of_comparable_ty elt in
        check_item_ty r pr loc "REDUCE" 1 3 >>=? fun (Eq _) ->
        check_item_ty elt pelt loc "REDUCE" 2 3 >>=? fun (Eq _) ->
        check_item_ty init r loc "REDUCE" 3 3 >>=? fun (Eq _) ->
        return (typed loc annot (Set_reduce, Item_t (r, rest)))
    | Prim (loc, "MEM", [], annot),
      Item_t (v, Item_t (Set_t elt, rest)) ->
        let elt = ty_of_comparable_ty elt in
        check_item_ty elt v loc "MEM" 1 2 >>=? fun (Eq _) ->
        return (typed loc annot (Set_mem, Item_t (Bool_t, rest)))
    | Prim (loc, "UPDATE", [], annot),
      Item_t (v, Item_t (Bool_t, Item_t (Set_t elt, rest))) ->
        let ty = ty_of_comparable_ty elt in
        check_item_ty ty v loc "UPDATE" 1 3 >>=? fun (Eq _) ->
        return (typed loc annot (Set_update, Item_t (Set_t elt, rest)))
    | Prim (loc, "SIZE", [], annot),
      Item_t (Set_t _, rest) ->
        return (typed loc annot (Set_size, Item_t (Nat_t, rest)))
    (* maps *)
    | Prim (loc, "EMPTY_MAP", [ tk ; tv ], annot),
      stack ->
        (Lwt.return (parse_comparable_ty tk)) >>=? fun (Ex_comparable_ty tk) ->
        (Lwt.return (parse_ty tv)) >>=? fun (Ex_ty tv) ->
        return (typed loc annot (Empty_map (tk, tv), Item_t (Map_t (tk, tv), stack)))
    | Prim (loc, "MAP", [], annot),
      Item_t (Lambda_t (Pair_t (pk, pv), ret), Item_t (Map_t (ck, v), rest)) ->
        let k = ty_of_comparable_ty ck in
        check_item_ty pk k loc "MAP" 1 2 >>=? fun (Eq _) ->
        check_item_ty pv v loc "MAP" 1 2 >>=? fun (Eq _) ->
        return (typed loc annot (Map_map, Item_t (Map_t (ck, ret), rest)))
    | Prim (loc, "REDUCE", [], annot),
      Item_t (Lambda_t (Pair_t (Pair_t (pk, pv), pr), r),
              Item_t (Map_t (ck, v), Item_t (init, rest))) ->
        let k = ty_of_comparable_ty ck in
        check_item_ty pk k loc "REDUCE" 2 3 >>=? fun (Eq _) ->
        check_item_ty pv v loc "REDUCE" 2 3 >>=? fun (Eq _) ->
        check_item_ty r pr loc "REDUCE" 1 3 >>=? fun (Eq _) ->
        check_item_ty init r loc "REDUCE" 3 3 >>=? fun (Eq _) ->
        return (typed loc annot (Map_reduce, Item_t (r, rest)))
    | Prim (loc, "MEM", [], annot),
      Item_t (vk, Item_t (Map_t (ck, _), rest)) ->
        let k = ty_of_comparable_ty ck in
        check_item_ty vk k loc "MEM" 1 2 >>=? fun (Eq _) ->
        return (typed loc annot (Map_mem, Item_t (Bool_t, rest)))
    | Prim (loc, "GET", [], annot),
      Item_t (vk, Item_t (Map_t (ck, elt), rest)) ->
        let k = ty_of_comparable_ty ck in
        check_item_ty vk k loc "GET" 1 2 >>=? fun (Eq _) ->
        return (typed loc annot (Map_get, Item_t (Option_t elt, rest)))
    | Prim (loc, "UPDATE", [], annot),
      Item_t (vk, Item_t (Option_t vv, Item_t (Map_t (ck, v), rest))) ->
        let k = ty_of_comparable_ty ck in
        check_item_ty vk k loc "UPDATE" 1 3 >>=? fun (Eq _) ->
        check_item_ty vv v loc "UPDATE" 2 3 >>=? fun (Eq _) ->
        return (typed loc annot (Map_update, Item_t (Map_t (ck, v), rest)))
    | Prim (loc, "SIZE", [], annot),
      Item_t (Map_t (_, _), rest) ->
        return (typed loc annot (Map_size, Item_t (Nat_t, rest)))
    (* control *)
    | Seq (loc, [], annot),
      stack ->
        return (typed loc annot (Nop, stack))
    | Seq (_, [ single ], None),
      stack ->
        parse_instr ?storage_type ?type_logger ctxt single stack
    | Seq (loc, [ single ], (Some _ as annot)),
      stack ->
        parse_instr ?storage_type ?type_logger ctxt single stack >>=? begin function
          | Typed ({ aft } as instr) ->
              let nop = { bef = aft ; loc = loc ; aft ; annot = None ; instr = Nop } in
              return (typed loc annot (Seq (instr, nop), aft))
          | Failed { descr } ->
              let descr aft =
                let nop = { bef = aft ; loc = loc ; aft ; annot = None ; instr = Nop } in
                let descr = descr aft in
                { descr with instr = Seq (descr, nop) ; annot } in
              return (Failed { descr })
        end
    | Seq (loc, hd :: tl, annot),
      stack ->
        parse_instr ?storage_type ?type_logger ctxt hd stack >>=? begin function
          | Failed _ ->
              fail (Fail_not_in_tail_position loc)
          | Typed ({ aft = middle } as ihd) ->
              parse_instr ?storage_type ?type_logger ctxt (Seq (loc, tl, annot)) middle >>=? function
              | Failed { descr } ->
                  let descr ret =
                    { loc ; instr = Seq (ihd, descr ret) ;
                      bef = stack ; aft = ret ; annot = None } in
                  return (Failed { descr })
              | Typed itl ->
                  return (typed loc annot (Seq (ihd, itl), itl.aft))
        end
    | Prim (loc, "IF", [ bt ; bf ], annot),
      (Item_t (Bool_t, rest) as bef) ->
        check_kind [ Seq_kind ] bt >>=? fun () ->
        check_kind [ Seq_kind ] bf >>=? fun () ->
        parse_instr ?storage_type ?type_logger ctxt bt rest >>=? fun btr ->
        parse_instr ?storage_type ?type_logger ctxt bf rest >>=? fun bfr ->
        let branch ibt ibf =
          { loc ; instr = If (ibt, ibf) ; bef ; aft = ibt.aft ; annot } in
        merge_branches loc btr bfr { branch }
    | Prim (loc, "LOOP", [ body ], annot),
      (Item_t (Bool_t, rest) as stack) ->
        check_kind [ Seq_kind ] body >>=? fun () ->
        parse_instr ?storage_type ?type_logger ctxt body rest >>=? begin function
          | Typed ibody ->
              trace
                (Unmatched_branches (loc, ibody.aft, stack))
                (Lwt.return (stack_ty_eq 1 ibody.aft stack)) >>=? fun (Eq _) ->
              return (typed loc annot (Loop ibody, rest))
          | Failed { descr } ->
              let ibody = descr (Item_t (Bool_t, rest)) in
              return (typed loc annot (Loop ibody, rest))
        end
    | Prim (loc, "LAMBDA", [ arg ; ret ; code ], annot),
      stack ->
        (Lwt.return (parse_ty arg)) >>=? fun (Ex_ty arg) ->
        (Lwt.return (parse_ty ret)) >>=? fun (Ex_ty ret) ->
        check_kind [ Seq_kind ] code >>=? fun () ->
        parse_lambda ?type_logger ctxt arg ret code >>=? fun lambda ->
        return (typed loc annot (Lambda lambda, Item_t (Lambda_t (arg, ret), stack)))
    | Prim (loc, "EXEC", [], annot),
      Item_t (arg, Item_t (Lambda_t (param, ret), rest)) ->
        check_item_ty arg param loc "EXEC" 1 2 >>=? fun (Eq _) ->
        return (typed loc annot (Exec, Item_t (ret, rest)))
    | Prim (loc, "DIP", [ code ], annot),
      Item_t (v, rest) ->
        check_kind [ Seq_kind ] code >>=? fun () ->
        parse_instr ?type_logger ctxt code rest >>=? begin function
          | Typed descr ->
              return (typed loc annot (Dip descr, Item_t (v, descr.aft)))
          | Failed _ ->
              fail (Fail_not_in_tail_position loc)
        end
    | Prim (loc, "FAIL", [], annot),
      bef ->
        let descr aft = { loc ; instr = Fail ; bef ; aft ; annot } in
        return (Failed { descr })
    (* timestamp operations *)
    | Prim (loc, "ADD", [], annot),
      Item_t (Timestamp_t, Item_t (Nat_t, rest)) ->
        return (typed loc annot (Add_timestamp_to_seconds, Item_t (Timestamp_t, rest)))
    | Prim (loc, "ADD", [], annot),
      Item_t (Nat_t, Item_t (Timestamp_t, rest)) ->
        return (typed loc annot (Add_seconds_to_timestamp, Item_t (Timestamp_t, rest)))
    (* string operations *)
    | Prim (loc, "CONCAT", [], annot),
      Item_t (String_t, Item_t (String_t, rest)) ->
        return (typed loc annot (Concat, Item_t (String_t, rest)))
    (* currency operations *)
    | Prim (loc, "ADD", [], annot),
      Item_t (Tez_t, Item_t (Tez_t, rest)) ->
        return (typed loc annot (Add_tez, Item_t (Tez_t, rest)))
    | Prim (loc, "SUB", [], annot),
      Item_t (Tez_t, Item_t (Tez_t, rest)) ->
        return (typed loc annot (Sub_tez, Item_t (Tez_t, rest)))
    | Prim (loc, "MUL", [], annot),
      Item_t (Tez_t, Item_t (Nat_t, rest)) ->
        return (typed loc annot (Mul_teznat, Item_t (Tez_t, rest)))
    | Prim (loc, "MUL", [], annot),
      Item_t (Nat_t, Item_t (Tez_t, rest)) ->
        return (typed loc annot (Mul_nattez, Item_t (Tez_t, rest)))
    (* boolean operations *)
    | Prim (loc, "OR", [], annot),
      Item_t (Bool_t, Item_t (Bool_t, rest)) ->
        return (typed loc annot (Or, Item_t (Bool_t, rest)))
    | Prim (loc, "AND", [], annot),
      Item_t (Bool_t, Item_t (Bool_t, rest)) ->
        return (typed loc annot (And, Item_t (Bool_t, rest)))
    | Prim (loc, "XOR", [], annot),
      Item_t (Bool_t, Item_t (Bool_t, rest)) ->
        return (typed loc annot (Xor, Item_t (Bool_t, rest)))
    | Prim (loc, "NOT", [], annot),
      Item_t (Bool_t, rest) ->
        return (typed loc annot (Not, Item_t (Bool_t, rest)))
    (* integer operations *)
    | Prim (loc, "ABS", [], annot),
      Item_t (Int_t, rest) ->
        return (typed loc annot (Abs_int, Item_t (Nat_t, rest)))
    | Prim (loc, "INT", [], annot),
      Item_t (Nat_t, rest) ->
        return (typed loc annot (Int_nat, Item_t (Int_t, rest)))
    | Prim (loc, "NEG", [], annot),
      Item_t (Int_t, rest) ->
        return (typed loc annot (Neg_int, Item_t (Int_t, rest)))
    | Prim (loc, "NEG", [], annot),
      Item_t (Nat_t, rest) ->
        return (typed loc annot (Neg_nat, Item_t (Int_t, rest)))
    | Prim (loc, "ADD", [], annot),
      Item_t (Int_t, Item_t (Int_t, rest)) ->
        return (typed loc annot (Add_intint, Item_t (Int_t, rest)))
    | Prim (loc, "ADD", [], annot),
      Item_t (Int_t, Item_t (Nat_t, rest)) ->
        return (typed loc annot (Add_intnat, Item_t (Int_t, rest)))
    | Prim (loc, "ADD", [], annot),
      Item_t (Nat_t, Item_t (Int_t, rest)) ->
        return (typed loc annot (Add_natint, Item_t (Int_t, rest)))
    | Prim (loc, "ADD", [], annot),
      Item_t (Nat_t, Item_t (Nat_t, rest)) ->
        return (typed loc annot (Add_natnat, Item_t (Nat_t, rest)))
    | Prim (loc, "SUB", [], annot),
      Item_t (Int_t, Item_t (Int_t, rest)) ->
        return (typed loc annot (Sub_int, Item_t (Int_t, rest)))
    | Prim (loc, "SUB", [], annot),
      Item_t (Int_t, Item_t (Nat_t, rest)) ->
        return (typed loc annot (Sub_int, Item_t (Int_t, rest)))
    | Prim (loc, "SUB", [], annot),
      Item_t (Nat_t, Item_t (Int_t, rest)) ->
        return (typed loc annot (Sub_int, Item_t (Int_t, rest)))
    | Prim (loc, "SUB", [], annot),
      Item_t (Nat_t, Item_t (Nat_t, rest)) ->
        return (typed loc annot (Sub_int, Item_t (Int_t, rest)))
    | Prim (loc, "MUL", [], annot),
      Item_t (Int_t, Item_t (Int_t, rest)) ->
        return (typed loc annot (Mul_intint, Item_t (Int_t, rest)))
    | Prim (loc, "MUL", [], annot),
      Item_t (Int_t, Item_t (Nat_t, rest)) ->
        return (typed loc annot (Mul_intnat, Item_t (Int_t, rest)))
    | Prim (loc, "MUL", [], annot),
      Item_t (Nat_t, Item_t (Int_t, rest)) ->
        return (typed loc annot (Mul_natint, Item_t (Int_t, rest)))
    | Prim (loc, "MUL", [], annot),
      Item_t (Nat_t, Item_t (Nat_t, rest)) ->
        return (typed loc annot (Mul_natnat, Item_t (Nat_t, rest)))
    | Prim (loc, "EDIV", [], annot),
      Item_t (Tez_t, Item_t (Nat_t, rest)) ->
        return (typed loc annot (Ediv_teznat,
               Item_t (Option_t (Pair_t (Tez_t,Tez_t)), rest)))
    | Prim (loc, "EDIV", [], annot),
      Item_t (Tez_t, Item_t (Tez_t, rest)) ->
        return (typed loc annot (Ediv_tez,
               Item_t (Option_t (Pair_t (Nat_t,Tez_t)), rest)))
    | Prim (loc, "EDIV", [], annot),
      Item_t (Int_t, Item_t (Int_t, rest)) ->
        return (typed loc annot (Ediv_intint,
               Item_t (Option_t (Pair_t (Int_t,Nat_t)), rest)))
    | Prim (loc, "EDIV", [], annot),
      Item_t (Int_t, Item_t (Nat_t, rest)) ->
        return (typed loc annot (Ediv_intnat,
               Item_t (Option_t (Pair_t (Int_t,Nat_t)), rest)))
    | Prim (loc, "EDIV", [], annot),
      Item_t (Nat_t, Item_t (Int_t, rest)) ->
        return (typed loc annot (Ediv_natint,
               Item_t (Option_t (Pair_t (Int_t,Nat_t)), rest)))
    | Prim (loc, "EDIV", [], annot),
      Item_t (Nat_t, Item_t (Nat_t, rest)) ->
        return (typed loc annot (Ediv_natnat,
               Item_t (Option_t (Pair_t (Nat_t,Nat_t)), rest)))
    | Prim (loc, "LSL", [], annot),
      Item_t (Nat_t, Item_t (Nat_t, rest)) ->
        return (typed loc annot (Lsl_nat, Item_t (Nat_t, rest)))
    | Prim (loc, "LSR", [], annot),
      Item_t (Nat_t, Item_t (Nat_t, rest)) ->
        return (typed loc annot (Lsr_nat, Item_t (Nat_t, rest)))
    | Prim (loc, "OR", [], annot),
      Item_t (Nat_t, Item_t (Nat_t, rest)) ->
        return (typed loc annot (Or_nat, Item_t (Nat_t, rest)))
    | Prim (loc, "AND", [], annot),
      Item_t (Nat_t, Item_t (Nat_t, rest)) ->
        return (typed loc annot (And_nat, Item_t (Nat_t, rest)))
    | Prim (loc, "XOR", [], annot),
      Item_t (Nat_t, Item_t (Nat_t, rest)) ->
        return (typed loc annot (Xor_nat, Item_t (Nat_t, rest)))
    | Prim (loc, "NOT", [], annot),
      Item_t (Int_t, rest) ->
        return (typed loc annot (Not_int, Item_t (Int_t, rest)))
    | Prim (loc, "NOT", [], annot),
      Item_t (Nat_t, rest) ->
        return (typed loc annot (Not_nat, Item_t (Int_t, rest)))
    (* comparison *)
    | Prim (loc, "COMPARE", [], annot),
      Item_t (Int_t, Item_t (Int_t, rest)) ->
        return (typed loc annot (Compare Int_key, Item_t (Int_t, rest)))
    | Prim (loc, "COMPARE", [], annot),
      Item_t (Nat_t, Item_t (Nat_t, rest)) ->
        return (typed loc annot (Compare Nat_key, Item_t (Int_t, rest)))
    | Prim (loc, "COMPARE", [], annot),
      Item_t (Bool_t, Item_t (Bool_t, rest)) ->
        return (typed loc annot (Compare Bool_key, Item_t (Int_t, rest)))
    | Prim (loc, "COMPARE", [], annot),
      Item_t (String_t, Item_t (String_t, rest)) ->
        return (typed loc annot (Compare String_key, Item_t (Int_t, rest)))
    | Prim (loc, "COMPARE", [], annot),
      Item_t (Tez_t, Item_t (Tez_t, rest)) ->
        return (typed loc annot (Compare Tez_key, Item_t (Int_t, rest)))
    | Prim (loc, "COMPARE", [], annot),
      Item_t (Key_hash_t, Item_t (Key_hash_t, rest)) ->
        return (typed loc annot (Compare Key_hash_key, Item_t (Int_t, rest)))
    | Prim (loc, "COMPARE", [], annot),
      Item_t (Timestamp_t, Item_t (Timestamp_t, rest)) ->
        return (typed loc annot (Compare Timestamp_key, Item_t (Int_t, rest)))
    (* comparators *)
    | Prim (loc, "EQ", [], annot),
      Item_t (Int_t, rest) ->
        return (typed loc annot (Eq, Item_t (Bool_t, rest)))
    | Prim (loc, "NEQ", [], annot),
      Item_t (Int_t, rest) ->
        return (typed loc annot (Neq, Item_t (Bool_t, rest)))
    | Prim (loc, "LT", [], annot),
      Item_t (Int_t, rest) ->
        return (typed loc annot (Lt, Item_t (Bool_t, rest)))
    | Prim (loc, "GT", [], annot),
      Item_t (Int_t, rest) ->
        return (typed loc annot (Gt, Item_t (Bool_t, rest)))
    | Prim (loc, "LE", [], annot),
      Item_t (Int_t, rest) ->
        return (typed loc annot (Le, Item_t (Bool_t, rest)))
    | Prim (loc, "GE", [], annot),
      Item_t (Int_t, rest) ->
        return (typed loc annot (Ge, Item_t (Bool_t, rest)))
    (* protocol *)
    | Prim (loc, "MANAGER", [], annot),
      Item_t (Contract_t _, rest) ->
        return (typed loc annot (Manager, Item_t (Key_hash_t, rest)))
    | Prim (loc, "TRANSFER_TOKENS", [], annot),
      Item_t (p, Item_t
                (Tez_t, Item_t
                   (Contract_t (cp, cr), Item_t
                      (storage, Empty_t)))) ->
        check_item_ty p cp loc "TRANSFER_TOKENS" 1 4 >>=? fun (Eq _) ->
        begin match storage_type with
          | Some storage_type ->
              check_item_ty storage storage_type loc "TRANSFER_TOKENS" 3 4 >>=? fun (Eq _) ->
              return (typed loc annot (Transfer_tokens storage,
                                 Item_t (cr, Item_t (storage, Empty_t))))
          | None ->
              fail (Transfer_in_lambda loc)
        end
    | Prim (loc, "CREATE_ACCOUNT", [], annot),
      Item_t
        (Key_hash_t, Item_t
           (Option_t Key_hash_t, Item_t
              (Bool_t, Item_t
                 (Tez_t, rest)))) ->
        return (typed loc annot (Create_account,
                           Item_t (Contract_t (Unit_t, Unit_t), rest)))
    | Prim (loc, "DEFAULT_ACCOUNT", [], annot),
      Item_t (Key_hash_t, rest) ->
        return
          (typed loc annot (Default_account, Item_t (Contract_t (Unit_t, Unit_t), rest)))
    | Prim (loc, "CREATE_CONTRACT", [], annot),
      Item_t
        (Key_hash_t, Item_t
           (Option_t Key_hash_t, Item_t
              (Bool_t, Item_t
                 (Bool_t, Item_t
                    (Tez_t, Item_t
                       (Lambda_t (Pair_t (p, gp),
                                  Pair_t (r, gr)), Item_t
                          (ginit, rest))))))) ->
        check_item_ty gp gr loc "CREATE_CONTRACT" 5 7 >>=? fun (Eq _) ->
        check_item_ty ginit gp loc "CREATE_CONTRACT" 6 7 >>=? fun (Eq _) ->
        return (typed loc annot (Create_contract (gp, p, r),
                           Item_t (Contract_t (p, r), rest)))
    | Prim (loc, "NOW", [], annot),
      stack ->
        return (typed loc annot (Now, Item_t (Timestamp_t, stack)))
    | Prim (loc, "AMOUNT", [], annot),
      stack ->
        return (typed loc annot (Amount, Item_t (Tez_t, stack)))
    | Prim (loc, "BALANCE", [], annot),
      stack ->
        return (typed loc annot (Balance, Item_t (Tez_t, stack)))
    | Prim (loc, "HASH_KEY", [], annot),
      Item_t (Key_t, rest) ->
        return (typed loc annot (Hash_key, Item_t (Key_hash_t, rest)))
    | Prim (loc, "CHECK_SIGNATURE", [], annot),
      Item_t (Key_t, Item_t (Pair_t (Signature_t, String_t), rest)) ->
        return (typed loc annot (Check_signature, Item_t (Bool_t, rest)))
    | Prim (loc, "H", [], annot),
      Item_t (t, rest) ->
        return (typed loc annot (H t, Item_t (String_t, rest)))
    | Prim (loc, "STEPS_TO_QUOTA", [], annot),
      stack ->
        return (typed loc annot (Steps_to_quota, Item_t (Nat_t, stack)))
    | Prim (loc, "SOURCE", [ ta; tb ], annot),
      stack ->
        (Lwt.return (parse_ty ta)) >>=? fun (Ex_ty ta) ->
        (Lwt.return (parse_ty tb)) >>=? fun (Ex_ty tb) ->
        return (typed loc annot (Source (ta, tb), Item_t (Contract_t (ta, tb), stack)))
    (* Primitive parsing errors *)
    | Prim (loc, ("DROP" | "DUP" | "SWAP" | "SOME" | "UNIT"
                 | "PAIR" | "CAR" | "CDR" | "CONS"
                 | "MEM" | "UPDATE" | "MAP" | "REDUCE"
                 | "GET" | "EXEC" | "FAIL" | "SIZE"
                 | "CONCAT" | "ADD" | "SUB"
                 | "MUL" | "EDIV" | "OR" | "AND" | "XOR"
                 | "NOT"
                 | "ABS" | "NEG" | "LSL" | "LSR"
                 | "COMPARE" | "EQ" | "NEQ"
                 | "LT" | "GT" | "LE" | "GE"
                 | "MANAGER" | "TRANSFER_TOKENS" | "CREATE_ACCOUNT"
                 | "CREATE_CONTRACT" | "NOW"
                 | "DEFAULT_ACCOUNT" | "AMOUNT" | "BALANCE"
                 | "CHECK_SIGNATURE" | "HASH_KEY"
                 | "H" | "STEPS_TO_QUOTA"
                 as name), (_ :: _ as l), _), _ ->
        fail (Invalid_arity (loc, name, 0, List.length l))
    | Prim (loc, ("NONE" | "LEFT" | "RIGHT" | "NIL"
                 | "EMPTY_SET" | "DIP" | "LOOP"
                 as name), ([]
                           | _ :: _ :: _ as l), _), _ ->
        fail (Invalid_arity (loc, name, 1, List.length l))
    | Prim (loc, ("PUSH" | "IF_NONE" | "IF_LEFT" | "IF_CONS"
                 | "EMPTY_MAP" | "IF" | "SOURCE"
                 as name), ([] | [ _ ]
                           | _ :: _ :: _ :: _ as l), _), _ ->
        fail (Invalid_arity (loc, name, 2, List.length l))
    | Prim (loc, "LAMBDA", ([] | [ _ ] | [ _ ; _ ]
                           | _ :: _ :: _ :: _ :: _ as l), _), _ ->
        fail (Invalid_arity (loc, "LAMBDA", 3, List.length l))
    (* Stack errors *)
    | Prim (loc, ("ADD" | "SUB" | "MUL" | "EDIV"
                 | "AND" | "OR" | "XOR" | "LSL" | "LSR"
                 | "CONCAT" | "COMPARE" as name), [], _),
      Item_t (ta, Item_t (tb, _)) ->
        fail (Undefined_binop (loc, name, ta, tb))
    | Prim (loc, ("NEG" | "ABS" | "NOT"
                 | "EQ" | "NEQ" | "LT" | "GT" | "LE" | "GE" as name),
            [], _),
      Item_t (t, _) ->
        fail (Undefined_unop (loc, name, t))
    | Prim (loc, ("REDUCE" | "UPDATE" as name), [], _),
      stack ->
        fail (Bad_stack (loc, name, 3, stack))
    | Prim (loc, "CREATE_CONTRACT", [], _),
      stack ->
        fail (Bad_stack (loc, "CREATE_CONTRACT", 7, stack))
    | Prim (loc, "CREATE_ACCOUNT", [], _),
      stack ->
        fail (Bad_stack (loc, "CREATE_ACCOUNT", 4, stack))
    | Prim (loc, "TRANSFER_TOKENS", [], _),
      stack ->
        fail (Bad_stack (loc, "TRANSFER_TOKENS", 3, stack))
    | Prim (loc, ("DROP" | "DUP" | "CAR" | "CDR" | "SOME" | "H" | "DIP"
                 | "IF_NONE" | "LEFT" | "RIGHT" | "IF_LEFT" | "IF"
                 | "LOOP" | "IF_CONS" | "MANAGER" | "DEFAULT_ACCOUNT"
                 | "NEG" | "ABS" | "INT" | "NOT"
                 | "EQ" | "NEQ" | "LT" | "GT" | "LE" | "GE" as name), _, _),
      stack ->
        fail (Bad_stack (loc, name, 1, stack))
    | Prim (loc, ("SWAP" | "PAIR" | "CONS"
                 | "MAP" | "GET" | "MEM" | "EXEC"
                 | "CHECK_SIGNATURE" | "ADD" | "SUB" | "MUL"
                 | "EDIV" | "AND" | "OR" | "XOR"
                 | "LSL" | "LSR" | "CONCAT" as name), _, _),
      stack ->
        fail (Bad_stack (loc, name, 2, stack))
    (* Generic parsing errors *)
    | expr, _ ->
        fail @@ unexpected expr [ Seq_kind ] Instr_namespace
          [ "DROP" ; "DUP" ; "SWAP" ; "SOME" ; "UNIT" ;
            "PAIR" ; "CAR" ; "CDR" ; "CONS" ;
            "MEM" ; "UPDATE" ; "MAP" ; "REDUCE" ;
            "GET" ; "EXEC" ; "FAIL" ; "SIZE" ;
            "CONCAT" ; "ADD" ; "SUB" ;
            "MUL" ; "EDIV" ; "OR" ; "AND" ; "XOR" ;
            "NOT" ;
            "ABS" ; "INT"; "NEG" ; "LSL" ; "LSR" ;
            "COMPARE" ; "EQ" ; "NEQ" ;
            "LT" ; "GT" ; "LE" ; "GE" ;
            "MANAGER" ; "TRANSFER_TOKENS" ; "CREATE_ACCOUNT" ;
            "CREATE_CONTRACT" ; "NOW" ; "AMOUNT" ; "BALANCE" ;
            "DEFAULT_ACCOUNT" ; "CHECK_SIGNATURE" ; "H" ; "HASH_KEY" ;
            "STEPS_TO_QUOTA" ;
            "PUSH" ; "NONE" ; "LEFT" ; "RIGHT" ; "NIL" ;
            "EMPTY_SET" ; "DIP" ; "LOOP" ;
            "IF_NONE" ; "IF_LEFT" ; "IF_CONS" ;
            "EMPTY_MAP" ; "IF" ; "SOURCE" ; "LAMBDA" ]

and parse_contract
  : type arg ret. context -> arg ty -> ret ty -> Script.location -> Contract.t ->
    (arg, ret) typed_contract tzresult Lwt.t
  = fun ctxt arg ret loc contract ->
    Contract.exists ctxt contract >>=? function
    | false -> fail (Invalid_contract (loc, contract))
    | true ->
        trace
          (Invalid_contract (loc, contract)) @@
        Contract.get_script ctxt contract >>=? function
        | None ->
            Lwt.return
              (ty_eq arg Unit_t >>? fun (Eq _) ->
               ty_eq ret Unit_t >>? fun (Eq _) ->
               let contract : (arg, ret) typed_contract =
                 (arg, ret, contract) in
               ok contract)
        | Some { code = { arg_type; ret_type} } ->
            Lwt.return
              (parse_ty arg_type >>? fun (Ex_ty targ) ->
               parse_ty ret_type >>? fun (Ex_ty tret) ->
               ty_eq targ arg >>? fun (Eq _) ->
               ty_eq tret ret >>? fun (Eq _) ->
               let contract : (arg, ret) typed_contract =
                 (arg, ret, contract) in
               ok contract)

type ex_script = Ex_script : ('a, 'b, 'c) script -> ex_script

let parse_script
  : ?type_logger: (int * (Script.expr list * Script.expr list) -> unit) ->
  context -> Script.storage -> Script.code -> ex_script tzresult Lwt.t
  = fun ?type_logger ctxt
    { storage; storage_type = init_storage_type }
    { code; arg_type; ret_type; storage_type } ->
    trace
      (Ill_formed_type (Some "parameter", arg_type))
      (Lwt.return (parse_ty arg_type)) >>=? fun (Ex_ty arg_type) ->
    trace
      (Ill_formed_type (Some "return", ret_type))
      (Lwt.return (parse_ty ret_type)) >>=? fun (Ex_ty ret_type) ->
    trace
      (Ill_formed_type (Some "initial storage", init_storage_type))
      (Lwt.return (parse_ty init_storage_type)) >>=? fun (Ex_ty init_storage_type) ->
    trace
      (Ill_formed_type (Some "storage", storage_type))
      (Lwt.return (parse_ty storage_type)) >>=? fun (Ex_ty storage_type) ->
    let arg_type_full = Pair_t (arg_type, storage_type) in
    let ret_type_full = Pair_t (ret_type, storage_type) in
    Lwt.return (ty_eq init_storage_type storage_type) >>=? fun (Eq _) ->
    trace
      (Ill_typed_data (None, storage, storage_type))
      (parse_data ?type_logger ctxt storage_type storage) >>=? fun storage ->
    trace
      (Ill_typed_contract (code, arg_type, ret_type, storage_type, []))
      (parse_lambda ctxt ~storage_type ?type_logger arg_type_full ret_type_full code) >>=? fun code ->
    return (Ex_script { code; arg_type; ret_type; storage; storage_type })

let type_map_enc =
  let open Data_encoding in
  list
    (tup2
       int31
       (tup2
          (list Script.expr_encoding)
          (list Script.expr_encoding)))

let type_map descr =
  let rec instr_type_map
    : type bef aft. type_map -> (bef, aft) descr -> type_map
    = fun acc { loc ; instr ; bef ; aft } ->
      let self acc =
        (loc, (unparse_stack bef, unparse_stack aft)) :: acc in
      match instr, aft with
      | If_none (dbt, dbf), _ ->
          let acc = instr_type_map acc dbt in
          let acc = instr_type_map acc dbf in
          self acc
      | If_left (dbt, dbf), _ ->
          let acc = instr_type_map acc dbt in
          let acc = instr_type_map acc dbf in
          self acc
      | If_cons (dbt, dbf), _ ->
          let acc = instr_type_map acc dbt in
          let acc = instr_type_map acc dbf in
          self acc
      | Seq (dl, dr), _ ->
          let acc = instr_type_map acc dl in
          let acc = instr_type_map acc dr in
          acc
      | If (dbt, dbf), _ ->
          let acc = instr_type_map acc dbt in
          let acc = instr_type_map acc dbf in
          self acc
      | Loop body, _ ->
          let acc = instr_type_map acc body in
          self acc
      | Dip body, _ ->
          let acc = instr_type_map acc body in
          self acc
      | Lambda (Lam (body, _)), _ ->
          let acc = instr_type_map acc body in
          self acc
      | Const v, Item_t (ty, _) ->
          let acc = data_type_map acc ty v in
          self acc
      | _, _ ->
          self acc
  and data_type_map
    : type a. type_map -> a ty -> a -> type_map
    = fun acc ty v ->
      match ty, v with
      | Unit_t, _ -> acc
      | Int_t, _ -> acc
      | Nat_t, _ -> acc
      | Signature_t, _ -> acc
      | String_t, _ -> acc
      | Tez_t, _ -> acc
      | Key_t, _ -> acc
      | Key_hash_t, _ -> acc
      | Timestamp_t, _ -> acc
      | Bool_t, _ -> acc
      | Contract_t _,_ -> acc
      | Set_t _, _ -> acc
      | Pair_t (lty, rty), (l, r) ->
          let acc = data_type_map acc lty l in
          let acc = data_type_map acc rty r in
          acc
      | Union_t (lty, _), L l ->
          data_type_map acc lty l
      | Union_t (_, rty), R r ->
          data_type_map acc rty r
      | Lambda_t _, Lam (body, _) ->
          instr_type_map acc body
      | Option_t _, None -> acc
      | Option_t ty, Some v ->
          data_type_map acc ty v
      | List_t ty, l ->
          List.fold_left
            (fun acc v -> data_type_map acc ty v)
            acc l
      | Map_t (_, ty), m ->
          map_fold
            (fun _ v acc -> data_type_map acc ty v)
            m acc in
  instr_type_map [] descr

let typecheck_code
  : context -> Script.code -> type_map tzresult Lwt.t
  = fun ctxt { code; arg_type; ret_type; storage_type } ->
    let failure_type_map = ref [] in
    trace
      (Ill_formed_type (Some "parameter", arg_type))
      (Lwt.return (parse_ty arg_type)) >>=? fun (Ex_ty arg_type) ->
    trace
      (Ill_formed_type (Some "return", ret_type))
      (Lwt.return (parse_ty ret_type)) >>=? fun (Ex_ty ret_type) ->
    trace
      (Ill_formed_type (Some "storage", storage_type))
      (Lwt.return (parse_ty storage_type)) >>=? fun (Ex_ty storage_type) ->
    let arg_type_full = Pair_t (arg_type, storage_type) in
    let ret_type_full = Pair_t (ret_type, storage_type) in
    let result =
      parse_lambda ctxt
        ~storage_type
        ~type_logger:(fun x -> failure_type_map := x :: !failure_type_map)
        arg_type_full ret_type_full
        code in
    trace
      (Ill_typed_contract (code, arg_type, ret_type, storage_type, !failure_type_map))
      result >>=? fun (Lam (descr,_)) ->
    return (type_map descr)

let typecheck_data
  : ?type_logger: (int * (Script.expr list * Script.expr list) -> unit) ->
  context -> Script.expr * Script.expr -> unit tzresult Lwt.t
  = fun ?type_logger ctxt (data, exp_ty) ->
    trace
      (Ill_formed_type (None, exp_ty))
      (Lwt.return (parse_ty exp_ty)) >>=? fun (Ex_ty exp_ty) ->
    trace
      (Ill_typed_data (None, data, exp_ty))
      (parse_data ?type_logger ctxt exp_ty data) >>=? fun _ ->
    return ()

(* ---- Error registration --------------------------------------------------*)

let ex_ty_enc =
    Data_encoding.conv
      (fun (Ex_ty ty) -> unparse_ty ty)
      (fun expr ->
         match parse_ty expr with
         | Ok (Ex_ty ty) -> Ex_ty ty
         | _ -> Ex_ty Unit_t (* FIXME: ? *))
      Script.expr_encoding

let () =
  let open Data_encoding in
  let located enc =
    merge_objs
      (obj1 (req "location" Script.location_encoding))
      enc in
  let arity_enc =
    int8 in
  let namespace_enc =
    def "primitiveNamespace" @@
    describe
      ~title: "Primitive namespace"
      ~description:
        "One of the three possible namespaces of primitive \
         (data constructor, type name or instruction)." @@
    string_enum [ "type", Type_namespace ;
                  "constant", Constant_namespace ;
                  "instruction", Instr_namespace ] in
  let kind_enc =
    def "primitiveNamespace" @@
    describe
      ~title: "Expression kind"
      ~description:
        "One of the four possible kinds of expression \
         (integer, string, primitive application or sequence)." @@
    string_enum [ "integer", Int_kind ;
                  "string", String_kind ;
                  "primitiveApplication", Prim_kind ;
                  "sequence", Seq_kind ] in
  let ex_stack_ty_enc =
    let rec unfold = function
      | Ex_stack_ty (Item_t (ty, rest)) ->
          Ex_ty ty :: unfold (Ex_stack_ty rest)
      | Ex_stack_ty Empty_t -> [] in
    let rec fold = function
      | Ex_ty ty :: rest ->
          let Ex_stack_ty rest = fold rest in
          Ex_stack_ty (Item_t (ty, rest))
      | [] -> Ex_stack_ty Empty_t in
    conv unfold fold (list ex_ty_enc) in
  (* -- Structure errors ---------------------- *)
  register_error_kind
    `Permanent
    ~id:"invalidArityTypeError"
    ~title: "Invalid arity (typechecking error)"
    ~description:
      "In a script or data expression, a primitive was applied \
       to an unsupported number of arguments."
    (located (obj3
                (req "primitiveName" string)
                (req "expectedArity" arity_enc)
                (req "wrongArity" arity_enc)))
    (function
      | Invalid_arity (loc, name, exp, got) ->
          Some (loc, (name, exp, got))
      | _ -> None)
    (fun (loc, (name, exp, got)) ->
       Invalid_arity (loc, name, exp, got)) ;
  register_error_kind
    `Permanent
    ~id:"invalidPrimitiveTypeError"
    ~title: "Invalid primitive (typechecking error)"
    ~description:
      "In a script or data expression, a primitive was unknown."
    (located (obj2
                (dft "expectedPrimitiveNames" (list string) [])
                (req "wrongPrimitiveName" string)))
    (function
      | Invalid_primitive (loc, exp, got) -> Some (loc, (exp, got))
      | _ -> None)
    (fun (loc, (exp, got)) ->
       Invalid_primitive (loc, exp, got)) ;
  register_error_kind
    `Permanent
    ~id:"invalidPrimitiveNameCaseTypeError"
    ~title: "Invalid primitive name case (typechecking error)"
    ~description:
      "In a script or data expression, a primitive name is \
       neither uppercase, lowercase or capitalized."
    (located (obj1 (req "wrongPrimitiveName" string)))
    (function
      | Invalid_case (loc, name) -> Some (loc, name)
      | _ -> None)
    (fun (loc, name) ->
       Invalid_case (loc, name)) ;
  register_error_kind
    `Permanent
    ~id:"invalidExpressionKindTypeError"
    ~title: "Invalid expression kind (typechecking error)"
    ~description:
      "In a script or data expression, an expression was of the wrong kind \
       (for instance a string where only a primitive applications can appear)."
    (located (obj2
                (req "expectedKinds" (list kind_enc))
                (req "wrongKind" kind_enc)))
    (function
      | Invalid_kind (loc, exp, got) -> Some (loc, (exp, got))
      | _ -> None)
    (fun (loc, (exp, got)) ->
       Invalid_kind (loc, exp, got)) ;
  register_error_kind
    `Permanent
    ~id:"invalidPrimitiveNamespaceTypeError"
    ~title: "Invalid primitive namespace (typechecking error)"
    ~description:
      "In a script or data expression, a primitive was of the wrong namespace."
    (located (obj3
                (req "primitiveName" string)
                (req "expectedNamespace" namespace_enc)
                (req "wrongNamespace" namespace_enc)))
    (function
      | Invalid_namespace (loc, name, exp, got) -> Some (loc, (name, exp, got))
      | _ -> None)
    (fun (loc, (name, exp, got)) ->
       Invalid_namespace (loc, name, exp, got)) ;
  register_error_kind
    `Permanent
    ~id:"unorderedMapLiteral"
    ~title:"Invalid map key order"
    ~description:"Map keys must be in strictly increasing order"
    (obj2
       (req "location" Script.location_encoding)
       (req "item" Script.expr_encoding))
    (function
      | Unordered_map_keys (loc, expr) -> Some (loc, expr)
      | _ -> None)
    (fun (loc, expr) -> Unordered_map_keys (loc, expr));
  register_error_kind
    `Permanent
    ~id:"duplicateMapKeys"
    ~title:"Duplicate map keys"
    ~description:"Map literals cannot contain duplicated keys"
    (obj2
       (req "location" Script.location_encoding)
       (req "item" Script.expr_encoding))
    (function
      | Duplicate_map_keys (loc, expr) -> Some (loc, expr)
      | _ -> None)
    (fun (loc, expr) -> Duplicate_map_keys (loc, expr));
  register_error_kind
    `Permanent
    ~id:"unorderedSetLiteral"
    ~title:"Invalid set value order"
    ~description:"Set values must be in strictly increasing order"
    (obj2
       (req "location" Script.location_encoding)
       (req "value" Script.expr_encoding))
    (function
      | Unordered_set_values (loc, expr) -> Some (loc, expr)
      | _ -> None)
    (fun (loc, expr) -> Unordered_set_values (loc, expr));
  register_error_kind
    `Permanent
    ~id:"duplicateSetValuesInLiteral"
    ~title:"Sets literals cannot contain duplicate elements"
    ~description:"Set literals cannot contain duplicate elements, \
                  but a duplicae was found while parsing."
    (obj2
       (req "location" Script.location_encoding)
       (req "value" Script.expr_encoding))
    (function
      | Duplicate_set_values (loc, expr) -> Some (loc, expr)
      | _ -> None)
    (fun (loc, expr) -> Duplicate_set_values (loc, expr));
  (* -- Instruction typing errors ------------- *)
  register_error_kind
    `Permanent
    ~id:"failNotInTailPositionTypeError"
    ~title: "FAIL not in tail position (typechecking error)"
    ~description:
      "There is non trivial garbage code after a FAIL instruction."
    (located empty)
    (function
      | Fail_not_in_tail_position loc -> Some (loc, ())
      | _ -> None)
    (fun (loc, ()) ->
       Fail_not_in_tail_position loc) ;
  register_error_kind
    `Permanent
    ~id:"undefinedBinopTypeError"
    ~title: "Undefined binop (typechecking error)"
    ~description:
      "A binary operation is called on operands of types \
       over which it is not defined."
    (located (obj3
                (req "operatorName" string)
                (req "wrongLeftOperandType" ex_ty_enc)
                (req "wrongRightOperandType" ex_ty_enc)))
    (function
      | Undefined_binop (loc, n, tyl, tyr) ->
          Some (loc, (n, Ex_ty tyl, Ex_ty tyr))
      | _ -> None)
    (fun (loc, (n, Ex_ty tyl, Ex_ty tyr)) ->
       Undefined_binop (loc, n, tyl, tyr)) ;
  register_error_kind
    `Permanent
    ~id:"undefinedUnopTypeError"
    ~title: "Undefined unop (typechecking error)"
    ~description:
      "A unary operation is called on an operand of type \
       over which it is not defined."
    (located (obj2
                (req "operatorName" string)
                (req "wrongOperandType" ex_ty_enc)))
    (function
      | Undefined_unop (loc, n, ty) ->
          Some (loc, (n, Ex_ty ty))
      | _ -> None)
    (fun (loc, (n, Ex_ty ty)) ->
       Undefined_unop (loc, n, ty)) ;
  register_error_kind
    `Permanent
    ~id:"badReturnTypeError"
    ~title: "Bad return (typechecking error)"
    ~description:
      "Unexpected stack at the end of a lambda or script."
    (located (obj2
                (req "expectedReturnType" ex_ty_enc)
                (req "wrongStackType" ex_stack_ty_enc)))
    (function
      | Bad_return (loc, sty, ty) -> Some (loc, (Ex_ty ty, Ex_stack_ty sty))
      | _ -> None)
    (fun (loc, (Ex_ty ty, Ex_stack_ty sty)) ->
       Bad_return (loc, sty, ty)) ;
  register_error_kind
    `Permanent
    ~id:"badStackTypeError"
    ~title: "Bad stack (typechecking error)"
    ~description:
      "The stack has an unexpected length or contents."
    (located (obj3
                (req "primitiveName" string)
                (req "relevantStackPortion" int16)
                (req "wrongStackType" ex_stack_ty_enc)))
    (function
      | Bad_stack (loc, name, s, sty) -> Some (loc, (name, s, Ex_stack_ty sty))
      | _ -> None)
    (fun (loc, (name, s, Ex_stack_ty sty)) ->
       Bad_stack (loc, name, s, sty)) ;
  register_error_kind
    `Permanent
    ~id:"unmatchedBranchesTypeError"
    ~title: "Unmatched branches (typechecking error)"
    ~description:
      "At the join point at the end of two code branches \
       the stacks have inconsistent lengths or contents."
    (located (obj2
                (req "firstStackType" ex_stack_ty_enc)
                (req "otherStackType" ex_stack_ty_enc)))
    (function
      | Unmatched_branches (loc, stya, styb) ->
          Some (loc, (Ex_stack_ty stya, Ex_stack_ty styb))
      | _ -> None)
    (fun (loc, (Ex_stack_ty stya, Ex_stack_ty styb)) ->
       Unmatched_branches (loc, stya, styb)) ;
  register_error_kind
    `Permanent
    ~id:"badStackItemTypeError"
    ~title: "Bad stack item (typechecking error)"
    ~description:
      "The type of a stack item is unexpected \
       (this error is always accompanied by a more precise one)."
    (obj1 (req "itemLevel" int16))
    (function
      | Bad_stack_item n -> Some n
      | _ -> None)
    (fun n ->
       Bad_stack_item n) ;
  register_error_kind
    `Permanent
    ~id:"TransferInLambdaTypeError"
    ~title: "Transfer in lambda (typechecking error)"
    ~description:
      "A TRANSFER_TOKENS instruction was encountered in a lambda expression."
    (located empty)
    (function
      | Transfer_in_lambda loc -> Some (loc, ())
      | _ -> None)
    (fun (loc, ()) ->
       Transfer_in_lambda loc) ;
  register_error_kind
    `Permanent
    ~id:"inconsistentStackLengthsTypeError"
    ~title: "Inconsistent stack lengths (typechecking error)"
    ~description:
      "A stack was of an unexpected length \
       (this error is always in the context of a located error)."
    empty
    (function
      | Bad_stack_length -> Some ()
      | _ -> None)
    (fun () ->
       Bad_stack_length) ;
  (* -- Value typing errors ------------------- *)
  register_error_kind
    `Permanent
    ~id:"invalidConstantTypeError"
    ~title: "Invalid constant (typechecking error)"
    ~description:
      "A data expression was invalid for its expected type."
    (located (obj2
                (req "expectedType" ex_ty_enc)
                (req "wrongExpression" Script.expr_encoding)))
    (function
      | Invalid_constant (loc, expr, ty) ->
          Some (loc, (Ex_ty ty, expr))
      | _ -> None)
    (fun (loc, (Ex_ty ty, expr)) ->
       Invalid_constant (loc, expr, ty)) ;
  register_error_kind
    `Permanent
    ~id:"invalidContractTypeError"
    ~title: "Invalid contract (typechecking error)"
    ~description:
      "A script or data expression references a contract that does not \
       exist or assumes a wrong type for an existing contract."
    (located (obj1 (req "contract" Contract.encoding)))
    (function
      | Invalid_contract (loc, c) ->
          Some (loc, c)
      | _ -> None)
    (fun (loc, c) ->
       Invalid_contract (loc, c)) ;
  register_error_kind
    `Permanent
    ~id:"comparableTypeExpectedTypeError"
    ~title: "Comparable type expected (typechecking error)"
    ~description:
      "A non comparable type was used in a place where \
       only comparable types are accepted."
    (located (obj1 (req "wrongType" ex_ty_enc)))
    (function
      | Comparable_type_expected (loc, ty) -> Some (loc, Ex_ty ty)
      | _ -> None)
    (fun (loc, Ex_ty ty) ->
       Comparable_type_expected (loc, ty)) ;
  register_error_kind
    `Permanent
    ~id:"InconsistentTypesTypeError"
    ~title: "Inconsistent types (typechecking error)"
    ~description:
      "This is the basic type clash error, \
       that appears in several places where the equality of \
       two types have to be proven, it is always accompanied \
       with another error that provides more context."
    (obj2
       (req "firstType" ex_ty_enc)
       (req "otherType" ex_ty_enc))
    (function
      | Inconsistent_types (tya, tyb) ->
          Some (Ex_ty tya, Ex_ty tyb)
      | _ -> None)
    (fun (Ex_ty tya, Ex_ty tyb) ->
       Inconsistent_types (tya, tyb)) ;

  (* Toplevel errors *)
  register_error_kind
    `Permanent
    ~id:"illTypedDataTypeError"
    ~title: "Ill typed data (typechecking error)"
    ~description:
      "The toplevel error thrown when trying to typecheck \
       a data expression against a given type \
       (always followed by more precise errors)."
    (obj3
       (opt "identifier" string)
       (req "expectedType" ex_ty_enc)
       (req "illTypedExpression" Script.expr_encoding))
    (function
      | Ill_typed_data (name, expr, ty) -> Some (name, Ex_ty ty,  expr)
      | _ -> None)
    (fun (name, Ex_ty ty,  expr) ->
       Ill_typed_data (name, expr, ty)) ;
  (* type error += Ill_formed_type of string option * Script.expr *)
  register_error_kind
    `Permanent
    ~id:"illFormedTypeTypeError"
    ~title: "Ill formed type (typechecking error)"
    ~description:
      "The toplevel error thrown when trying to parse a type expression \
       (always followed by more precise errors)."
    (obj2
       (opt "identifier" string)
       (req "illFormedExpression" Script.expr_encoding))
    (function
      | Ill_formed_type (name, expr) -> Some (name, expr)
      | _ -> None)
    (fun (name, expr) ->
       Ill_formed_type (name, expr)) ;
  register_error_kind
    `Permanent
    ~id:"illTypedContractTypeError"
    ~title: "Ill typed contract (typechecking error)"
    ~description:
      "The toplevel error thrown when trying to typecheck \
       a contract code against given input, output and storage types \
       (always followed by more precise errors)."
    (obj5
       (req "expectedParameterType" ex_ty_enc)
       (req "expectedReturnType" ex_ty_enc)
       (req "expectedStorageType" ex_ty_enc)
       (req "illTypedExpression" Script.expr_encoding)
       (req "typeMap" type_map_enc))
    (function
      | Ill_typed_contract (expr, arg_ty, ret_ty, storage_ty, type_map) ->
          Some (Ex_ty arg_ty, Ex_ty ret_ty, Ex_ty storage_ty, expr, type_map)
      | _ -> None)
    (fun (Ex_ty arg_ty, Ex_ty ret_ty, Ex_ty storage_ty, expr, type_map) ->
       Ill_typed_contract (expr, arg_ty, ret_ty, storage_ty, type_map))
