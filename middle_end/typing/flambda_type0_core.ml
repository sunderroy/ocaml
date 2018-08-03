(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2013--2018 OCamlPro SAS                                    *)
(*   Copyright 2014--2018 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-4-30-40-41-42"]

(* CR mshinwell: Delete >= 4.08 *)
[@@@ocaml.warning "-60"]
module Blocks = struct end
module Closure_elements = struct end
module Closure_ids = struct end
module Closures_entry_by_closure_id = struct end
module Discriminants = struct end
module Expr = struct end
module Function_type = struct end
module Immediates = struct end
module Types_by_closure_id = struct end

module Make (W : Typing_world.S) = struct
  open! W

  module Flambda_types =
    Flambda_types.Make
      (Blocks)
      (Closure_elements)
      (Closure_ids)
      (Closures_entry_by_closure_id)
      (Discriminants)
      (Expr)
      (Function_type)
      (Immediates)
      (Types_by_closure_id)

  include Flambda_types

  module K = Flambda_kind

  let print = Type_printers.print
  let print_with_cache = Type_printers.print_with_cache

  let free_names = Type_free_names.free_names

  let force_to_kind_value t =
    match t with
    | Value ty_value -> ty_value
    | Naked_number _
    | Fabricated _ ->
      Misc.fatal_errorf "Type has wrong kind (expected [Value]):@ %a"
        print t

  let force_to_kind_naked_immediate (t : t)
        : Immediate.Set.t ty_naked_number =
    match t with
    | Naked_number (ty_naked_number, K.Naked_number.Naked_immediate) ->
      ty_naked_number
    | Naked_number _
    | Fabricated _
    | Value _ ->
      Misc.fatal_errorf
        "Type has wrong kind (expected [Naked_number Immediate]):@ %a"
        print t

  let force_to_kind_naked_float (t : t)
        : Float.Set.t ty_naked_number =
    match t with
    | Naked_number (ty_naked_number, K.Naked_number.Naked_float) ->
      ty_naked_number
    | Naked_number _
    | Fabricated _
    | Value _ ->
      Misc.fatal_errorf
        "Type has wrong kind (expected [Naked_number Float]):@ %a"
        print t

  let force_to_kind_naked_int32 (t : t) : Int32.Set.t ty_naked_number =
    match t with
    | Naked_number (ty_naked_number, K.Naked_number.Naked_int32) ->
      ty_naked_number
    | Naked_number _
    | Fabricated _
    | Value _ ->
      Misc.fatal_errorf
        "Type has wrong kind (expected [Naked_number Int32]):@ %a"
        print t

  let force_to_kind_naked_int64 (t : t) : Int64.Set.t ty_naked_number =
    match t with
    | Naked_number (ty_naked_number, K.Naked_number.Naked_int64) ->
      ty_naked_number
    | Naked_number _
    | Fabricated _
    | Value _ ->
      Misc.fatal_errorf
        "Type has wrong kind (expected [Naked_number Int64]):@ %a"
        print t

  let force_to_kind_naked_nativeint (t : t)
        : Targetint.Set.t ty_naked_number =
    match t with
    | Naked_number (ty_naked_number, K.Naked_number.Naked_nativeint) ->
      ty_naked_number
    | Naked_number _
    | Fabricated _
    | Value _ ->
      Misc.fatal_errorf
        "Type has wrong kind (expected [Naked_number Nativeint]):@ %a"
        print t

  let force_to_kind_naked_number (type n) (kind : n K.Naked_number.t) (t : t)
        : n ty_naked_number =
    match t, kind with
    | Naked_number (ty_naked_number, K.Naked_number.Naked_immediate),
        K.Naked_number.Naked_immediate ->
      ty_naked_number
    | Naked_number (ty_naked_number, K.Naked_number.Naked_float),
        K.Naked_number.Naked_float ->
      ty_naked_number
    | Naked_number (ty_naked_number, K.Naked_number.Naked_int32),
        K.Naked_number.Naked_int32 ->
      ty_naked_number
    | Naked_number (ty_naked_number, K.Naked_number.Naked_int64),
        K.Naked_number.Naked_int64 ->
      ty_naked_number
    | Naked_number (ty_naked_number, K.Naked_number.Naked_nativeint),
        K.Naked_number.Naked_nativeint ->
      ty_naked_number
    | Naked_number _, _
    | Fabricated _, _
    | Value _, _ ->
      Misc.fatal_errorf "Type has wrong kind (expected [Naked_number %a]):@ %a"
        K.Naked_number.print kind
        print t

  let force_to_kind_fabricated t =
    match t with
    | Fabricated ty_fabricated -> ty_fabricated
    | Value _
    | Naked_number _ ->
      Misc.fatal_errorf "Type has wrong kind (expected [Fabricated]):@ %a"
        print t

  let ty_is_obviously_bottom (ty : _ ty) =
    match ty with
    | No_alias (Join []) -> true
    | _ -> false

  let is_obviously_bottom (t : t) =
    match t with
    | Value ty -> ty_is_obviously_bottom ty
    | Naked_number (ty, _) -> ty_is_obviously_bottom ty
    | Fabricated ty -> ty_is_obviously_bottom ty

  let of_ty_value ty_value : t =
    Value ty_value

  let of_ty_naked_number (type n) (ty_naked_number : n ty_naked_number)
        (kind : n K.Naked_number.t) : t =
    Naked_number (ty_naked_number, kind)

  let of_ty_fabricated ty_fabricated : t =
    Fabricated ty_fabricated

  (* CR-someday mshinwell: Functions such as [alias] and [bottom] could be
     simplified if [K.t] were a GADT. *)

  type 'a type_accessor = Typing_env.t -> 'a

  let alias_type_of (kind : K.t) name : t =
    match kind with
    | Value ->
      Value (Equals name)
    | Naked_number Naked_immediate ->
      Naked_number (Equals name, K.Naked_number.Naked_immediate)
    | Naked_number Naked_float ->
      Naked_number (Equals name, K.Naked_number.Naked_float)
    | Naked_number Naked_int32 ->
      Naked_number (Equals name, K.Naked_number.Naked_int32)
    | Naked_number Naked_int64 ->
      Naked_number (Equals name, K.Naked_number.Naked_int64)
    | Naked_number Naked_nativeint ->
      Naked_number (Equals name, K.Naked_number.Naked_nativeint)
    | Fabricated ->
      Fabricated (Equals name)

  let alias_type_of_as_ty_value name : ty_value = Equals name

  let alias_type_of_as_ty_fabricated name : ty_fabricated = Equals name

  let alias_type (kind : K.t) export_id : t =
    match kind with
    | Value ->
      Value (Type export_id)
    | Naked_number Naked_immediate ->
      Naked_number (Type export_id, K.Naked_number.Naked_immediate)
    | Naked_number Naked_float ->
      Naked_number (Type export_id, K.Naked_number.Naked_float)
    | Naked_number Naked_int32 ->
      Naked_number (Type export_id, K.Naked_number.Naked_int32)
    | Naked_number Naked_int64 ->
      Naked_number (Type export_id, K.Naked_number.Naked_int64)
    | Naked_number Naked_nativeint ->
      Naked_number (Type export_id, K.Naked_number.Naked_nativeint)
    | Fabricated ->
      Fabricated (Type export_id)

  let bottom_as_ty_value () : ty_value =
    No_alias (Join [])

  let bottom_as_ty_fabricated () : ty_fabricated =
    No_alias (Join [])

  let bottom (kind : K.t) : t =
    match kind with
    | Value ->
      Value (No_alias (Join []))
    | Naked_number Naked_immediate ->
      Naked_number (No_alias (Join []), K.Naked_number.Naked_immediate)
    | Naked_number Naked_float ->
      Naked_number (No_alias (Join []), K.Naked_number.Naked_float)
    | Naked_number Naked_int32 ->
      Naked_number (No_alias (Join []), K.Naked_number.Naked_int32)
    | Naked_number Naked_int64 ->
      Naked_number (No_alias (Join []), K.Naked_number.Naked_int64)
    | Naked_number Naked_nativeint ->
      Naked_number (No_alias (Join []), K.Naked_number.Naked_nativeint)
    | Fabricated ->
      Fabricated (No_alias (Join []))

  let any_value_as_ty_value () : ty_value =
    No_alias Unknown

  let any_fabricated_as_ty_fabricated () : ty_fabricated =
    No_alias Unknown

  let any_naked_float_as_ty_naked_float () : _ ty_naked_number =
    No_alias Unknown

  let any_value () : t =
    Value (any_value_as_ty_value ())

  let any_tagged_immediate () : t =
    Value (No_alias (Join [Blocks_and_tagged_immediates {
      immediates = Immediates.create_unknown ();
      blocks = Blocks.create_bottom ();
    }, Name_permutation.create ()]))

  let any_naked_immediate () : t =
    Naked_number (No_alias Unknown, K.Naked_number.Naked_immediate)

  let any_naked_float () : t =
    Naked_number (No_alias Unknown, K.Naked_number.Naked_float)

  let any_naked_int32 () : t =
    Naked_number (No_alias Unknown, K.Naked_number.Naked_int32)

  let any_naked_int64 () : t =
    Naked_number (No_alias Unknown, K.Naked_number.Naked_int64)

  let any_naked_nativeint () : t =
    Naked_number (No_alias Unknown, K.Naked_number.Naked_nativeint)

  let any_fabricated () : t =
    Fabricated (No_alias Unknown)

  let unknown (kind : K.t) =
    match kind with
    | Value ->
      Value (No_alias Unknown)
    | Naked_number Naked_immediate ->
      Naked_number (No_alias Unknown, K.Naked_number.Naked_immediate)
    | Naked_number Naked_float ->
      Naked_number (No_alias Unknown, K.Naked_number.Naked_float)
    | Naked_number Naked_int32 ->
      Naked_number (No_alias Unknown, K.Naked_number.Naked_int32)
    | Naked_number Naked_int64 ->
      Naked_number (No_alias Unknown, K.Naked_number.Naked_int64)
    | Naked_number Naked_nativeint ->
      Naked_number (No_alias Unknown, K.Naked_number.Naked_nativeint)
    | Fabricated ->
      Fabricated (No_alias Unknown)

  let these_naked_immediates (is : Immediate.Set.t) : t =
    let of_kind : _ of_kind_naked_number = Immediate is in
    Naked_number (No_alias (Join [of_kind, Name_permutation.create ()]),
      K.Naked_number.Naked_immediate)

  let these_naked_floats (is : Float.Set.t) : t =
    let of_kind : _ of_kind_naked_number = Float is in
    Naked_number (No_alias (Join [of_kind, Name_permutation.create ()]),
      K.Naked_number.Naked_float)

  let these_naked_int32s (is : Int32.Set.t) : t =
    let of_kind : _ of_kind_naked_number = Int32 is in
    Naked_number (No_alias (Join [of_kind, Name_permutation.create ()]),
      K.Naked_number.Naked_int32)

  let these_naked_int64s (is : Int64.Set.t) : t =
    let of_kind : _ of_kind_naked_number = Int64 is in
    Naked_number (No_alias (Join [of_kind, Name_permutation.create ()]),
      K.Naked_number.Naked_int64)

  let these_naked_nativeints (is : Targetint.Set.t) : t =
    let of_kind : _ of_kind_naked_number = Nativeint is in
    Naked_number (No_alias (Join [of_kind, Name_permutation.create ()]),
      K.Naked_number.Naked_nativeint)

  let this_naked_immediate i =
    these_naked_immediates (Immediate.Set.singleton i)

  let this_naked_float f =
    these_naked_floats (Float.Set.singleton f)

  let this_naked_float_as_ty_naked_float f =
    let fs = Float.Set.singleton f in
    let of_kind : _ of_kind_naked_number = Float fs in
    No_alias (Join [of_kind, Name_permutation.create ()])

  let this_naked_int32 i =
    these_naked_int32s (Int32.Set.singleton i)

  let this_naked_int64 i =
    these_naked_int64s (Int64.Set.singleton i)

  let this_naked_nativeint i =
    these_naked_nativeints (Targetint.Set.singleton i)

(* This one is tricky
  let tag_immediate (t : t) : t =
    match t with
    | Naked_number (ty_naked_number, Naked_immediate) ->


      Value (No_alias (Ok (No_alias (
        Tagged_immediate ty_naked_immediate))))
    | Value _
    | Naked_number _
    | Fabricated _
    | Phantom _ ->
      Misc.fatal_errorf "Type of wrong kind for [tag_immediate]: %a"
        print t
*)

  let box_float (t : t) : t =
    match t with
    | Naked_number (ty_naked_float, K.Naked_number.Naked_float) ->
      Value (No_alias (Join [
        Boxed_number (Boxed_float ty_naked_float),
          Name_permutation.create ()]))
    | Value _
    | Naked_number _
    | Fabricated _ ->
      Misc.fatal_errorf "Type of wrong kind for [box_float]: %a"
        print t

  let box_int32 (t : t) : t =
    match t with
    | Naked_number (ty_naked_int32, K.Naked_number.Naked_int32) ->
      Value (No_alias (Join [
        Boxed_number (Boxed_int32 ty_naked_int32),
          Name_permutation.create ()]))
    | Value _
    | Naked_number _
    | Fabricated _ ->
      Misc.fatal_errorf "Type of wrong kind for [box_int32]: %a"
        print t

  let box_int64 (t : t) : t =
    match t with
    | Naked_number (ty_naked_int64, K.Naked_number.Naked_int64) ->
      Value (No_alias (Join [
        Boxed_number (Boxed_int64 ty_naked_int64),
          Name_permutation.create ()]))
    | Value _
    | Naked_number _
    | Fabricated _ ->
      Misc.fatal_errorf "Type of wrong kind for [box_int64]: %a"
        print t

  let box_nativeint (t : t) : t =
    match t with
    | Naked_number (ty_naked_nativeint, K.Naked_number.Naked_nativeint) ->
      Value (No_alias (Join [
        Boxed_number (Boxed_nativeint ty_naked_nativeint),
          Name_permutation.create ()]))
    | Value _
    | Naked_number _
    | Fabricated _ ->
      Misc.fatal_errorf "Type of wrong kind for [box_nativeint]: %a"
        print t

  let these_tagged_immediates imms : t =
    if Immediate.Set.is_empty imms then
      bottom (K.value ())
    else
      let immediates =
        Immediates.create_with_equations (
          Immediate.Map.of_set (fun _imm -> Typing_env_extension.empty)
            imms)
      in
      let blocks_and_tagged_immediates : blocks_and_tagged_immediates =
        { immediates;
          blocks = Blocks.create_bottom ();
        }
      in
      Value (No_alias (Join [
        Blocks_and_tagged_immediates blocks_and_tagged_immediates,
          Name_permutation.create ()]))

  let these_tagged_immediates_with_envs env_map =
    if Immediate.Map.is_empty env_map then
      bottom (K.value ())
    else
      let blocks_and_tagged_immediates : blocks_and_tagged_immediates =
        { immediates = Immediates.create_with_equations env_map;
          blocks = Blocks.create_bottom ();
        }
      in
      Value (No_alias (Join [
        Blocks_and_tagged_immediates blocks_and_tagged_immediates,
          Name_permutation.create ()]))

  let this_tagged_immediate imm =
    these_tagged_immediates (Immediate.Set.singleton imm)

  let any_tagged_bool () =
    let bools =
      Immediate.Set.add Immediate.bool_false
        (Immediate.Set.add Immediate.bool_true Immediate.Set.empty)
    in
    these_tagged_immediates bools

  let this_boxed_float f = box_float (this_naked_float f)
  let this_boxed_int32 f = box_int32 (this_naked_int32 f)
  let this_boxed_int64 f = box_int64 (this_naked_int64 f)
  let this_boxed_nativeint f = box_nativeint (this_naked_nativeint f)

  let these_boxed_floats f = box_float (these_naked_floats f)
  let these_boxed_int32s f = box_int32 (these_naked_int32s f)
  let these_boxed_int64s f = box_int64 (these_naked_int64s f)
  let these_boxed_nativeints f = box_nativeint (these_naked_nativeints f)

  let these_discriminants_as_ty_fabricated discriminants_to_env_extension
        : ty_fabricated =
    let discriminants =
      Discriminants.create_with_equations discriminants_to_env_extension
    in
    No_alias (Join [Discriminants discriminants, Name_permutation.create ()])

  let these_discriminants discriminants_to_env_extension : t =
    Fabricated (
      these_discriminants_as_ty_fabricated discriminants_to_env_extension)

  let this_discriminant_as_ty_fabricated discriminant =
    let discriminants =
      Discriminants.create (Discriminant.Set.singleton discriminant)
    in
    No_alias (Join [Discriminants discriminants, Name_permutation.create ()])

  let this_discriminant discriminant : t =
    Fabricated (this_discriminant_as_ty_fabricated discriminant)

  let any_discriminant_as_ty_fabricated () : ty_fabricated =
    No_alias Unknown

  let this_immutable_string_as_ty_value str : ty_value =
    let str =
      String_info.create ~contents:(Contents str)
        ~size:(Targetint.OCaml.of_int (String.length str))
    in
    let str = String_info.Set.singleton str in
    No_alias (Join [String str, Name_permutation.create ()])

  let this_immutable_string str : t =
    Value (this_immutable_string_as_ty_value str)

  let immutable_string_as_ty_value ~size : ty_value =
    let str = String_info.create ~contents:Unknown_or_mutable ~size in
    let str = String_info.Set.singleton str in
    No_alias (Join [String str, Name_permutation.create ()])

  let immutable_string ~size : t =
    Value (immutable_string_as_ty_value ~size)

  let mutable_string ~size : t =
    let str = String_info.create ~contents:Unknown_or_mutable ~size in
    let str = String_info.Set.singleton str in
    Value (No_alias (Join [String str, Name_permutation.create ()]))

  let kind (t : t) =
    match t with
    | Value _ -> K.value ()
    | Naked_number (_, K.Naked_number.Naked_immediate) -> K.naked_immediate ()
    | Naked_number (_, K.Naked_number.Naked_float) -> K.naked_float ()
    | Naked_number (_, K.Naked_number.Naked_int32) -> K.naked_int32 ()
    | Naked_number (_, K.Naked_number.Naked_int64) -> K.naked_int64 ()
    | Naked_number (_, K.Naked_number.Naked_nativeint) -> K.naked_nativeint ()
    | Fabricated _ -> K.fabricated ()

  let mutable_float_array ~size : t =
    match Targetint.OCaml.to_int_option size with
    | None ->
      (* CR mshinwell: Here and elsewhere, this should be a normal compilation
         error, not a fatal error. *)
      Misc.fatal_error "Mutable float array too long for host"
    | Some size ->
      let field_tys = List.init size (fun _index -> any_naked_float ()) in
      let blocks =
        Blocks.create ~field_tys (Closed Tag.double_array_tag)
      in
      let blocks_imms : blocks_and_tagged_immediates =
        { immediates = Immediates.create_bottom ();
          blocks;
        }
      in
      Value (No_alias (Join [
        Blocks_and_tagged_immediates blocks_imms,
        Name_permutation.create ()]))

  let immutable_float_array fields : t =
    match Targetint.OCaml.of_int_option (Array.length fields) with
    | None ->
      Misc.fatal_error "Immutable float array too long for target"
    | Some size ->
      let field_tys =
        Array.map (fun ty_naked_number : t ->
            Naked_number (ty_naked_number, K.Naked_number.Naked_float))
          fields
      in
      let blocks =
        Blocks.create ~field_tys:(Array.to_list field_tys)
          (Closed Tag.double_array_tag)
      in
      let blocks_imms : blocks_and_tagged_immediates =
        { immediates = Immediates.create_bottom ();
          blocks;
        }
      in
      Value (No_alias (Join [
        Blocks_and_tagged_immediates blocks_imms,
        Name_permutation.create ()]))

  let this_immutable_float_array fields : t =
    let make_field f : _ ty_naked_number =
      No_alias (Join [
        Float (Float.Set.singleton f), Name_permutation.create ()])
    in
    let fields = Array.map make_field fields in
    immutable_float_array fields

  let block tag ~(fields : t list) =
    (* CR mshinwell: We should check the field kinds against the tag. *)
    match Targetint.OCaml.of_int_option (List.length fields) with
    | None ->
      Misc.fatal_error "Block too long for target"
    | Some size ->
      let blocks = Blocks.create ~field_tys:fields (Closed tag) in
      let blocks_imms : blocks_and_tagged_immediates =
        { immediates = Immediates.create_bottom ();
          blocks;
        }
      in
      Value (No_alias (Join [
        Blocks_and_tagged_immediates blocks_imms,
          Name_permutation.create ()]))

  (* CR mshinwell: bad name *)
  let block_of_values tag ~(fields : ty_value list) =
    block tag ~fields:(List.map (fun field : t -> Value field) fields)

  let block_of_unknown_values _tag ~size:_ = Misc.fatal_error "TBD"
(*
    let fields =
      Array.init size (fun _index : _ mutable_or_immutable ->
        Immutable (any_value_as_ty_value ()))
    in
    block_of_values tag ~fields
*)

  let block_with_size_at_least ~n ~field_n_minus_one =
    let type_of_field_n_minus_one =
      alias_type_of (Flambda_kind.value ()) (Simple.var field_n_minus_one)
    in
    let field_tys =
      Array.init n (fun index ->
        if index = n - 1 then type_of_field_n_minus_one
        else any_value ())
    in
    let blocks = Blocks.create ~field_tys Open in
    let blocks_imms : blocks_and_tagged_immediates =
      { immediates = Immediates.create_bottom ();
        blocks;
      }
    in
    Value (No_alias (Join [
      Blocks_and_tagged_immediates blocks_imms,
        Name_permutation.create ()]))

  let any_boxed_float () = box_float (any_naked_float ())
  let any_boxed_int32 () = box_int32 (any_naked_int32 ())
  let any_boxed_int64 () = box_int64 (any_naked_int64 ())
  let any_boxed_nativeint () = box_nativeint (any_naked_nativeint ())

  let check_of_kind t (expected_kind : K.t) =
    let actual_kind = kind t in
    if not (K.equal actual_kind expected_kind) then begin
      Misc.fatal_errorf "Type has wrong kind: have %a but expected %a"
        K.print actual_kind
        K.print expected_kind
    end

  let bottom_like t = bottom (kind t)
  let unknown_like t = unknown (kind t)

  let create_inlinable_function_declaration ~is_classic_mode ~closure_origin
        ~continuation_param ~exn_continuation_param ~params ~body ~code_id
        ~result_arity ~stub ~dbg ~inline ~specialise ~is_a_functor
        ~invariant_params ~size ~direct_call_surrogate ~my_closure
        : function_declaration =
    Inlinable [({
      closure_origin;
      continuation_param;
      exn_continuation_param;
      is_classic_mode;
      params;
      body;
      code_id;
      free_names_in_body = Expr.free_names body;
      result_arity;
      stub;
      dbg;
      inline;
      specialise;
      is_a_functor;
      invariant_params;
      size;
      direct_call_surrogate;
      my_closure;
    } : inlinable_function_declaration)]

  let create_non_inlinable_function_declaration ~direct_call_surrogate
        : function_declaration =
    Non_inlinable

  let closure closure_id function_decl ty closure_elements ~set_of_closures =
    let closure_elements' =
      let closure_elements =
        Var_within_closure.Map.map (fun ty_value : t -> Value ty_value)
          closure_elements
      in
      Closure_elements.create closure_elements
    in
    let closures_entry : closures_entry =
      { function_decl;
        ty;
        closure_elements = closure_elements';
        set_of_closures;
      }
    in
    let by_closure_id =
      Closures_entry_by_closure_id.create_exactly_multiple
        (Closure_id_and_var_within_closure_set.Map.singleton
          (closure_id, Var_within_closure.Map.keys closure_elements)
          closures_entry)
    in
    let closures : closures =
      { by_closure_id;
      }
    in
    Value (No_alias (Join [Closures closures, Name_permutation.create ()]))

  let closure_containing_at_least ~closure_name var_within_closure ty_value =
    let closure_elements =
      Var_within_closure.Map.singleton var_within_closure (Value ty_value)
    in
    let closures_entry : closures_entry =
      { function_decl;
        ty;
        closure_elements = closure_elements';
        set_of_closures = any_fabricated_as_ty_fabricated ()
      }
    in
    let by_closure_id =
      Closures_entry_by_closure_id.create_at_least_multiple
        (Closures_entry_by_closure_id.Var_within_closure_set.Map.singleton
          (Var_within_closure.Set.singleton var_within_closure)
          closures_entry)
    in
    let closures : closures =
      { by_closure_id;
      }
    in
    Value (No_alias (Join [Closures closures, Name_permutation.create ()]))

  let set_of_closures ~closures =
    let all_closures = Closure_id.Map.keys closures in
    if Closure_id.Map.is_empty all_closures then bottom_as_ty_fabricated ()
    else
      let by_closure_id = Types_by_closure_id.create closures in
      let set_of_closures_entry : set_of_closures_entry = { by_closure_id; } in
      let closures =
        Closure_ids.create
          (Closure_id_set.Map.singleton all_closures set_of_closures_entry)
          Closed
      in
      Fabricated (No_alias (Join [Set_of_closures { closures; },
        Name_permutation.create ()]))

  let set_of_closures_containing_at_least closure_id =
    let by_closure_id =
      Types_by_closure_id.create
        (Closure_id.Map.singleton closure_id (any_value ()))
    in
    let set_of_closures_entry : set_of_closures_entry = { by_closure_id; } in
    let closure_id = Closure_id.Set.singleton closure_id in
    let closures =
      Closure_ids.create
        (Closure_id_set.Map.singleton closure_id set_of_closures_entry)
        Open
    in
    Fabricated (No_alias (Join [Set_of_closures { closures; },
      Name_permutation.create ()]))

  let apply_name_permutation_unknown_or_join unknown_or_join perm =
    match unknown_or_join with
    | Unknown -> unknown_or_join
    | Join of_kind_foos ->
      let something_changed = ref false in
      let of_kind_foos =
        List.map (fun (of_kind_foo, existing_perm) ->
            let new_perm = Name_permutation.compose existing_perm new_perm in
            if not (new_perm == existing_perm) then begin
              something_changed := true
            end;
            of_kind_foo, new_perm)
          of_kind_foos
      in
      if not !something_changed then unknown_or_join
      else Join of_kind_foos

  let apply_name_permutation_ty ty perm =
    match ty with
    | No_alias unknown_or_join ->
      let unknown_or_join' =
        apply_name_permutation_unknown_or_join unknown_or_join perm
      in
      if unknown_or_join == unknown_or_join' then ty
      else No_alias unknown_or_join'
    | Type _ -> ty
    | Equals simple ->
      let simple' = Name_permutation.apply_simple perm simple in
      if simple == simple' then ty
      else Equals simple'

  let apply_name_permutation_t t perm =
    match t with
    | Value ty_value ->
      let ty_value' = apply_name_permutation_ty ty_value perm in
      if ty_value == ty_value' then t
      else Value ty_value'
    | Naked_number (ty_naked_number, kind) ->
      let ty_naked_number' = apply_name_permutation_ty ty_naked_number perm in
      if ty_naked_number == ty_naked_number' then t
      else Naked_number (ty_naked_number', kind)
    | Fabricated ty_fabricated ->
      let ty_fabricated' = apply_name_permutation_ty ty_fabricated perm in
      if ty_fabricated == ty_fabricated' then t
      else Fabricated ty_fabricated'

  let get_alias t =
    match t with
    | Value (Equals simple) -> Some simple
    | Value _ -> None
    | Naked_number (Equals simple, _) -> Some simple
    | Naked_number _ -> None
    | Fabricated (Equals simple) -> Some simple
    | Fabricated _ -> None

(*
  (* CR mshinwell: Add comment that this forms an equivalence relation *)
  let function_declarations_compatible
        (decl1 : function_declaration)
        (decl2 : function_declaration) =
    let check (params1 : parameters) (params2 : parameters) =
      let arity1 = Kinded_parameter.arity params1.params in
      let arity2 = Kinded_parameter.arity params2.params in
      Flambda_arity.equal arity1 arity2
        || (Flambda_arity.all_values arity1 && Flambda_arity.all_values arity2)
    in
    check decl1.ty.params decl2.ty.params
      && check decl1.ty.result decl2.ty.result
*)

  let meet = Both_meet_and_join.meet
  let join = Both_meet_and_join.join
  let as_or_more_precise = Both_meet_and_join.as_or_more_precise
  let strictly_more_precise = Both_meet_and_join.strictly_more_precise
  let fast_equal = Type_equality.fast_equal
  let equal = Type_equality.equal
end