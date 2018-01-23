(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2013--2017 OCamlPro SAS                                    *)
(*   Copyright 2014--2017 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-4-9-30-40-41-42"]

(* CR mshinwell: This warning appears to be broken (e.g. it claims
   [Meet_and_join_value] is unused) *)
[@@@ocaml.warning "-60"]

module Float_by_bit_pattern = Numbers.Float_by_bit_pattern
module Int32 = Numbers.Int32
module Int64 = Numbers.Int64

module K = Flambda_kind

module Make (Expr : sig
  type t
  val print : Format.formatter -> t -> unit
  val free_names : t -> Name.Set.t
end) = struct
  type expr = Expr.t

  type inline_attribute =
    | Always_inline
    | Never_inline
    | Unroll of int
    | Default_inline

  let print_inline_attribute ppf attr =
    let fprintf = Format.fprintf in
    match attr with
    | Always_inline -> fprintf ppf "Always_inline"
    | Never_inline -> fprintf ppf "Never_inline"
    | Unroll n -> fprintf ppf "@[(Unroll %d)@]" n
    | Default_inline -> fprintf ppf "Default_inline"

  type specialise_attribute =
    | Always_specialise
    | Never_specialise
    | Default_specialise

  let print_specialise_attribute ppf attr =
    let fprintf = Format.fprintf in
    match attr with
    | Always_specialise -> fprintf ppf "Always_specialise"
    | Never_specialise -> fprintf ppf "Never_specialise"
    | Default_specialise -> fprintf ppf "Default_specialise"

  type string_contents =
    | Contents of string
    | Unknown_or_mutable

  module String_info = struct
    type t = {
      contents : string_contents;
      size : Targetint.OCaml.t;
    }

    include Identifiable.Make (struct
      type nonrec t = t

      let compare t1 t2 =
        let c =
          match t1.contents, t2.contents with
          | Contents s1, Contents s2 -> String.compare s1 s2
          | Unknown_or_mutable, Unknown_or_mutable -> 0
          | Contents _, Unknown_or_mutable -> -1
          | Unknown_or_mutable, Contents _ -> 1
        in
        if c <> 0 then c
        else Pervasives.compare t1.size t2.size

      let equal t1 t2 =
        compare t1 t2 = 0

      let hash t = Hashtbl.hash t

      let print ppf { contents; size; } =
        match contents with
        | Unknown_or_mutable ->
          Format.fprintf ppf "(size %a)" Targetint.OCaml.print size
        | Contents s ->
          let s, dots =
            let max_size = Targetint.OCaml.ten in
            let long = Targetint.OCaml.compare size max_size > 0 in
            if long then String.sub s 0 8, "..."
            else s, ""
          in
          Format.fprintf ppf "(size %a) (contents \"%S\"%s)"
            Targetint.OCaml.print size
            s dots
    end)
  end

  type 'a mutable_or_immutable =
    | Immutable of 'a
    | Mutable

  type 'a or_unknown =
    | Known of 'a
    | Unknown

  type 'a or_alias =
    | No_alias of 'a
    | Type of Export_id.t
    | Type_of of Name.t

  type 'a extensibility =
    | Open of 'a
    | Exactly of 'a

  let extensibility_contents (e : _ extensibility) =
    match e with
    | Open contents | Exactly contents -> contents

  type t =
    | Value of ty_value
    | Naked_number :
        'kind ty_naked_number * 'kind K.Naked_number.t -> t
    | Fabricated of ty_fabricated
    | Phantom of ty_phantom

  and flambda_type = t

  and ty_value = (of_kind_value, K.Value_kind.t) ty
  and 'a ty_naked_number = ('a of_kind_naked_number, unit) ty
  and ty_fabricated = (of_kind_fabricated, K.Value_kind.t) ty
  and ty_phantom = (of_kind_phantom, K.Phantom_kind.t) ty

  and ('a, 'u) ty = ('a, 'u) unknown_or_join or_alias

  and ('a, 'u) unknown_or_join =
    | Unknown of 'u
    | Join of 'a list

  and of_kind_value =
    | Blocks_and_tagged_immediates of blocks_and_tagged_immediates
    | Boxed_number : _ of_kind_value_boxed_number -> of_kind_value
    | Closures of closures
    | String of String_info.Set.t

  and immediate_case = {
    env_extension : typing_environment;
  }
 
  and singleton_block = {
    env_extension : typing_environment;
    fields : t mutable_or_immutable array;
  }

  and block_cases =
    | Join of { by_length : singleton_block Targetint.OCaml.Map.t; }

  and blocks_and_tagged_immediates = {
    immediates : immediate_case Immediate.Map.t or_unknown;
    blocks : block_cases Tag.Map.t;
  }

  and 'a of_kind_value_boxed_number =
    | Boxed_float
         : Numbers.Float_by_bit_pattern.Set.t ty_naked_number
        -> Numbers.Float_by_bit_pattern.Set.t ty_naked_number
             of_kind_value_boxed_number
    | Boxed_int32
         : Int32.Set.t ty_naked_number
        -> Int32.Set.t ty_naked_number of_kind_value_boxed_number
    | Boxed_int64
         : Int64.Set.t ty_naked_number
        -> Int64.Set.t ty_naked_number of_kind_value_boxed_number
    | Boxed_nativeint
         : Targetint.Set.t ty_naked_number
        -> Targetint.Set.t ty_naked_number of_kind_value_boxed_number

  and inlinable_function_declaration = {
    closure_origin : Closure_origin.t;
    continuation_param : Continuation.t;
    exn_continuation_param : Continuation.t;
    is_classic_mode : bool;
    params : (Parameter.t * t) list;
    code_id : Code_id.t;
    body : expr;
    free_names_in_body : Name.Set.t;
    result : t list;
    result_env_extension : typing_environment;
    stub : bool;
    dbg : Debuginfo.t;
    inline : inline_attribute;
    specialise : specialise_attribute;
    is_a_functor : bool;
    invariant_params : Variable.Set.t lazy_t;
    size : int option lazy_t;
    direct_call_surrogate : Closure_id.t option;
    my_closure : Variable.t;
  }

  and non_inlinable_function_declarations = {
    params : t list;
    result : t list;
    result_env_extension : typing_environment;
    direct_call_surrogate : Closure_id.t option;
  }

  and function_declarations =
    | Non_inlinable of non_inlinable_function_declarations option
    | Inlinable of inlinable_function_declaration

  and closures_entry = {
    set_of_closures : ty_fabricated;
  }

  and closures = closures_entry Closure_id.Map.t

  and 'a of_kind_naked_number =
    | Immediate : Immediate.Set.t -> Immediate.Set.t of_kind_naked_number
    | Float : Numbers.Float_by_bit_pattern.Set.t
        -> Numbers.Float_by_bit_pattern.Set.t of_kind_naked_number
    | Int32 : Int32.Set.t -> Int32.Set.t of_kind_naked_number
    | Int64 : Int64.Set.t -> Int64.Set.t of_kind_naked_number
    | Nativeint : Targetint.Set.t -> Targetint.Set.t of_kind_naked_number

  and tag_case = {
    env_extension : typing_environment;
  }

  and of_kind_fabricated =
    | Tag of tag_case Tag.Map.t
    | Set_of_closures of set_of_closures
    | Closure of closure

  and set_of_closures = {
    closures : ty_fabricated Closure_id.Map.t extensibility;
    closure_elements : ty_value Var_within_closure.Map.t extensibility;
  }

  and closure = {
    function_decls : function_declarations;
  }

  and of_kind_phantom =
    | Value of ty_value
    | Naked_number
         : 'kind ty_naked_number * 'kind K.Naked_number.t
        -> of_kind_phantom
    | Fabricated of ty_fabricated

  and typing_environment = {
    names_to_types : t Name.Map.t;
    levels_to_names : Name.Set.t Scope_level.Map.t;
    existentials : Name.Set.t;
    existential_freshening : Freshening.t;
  }

  let ty_is_obviously_bottom (ty : _ ty) =
    match ty with
    | No_alias (Join []) -> true
    | _ -> false

  let is_obviously_bottom (t : t) =
    match t with
    | Value ty -> ty_is_obviously_bottom ty
    | Naked_number (ty, _) -> ty_is_obviously_bottom ty
    | Fabricated ty -> ty_is_obviously_bottom ty
    | Phantom ty -> ty_is_obviously_bottom ty

  let print_extensibility print_contents ppf (e : _ extensibility) =
    match e with
    | Open contents ->
      Format.fprintf ppf "@[(Open@ %a)@]" print_contents contents
    | Exactly contents ->
      Format.fprintf ppf "@[(Exactly@ %a)@]" print_contents contents

  let print_mutable_or_immutable print_contents ppf
        (mut : _ mutable_or_immutable) =
    match mut with
    | Immutable contents -> print_contents ppf contents
    | Mutable -> Format.pp_print_string ppf "<mutable>"

  let print_or_unknown print_contents ppf (or_unknown : _ or_unknown) =
    match or_unknown with
    | Known contents -> print_contents ppf contents
    | Unknown -> Format.pp_print_string ppf "<unknown>"

  let print_or_alias print_descr ppf (or_alias : _ or_alias) =
    match or_alias with
    | No_alias descr -> print_descr ppf descr
    | Type_of name ->
      Format.fprintf ppf "@[(= type_of %a)@]" Name.print name
    | Type export_id ->
      Format.fprintf ppf "@[(= %a)@]" Export_id.print export_id

  let print_unknown_or_join print_contents print_unknown_payload ppf
        (o : _ unknown_or_join) =
    match o with
    | Unknown payload ->
      Format.fprintf ppf "@[Unknown %a@]" print_unknown_payload payload
    | Join [] -> Format.fprintf ppf "Bottom"
    | Join [contents] -> print_contents ppf contents
    | Join incompatibles ->
      Format.fprintf ppf "@[Join_incompatible@ (%a)@]"
        (Format.pp_print_list print_contents) incompatibles

  let print_ty_generic print_contents print_unknown_payload ppf ty =
    (print_or_alias
        (print_unknown_or_join
          print_contents
          print_unknown_payload))
      ppf ty

  let print_of_kind_naked_number (type n) ppf (n : n of_kind_naked_number) =
    match n with
    | Immediate i ->
      Format.fprintf ppf "@[(Naked_immediates@ (%a))@]"
        Immediate.Set.print i
    | Float f ->
      Format.fprintf ppf "@[(Naked_floats@ (%a))@]"
        Float_by_bit_pattern.Set.print f
    | Int32 i ->
      Format.fprintf ppf "@[(Naked_int32s@ (%a))@]"
        Int32.Set.print i
    | Int64 i ->
      Format.fprintf ppf "@[(Naked_int64s@ (%a))@]"
        Int64.Set.print i
    | Nativeint i ->
      Format.fprintf ppf "@[(Naked_nativeints@ (%a))@]"
        Targetint.Set.print i

  let print_ty_naked_number (type n) ppf (ty : n ty_naked_number) =
    print_ty_generic print_of_kind_naked_number (fun _ () -> ()) ppf ty

  let print_of_kind_value_boxed_number (type n)
        ppf (n : n of_kind_value_boxed_number) =
    match n with
    | Boxed_float f ->
      Format.fprintf ppf "@[(Boxed_float@ (%a))@]"
        print_ty_naked_number f
    | Boxed_int32 i ->
      Format.fprintf ppf "@[(Boxed_int32@ (%a))@]"
        print_ty_naked_number i
    | Boxed_int64 i ->
      Format.fprintf ppf "@[(Boxed_int64@ (%a))@]"
        print_ty_naked_number i
    | Boxed_nativeint i ->
      Format.fprintf ppf "@[(Boxed_nativeint@ (%a))@]"
        print_ty_naked_number i

  let rec print_immediate_case ppf ({ env_extension; } : immediate_case) =
    Format.fprintf ppf "@[(env_extension@ %a)@]"
      print_typing_environment env_extension

  and print_fields ppf (fields : t mutable_or_immutable array) =
    Format.fprintf ppf "@[[| %a |]@]"
      (Format.pp_print_list
        ~pp_sep:(fun ppf () -> Format.pp_print_string ppf ";@ ")
        (print_mutable_or_immutable print))
      (Array.to_list fields)

  and print_singleton_block ppf { env_extension; fields; } =
    Format.fprintf ppf "@[((env_extension@ %a)@ (fields@ %a))@]"
      print_typing_environment env_extension
      print_fields fields

  and print_block_cases ppf ((Join { by_length; }) : block_cases) =
    match Targetint.OCaml.Map.get_singleton by_length with
    | Some (_length, block) -> print_singleton_block ppf block
    | None ->
      Format.fprintf ppf "@[(Join (by_length@ %a))@]"
        (Targetint.OCaml.Map.print print_singleton_block) by_length

  and print_immediates ppf cases =
    Immediate.Map.print print_immediate_case ppf cases

  and print_blocks ppf cases =
    Tag.Map.print print_block_cases ppf cases

  and print_of_kind_value ppf (of_kind_value : of_kind_value) =
    match of_kind_value with
    | Blocks_and_tagged_immediates { blocks; immediates; } ->
      Format.fprintf ppf
        "@[(Blocks_and_immediates@ \
         @[(blocks@ %a)@]@ \
         @[(immediates@ @[%a@])@])@]"
        print_blocks blocks
        (print_or_unknown print_immediates) immediates
    | Boxed_number n ->
      Format.fprintf ppf "@[(Boxed_number %a)@]"
        print_of_kind_value_boxed_number n
    | Closures closures -> print_closures ppf closures
    | String str_infos ->
      Format.fprintf ppf "@[(Strings (%a))@]" String_info.Set.print str_infos

  and print_ty_value ppf (ty : ty_value) =
    print_ty_generic print_of_kind_value K.Value_kind.print ppf ty

  and print_ty_value_array ppf ty_values =
    Format.fprintf ppf "@[[| %a |]@]"
      (Format.pp_print_list
        ~pp_sep:(fun ppf () -> Format.pp_print_string ppf ";@ ")
        print_ty_value)
      (Array.to_list ty_values)

  and _unused = Expr.print

  and print_closures ppf (closures : closures) =
    Format.fprintf ppf "@[(Closures %a)@]"
      (Closure_id.Map.print print_closures_entry) closures

  and print_closures_entry ppf (entry : closures_entry) =
    Format.fprintf ppf "@[(set_of_closures %a)@]"
      print_ty_fabricated entry.set_of_closures

  and print_inlinable_function_declaration ppf
        (decl : inlinable_function_declaration) =
    Format.fprintf ppf
      "@[(inlinable@ \
        @[(closure_origin@ %a)@]@ \
        @[(continuation_param@ %a)@]@ \
        @[(exn_continuation_param@ %a)@]@ \
        @[(is_classic_mode@ %b)@]@ \
        @[(params (%a))@]@ \
        @[(body <elided>)@]@ \
        @[(free_names_in_body@ %a)@]@ \
        @[(result@ (%a))@]@ \
        @[(stub@ %b)@]@ \
        @[(dbg@ %a)@]@ \
        @[(inline@ %a)@]@ \
        @[(specialise@ %a)@]@ \
        @[(is_a_functor@ %b)@]@ \
        @[(invariant_params@ %a)@]@ \
        @[(size@ %a)@]@ \
        @[(direct_call_surrogate@ %a)@]@ \
        @[(my_closure@ %a)@])@]"
      Closure_origin.print decl.closure_origin
      Continuation.print decl.continuation_param
      Continuation.print decl.exn_continuation_param
      decl.is_classic_mode
      (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.fprintf ppf ", ")
        (fun ppf (param, ty) ->
          Format.fprintf ppf "@[(%a@ :@ %a)@]"
            Parameter.print param
            print ty)) decl.params
      Name.Set.print decl.free_names_in_body
      (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.fprintf ppf ", ")
        (fun ppf ty ->
          Format.fprintf ppf "%a"
            print ty)) decl.result
      decl.stub
      Debuginfo.print_compact decl.dbg
      print_inline_attribute decl.inline
      print_specialise_attribute decl.specialise
      decl.is_a_functor
      Variable.Set.print (Lazy.force decl.invariant_params)
      (Misc.Stdlib.Option.print Format.pp_print_int) (Lazy.force decl.size)
      (Misc.Stdlib.Option.print Closure_id.print) decl.direct_call_surrogate
      Variable.print decl.my_closure

  and print_non_inlinable_function_declarations ppf
        (decl : non_inlinable_function_declarations) =
    Format.fprintf ppf
      "@[(Non_inlinable@ \
        @[(result (%a))@]@ \
        @[(direct_call_surrogate %a)@])@]"
      (Format.pp_print_list ~pp_sep:(fun ppf () -> Format.fprintf ppf ", ")
        (fun ppf ty ->
          Format.fprintf ppf "%a"
            print ty)) decl.result
      (Misc.Stdlib.Option.print Closure_id.print) decl.direct_call_surrogate

  and print_function_declarations ppf (decl : function_declarations) =
    match decl with
    | Inlinable decl -> print_inlinable_function_declaration ppf decl
    | Non_inlinable decl ->
      begin match decl with
      | None -> Format.fprintf ppf "Non_inlinable"
      | Some decl -> print_non_inlinable_function_declarations ppf decl
      end

  and print_set_of_closures ppf (set : set_of_closures) =
    Format.fprintf ppf
      "@[(Set_of_closures@ \
          @[(closures@ %a)@]@ \
          @[(closure_elements@ %a)@])@]"
      (print_extensibility (Closure_id.Map.print print_ty_fabricated))
        set.closures
      (print_extensibility (Var_within_closure.Map.print print_ty_value))
        set.closure_elements

  and print_closure ppf (closure : closure) =
    Format.fprintf ppf "@[(Closure (function_decls@ %a))@]"
      print_function_declarations closure.function_decls

  and print_tag_case ppf ({ env_extension; } : tag_case) =
    Format.fprintf ppf "@[(env_extension %a)@]"
      print_typing_environment env_extension

  and print_of_kind_fabricated ppf (o : of_kind_fabricated) =
    match o with
    | Tag tag_map ->
      Format.fprintf ppf "@[(Tags %a)@]" (Tag.Map.print print_tag_case) tag_map
    | Set_of_closures set -> print_set_of_closures ppf set
    | Closure closure -> print_closure ppf closure

  and print_ty_fabricated ppf (ty : ty_fabricated) =
    print_ty_generic print_of_kind_fabricated K.Value_kind.print ppf ty

  and print_of_kind_phantom ppf (o : of_kind_phantom) =
    match o with
    | Value ty_value ->
      Format.fprintf ppf "[@(Phantom %a)@]"
        print_ty_value ty_value
    | Naked_number (ty_naked_number, _kind) ->
      Format.fprintf ppf "[@(Phantom %a)@]"
        print_ty_naked_number ty_naked_number
    | Fabricated ty_fabricated ->
      Format.fprintf ppf "[@(Fabricated %a)@]"
        print_ty_fabricated ty_fabricated

  and print_ty_phantom ppf (ty : ty_phantom) =
    print_ty_generic print_of_kind_phantom K.Phantom_kind.print ppf ty

  and print ppf (t : t) =
    match t with
    | Value ty ->
      Format.fprintf ppf "@[(Value@ (%a))@]" print_ty_value ty
    | Naked_number (ty, _kind) ->
      Format.fprintf ppf "@[(Naked_number@ (%a))@]" print_ty_naked_number ty
    | Fabricated ty ->
      Format.fprintf ppf "@[(Fabricated@ (%a))@]" print_ty_fabricated ty
    | Phantom ty ->
      Format.fprintf ppf "@[(Phantom@ (%a))@]" print_ty_phantom ty

  and print_typing_environment ppf { names_to_types; levels_to_names;
        existentials; existential_freshening; } =
    if Name.Map.is_empty names_to_types then
      Format.pp_print_string ppf "Empty"
    else
      Format.fprintf ppf
        "@[((names_to_types@ %a)@ \
            (levels_to_names@ %a)@ \
            (existentials@ %a)@ \
            (existential_freshening@ %a))@]"
        (Name.Map.print print) names_to_types
        (Scope_level.Map.print Name.Set.print) levels_to_names
        Name.Set.print existentials
        Freshening.print existential_freshening

  let create_typing_environment () =
    let existential_freshening = Freshening.activate Freshening.empty in
    { names_to_types = Name.Map.empty;
      levels_to_names = Scope_level.Map.empty;
      existentials = Name.Set.empty;
      existential_freshening;
    }

  let singleton_typing_environment name t =
    let existential_freshening = Freshening.activate Freshening.empty in
    { names_to_types = Name.Map.add name t Name.Map.empty;
      levels_to_names = Scope_level.Map.empty;
      existentials = Name.Set.empty;
      existential_freshening;
    }

  let of_ty_value ty_value : t = Value ty_value

  let of_ty_naked_number (type n) (ty_naked_number : n ty_naked_number)
        (kind : n K.Naked_number.t) : t =
    Naked_number (ty_naked_number, kind)

  let of_ty_fabricated ty_fabricated : t = Fabricated ty_fabricated

  let free_names_or_alias free_names_contents (or_alias : _ or_alias) acc =
    match or_alias with
    | No_alias contents -> free_names_contents contents acc
    | Type _export_id -> acc
    | Type_of name -> Name.Set.add name acc

  let free_names_unknown_or_join free_names_contents free_names_unk
        (o : _ unknown_or_join) acc =
    match o with
    | Unknown unk -> free_names_unk unk acc
    | Join contents_list ->
      List.fold_left (fun free_names contents ->
          free_names_contents contents free_names)
        Name.Set.empty
        contents_list

  let free_names_ty free_names_contents ty acc =
    let free_names_unk _unk acc = acc in
    free_names_or_alias
      (free_names_unknown_or_join free_names_contents free_names_unk)
      ty
      acc

  let free_names_of_kind_naked_number (type n) (_ty : n of_kind_naked_number)
        acc =
    acc

  let rec free_names (t : t) acc =
    match t with
    | Value ty -> free_names_ty free_names_of_kind_value ty acc
    | Naked_number (ty, _kind) ->
      free_names_ty free_names_of_kind_naked_number ty acc
    | Fabricated ty -> free_names_ty free_names_of_kind_fabricated ty acc
    | Phantom ty ->
      (* CR mshinwell: We need to think more about this.  There may be a need
         for a normal name / phantom name split. *)
      free_names_ty free_names_of_kind_phantom ty acc

  and free_names_of_kind_value (of_kind : of_kind_value) acc =
    match of_kind with
    | Blocks_and_tagged_immediates { blocks; immediates; } ->
      let acc =
        Tag.Map.fold (fun _tag ((Join { by_length; }) : block_cases) acc ->
            Targetint.OCaml.Map.fold
              (fun _length (singleton : singleton_block) acc ->
                let acc =
                  free_names_of_typing_environment singleton.env_extension acc
                in
                Array.fold_left (fun acc (field : _ mutable_or_immutable) ->
                    match field with
                    | Immutable t -> free_names t acc
                    | Mutable -> acc)
                  acc singleton.fields)
              by_length
              acc)
          blocks
          acc
      in
      begin match immediates with
      | Unknown -> acc
      | Known immediates ->
        Immediate.Map.fold (fun _imm (case : immediate_case) acc ->
            free_names_of_typing_environment case.env_extension acc)
          immediates
          acc
      end
    | Boxed_number (Boxed_float n) ->
      free_names_ty free_names_of_kind_naked_number n acc
    | Boxed_number (Boxed_int32 n) ->
      free_names_ty free_names_of_kind_naked_number n acc
    | Boxed_number (Boxed_int64 n) ->
      free_names_ty free_names_of_kind_naked_number n acc
    | Boxed_number (Boxed_nativeint n) ->
      free_names_ty free_names_of_kind_naked_number n acc
    | Closures closures ->
      Closure_id.Map.fold (fun _closure_id (entry : closures_entry) acc ->
          free_names_ty free_names_of_kind_fabricated entry.set_of_closures acc)
        closures
        acc
    | String _ -> acc

  and free_names_of_kind_fabricated (of_kind : of_kind_fabricated) acc =
    match of_kind with
    | Tag tag_map ->
      Tag.Map.fold (fun _tag ({ env_extension; } : tag_case) acc ->
          free_names_of_typing_environment env_extension acc)
        tag_map
        acc
    | Set_of_closures set ->
      let acc =
        Closure_id.Map.fold (fun _closure_id ty_fabricated acc ->
            free_names_ty free_names_of_kind_fabricated ty_fabricated acc)
          (extensibility_contents set.closures) acc
      in
      Var_within_closure.Map.fold (fun _var ty_value acc ->
          free_names_ty free_names_of_kind_value ty_value acc)
        (extensibility_contents set.closure_elements) acc
    | Closure closure -> free_names_of_closure closure acc

  and free_names_of_closure (closure : closure) acc =
    match closure.function_decls with
    | Inlinable decl ->
      let acc =
        List.fold_left (fun acc t ->
          free_names t acc)
          acc
          decl.result
      in
      List.fold_left (fun acc (_param, t) ->
          free_names t acc)
        acc
        decl.params
    | Non_inlinable None -> acc
    | Non_inlinable (Some decls) ->
      List.fold_left (fun acc t ->
        free_names t acc)
        acc
        decls.result

  and free_names_of_kind_phantom (of_kind : of_kind_phantom) acc =
    match of_kind with
    | Value ty_value ->
      free_names_ty free_names_of_kind_value ty_value acc
    | Naked_number (ty_naked_number, _kind) ->
      free_names_ty free_names_of_kind_naked_number ty_naked_number acc
    | Fabricated ty_fabricated ->
      free_names_ty free_names_of_kind_fabricated ty_fabricated acc

  and free_names_of_typing_environment (env : typing_environment) acc =
    let all_names =
      Name.Map.fold (fun _bound_name t all_names ->
          free_names t all_names)
        env.names_to_types
        Name.Set.empty
    in
    let bound_names =
      Name.Set.union (Name.Map.keys env.names_to_types)
        env.existentials
    in
    let free_names = Name.Set.diff all_names bound_names in
    Name.Set.union free_names acc

  let free_names t = free_names t Name.Set.empty

  (* CR-someday mshinwell: Functions such as [alias] and [bottom] could be
     simplified if [K.t] were a GADT. *)

  let phantomize t : t =
    match t with
    | Value ty_value ->
      let of_kind_phantom : of_kind_phantom =
        Value ty_value
      in
      Phantom (No_alias (Join [of_kind_phantom]))
    | Naked_number (ty_naked_number, kind) ->
      let of_kind_phantom : of_kind_phantom =
        Naked_number (ty_naked_number, kind)
      in
      Phantom (No_alias (Join [of_kind_phantom]))
    | Fabricated ty_fabricated ->
      let of_kind_phantom : of_kind_phantom =
        Fabricated ty_fabricated
      in
      Phantom (No_alias (Join [of_kind_phantom]))
    | Phantom _ -> t

  module Name_or_export_id = struct
    type t =
      | Name of Name.t
      | Export_id of Export_id.t

    include Identifiable.Make (struct
      type nonrec t = t

      let compare t1 t2 =
        match t1, t2 with
        | Name _, Export_id _ -> -1
        | Export_id _, Name _ -> 1
        | Name name1, Name name2 -> Name.compare name1 name2
        | Export_id id1, Export_id id2 -> Export_id.compare id1 id2

      let equal t1 t2 =
        compare t1 t2 = 0
 
      let hash t =
        match t with
        | Name name -> Hashtbl.hash (0, Name.hash name)
        | Export_id id -> Hashtbl.hash (1, Export_id.hash id)

      let print ppf t =
        match t with
        | Name name -> Name.print ppf name
        | Export_id id -> Export_id.print ppf id
    end)
  end

  type type_of_name =
       ?local_env:typing_environment
    -> Name_or_export_id.t
    -> t option

  type 'a type_accessor = type_of_name:type_of_name -> 'a

  let alias_type_of (kind : K.t) name : t =
    match kind with
    | Value _ -> Value (Type_of name)
    | Naked_number Naked_immediate ->
      Naked_number (Type_of name, K.Naked_number.Naked_immediate)
    | Naked_number Naked_float ->
      Naked_number (Type_of name, K.Naked_number.Naked_float)
    | Naked_number Naked_int32 ->
      Naked_number (Type_of name, K.Naked_number.Naked_int32)
    | Naked_number Naked_int64 ->
      Naked_number (Type_of name, K.Naked_number.Naked_int64)
    | Naked_number Naked_nativeint ->
      Naked_number (Type_of name, K.Naked_number.Naked_nativeint)
    | Fabricated _ -> Fabricated (Type_of name)
    | Phantom _ -> Phantom (Type_of name)

  let alias_type_of_as_ty_value name : ty_value = Type_of name

  let alias_type_of_as_ty_fabricated name : ty_fabricated = Type_of name

  let alias_type (kind : K.t) export_id : t =
    match kind with
    | Value _ -> Value (Type export_id)
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
    | Fabricated _ -> Fabricated (Type export_id)
    | Phantom _ -> Phantom (Type export_id)

  let bottom_as_ty_value () : ty_value =
    No_alias (Join [])

  let bottom_as_ty_fabricated () : ty_fabricated =
    No_alias (Join [])

  let bottom (kind : K.t) : t =
    match kind with
    | Value _ -> Value (bottom_as_ty_value ())
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
    | Fabricated _ -> Fabricated (No_alias (Join []))
    | Phantom _ -> Phantom (No_alias (Join []))

  let any_value_as_ty_value value_kind : ty_value =
    No_alias (Unknown value_kind)

  let any_fabricated_as_ty_fabricated fabricated_kind : ty_fabricated =
    No_alias (Unknown fabricated_kind)

  let any_naked_float_as_ty_naked_float () : _ ty_naked_number =
    No_alias (Unknown ())

  let any_value value_kind : t =
    Value (any_value_as_ty_value value_kind)

  let any_tagged_immediate () : t =
    Value (No_alias (Join [Blocks_and_tagged_immediates {
      blocks = Tag.Map.empty;
      immediates = Unknown;
    }]))

  let any_naked_immediate () : t =
    Naked_number (No_alias (Unknown ()), K.Naked_number.Naked_immediate)

  let any_naked_float () : t =
    Naked_number (No_alias (Unknown ()), K.Naked_number.Naked_float)

  let any_naked_int32 () : t =
    Naked_number (No_alias (Unknown ()), K.Naked_number.Naked_int32)

  let any_naked_int64 () : t =
    Naked_number (No_alias (Unknown ()), K.Naked_number.Naked_int64)

  let any_naked_nativeint () : t =
    Naked_number (No_alias (Unknown ()), K.Naked_number.Naked_nativeint)

  let any_fabricated value_kind : t =
    Fabricated (No_alias (Unknown value_kind))

  let any_phantom () : t =
    Phantom (No_alias (Unknown K.Phantom_kind.Unknown))

  let unknown (kind : K.t) =
    match kind with
    | Value value_kind -> any_value value_kind
    | Naked_number Naked_immediate -> any_naked_immediate ()
    | Naked_number Naked_float -> any_naked_float ()
    | Naked_number Naked_int32 -> any_naked_int32 ()
    | Naked_number Naked_int64 -> any_naked_int64 ()
    | Naked_number Naked_nativeint -> any_naked_nativeint ()
    | Fabricated value_kind -> any_fabricated value_kind
    | Phantom _ -> any_phantom ()

  let these_naked_immediates (is : Immediate.Set.t) : t =
    let of_kind : _ of_kind_naked_number = Immediate is in
    Naked_number (No_alias (Join [of_kind]),
      K.Naked_number.Naked_immediate)

  let these_naked_floats (is : Float_by_bit_pattern.Set.t) : t =
    let of_kind : _ of_kind_naked_number = Float is in
    Naked_number (No_alias (Join [of_kind]),
      K.Naked_number.Naked_float)

  let these_naked_int32s (is : Int32.Set.t) : t =
    let of_kind : _ of_kind_naked_number = Int32 is in
    Naked_number (No_alias (Join [of_kind]),
      K.Naked_number.Naked_int32)

  let these_naked_int64s (is : Int64.Set.t) : t =
    let of_kind : _ of_kind_naked_number = Int64 is in
    Naked_number (No_alias (Join [of_kind]),
      K.Naked_number.Naked_int64)

  let these_naked_nativeints (is : Targetint.Set.t) : t =
    let of_kind : _ of_kind_naked_number = Nativeint is in
    Naked_number (No_alias (Join [of_kind]),
      K.Naked_number.Naked_nativeint)

  let this_naked_immediate i =
    these_naked_immediates (Immediate.Set.singleton i)

  let this_naked_float f =
    these_naked_floats (Float_by_bit_pattern.Set.singleton f)

  let this_naked_float_as_ty_naked_float f =
    let fs = Float_by_bit_pattern.Set.singleton f in
    let of_kind : _ of_kind_naked_number = Float fs in
    No_alias (Join [of_kind])

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
        Boxed_number (Boxed_float ty_naked_float)]))
    | Value _
    | Naked_number _
    | Fabricated _
    | Phantom _ ->
      Misc.fatal_errorf "Type of wrong kind for [box_float]: %a"
        print t

  let box_int32 (t : t) : t =
    match t with
    | Naked_number (ty_naked_int32, K.Naked_number.Naked_int32) ->
      Value (No_alias (Join [
        Boxed_number (Boxed_int32 ty_naked_int32)]))
    | Value _
    | Naked_number _
    | Fabricated _
    | Phantom _ ->
      Misc.fatal_errorf "Type of wrong kind for [box_int32]: %a"
        print t

  let box_int64 (t : t) : t =
    match t with
    | Naked_number (ty_naked_int64, K.Naked_number.Naked_int64) ->
      Value (No_alias (Join [
        Boxed_number (Boxed_int64 ty_naked_int64)]))
    | Value _
    | Naked_number _
    | Fabricated _
    | Phantom _ ->
      Misc.fatal_errorf "Type of wrong kind for [box_int64]: %a"
        print t

  let box_nativeint (t : t) : t =
    match t with
    | Naked_number (ty_naked_nativeint, K.Naked_number.Naked_nativeint) ->
      Value (No_alias (Join [
        Boxed_number (Boxed_nativeint ty_naked_nativeint)]))
    | Value _
    | Naked_number _
    | Fabricated _
    | Phantom _ ->
      Misc.fatal_errorf "Type of wrong kind for [box_nativeint]: %a"
        print t

  let these_tagged_immediates imms : t =
    (* CR mshinwell: Hmm, or should this return "any_tagged_immediate" if the
       set is empty? *)
    if Immediate.Set.is_empty imms then
      bottom (K.value Definitely_immediate)
    else
      let immediates =
        Immediate.Set.fold (fun imm map ->
            let case : immediate_case =
              { env_extension = create_typing_environment ();
              }
            in
            Immediate.Map.add imm case map)
          imms
          Immediate.Map.empty
      in
      (* CR mshinwell: See if we can have a creation function for this *)
      let blocks_and_tagged_immediates : blocks_and_tagged_immediates =
        { immediates = Known immediates;
          blocks = Tag.Map.empty;
        }
      in
      Value (No_alias (Join [Blocks_and_tagged_immediates
        blocks_and_tagged_immediates]))

  let this_tagged_immediate imm =
    these_tagged_immediates (Immediate.Set.singleton imm)

  let this_boxed_float f = box_float (this_naked_float f)
  let this_boxed_int32 f = box_int32 (this_naked_int32 f)
  let this_boxed_int64 f = box_int64 (this_naked_int64 f)
  let this_boxed_nativeint f = box_nativeint (this_naked_nativeint f)

  let these_boxed_floats f = box_float (these_naked_floats f)
  let these_boxed_int32s f = box_int32 (these_naked_int32s f)
  let these_boxed_int64s f = box_int64 (these_naked_int64s f)
  let these_boxed_nativeints f = box_nativeint (these_naked_nativeints f)

  let these_tags_as_ty_fabricated tags_to_env_extensions : ty_fabricated =
    let tag_map =
      Tag.Map.map (fun env : tag_case ->
          { env_extension = env; })
        tags_to_env_extensions
    in
    No_alias (Join [Tag tag_map])

  let these_tags tags_to_env_extensions : t =
    Fabricated (these_tags_as_ty_fabricated tags_to_env_extensions)

  let this_tag_as_ty_fabricated tag =
    let tags_to_env_extensions =
      Tag.Map.add tag (create_typing_environment ()) Tag.Map.empty
    in
    these_tags_as_ty_fabricated tags_to_env_extensions

  let this_tag tag : t =
    Fabricated (this_tag_as_ty_fabricated tag)

  let any_tag_as_ty_fabricated () : ty_fabricated =
    No_alias (Unknown K.Value_kind.Definitely_immediate)

  let this_immutable_string_as_ty_value str : ty_value =
    let str : String_info.t =
      { contents = Contents str;
        (* CR mshinwell: Possibility for exception? *)
        size = Targetint.OCaml.of_int (String.length str);
      }
    in
    let str = String_info.Set.singleton str in
    No_alias (Join [String str])

  let this_immutable_string str : t =
    Value (this_immutable_string_as_ty_value str)

  let immutable_string_as_ty_value ~size : ty_value =
    let str : String_info.t =
      { contents = Unknown_or_mutable;
        size;
      }
    in
    let str = String_info.Set.singleton str in
    No_alias (Join [String str])

  let immutable_string ~size : t =
    Value (immutable_string_as_ty_value ~size)

  let mutable_string ~size : t =
    let str : String_info.t =
      { contents = Unknown_or_mutable;
        size;
      }
    in
    let str = String_info.Set.singleton str in
    Value (No_alias (Join [String str]))

  let mutable_float_array ~size : t =
    let fields =
      Array.init (Targetint.OCaml.to_int size)
        (fun _index : _ mutable_or_immutable -> Mutable)
    in
    let singleton_block : singleton_block =
      { env_extension = create_typing_environment ();
        fields;
      }
    in
    let by_length =
      Targetint.OCaml.Map.add size singleton_block
        Targetint.OCaml.Map.empty
    in
    let block_cases : block_cases = Join { by_length; } in
    let blocks =
      Tag.Map.add Tag.double_array_tag block_cases Tag.Map.empty
    in
    let blocks_imms : blocks_and_tagged_immediates =
      { immediates = Known Immediate.Map.empty;
        blocks;
      }
    in
    Value (No_alias (Join [Blocks_and_tagged_immediates blocks_imms]))

  let immutable_float_array fields : t =
    match Targetint.OCaml.of_int_option (Array.length fields) with
    | None ->
      Misc.fatal_error "Immutable float array too long for target"
    | Some length ->
      let fields =
        Array.map (fun ty_naked_number : _ mutable_or_immutable ->
            let t : t =
              Naked_number (ty_naked_number, K.Naked_number.Naked_float)
            in
            Immutable t)
          fields
      in
      let singleton_block : singleton_block =
        { env_extension = create_typing_environment ();
          fields;
        }
      in
      let by_length =
        Targetint.OCaml.Map.add length singleton_block
          Targetint.OCaml.Map.empty
      in
      let block_cases : block_cases = Join { by_length; } in
      let blocks =
        Tag.Map.add Tag.double_array_tag block_cases Tag.Map.empty
      in
      let blocks_imms : blocks_and_tagged_immediates =
        { immediates = Known Immediate.Map.empty;
          blocks;
        }
      in
      Value (No_alias (Join [Blocks_and_tagged_immediates blocks_imms]))

  let this_immutable_float_array fields : t =
    let make_field f : _ ty_naked_number =
      No_alias (Join [Float (Float_by_bit_pattern.Set.singleton f)])
    in
    let fields = Array.map make_field fields in
    immutable_float_array fields

  let block tag ~fields =
    let tag = Tag.Scannable.to_tag tag in
    match Targetint.OCaml.of_int_option (Array.length fields) with
    | None ->
      Misc.fatal_error "Block too long for target"
    | Some length ->
      let fields =
        Array.map
          (fun (field : _ mutable_or_immutable) : t mutable_or_immutable ->
            match field with
            | Immutable t -> Immutable t
            | Mutable -> Mutable)
          fields
      in
      let singleton_block : singleton_block =
        { env_extension = create_typing_environment ();
          fields;
        }
      in
      let by_length =
        Targetint.OCaml.Map.add length singleton_block
          Targetint.OCaml.Map.empty
      in
      let block_cases : block_cases = Join { by_length; } in
      let blocks = Tag.Map.add tag block_cases Tag.Map.empty in
      let blocks_imms : blocks_and_tagged_immediates =
        { immediates = Known Immediate.Map.empty;
          blocks;
        }
      in
      Value (No_alias (Join [Blocks_and_tagged_immediates blocks_imms]))

  let block_of_values tag ~fields =
    (* CR mshinwell: Express in terms of the new [block] function above *)
    let tag = Tag.Scannable.to_tag tag in
    match Targetint.OCaml.of_int_option (Array.length fields) with
    | None ->
      Misc.fatal_error "Block of values too long for target"
    | Some length ->
      let fields =
        Array.map
          (fun (field : _ mutable_or_immutable) : t mutable_or_immutable ->
            match field with
            | Immutable ty_value -> Immutable (Value ty_value)
            | Mutable -> Mutable)
          fields
      in
      let singleton_block : singleton_block =
        { env_extension = create_typing_environment ();
          fields;
        }
      in
      let by_length =
        Targetint.OCaml.Map.add length singleton_block
          Targetint.OCaml.Map.empty
      in
      let block_cases : block_cases = Join { by_length; } in
      let blocks = Tag.Map.add tag block_cases Tag.Map.empty in
      let blocks_imms : blocks_and_tagged_immediates =
        { immediates = Known Immediate.Map.empty;
          blocks;
        }
      in
      Value (No_alias (Join [Blocks_and_tagged_immediates blocks_imms]))

  let block_of_unknown_values tag value_kind ~size =
    let fields =
      Array.init size (fun _index : _ mutable_or_immutable ->
        Immutable (any_value_as_ty_value value_kind))
    in
    block_of_values tag ~fields

  let any_boxed_float () = box_float (any_naked_float ())
  let any_boxed_int32 () = box_int32 (any_naked_int32 ())
  let any_boxed_int64 () = box_int64 (any_naked_int64 ())
  let any_boxed_nativeint () = box_nativeint (any_naked_nativeint ())

  let force_to_kind_value t =
    match t with
    | Value ty_value -> ty_value
    | Naked_number _
    | Fabricated _
    | Phantom _ ->
      Misc.fatal_errorf "Type has wrong kind (expected [Value]):@ %a"
        print t

  let force_to_kind_naked_immediate (t : t) : Immediate.Set.t ty_naked_number =
    match t with
    | Naked_number (ty_naked_number, K.Naked_number.Naked_immediate) ->
      ty_naked_number
    | Naked_number _
    | Fabricated _
    | Value _
    | Phantom _ ->
      Misc.fatal_errorf
        "Type has wrong kind (expected [Naked_number Immediate]):@ %a"
        print t

  let force_to_kind_naked_float (t : t)
        : Float_by_bit_pattern.Set.t ty_naked_number =
    match t with
    | Naked_number (ty_naked_number, K.Naked_number.Naked_float) ->
      ty_naked_number
    | Naked_number _
    | Fabricated _
    | Value _
    | Phantom _ ->
      Misc.fatal_errorf
        "Type has wrong kind (expected [Naked_number Float]):@ %a"
        print t

  let force_to_kind_naked_int32 (t : t) : Int32.Set.t ty_naked_number =
    match t with
    | Naked_number (ty_naked_number, K.Naked_number.Naked_int32) ->
      ty_naked_number
    | Naked_number _
    | Fabricated _
    | Value _
    | Phantom _ ->
      Misc.fatal_errorf
        "Type has wrong kind (expected [Naked_number Int32]):@ %a"
        print t

  let force_to_kind_naked_int64 (t : t) : Int64.Set.t ty_naked_number =
    match t with
    | Naked_number (ty_naked_number, K.Naked_number.Naked_int64) ->
      ty_naked_number
    | Naked_number _
    | Fabricated _
    | Value _
    | Phantom _ ->
      Misc.fatal_errorf
        "Type has wrong kind (expected [Naked_number Int64]):@ %a"
        print t

  let force_to_kind_naked_nativeint (t : t) : Targetint.Set.t ty_naked_number =
    match t with
    | Naked_number (ty_naked_number, K.Naked_number.Naked_nativeint) ->
      ty_naked_number
    | Naked_number _
    | Fabricated _
    | Value _
    | Phantom _ ->
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
    | Value _, _
    | Phantom _, _ ->
      Misc.fatal_errorf "Type has wrong kind (expected [Naked_number %a]):@ %a"
        K.Naked_number.print kind
        print t

  let force_to_kind_fabricated t =
    match t with
    | Fabricated ty_fabricated -> ty_fabricated
    | Value _
    | Naked_number _
    | Phantom _ ->
      Misc.fatal_errorf "Type has wrong kind (expected [Fabricated]):@ %a"
        print t

  let force_to_kind_phantom t =
    match t with
    | Phantom ty_phantom -> ty_phantom
    | Value _
    | Naked_number _
    | Fabricated _ ->
      Misc.fatal_errorf "Type has wrong kind (expected [Phantom]):@ %a"
        print t

  let resolve_aliases_on_ty (type a)
        ~(type_of_name : type_of_name)
        ~(force_to_kind : t -> (a, _) ty)
        (ty : (a, _) ty)
        : (a, _) ty * (Name.t option) =
    let rec resolve_aliases names_seen ~canonical_name (ty : (a, _) ty) =
      let resolve (name : Name_or_export_id.t) =
        if Name_or_export_id.Set.mem name names_seen then begin
          (* CR-soon mshinwell: Improve message -- but this means passing the
             printing functions to this function. *)
          Misc.fatal_errorf "Loop on %a whilst resolving aliases"
            Name_or_export_id.print name
        end;
        let canonical_name =
          match name with
          | Name name -> Some name
          | Export_id _ -> None
        in
        begin match type_of_name name with
        | None ->
          (* The type could not be obtained but we still wish to keep the
             name (in case for example a .cmx file subsequently becomes
             available). *)
          ty, canonical_name
        | Some t ->
          let names_seen = Name_or_export_id.Set.add name names_seen in
          let ty = force_to_kind t in
          resolve_aliases names_seen ~canonical_name ty
        end
      in
      match ty with
      | No_alias _ -> ty, canonical_name
      | Type export_id -> resolve (Name_or_export_id.Export_id export_id)
      | Type_of name -> resolve (Name_or_export_id.Name name)
    in
    resolve_aliases Name_or_export_id.Set.empty ~canonical_name:None ty

  let resolve_aliases_and_squash_unresolved_names_on_ty ~type_of_name
        ~force_to_kind ~unknown_payload ty =
    let ty, canonical_name =
      resolve_aliases_on_ty ~force_to_kind ~type_of_name ty
    in
    let ty =
      match ty with
      | No_alias ty -> ty
      | Type _ | Type_of _ -> Unknown unknown_payload
    in
    ty, canonical_name

  let resolve_aliases ~type_of_name t : t * (Name.t option) =
    match t with
    | Value ty ->
      let force_to_kind = force_to_kind_value in
      let ty, canonical_name =
        resolve_aliases_on_ty ~force_to_kind ~type_of_name ty
      in
      Value ty, canonical_name
    | Naked_number (ty, kind) ->
      let force_to_kind = force_to_kind_naked_number kind in
      let ty, canonical_name =
        resolve_aliases_on_ty ~force_to_kind ~type_of_name ty
      in
      Naked_number (ty, kind), canonical_name
    | Fabricated ty ->
      let force_to_kind = force_to_kind_fabricated in
      let ty, canonical_name =
        resolve_aliases_on_ty ~force_to_kind ~type_of_name ty
      in
      Fabricated ty, canonical_name
    | Phantom ty ->
      let force_to_kind = force_to_kind_phantom in
      let ty, canonical_name =
        resolve_aliases_on_ty ~force_to_kind ~type_of_name ty
      in
      Phantom ty, canonical_name

  let resolve_aliases_and_squash_unresolved_names ~type_of_name t
        : t * (Name.t option) =
    match t with
    | Value ty ->
      let force_to_kind = force_to_kind_value in
      let ty, canonical_name =
        resolve_aliases_and_squash_unresolved_names_on_ty ~force_to_kind
          ~type_of_name ~unknown_payload:K.Value_kind.Unknown ty
      in
      Value (No_alias ty), canonical_name
    | Naked_number (ty, kind) ->
      let force_to_kind
          = force_to_kind_naked_number kind in
      let ty, canonical_name =
        resolve_aliases_and_squash_unresolved_names_on_ty ~force_to_kind
          ~type_of_name ~unknown_payload:() ty
      in
      Naked_number (No_alias ty, kind), canonical_name
    | Fabricated ty ->
      let force_to_kind
          = force_to_kind_fabricated in
      let ty, canonical_name =
        resolve_aliases_and_squash_unresolved_names_on_ty ~force_to_kind
          ~type_of_name ~unknown_payload:K.Value_kind.Unknown ty
      in
      Fabricated (No_alias ty), canonical_name
    | Phantom ty ->
      let force_to_kind
          = force_to_kind_phantom in
      let ty, canonical_name =
        resolve_aliases_and_squash_unresolved_names_on_ty ~force_to_kind
          ~type_of_name ~unknown_payload:K.Phantom_kind.Unknown ty
      in
      Phantom (No_alias ty), canonical_name

  let value_kind_ty_value ~type_of_name ty =
    let value_kind_ty_value (ty : ty_value) : K.Value_kind.t =
      let (ty : _ unknown_or_join), _canonical_name =
        resolve_aliases_and_squash_unresolved_names_on_ty
          ~force_to_kind:force_to_kind_value
          ~type_of_name
          ~unknown_payload:K.Value_kind.Unknown
          ty
      in
      match ty with
      | Unknown value_kind -> value_kind
      | Join of_kind_values ->
        List.fold_left (fun result of_kind_value ->
            let this_kind : K.Value_kind.t =
              match of_kind_value with
              | Blocks_and_tagged_immediates { blocks; immediates; } ->
                if Tag.Map.is_empty blocks then
                  Definitely_immediate
                else
                  begin match immediates with
                  | Known imms when Immediate.Map.is_empty imms ->
                    Definitely_pointer
                  | Known _ | Unknown ->
                    Unknown
                  end
              | Boxed_number _ | Closures _ | String _ -> Definitely_pointer
            in
            K.Value_kind.join result this_kind)
          K.Value_kind.Bottom
          of_kind_values
    in
    value_kind_ty_value ty

  let kind_ty_value ~type_of_name (ty : ty_value) =
    let value_kind =
      value_kind_ty_value ~type_of_name ty
    in
    K.value value_kind

  let value_kind_ty_fabricated ~type_of_name ty =
    let value_kind_ty_fabricated (ty : ty_fabricated) : K.Value_kind.t =
      let (ty : _ unknown_or_join), _canonical_name =
        resolve_aliases_and_squash_unresolved_names_on_ty
          ~force_to_kind:force_to_kind_fabricated
          ~type_of_name
          ~unknown_payload:K.Value_kind.Unknown
          ty
      in
      match ty with
      | Unknown value_kind -> value_kind
      | Join of_kind_fabricateds ->
        List.fold_left (fun result of_kind_fabricated ->
            let this_kind : K.Value_kind.t =
              match of_kind_fabricated with
              | Tag _ -> K.Value_kind.Definitely_immediate
              | Set_of_closures _
              | Closure _ -> K.Value_kind.Definitely_pointer
            in
            K.Value_kind.join result this_kind)
          K.Value_kind.Bottom
          of_kind_fabricateds
    in
    value_kind_ty_fabricated ty

  let kind_ty_fabricated ~type_of_name ty =
    let value_kind = value_kind_ty_fabricated ~type_of_name ty in
    K.fabricated value_kind

  let phantom_kind_ty_phantom ~type_of_name ty =
    let phantom_kind_ty_phantom (ty : ty_phantom)
          : K.Phantom_kind.t =
      let (ty : _ unknown_or_join), _canonical_name =
        resolve_aliases_and_squash_unresolved_names_on_ty
          ~force_to_kind:force_to_kind_phantom
          ~type_of_name
          ~unknown_payload:K.Phantom_kind.Unknown
          ty
      in
      match ty with
      | Unknown phantom_kind -> phantom_kind
      | Join of_kind_phantoms ->
        List.fold_left (fun result (of_kind_phantom : of_kind_phantom) ->
            let this_kind : K.Phantom_kind.t =
              match of_kind_phantom with
              | Value ty_value ->
                let value_kind =
                  value_kind_ty_value ~type_of_name ty_value
                in
                Value value_kind
              | Naked_number (_, K.Naked_number.Naked_immediate) ->
                Naked_number Naked_immediate
              | Naked_number (_, K.Naked_number.Naked_float) ->
                Naked_number Naked_float
              | Naked_number (_, K.Naked_number.Naked_int32) ->
                Naked_number Naked_int32
              | Naked_number (_, K.Naked_number.Naked_int64) ->
                Naked_number Naked_int64
              | Naked_number (_, K.Naked_number.Naked_nativeint) ->
                Naked_number Naked_nativeint
              | Fabricated ty_fabricated ->
                let value_kind =
                  value_kind_ty_fabricated ~type_of_name ty_fabricated
                in
                Fabricated value_kind
            in
            K.Phantom_kind.join result this_kind)
          K.Phantom_kind.Bottom
          of_kind_phantoms
    in
    phantom_kind_ty_phantom ty

  let kind_ty_phantom ~type_of_name ty =
    let phantom_kind = phantom_kind_ty_phantom ~type_of_name ty in
    K.phantom phantom_kind

  let kind ~type_of_name (t : t) =
    match t with
    | Value ty -> kind_ty_value ~type_of_name ty
    | Naked_number (_, K.Naked_number.Naked_immediate) ->
      K.naked_immediate ()
    | Naked_number (_, K.Naked_number.Naked_float) ->
      K.naked_float ()
    | Naked_number (_, K.Naked_number.Naked_int32) ->
      K.naked_int32 ()
    | Naked_number (_, K.Naked_number.Naked_int64) ->
      K.naked_int64 ()
    | Naked_number (_, K.Naked_number.Naked_nativeint) ->
      K.naked_nativeint ()
    | Fabricated ty -> kind_ty_fabricated ~type_of_name ty
    | Phantom ty -> kind_ty_phantom ~type_of_name ty

  let check_of_kind ~type_of_name t (expected_kind : K.t) =
    let actual_kind = kind ~type_of_name t in
    if not (K.equal actual_kind expected_kind) then begin
      Misc.fatal_errorf "Type has wrong kind: have %a but expected %a"
        K.print actual_kind
        K.print expected_kind
    end

  let bottom_like ~type_of_name t =
    let kind = kind ~type_of_name t in
    bottom kind

  let unknown_like ~type_of_name t =
    let kind = kind ~type_of_name t in
    unknown kind

  let create_inlinable_function_declaration ~is_classic_mode ~closure_origin
        ~continuation_param ~exn_continuation_param
        ~params ~body ~result ~stub ~dbg ~inline
        ~specialise ~is_a_functor ~invariant_params ~size ~direct_call_surrogate
        ~my_closure : function_declarations =
    Inlinable {
      closure_origin;
      continuation_param;
      exn_continuation_param;
      is_classic_mode;
      params;
      body;
      code_id = Code_id.create (Compilation_unit.get_current_exn ());
      free_names_in_body = Expr.free_names body;
      result_env_extension = create_typing_environment ();
      result;
      stub;
      dbg;
      inline;
      specialise;
      is_a_functor;
      invariant_params;
      size;
      direct_call_surrogate;
      my_closure;
    }

  let create_non_inlinable_function_declaration ~params ~result
        ~result_env_extension ~direct_call_surrogate
        : function_declarations =
    let decl : non_inlinable_function_declarations =
      { params;
        result;
        result_env_extension;
        direct_call_surrogate;
      }
    in
    Non_inlinable (Some decl)

  let closure function_decls : ty_fabricated =
    No_alias (Join [Closure { function_decls; }])

  let closures_entry ~set_of_closures : closures_entry =
    { set_of_closures; }

  let closures by_closure_id : t =
    Value (No_alias (Join [Closures by_closure_id]))

  let set_of_closures ~closures ~closure_elements =
    let set_of_closures : set_of_closures =
      { closures;
        closure_elements;
      }
    in
    let no_closures =
      match set_of_closures.closures with
      | Open _ -> false
      | Exactly map -> Closure_id.Map.is_empty map
    in
    if no_closures then
      Fabricated (No_alias (Join []))
    else
      Fabricated (No_alias (Join [Set_of_closures set_of_closures]))

  type 'a or_bottom =
    | Ok of 'a
    | Bottom

  type judgements_from_meet = (Name.t * t) list

  module type Meet_and_join_spec = sig
    type of_kind_foo
    type unk

    val to_type : (of_kind_foo, unk) ty -> t

    val force_to_kind : t -> (of_kind_foo, unk) ty

    val unknown_payload : unk

    val meet_of_kind_foo
       : (of_kind_foo
      -> of_kind_foo
      -> (of_kind_foo * judgements_from_meet) or_bottom) type_accessor

    val meet_unk : unk -> unk -> unk

    (* If the supplied types are compatible, the join must be pushed inside
       their structure, and [Ok] returned.  Otherwise [Unknown] must be
       returned. *)
    (* CR mshinwell: add comment about requirement for equivalence
       relationness *)
    val join_of_kind_foo
       : (of_kind_foo
      -> of_kind_foo
      -> of_kind_foo or_unknown) type_accessor

    val join_unk : unk -> unk -> unk
  end

  module type Meet_and_join = sig
    type of_kind_foo
    type unk

    (* Least upper bound of two types of a particular kind. *)
    val join_ty
       : ((of_kind_foo, unk) ty
      -> (of_kind_foo, unk) ty
      -> (of_kind_foo, unk) ty) type_accessor

    (* Greatest lower bound of two types of a particular kind.
       The computation of such may yield new judgements. *)
    val meet_ty
       : ((of_kind_foo, unk) ty
      -> (of_kind_foo, unk) ty
      -> (of_kind_foo, unk) ty * judgements_from_meet) type_accessor
  end

  (* CR mshinwell: Work out which properties we need to prove, e.g.
     Distributivity of meet over join:
       X n (X' u Y') == (X n X') u (X n Y'). *)
  module Make_meet_and_join (S : Meet_and_join_spec) : sig
    include Meet_and_join
      with type of_kind_foo := S.of_kind_foo
      with type unk := S.unk
  end = struct
    let rec join_on_unknown_or_join ~type_of_name
          (uj1 : (S.of_kind_foo, S.unk) unknown_or_join)
          (uj2 : (S.of_kind_foo, S.unk) unknown_or_join)
          : (S.of_kind_foo, S.unk) unknown_or_join =
      match uj1, uj2 with
      | Unknown unk_left, Unknown unk_right ->
        Unknown (S.join_unk unk_left unk_right)
      | Unknown unk, _ | _, Unknown unk -> Unknown unk
      | Join of_kind_foos1, Join of_kind_foos2 ->
        (* We rely on the invariant in flambda_type0_intf.ml.
           Everything in [of_kind_foos1] is mutually incompatible with each
           other; likewise in [of_kind_foos2]. *)
        let of_kind_foos =
          List.fold_left (fun of_kind_foos of_kind_foo ->
              (* [of_kind_foo] can be compatible with at most one of the
                 elements of [of_kind_foos]. *)
              let found_one = ref false in
              let joined =
                List.map (fun of_kind_foo' ->
                    let join =
                      S.join_of_kind_foo ~type_of_name of_kind_foo of_kind_foo'
                    in
                    match join with
                    | Known of_kind_foo ->
                      if !found_one then begin
                        (* CR mshinwell: Add detail showing what was wrong. *)
                        Misc.fatal_errorf "Invariant broken for [Join]"
                      end;
                      found_one := true;
                      of_kind_foo
                    | Unknown -> of_kind_foo')
                  of_kind_foos
              in
              if not !found_one then of_kind_foo :: of_kind_foos
              else joined)
            of_kind_foos2
            of_kind_foos1
        in
        Join of_kind_foos

    and join_ty ~type_of_name
          (or_alias1 : (S.of_kind_foo, S.unk) ty)
          (or_alias2 : (S.of_kind_foo, S.unk) ty)
          : (S.of_kind_foo, S.unk) ty =
      let unknown_or_join1, canonical_name1 =
        resolve_aliases_and_squash_unresolved_names_on_ty ~type_of_name
          ~force_to_kind:S.force_to_kind
          ~unknown_payload:S.unknown_payload
          or_alias1
      in
      let unknown_or_join2, canonical_name2 =
        resolve_aliases_and_squash_unresolved_names_on_ty ~type_of_name
          ~force_to_kind:S.force_to_kind
          ~unknown_payload:S.unknown_payload
          or_alias2
      in
      match canonical_name1, canonical_name2 with
      | Some name1, Some name2 when Name.equal name1 name2 ->
        Type_of name1
      | _, _ ->
        let unknown_or_join =
          join_on_unknown_or_join ~type_of_name
            unknown_or_join1 unknown_or_join2
        in
        No_alias unknown_or_join

    let rec meet_on_unknown_or_join ~type_of_name
          (ou1 : (S.of_kind_foo, S.unk) unknown_or_join)
          (ou2 : (S.of_kind_foo, S.unk) unknown_or_join)
          : (S.of_kind_foo, S.unk) unknown_or_join * judgements_from_meet =
      match ou1, ou2 with
      | Unknown unk1, Unknown unk2 -> Unknown (S.meet_unk unk1 unk2), []
      | Unknown _, ou2 -> ou2, []
      | ou1, Unknown _ -> ou1, []
      | Join of_kind_foos1, Join of_kind_foos2 ->
        let of_kind_foos, judgements =
          List.fold_left (fun (of_kind_foos, judgements) of_kind_foo ->
              let new_judgements = ref [] in
              let of_kind_foos =
                Misc.Stdlib.List.filter_map (fun of_kind_foo' ->
                    let meet =
                      S.meet_of_kind_foo ~type_of_name of_kind_foo of_kind_foo'
                    in
                    match meet with
                    | Ok (of_kind_foo, new_judgements') ->
                      new_judgements := new_judgements' @ !new_judgements;
                      Some of_kind_foo
                    | Bottom -> None)
                  of_kind_foos
              in
              of_kind_foos, !new_judgements @ judgements)
            (of_kind_foos2, [])
            of_kind_foos1
        in
        Join of_kind_foos, judgements

    and meet_ty ~type_of_name
          (or_alias1 : (S.of_kind_foo, S.unk) ty)
          (or_alias2 : (S.of_kind_foo, S.unk) ty)
          : (S.of_kind_foo, S.unk) ty * judgements_from_meet =
      let unknown_or_join1, canonical_name1 =
        resolve_aliases_and_squash_unresolved_names_on_ty ~type_of_name
          ~force_to_kind:S.force_to_kind
          ~unknown_payload:S.unknown_payload
          or_alias1
      in
      let unknown_or_join2, canonical_name2 =
        resolve_aliases_and_squash_unresolved_names_on_ty ~type_of_name
          ~force_to_kind:S.force_to_kind
          ~unknown_payload:S.unknown_payload
          or_alias2
      in
      let normal_case ~names_to_bind =
        let unknown_or_join, new_judgements =
          meet_on_unknown_or_join ~type_of_name
            unknown_or_join1 unknown_or_join2
        in
        let new_judgements' =
          List.map (fun name -> name, S.to_type (No_alias unknown_or_join))
            names_to_bind
        in
        No_alias unknown_or_join, new_judgements @ new_judgements'
      in
      match canonical_name1, canonical_name2 with
      | Some name1, Some name2 when Name.equal name1 name2 ->
        Type_of name1, []
      (* XXX This should bind the type to just one of the names, and set the
         other name equal to that *)
      | Some name1, Some name2 -> normal_case ~names_to_bind:[name1; name2]
      | Some name1, None -> normal_case ~names_to_bind:[name1]
      | None, Some name2 -> normal_case ~names_to_bind:[name2]
      | None, None -> normal_case ~names_to_bind:[]
  end

  module rec Meet_and_join_value : sig
    include Meet_and_join
      with type of_kind_foo := of_kind_value
      with type unk := K.Value_kind.t
  end = Make_meet_and_join (struct
    type of_kind_foo = of_kind_value
    type unk = K.Value_kind.t

    let to_type ty : t = Value ty
    let force_to_kind = force_to_kind_value

    let unknown_payload = K.Value_kind.Unknown

    let meet_immediate_case ~type_of_name
          ({ env_extension = env_extension1; } : immediate_case)
          ({ env_extension = env_extension2; } : immediate_case)
          : immediate_case =
      let env_extension =
        Meet_and_join.meet_typing_environment ~type_of_name
          env_extension1 env_extension2
      in
      { env_extension; }

    let join_immediate_case ~type_of_name
          ({ env_extension = env_extension1; } : immediate_case)
          ({ env_extension = env_extension2; } : immediate_case)
          : immediate_case =
      let env_extension =
        Meet_and_join.join_typing_environment ~type_of_name
          env_extension1 env_extension2
      in
      { env_extension; }

    let meet_immediates ~type_of_name immediates1 immediates2 : _ or_bottom =
      let immediates =
        Immediate.Map.inter_merge (fun imm1 imm2 ->
            meet_immediate_case ~type_of_name imm1 imm2)
          immediates1
          immediates2
      in
      if Immediate.Map.is_empty immediates then Bottom
      else Ok immediates

    let join_immediates ~type_of_name immediates1 immediates2 =
      Immediate.Map.union_merge (fun imm1 imm2 ->
          join_immediate_case ~type_of_name imm1 imm2)
        immediates1
        immediates2

    let meet_singleton_block ~type_of_name
          ({ env_extension = env_extension1;
             fields = fields1;
           } : singleton_block)
          ({ env_extension = env_extension2;
             fields = fields2;
           } : singleton_block) : singleton_block * judgements_from_meet =
      let env_extension =
        Meet_and_join.meet_typing_environment ~type_of_name
          env_extension1 env_extension2
      in
      assert (Array.length fields1 = Array.length fields2);
      let judgements = ref [] in
      let fields =
        Array.map2
          (fun (field1 : _ mutable_or_immutable)
               (field2 : _ mutable_or_immutable) : _ mutable_or_immutable ->
            match field1, field2 with
            | Mutable, _ | _, Mutable -> Mutable
            | Immutable field1, Immutable field2 ->
              let field, new_judgements =
                Meet_and_join.meet ~type_of_name field1 field2
              in
              judgements := new_judgements @ !judgements;
              Immutable field)
          fields1
          fields2
      in
      { env_extension;
        fields;
      }, !judgements

    let join_singleton_block ~type_of_name
          ({ env_extension = env_extension1;
             fields = fields1;
           } : singleton_block)
          ({ env_extension = env_extension2;
             fields = fields2;
           } : singleton_block) : singleton_block =
      let env_extension =
        Meet_and_join.join_typing_environment ~type_of_name
          env_extension1 env_extension2
      in
      assert (Array.length fields1 = Array.length fields2);
      let fields =
        Array.map2
          (fun (field1 : _ mutable_or_immutable)
               (field2 : _ mutable_or_immutable) : _ mutable_or_immutable ->
            match field1, field2 with
            | Mutable, _ | _, Mutable -> Mutable
            | Immutable field1, Immutable field2 ->
              Immutable (Meet_and_join.join ~type_of_name field1 field2))
          fields1
          fields2
      in
      { env_extension;
        fields;
      }

    let meet_block_cases ~type_of_name
          ((Join { by_length = singleton_blocks1; }) : block_cases)
          ((Join { by_length = singleton_blocks2; }) : block_cases)
          : (block_cases * judgements_from_meet) or_bottom =
      let judgements = ref [] in
      let by_length =
        Targetint.OCaml.Map.inter_merge
          (fun singleton_block1 singleton_block2 ->
            let singleton_block, new_judgements =
              meet_singleton_block ~type_of_name
                singleton_block1 singleton_block2
            in
            judgements := new_judgements @ !judgements;
            singleton_block)
          singleton_blocks1
          singleton_blocks2
      in
      if Targetint.OCaml.Map.is_empty by_length then Bottom
      else Ok (((Join { by_length; }) : block_cases), !judgements)

    let join_block_cases ~type_of_name
          ((Join { by_length = singleton_blocks1; }) : block_cases)
          ((Join { by_length = singleton_blocks2; }) : block_cases)
          : block_cases =
      let by_length =
        Targetint.OCaml.Map.union_merge
          (fun singleton_block1 singleton_block2 ->
            join_singleton_block ~type_of_name
              singleton_block1 singleton_block2)
          singleton_blocks1
          singleton_blocks2
      in
      Join { by_length; }

    let meet_blocks ~type_of_name blocks1 blocks2 : _ or_bottom =
      let judgements = ref [] in
      let blocks =
        Tag.Map.inter (fun block_cases1 block_cases2 ->
            match meet_block_cases ~type_of_name block_cases1 block_cases2 with
            | Ok (block_cases, new_judgements) ->
              judgements := new_judgements @ !judgements;
              Some block_cases
            | Bottom -> None)
          blocks1
          blocks2
      in
      if Tag.Map.is_empty blocks then Bottom
      else Ok (blocks, !judgements)

    let join_blocks ~type_of_name blocks1 blocks2 =
      Tag.Map.union_merge (fun block_cases1 block_cases2 ->
          join_block_cases ~type_of_name block_cases1 block_cases2)
        blocks1
        blocks2

    let meet_blocks_and_tagged_immediates ~type_of_name
          { blocks = blocks1; immediates = imms1; }
          { blocks = blocks2; immediates = imms2; }
          : (blocks_and_tagged_immediates * judgements_from_meet) or_bottom =
      let blocks, judgements =
        match meet_blocks ~type_of_name blocks1 blocks2 with
        | Bottom -> Tag.Map.empty, []
        | Ok (blocks, judgements) -> blocks, judgements
      in
      let immediates : _ or_unknown =
        match imms1, imms2 with
        | Unknown, _ -> imms2
        | _, Unknown -> imms1
        | Known imms1, Known imms2 ->
          match meet_immediates ~type_of_name imms1 imms2 with
          | Bottom -> Known Immediate.Map.empty
          | Ok immediates -> Known immediates
      in
      let is_bottom =
        Tag.Map.is_empty blocks
          && begin match immediates with
             | Known imms when Immediate.Map.is_empty imms -> true
             | Known _ | Unknown -> false
             end
      in
      if is_bottom then Bottom
      else Ok ({ blocks; immediates; }, judgements)

    let join_blocks_and_tagged_immediates ~type_of_name
          { blocks = blocks1; immediates = imms1; }
          { blocks = blocks2; immediates = imms2; }
          : blocks_and_tagged_immediates =
      let blocks = join_blocks ~type_of_name blocks1 blocks2 in
      let immediates : _ or_unknown =
        match imms1, imms2 with
        | Unknown, _ | _, Unknown -> Unknown
        | Known imms1, Known imms2 ->
          Known (join_immediates ~type_of_name imms1 imms2)
      in
      { blocks; immediates; }

    let meet_of_kind_foo ~type_of_name
          (of_kind1 : of_kind_value) (of_kind2 : of_kind_value)
          : (of_kind_value * judgements_from_meet) or_bottom =
      match of_kind1, of_kind2 with
      | Blocks_and_tagged_immediates blocks_imms1,
          Blocks_and_tagged_immediates blocks_imms2 ->
        let blocks_imms =
          meet_blocks_and_tagged_immediates ~type_of_name
            blocks_imms1 blocks_imms2
        in
        begin match blocks_imms with
        | Ok (blocks_imms, judgements) ->
          Ok (Blocks_and_tagged_immediates blocks_imms, judgements)
        | Bottom -> Bottom
        end
      | Boxed_number (Boxed_float n1),
          Boxed_number (Boxed_float n2) ->
        let (n : _ ty_naked_number), judgements =
          Meet_and_join_naked_float.meet_ty ~type_of_name n1 n2
        in
        Ok (Boxed_number (Boxed_float n), judgements)
      | Boxed_number (Boxed_int32 n1),
          Boxed_number (Boxed_int32 n2) ->
        let (n : _ ty_naked_number), judgements =
          Meet_and_join_naked_int32.meet_ty ~type_of_name n1 n2
        in
        Ok (Boxed_number (Boxed_int32 n), judgements)
      | Boxed_number (Boxed_int64 n1),
          Boxed_number (Boxed_int64 n2) ->
        let (n : _ ty_naked_number), judgements =
          Meet_and_join_naked_int64.meet_ty ~type_of_name n1 n2
        in
        Ok (Boxed_number (Boxed_int64 n), judgements)
      | Boxed_number (Boxed_nativeint n1),
          Boxed_number (Boxed_nativeint n2) ->
        let (n : _ ty_naked_number), judgements =
          Meet_and_join_naked_nativeint.meet_ty ~type_of_name n1 n2
        in
        Ok (Boxed_number (Boxed_nativeint n), judgements)
      | Closures closures1, Closures closures2 ->
        let judgements = ref [] in
        let closures =
          Closure_id.Map.inter
            (fun (closures_entry1 : closures_entry)
                 (closures_entry2 : closures_entry) : closures_entry option ->
              let set1 = closures_entry1.set_of_closures in
              let set2 = closures_entry2.set_of_closures in
              let set, new_judgements =
                Meet_and_join_fabricated.meet_ty ~type_of_name set1 set2
              in
              if ty_is_obviously_bottom set then begin
                None
              end else begin
                judgements := new_judgements @ !judgements;
                Some { set_of_closures = set; }
              end)
            closures1
            closures2
        in
        if Closure_id.Map.is_empty closures then Bottom
        else Ok (Closures closures, !judgements)
      | String strs1, String strs2 ->
        let strs = String_info.Set.inter strs1 strs2 in
        if String_info.Set.is_empty strs then Bottom
        else Ok (String strs, [])
      | (Blocks_and_tagged_immediates _
          | Boxed_number _
          | Closures _
          | String _), _ ->
        Bottom

    let meet_unk value_kind1 value_kind2 =
      K.Value_kind.meet value_kind1 value_kind2

    let join_of_kind_foo ~type_of_name
          (of_kind1 : of_kind_value) (of_kind2 : of_kind_value)
          : of_kind_value or_unknown =
      match of_kind1, of_kind2 with
      | Blocks_and_tagged_immediates blocks_imms1,
          Blocks_and_tagged_immediates blocks_imms2 ->
        let blocks_imms =
          join_blocks_and_tagged_immediates ~type_of_name
            blocks_imms1 blocks_imms2
        in
        Known (Blocks_and_tagged_immediates blocks_imms)
      | Boxed_number (Boxed_float n1), Boxed_number (Boxed_float n2) ->
        let n : _ ty_naked_number =
          Meet_and_join_naked_float.join_ty ~type_of_name n1 n2
        in
        Known (Boxed_number (Boxed_float n))
      | Boxed_number (Boxed_int32 n1),
          Boxed_number (Boxed_int32 n2) ->
        let n : _ ty_naked_number =
          Meet_and_join_naked_int32.join_ty ~type_of_name n1 n2
        in
        Known (Boxed_number (Boxed_int32 n))
      | Boxed_number (Boxed_int64 n1),
          Boxed_number (Boxed_int64 n2) ->
        let n : _ ty_naked_number =
          Meet_and_join_naked_int64.join_ty ~type_of_name n1 n2
        in
        Known (Boxed_number (Boxed_int64 n))
      | Boxed_number (Boxed_nativeint n1),
          Boxed_number (Boxed_nativeint n2) ->
        let n : _ ty_naked_number =
          Meet_and_join_naked_nativeint.join_ty ~type_of_name n1 n2
        in
        Known (Boxed_number (Boxed_nativeint n))
      | Closures closures1, Closures closures2 ->
        let closures =
          Closure_id.Map.union_merge
            (fun (closures_entry1 : closures_entry)
                 (closures_entry2 : closures_entry) : closures_entry ->
              let set1 = closures_entry1.set_of_closures in
              let set2 = closures_entry2.set_of_closures in
              let set =
                Meet_and_join_fabricated.join_ty ~type_of_name set1 set2
              in
              { set_of_closures = set; })
            closures1
            closures2
        in
        Known (Closures closures)
      | String strs1, String strs2 ->
        let strs = String_info.Set.union strs1 strs2 in
        Known (String strs)
      | (Blocks_and_tagged_immediates _
          | Boxed_number _
          | Closures _
          | String _), _ ->
        Unknown

    let join_unk value_kind1 value_kind2 =
      K.Value_kind.join value_kind1 value_kind2
  end) and Meet_and_join_naked_immediate : sig
    (* CR mshinwell: See if we can abstract these naked number cases some
       more? *)
    include Meet_and_join
      with type of_kind_foo := Immediate.Set.t of_kind_naked_number
      with type unk := unit
  end = Make_meet_and_join (struct
    type of_kind_foo = Immediate.Set.t of_kind_naked_number
    type unk = unit

    let to_type ty : t = Naked_number (ty, Naked_immediate)
    let force_to_kind = force_to_kind_naked_immediate

    let unknown_payload = ()

    let meet_of_kind_foo ~type_of_name:_
          (of_kind1 : Immediate.Set.t of_kind_naked_number)
          (of_kind2 : Immediate.Set.t of_kind_naked_number)
          : (Immediate.Set.t of_kind_naked_number * judgements_from_meet)
              or_bottom =
      match of_kind1, of_kind2 with
      | Immediate fs1, Immediate fs2 ->
        let fs = Immediate.Set.inter fs1 fs2 in
        if Immediate.Set.is_empty fs then Bottom
        else Ok (Immediate fs, [])
      | _, _ -> Bottom

    let meet_unk () () = ()

    let join_of_kind_foo ~type_of_name:_
          (of_kind1 : Immediate.Set.t of_kind_naked_number)
          (of_kind2 : Immediate.Set.t of_kind_naked_number)
          : Immediate.Set.t of_kind_naked_number or_unknown =
      match of_kind1, of_kind2 with
      | Immediate fs1, Immediate fs2 ->
        let fs = Immediate.Set.union fs1 fs2 in
        Known (Immediate fs)
      | _, _ -> Unknown

    let join_unk () () = ()
  end) and Meet_and_join_naked_float : sig
    (* CR mshinwell: See if we can abstract these naked number cases some
       more? *)
    include Meet_and_join
      with type of_kind_foo := Float_by_bit_pattern.Set.t of_kind_naked_number
      with type unk := unit
  end = Make_meet_and_join (struct
    type of_kind_foo = Float_by_bit_pattern.Set.t of_kind_naked_number
    type unk = unit

    let to_type ty = Naked_number (ty, Naked_float)
    let force_to_kind = force_to_kind_naked_float

    let unknown_payload = ()

    let meet_of_kind_foo ~type_of_name:_
          (of_kind1 : Float_by_bit_pattern.Set.t of_kind_naked_number)
          (of_kind2 : Float_by_bit_pattern.Set.t of_kind_naked_number)
          : (Float_by_bit_pattern.Set.t of_kind_naked_number
              * judgements_from_meet) or_bottom =
      match of_kind1, of_kind2 with
      | Float fs1, Float fs2 ->
        let fs = Float_by_bit_pattern.Set.inter fs1 fs2 in
        if Float_by_bit_pattern.Set.is_empty fs then Bottom
        else Ok (Float fs, [])
      | _, _ -> Bottom

    let meet_unk () () = ()

    let join_of_kind_foo ~type_of_name:_
          (of_kind1 : Float_by_bit_pattern.Set.t of_kind_naked_number)
          (of_kind2 : Float_by_bit_pattern.Set.t of_kind_naked_number)
          : Float_by_bit_pattern.Set.t of_kind_naked_number or_unknown =
      match of_kind1, of_kind2 with
      | Float fs1, Float fs2 ->
        let fs = Float_by_bit_pattern.Set.union fs1 fs2 in
        Known (Float fs)
      | _, _ -> Unknown

    let join_unk () () = ()
  end) and Meet_and_join_naked_int32 : sig
    include Meet_and_join
      with type of_kind_foo := Int32.Set.t of_kind_naked_number
      with type unk := unit
  end = Make_meet_and_join (struct
    type of_kind_foo = Int32.Set.t of_kind_naked_number
    type unk = unit

    let to_type ty : t = Naked_number (ty, Naked_int32)
    let force_to_kind = force_to_kind_naked_int32

    let unknown_payload = ()

    let meet_of_kind_foo ~type_of_name:_
          (of_kind1 : Int32.Set.t of_kind_naked_number)
          (of_kind2 : Int32.Set.t of_kind_naked_number)
          : (Int32.Set.t of_kind_naked_number * judgements_from_meet)
              or_bottom =
      match of_kind1, of_kind2 with
      | Int32 is1, Int32 is2 ->
        let is = Int32.Set.inter is1 is2 in
        if Int32.Set.is_empty is then Bottom
        else Ok (Int32 is, [])
      | _, _ -> Bottom

    let meet_unk () () = ()

    let join_of_kind_foo ~type_of_name:_
          (of_kind1 : Int32.Set.t of_kind_naked_number)
          (of_kind2 : Int32.Set.t of_kind_naked_number)
          : Int32.Set.t of_kind_naked_number or_unknown =
      match of_kind1, of_kind2 with
      | Int32 is1, Int32 is2 ->
        let is = Int32.Set.union is1 is2 in
        Known (Int32 is)
      | _, _ -> Unknown

    let join_unk () () = ()
  end) and Meet_and_join_naked_int64 : sig
    include Meet_and_join
      with type of_kind_foo := Int64.Set.t of_kind_naked_number
      with type unk := unit
  end = Make_meet_and_join (struct
    type of_kind_foo = Int64.Set.t of_kind_naked_number
    type unk = unit

    let to_type ty : t = Naked_number (ty, Naked_int64)
    let force_to_kind = force_to_kind_naked_int64

    let unknown_payload = ()

    let meet_of_kind_foo ~type_of_name:_
          (of_kind1 : Int64.Set.t of_kind_naked_number)
          (of_kind2 : Int64.Set.t of_kind_naked_number)
          : (Int64.Set.t of_kind_naked_number * judgements_from_meet)
              or_bottom =
      match of_kind1, of_kind2 with
      | Int64 is1, Int64 is2 ->
        let is = Int64.Set.inter is1 is2 in
        if Int64.Set.is_empty is then Bottom
        else Ok (Int64 is, [])
      | _, _ -> Bottom

    let meet_unk () () = ()

    let join_of_kind_foo ~type_of_name:_
          (of_kind1 : Int64.Set.t of_kind_naked_number)
          (of_kind2 : Int64.Set.t of_kind_naked_number)
          : Int64.Set.t of_kind_naked_number or_unknown =
      match of_kind1, of_kind2 with
      | Int64 is1, Int64 is2 ->
        let is = Int64.Set.union is1 is2 in
        Known (Int64 is)
      | _, _ -> Unknown

    let join_unk () () = ()
  end) and Meet_and_join_naked_nativeint : sig
    include Meet_and_join
      with type of_kind_foo := Targetint.Set.t of_kind_naked_number
      with type unk := unit
  end = Make_meet_and_join (struct
    type of_kind_foo = Targetint.Set.t of_kind_naked_number
    type unk = unit

    let to_type ty : t = Naked_number (ty, Naked_nativeint)
    let force_to_kind = force_to_kind_naked_nativeint

    let unknown_payload = ()

    let meet_of_kind_foo ~type_of_name:_
          (of_kind1 : Targetint.Set.t of_kind_naked_number)
          (of_kind2 : Targetint.Set.t of_kind_naked_number)
          : (Targetint.Set.t of_kind_naked_number * judgements_from_meet)
              or_bottom =
      match of_kind1, of_kind2 with
      | Nativeint is1, Nativeint is2 ->
        let is = Targetint.Set.inter is1 is2 in
        if Targetint.Set.is_empty is then Bottom
        else Ok (Nativeint is, [])
      | _, _ -> Bottom

    let meet_unk () () = ()

    let join_of_kind_foo ~type_of_name:_
          (of_kind1 : Targetint.Set.t of_kind_naked_number)
          (of_kind2 : Targetint.Set.t of_kind_naked_number)
          : Targetint.Set.t of_kind_naked_number or_unknown =
      match of_kind1, of_kind2 with
      | Nativeint is1, Nativeint is2 ->
        let is = Targetint.Set.union is1 is2 in
        Known (Nativeint is)
      | _, _ -> Unknown

    let join_unk () () = ()
  end) and Meet_and_join_fabricated : sig
    include Meet_and_join
      with type of_kind_foo := of_kind_fabricated
      with type unk := K.Value_kind.t
  end = Make_meet_and_join (struct
    type of_kind_foo = of_kind_fabricated
    type unk = K.Value_kind.t

    let to_type ty : t = Fabricated ty
    let force_to_kind = force_to_kind_fabricated

    let unknown_payload = K.Value_kind.Unknown

    (* CR mshinwell: We need to work out how to stop direct call
       surrogates from being dropped e.g. when in a second round, a
       function type (with a surrogate) propagated from the first round is
       put into a meet with a type for the same function, but a new
       surrogate. *)
    let meet_closure ~(type_of_name : type_of_name)
          (closure1 : closure) (closure2 : closure)
          : (closure * judgements_from_meet) or_bottom =
      let cannot_prove_different ~params1 ~params2 ~result1 ~result2
            ~result_env_extension1 ~result_env_extension2 : _ or_bottom =
        let same_arity =
          List.compare_lengths params1 params2 = 0
        in
        let same_num_results =
          List.compare_lengths result1 result2 = 0
        in
        let result_env_extension =
          Meet_and_join.meet_typing_environment ~type_of_name
            result_env_extension1
            result_env_extension2
        in
        let type_of_name ?local_env name_or_export_id =
          match local_env with
          | None ->
            type_of_name ~local_env:result_env_extension name_or_export_id
          | Some local_env ->
            type_of_name ~local_env name_or_export_id
        in
        let judgements = ref [] in
        let has_bottom params =
          List.exists is_obviously_bottom params
        in
        let params : _ or_bottom =
          if not same_arity then Bottom
          else
            let params =
              List.map2 (fun t1 t2 ->
                  let t, new_judgements =
                    Meet_and_join.meet ~type_of_name t1 t2
                  in
                  judgements := new_judgements @ !judgements;
                  t)
                params1
                params2
            in
            if has_bottom params then Bottom
            else Ok params
        in
        let result : _ or_bottom =
          if not same_num_results then Bottom
          else
            let result =
              List.map2 (fun t1 t2 ->
                  let t, new_judgements =
                    Meet_and_join.meet ~type_of_name t1 t2
                  in
                  judgements := new_judgements @ !judgements;
                  t)
                result1
                result2
            in
            if has_bottom result then Bottom
            else Ok result
        in
        match params, result with
        | Ok params, Ok result ->
          Ok (params, result, result_env_extension, !judgements)
        | _, _ -> Bottom
      in
      let function_decls : _ or_bottom =
        match closure1.function_decls, closure2.function_decls with
        | Inlinable inlinable1, Inlinable inlinable2 ->
          let params1 = List.map snd inlinable1.params in
          let params2 = List.map snd inlinable2.params in
          let result =
            cannot_prove_different ~params1 ~params2
              ~result1:inlinable1.result
              ~result2:inlinable2.result
              ~result_env_extension1:inlinable1.result_env_extension
              ~result_env_extension2:inlinable2.result_env_extension
          in
          begin match result with
          | Ok (params, result, result_env_extension, judgements) ->
            (* [closure1.function_decls] and [closure2.function_decls] may be
               different, but we cannot prove it.  We arbitrarily pick
               [closure1.function_decls] to return, with parameter and result
               types refined. *)
            let params =
              List.map2 (fun (param, _old_ty) new_ty -> param, new_ty)
                inlinable1.params
                params
            in
            let inlinable_function_decl =
              { inlinable1 with
                params;
                result;
                result_env_extension;
              }
            in
            Ok (Inlinable inlinable_function_decl, judgements)
          | Bottom ->
            (* [closure1] and [closure2] are definitely different. *)
            Bottom
          end
        | Non_inlinable None, Non_inlinable None -> Ok (Non_inlinable None, [])
        | Non_inlinable (Some non_inlinable), Non_inlinable None
        | Non_inlinable None, Non_inlinable (Some non_inlinable) ->
          (* We can arbitrarily pick one side or the other: we choose the
             side which gives a more precise type. *)
          Ok (Non_inlinable (Some non_inlinable), [])
        | Non_inlinable None, Inlinable inlinable
        | Inlinable inlinable, Non_inlinable None ->
          (* Likewise. *)
          Ok (Inlinable inlinable, [])
        | Non_inlinable (Some non_inlinable1),
            Non_inlinable (Some non_inlinable2) ->
          let result =
            cannot_prove_different
              ~params1:non_inlinable1.params
              ~params2:non_inlinable2.params
              ~result1:non_inlinable1.result
              ~result2:non_inlinable2.result
              ~result_env_extension1:non_inlinable1.result_env_extension
              ~result_env_extension2:non_inlinable2.result_env_extension
          in
          begin match result with
          | Ok (params, result, result_env_extension, judgements) ->
            let non_inlinable_function_decl =
              { non_inlinable1 with
                params;
                result;
                result_env_extension;
              }
            in
            Ok (Non_inlinable (Some non_inlinable_function_decl), judgements)
          | Bottom ->
            Bottom
          end
        | Non_inlinable (Some non_inlinable), Inlinable inlinable
        | Inlinable inlinable, Non_inlinable (Some non_inlinable) ->
          let params1 = List.map snd inlinable.params in
          let result =
            cannot_prove_different
              ~params1
              ~params2:non_inlinable.params
              ~result1:inlinable.result
              ~result2:non_inlinable.result
              ~result_env_extension1:inlinable.result_env_extension
              ~result_env_extension2:non_inlinable.result_env_extension
          in
          begin match result with
          | Ok (params, result, result_env_extension, judgements) ->
            (* For the arbitrary choice, we pick the inlinable declaration,
               since it gives more information. *)
            let params =
              List.map2 (fun (param, _old_ty) new_ty -> param, new_ty)
                inlinable.params
                params
            in
            let inlinable_function_decl =
              { inlinable with
                params;
                result;
                result_env_extension;
              }
            in
            Ok (Inlinable inlinable_function_decl, judgements)
          | Bottom ->
            Bottom
          end
      in
      match function_decls with
      | Bottom -> Bottom
      | Ok (function_decls, judgements) ->
        Ok (({ function_decls; } : closure), judgements)

    let join_closure ~(type_of_name : type_of_name)
          (closure1 : closure) (closure2 : closure)
          : closure =
      let produce_non_inlinable ~params1 ~params2 ~result1 ~result2
            ~result_env_extension1 ~result_env_extension2
            ~direct_call_surrogate1 ~direct_call_surrogate2 =
        let same_arity =
          List.compare_lengths params1 params2 = 0
        in
        let same_num_results =
          List.compare_lengths result1 result2 = 0
        in
        if same_arity && same_num_results then
          let params =
            List.map2 (fun t1 t2 ->
                Meet_and_join.join ~type_of_name t1 t2)
              params1
              params2
          in
          let result =
            List.map2 (fun t1 t2 ->
                Meet_and_join.join ~type_of_name t1 t2)
              result1
              result2
          in
          let direct_call_surrogate =
            match direct_call_surrogate1, direct_call_surrogate2 with
            | Some closure_id1, Some closure_id2
                when Closure_id.equal closure_id1 closure_id2 ->
              Some closure_id1
            | _, _ -> None
          in
          let result_env_extension =
            Meet_and_join.join_typing_environment ~type_of_name
              result_env_extension1
              result_env_extension2
          in
          let non_inlinable : non_inlinable_function_declarations =
            { params;
              result;
              result_env_extension;
              direct_call_surrogate;
            }
          in
          Non_inlinable (Some non_inlinable)
        else
          Non_inlinable None
      in
      let function_decls : function_declarations =
        match closure1.function_decls, closure2.function_decls with
        | Non_inlinable None, _ | _, Non_inlinable None -> Non_inlinable None
        | Non_inlinable (Some non_inlinable1),
            Non_inlinable (Some non_inlinable2) ->
          produce_non_inlinable
            ~params1:non_inlinable1.params
            ~params2:non_inlinable2.params
            ~result1:non_inlinable1.result
            ~result2:non_inlinable2.result
            ~result_env_extension1:non_inlinable1.result_env_extension
            ~result_env_extension2:non_inlinable2.result_env_extension
            ~direct_call_surrogate1:non_inlinable1.direct_call_surrogate
            ~direct_call_surrogate2:non_inlinable2.direct_call_surrogate
        | Non_inlinable (Some non_inlinable), Inlinable inlinable
        | Inlinable inlinable, Non_inlinable (Some non_inlinable) ->
          let params1 = List.map snd inlinable.params in
          produce_non_inlinable
            ~params1
            ~params2:non_inlinable.params
            ~result1:inlinable.result
            ~result2:non_inlinable.result
            ~result_env_extension1:inlinable.result_env_extension
            ~result_env_extension2:non_inlinable.result_env_extension
            ~direct_call_surrogate1:inlinable.direct_call_surrogate
            ~direct_call_surrogate2:non_inlinable.direct_call_surrogate
        | Inlinable inlinable1, Inlinable inlinable2 ->
          if not (Code_id.equal inlinable1.code_id inlinable2.code_id)
          then begin
            let params1 = List.map snd inlinable1.params in
            let params2 = List.map snd inlinable2.params in
            produce_non_inlinable
              ~params1
              ~params2
              ~result1:inlinable1.result
              ~result2:inlinable2.result
              ~result_env_extension1:inlinable1.result_env_extension
              ~result_env_extension2:inlinable2.result_env_extension
              ~direct_call_surrogate1:inlinable1.direct_call_surrogate
              ~direct_call_surrogate2:inlinable2.direct_call_surrogate
          end else begin
            if !Clflags.flambda_invariant_checks then begin
              assert (Closure_origin.equal inlinable1.closure_origin
                inlinable2.closure_origin);
              assert (Continuation.equal inlinable1.continuation_param
                inlinable2.continuation_param);
              assert (Continuation.equal inlinable1.exn_continuation_param
                inlinable2.exn_continuation_param);
              assert (Pervasives.(=) inlinable1.is_classic_mode
                inlinable2.is_classic_mode);
              assert (List.compare_lengths inlinable1.params inlinable2.params
                = 0);
              assert (List.compare_lengths inlinable1.result inlinable2.result
                = 0);
              assert (Name.Set.equal inlinable1.free_names_in_body
                inlinable2.free_names_in_body);
              assert (Pervasives.(=) inlinable1.stub inlinable2.stub);
              assert (Debuginfo.equal inlinable1.dbg inlinable2.dbg);
              assert (Pervasives.(=) inlinable1.inline inlinable2.inline);
              assert (Pervasives.(=) inlinable1.specialise
                inlinable2.specialise);
              assert (Pervasives.(=) inlinable1.is_a_functor
                inlinable2.is_a_functor);
              assert (Variable.Set.equal
                (Lazy.force inlinable1.invariant_params)
                (Lazy.force inlinable2.invariant_params));
              assert (Pervasives.(=)
                (Lazy.force inlinable1.size)
                (Lazy.force inlinable2.size));
              assert (Variable.equal inlinable1.my_closure
                inlinable2.my_closure)
            end;
            (* Parameter types are treated covariantly. *)
            (* CR mshinwell: Add documentation for this -- the types provide
               information about the calling context rather than the code of
               the function. *)
            let result_env_extension =
              Meet_and_join.join_typing_environment ~type_of_name
                inlinable1.result_env_extension
                inlinable2.result_env_extension
            in
            (* CR mshinwell: Should we actually have [meet] and [join] take
               two environments, one per type? *)
            let type_of_name ?local_env name_or_export_id =
              match local_env with
              | None ->
                type_of_name ~local_env:result_env_extension name_or_export_id
              | Some local_env ->
                type_of_name ~local_env name_or_export_id
            in
            let params =
              List.map2 (fun (param1, t1) (param2, t2) ->
                  assert (Parameter.equal param1 param2);
                  let t = Meet_and_join.join ~type_of_name t1 t2 in
                  param1, t)
                inlinable1.params
                inlinable2.params
            in
            let result =
              List.map2 (fun t1 t2 ->
                  Meet_and_join.join ~type_of_name t1 t2)
                inlinable1.result
                inlinable2.result
            in
            let direct_call_surrogate =
              match inlinable1.direct_call_surrogate,
                    inlinable2.direct_call_surrogate
              with
              | Some closure_id1, Some closure_id2
                  when Closure_id.equal closure_id1 closure_id2 ->
                Some closure_id1
              | _, _ -> None
            in
            Inlinable {
              closure_origin = inlinable1.closure_origin;
              continuation_param = inlinable1.continuation_param;
              exn_continuation_param = inlinable1.exn_continuation_param;
              is_classic_mode = inlinable1.is_classic_mode;
              params;
              code_id = inlinable1.code_id;
              body = inlinable1.body;
              free_names_in_body = inlinable1.free_names_in_body;
              result;
              result_env_extension;
              stub = inlinable1.stub;
              dbg = inlinable1.dbg;
              inline = inlinable1.inline;
              specialise = inlinable1.specialise;
              is_a_functor = inlinable1.is_a_functor;
              invariant_params = inlinable1.invariant_params;
              size = inlinable1.size;
              direct_call_surrogate;
              my_closure = inlinable1.my_closure;
            }
          end
      in
      { function_decls; }

    let meet_set_of_closures ~type_of_name
          (set1 : set_of_closures) (set2 : set_of_closures)
          : (set_of_closures * judgements_from_meet) or_bottom =
      let judgements = ref [] in
      (* CR mshinwell: Try to refactor this code to shorten it. *)
      let closures : _ extensibility =
        match set1.closures, set2.closures with
        | Exactly closures1, Exactly closures2 ->
          let closures =
            Closure_id.Map.inter (fun ty_fabricated1 ty_fabricated2 ->
                let ty_fabricated, new_judgements =
                  Meet_and_join_fabricated.meet_ty ~type_of_name
                    ty_fabricated1 ty_fabricated2
                in
                if ty_is_obviously_bottom ty_fabricated then begin
                  None
                end else begin
                  judgements := new_judgements @ !judgements;
                  Some ty_fabricated
                end)
              closures1
              closures2
          in
          Exactly closures
        | Exactly closures1, Open closures2
        | Open closures2, Exactly closures1 ->
          let closures =
            Closure_id.Map.filter_map closures1 ~f:(fun closure_id ty1 ->
              match Closure_id.Map.find closure_id closures2 with
              | exception Not_found -> Some ty1
              | ty2 ->
                let ty_fabricated, new_judgements =
                  Meet_and_join_fabricated.meet_ty ~type_of_name ty1 ty2
                in
                if ty_is_obviously_bottom ty_fabricated then begin
                  None
                end else begin
                  judgements := new_judgements @ !judgements;
                  Some ty_fabricated
                end)
          in
          Exactly closures
        | Open closures1, Open closures2 ->
          let closures =
            Closure_id.Map.union_merge (fun ty_fabricated1 ty_fabricated2 ->
                let ty_fabricated, new_judgements =
                  Meet_and_join_fabricated.meet_ty ~type_of_name
                    ty_fabricated1 ty_fabricated2
                in
                if ty_is_obviously_bottom ty_fabricated then begin
                  bottom_as_ty_fabricated ()
                end else begin
                  judgements := new_judgements @ !judgements;
                  ty_fabricated
                end)
              closures1
              closures2
          in
          Open closures
      in
      let closure_elements =
        match set1.closure_elements, set2.closure_elements with
        | Exactly closure_elements1, Exactly closure_elements2 ->
          let closure_elements =
            Var_within_closure.Map.inter (fun ty_value1 ty_value2 ->
                let ty_value, new_judgements =
                  Meet_and_join_value.meet_ty ~type_of_name
                    ty_value1 ty_value2
                in
                if ty_is_obviously_bottom ty_value then begin
                  None
                end else begin
                  judgements := new_judgements @ !judgements;
                  Some ty_value
                end)
              closure_elements1
              closure_elements2
          in
          Exactly closure_elements
        | Exactly closure_elements1, Open closure_elements2
        | Open closure_elements2, Exactly closure_elements1 ->
          let closure_elements =
            Var_within_closure.Map.filter_map closure_elements1
              ~f:(fun closure_id ty1 ->
                match
                  Var_within_closure.Map.find closure_id closure_elements2
                with
                | exception Not_found -> Some ty1
                | ty2 ->
                  let ty_value, new_judgements =
                    Meet_and_join_value.meet_ty ~type_of_name ty1 ty2
                  in
                  if ty_is_obviously_bottom ty_value then begin
                    None
                  end else begin
                    judgements := new_judgements @ !judgements;
                    Some ty_value
                  end)
          in
          Exactly closure_elements
        | Open closure_elements1, Open closure_elements2 ->
          let closure_elements =
            Var_within_closure.Map.union_merge (fun ty_value1 ty_value2 ->
                let ty_value, new_judgements =
                  Meet_and_join_value.meet_ty ~type_of_name
                    ty_value1 ty_value2
                in
                if ty_is_obviously_bottom ty_value then begin
                  bottom_as_ty_value ()
                end else begin
                  judgements := new_judgements @ !judgements;
                  ty_value
                end)
              closure_elements1
              closure_elements2
          in
          Open closure_elements
      in
      match closures with
      | Exactly map when Closure_id.Map.is_empty map -> Bottom
      | _ ->
        let set : set_of_closures =
          { closures;
            closure_elements;
          }
        in
        Ok (set, !judgements)

    let join_set_of_closures ~type_of_name
          (set1 : set_of_closures) (set2 : set_of_closures)
          : set_of_closures =
      let closures : _ extensibility =
        match set1.closures, set2.closures with
        | Exactly closures1, Exactly closures2 ->
          let closures =
            Closure_id.Map.union_merge
              (fun ty_fabricated1 ty_fabricated2 ->
                Meet_and_join_fabricated.join_ty ~type_of_name
                  ty_fabricated1 ty_fabricated2)
              closures1
              closures2
          in
          Exactly closures
        | Exactly closures1, Open closures2
        | Open closures1, Exactly closures2 ->
          let closures =
            Closure_id.Map.union_merge
              (fun ty_fabricated1 ty_fabricated2 ->
                Meet_and_join_fabricated.join_ty ~type_of_name
                  ty_fabricated1 ty_fabricated2)
              closures1
              closures2
          in
          Open closures
        | Open closures1, Open closures2 ->
          let closures =
            Closure_id.Map.union_both
              (fun _ty_fabricated ->
                any_fabricated_as_ty_fabricated Definitely_pointer)
              (fun ty_fabricated1 ty_fabricated2 ->
                Meet_and_join_fabricated.join_ty ~type_of_name
                  ty_fabricated1 ty_fabricated2)
              closures1
              closures2
          in
          Open closures
      in
      let closure_elements : _ extensibility =
        match set1.closure_elements, set2.closure_elements with
        | Exactly closure_elements1, Exactly closure_elements2 ->
          let closure_elements =
            Var_within_closure.Map.union_merge
              (fun ty_value1 ty_value2 ->
                Meet_and_join_value.join_ty ~type_of_name
                  ty_value1 ty_value2)
              closure_elements1
              closure_elements2
          in
          Exactly closure_elements
        | Exactly closure_elements1, Open closure_elements2
        | Open closure_elements1, Exactly closure_elements2 ->
          let closure_elements =
            Var_within_closure.Map.union_merge
              (fun ty_value1 ty_value2 ->
                Meet_and_join_value.join_ty ~type_of_name
                  ty_value1 ty_value2)
              closure_elements1
              closure_elements2
          in
          Open closure_elements
        | Open closure_elements1, Open closure_elements2 ->
          let closure_elements =
            Var_within_closure.Map.union_both
              (fun _ty_value ->
                any_value_as_ty_value Definitely_pointer)
              (fun ty_value1 ty_value2 ->
                Meet_and_join_value.join_ty ~type_of_name
                  ty_value1 ty_value2)
              closure_elements1
              closure_elements2
          in
          Open closure_elements
      in
      { closures;
        closure_elements;
      }

    let meet_of_kind_foo ~type_of_name
          (of_kind1 : of_kind_fabricated) (of_kind2 : of_kind_fabricated)
          : (of_kind_fabricated * judgements_from_meet) or_bottom =
      match of_kind1, of_kind2 with
      | Tag tags1, Tag tags2 ->
        let tags =
          Tag.Map.inter_merge
            (fun ({ env_extension = env_extension1; } : tag_case)
                  ({ env_extension = env_extension2; } : tag_case)
                  : tag_case ->
              let env_extension =
                Meet_and_join.meet_typing_environment ~type_of_name
                  env_extension1 env_extension2
              in
              (* CR mshinwell: Do we ever flip back to [Bottom] here? *)
              { env_extension; })
            tags1
            tags2
        in
        Ok (Tag tags, [])
      | Set_of_closures set1, Set_of_closures set2 ->
        begin match meet_set_of_closures ~type_of_name set1 set2 with
        | Ok (set_of_closures, judgements) ->
          Ok (Set_of_closures set_of_closures, judgements)
        | Bottom -> Bottom
        end
      | Closure closure1, Closure closure2 ->
        begin match meet_closure ~type_of_name closure1 closure2 with
        | Ok (closure, judgements) -> Ok (Closure closure, judgements)
        | Bottom -> Bottom
        end
      | (Tag _ | Set_of_closures _ | Closure _), _ -> Bottom

    let meet_unk value_kind1 value_kind2 =
      K.Value_kind.meet value_kind1 value_kind2

    let join_of_kind_foo ~type_of_name
          (of_kind1 : of_kind_fabricated) (of_kind2 : of_kind_fabricated)
          : of_kind_fabricated or_unknown =
      match of_kind1, of_kind2 with
      | Tag tags1, Tag tags2 ->
        let tags =
          Tag.Map.union_merge
            (fun ({ env_extension = env_extension1; } : tag_case)
                  ({ env_extension = env_extension2; } : tag_case)
                  : tag_case ->
              let env_extension =
                Meet_and_join.join_typing_environment ~type_of_name
                  env_extension1 env_extension2
              in
              { env_extension; })
            tags1
            tags2
        in
        Known (Tag tags)
      | Set_of_closures set1, Set_of_closures set2 ->
        let set_of_closures = join_set_of_closures ~type_of_name set1 set2 in
        Known (Set_of_closures set_of_closures)
      | Closure closure1, Closure closure2 ->
        let closure = join_closure ~type_of_name closure1 closure2 in
        Known (Closure closure)
      | (Tag _ | Set_of_closures _ | Closure _), _ -> Unknown

    let join_unk value_kind1 value_kind2 =
      K.Value_kind.join value_kind1 value_kind2
  end) and Meet_and_join_phantom : sig
    include Meet_and_join
      with type of_kind_foo := of_kind_phantom
      with type unk := K.Phantom_kind.t
  end = Make_meet_and_join (struct
    type of_kind_foo = of_kind_phantom
    type unk = K.Phantom_kind.t

    let to_type ty : t = Phantom ty
    let force_to_kind = force_to_kind_phantom

    let unknown_payload = K.Phantom_kind.Unknown

    let meet_of_kind_foo ~type_of_name
          (of_kind1 : of_kind_phantom) (of_kind2 : of_kind_phantom)
          : (of_kind_phantom * judgements_from_meet) or_bottom =
      match of_kind1, of_kind2 with
      | Value ty_value1, Value ty_value2 ->
        let ty_value, judgements =
          Meet_and_join_value.meet_ty ~type_of_name ty_value1 ty_value2
        in
        (* CR mshinwell: Should this be tested for bottom and then we return
           Bottom if that succeeds?
           If not, then we should factor code about between this and [join],
           below. *)
        Ok (((Value ty_value) : of_kind_phantom), judgements)
      | Naked_number (ty_naked_number1, kind1),
          Naked_number (ty_naked_number2, kind2) ->
        let module N = K.Naked_number in
        begin match kind1, kind2 with
        | N.Naked_immediate, N.Naked_immediate ->
          let ty_naked_number, judgements =
            Meet_and_join_naked_immediate.meet_ty ~type_of_name
              ty_naked_number1 ty_naked_number2
          in
          Ok (((Naked_number (ty_naked_number, N.Naked_immediate))
            : of_kind_phantom), judgements)
        | N.Naked_float, N.Naked_float ->
          let ty_naked_number, judgements =
            Meet_and_join_naked_float.meet_ty ~type_of_name
              ty_naked_number1 ty_naked_number2
          in
          Ok (((Naked_number (ty_naked_number, N.Naked_float))
            : of_kind_phantom), judgements)
        | N.Naked_int32, N.Naked_int32 ->
          let ty_naked_number, judgements =
            Meet_and_join_naked_int32.meet_ty ~type_of_name
              ty_naked_number1 ty_naked_number2
          in
          Ok (((Naked_number (ty_naked_number, N.Naked_int32))
            : of_kind_phantom), judgements)
        | N.Naked_int64, N.Naked_int64 ->
          let ty_naked_number, judgements =
            Meet_and_join_naked_int64.meet_ty ~type_of_name
              ty_naked_number1 ty_naked_number2
          in
          Ok (((Naked_number (ty_naked_number, N.Naked_int64))
            : of_kind_phantom), judgements)
        | N.Naked_nativeint, N.Naked_nativeint ->
          let ty_naked_number, judgements =
            Meet_and_join_naked_nativeint.meet_ty ~type_of_name
              ty_naked_number1 ty_naked_number2
          in
          Ok (((Naked_number (ty_naked_number, N.Naked_nativeint))
            : of_kind_phantom), judgements)
        | _, _ -> Bottom
        end
      | Fabricated ty_fabricated1, Fabricated ty_fabricated2 ->
        let ty_fabricated, judgements =
          Meet_and_join_fabricated.meet_ty ~type_of_name
            ty_fabricated1 ty_fabricated2
        in
        Ok (((Fabricated ty_fabricated) : of_kind_phantom), judgements)
      | (Value _ | Naked_number _ | Fabricated _), _ -> Bottom

    let meet_unk phantom_kind1 phantom_kind2 =
      K.Phantom_kind.meet phantom_kind1 phantom_kind2

    let join_of_kind_foo ~type_of_name
          (of_kind1 : of_kind_phantom) (of_kind2 : of_kind_phantom)
          : of_kind_phantom or_unknown =
      match of_kind1, of_kind2 with
      | Value ty_value1, Value ty_value2 ->
        let ty_value =
          Meet_and_join_value.join_ty ~type_of_name ty_value1 ty_value2
        in
        Known ((Value ty_value) : of_kind_phantom)
      | Naked_number (ty_naked_number1, kind1),
          Naked_number (ty_naked_number2, kind2) ->
        let module N = K.Naked_number in
        begin match kind1, kind2 with
        | N.Naked_immediate, N.Naked_immediate ->
          let ty_naked_number =
            Meet_and_join_naked_immediate.join_ty ~type_of_name
              ty_naked_number1 ty_naked_number2
          in
          Known ((Naked_number (ty_naked_number, N.Naked_immediate))
            : of_kind_phantom)
        | N.Naked_float, N.Naked_float ->
          let ty_naked_number =
            Meet_and_join_naked_float.join_ty ~type_of_name
              ty_naked_number1 ty_naked_number2
          in
          Known ((Naked_number (ty_naked_number, N.Naked_float))
            : of_kind_phantom)
        | N.Naked_int32, N.Naked_int32 ->
          let ty_naked_number =
            Meet_and_join_naked_int32.join_ty ~type_of_name
              ty_naked_number1 ty_naked_number2
          in
          Known ((Naked_number (ty_naked_number, N.Naked_int32))
            : of_kind_phantom)
        | N.Naked_int64, N.Naked_int64 ->
          let ty_naked_number =
            Meet_and_join_naked_int64.join_ty ~type_of_name
              ty_naked_number1 ty_naked_number2
          in
          Known ((Naked_number (ty_naked_number, N.Naked_int64))
            : of_kind_phantom)
        | N.Naked_nativeint, N.Naked_nativeint ->
          let ty_naked_number =
            Meet_and_join_naked_nativeint.join_ty ~type_of_name
              ty_naked_number1 ty_naked_number2
          in
          Known ((Naked_number (ty_naked_number, N.Naked_nativeint))
            : of_kind_phantom)
        | _, _ -> Unknown
        end
      | Fabricated ty_fabricated1, Fabricated ty_fabricated2 ->
        let ty_fabricated =
          Meet_and_join_fabricated.join_ty ~type_of_name
            ty_fabricated1 ty_fabricated2
        in
        Known ((Fabricated ty_fabricated) : of_kind_phantom)
      | (Value _ | Naked_number _ | Fabricated _), _ ->
        (* CR mshinwell: isn't this really a kind error?  Same for meet *)
        Unknown

    let join_unk phantom_kind1 phantom_kind2 =
      K.Phantom_kind.join phantom_kind1 phantom_kind2
  end) and Meet_and_join : sig
(*
    val meet :
      (typing_environment -> t -> t -> typing_environment * t) type_accessor
*)
    val meet : (t -> t -> t * judgements_from_meet) type_accessor

    val join : (t -> t -> t) type_accessor

    val meet_typing_environment
       : (typing_environment
      -> typing_environment
      -> typing_environment) type_accessor

    val join_typing_environment
       : (typing_environment
      -> typing_environment
      -> typing_environment) type_accessor
  end = struct
    let meet ~type_of_name (t1 : t) (t2 : t) : t * judgements_from_meet =
      match t1, t2 with
      | Value ty_value1, Value ty_value2 ->
        let ty_value, judgements =
          Meet_and_join_value.meet_ty ~type_of_name ty_value1 ty_value2
        in
        Value ty_value, judgements
      | Naked_number (ty_naked_number1, kind1),
          Naked_number (ty_naked_number2, kind2) ->
        let module N = K.Naked_number in
        begin match kind1, kind2 with
        | N.Naked_immediate, N.Naked_immediate ->
          let ty_naked_number, judgements =
            Meet_and_join_naked_immediate.meet_ty ~type_of_name
              ty_naked_number1 ty_naked_number2
          in
          Naked_number (ty_naked_number, N.Naked_immediate), judgements
        | N.Naked_float, N.Naked_float ->
          let ty_naked_number, judgements =
            Meet_and_join_naked_float.meet_ty ~type_of_name
              ty_naked_number1 ty_naked_number2
          in
          Naked_number (ty_naked_number, N.Naked_float), judgements
        | N.Naked_int32, N.Naked_int32 ->
          let ty_naked_number, judgements =
            Meet_and_join_naked_int32.meet_ty ~type_of_name
              ty_naked_number1 ty_naked_number2
          in
          Naked_number (ty_naked_number, N.Naked_int32), judgements
        | N.Naked_int64, N.Naked_int64 ->
          let ty_naked_number, judgements =
            Meet_and_join_naked_int64.meet_ty ~type_of_name
              ty_naked_number1 ty_naked_number2
          in
          Naked_number (ty_naked_number, N.Naked_int64), judgements
        | N.Naked_nativeint, N.Naked_nativeint ->
          let ty_naked_number, judgements =
            Meet_and_join_naked_nativeint.meet_ty ~type_of_name
              ty_naked_number1 ty_naked_number2
          in
          Naked_number (ty_naked_number, N.Naked_nativeint), judgements
        | _, _ ->
          Misc.fatal_errorf "Kind mismatch upon meet: %a versus %a"
            print t1
            print t2
        end
      | Fabricated ty_fabricated1, Fabricated ty_fabricated2 ->
        let ty_fabricated, judgements =
          Meet_and_join_fabricated.meet_ty ~type_of_name
            ty_fabricated1 ty_fabricated2
        in
        Fabricated ty_fabricated, judgements
      | (Value _ | Naked_number _ | Fabricated _ | Phantom _), _ ->
        Misc.fatal_errorf "Kind mismatch upon meet: %a versus %a"
          print t1
          print t2

    let join ~type_of_name t1 t2 =
      match t1, t2 with
      | Value ty_value1, Value ty_value2 ->
        let ty_value =
          Meet_and_join_value.join_ty ~type_of_name ty_value1 ty_value2
        in
        Value ty_value
      | Naked_number (ty_naked_number1, kind1),
          Naked_number (ty_naked_number2, kind2) ->
        let module N = K.Naked_number in
        begin match kind1, kind2 with
        | N.Naked_immediate, N.Naked_immediate ->
          let ty_naked_number =
            Meet_and_join_naked_immediate.join_ty ~type_of_name
              ty_naked_number1 ty_naked_number2
          in
          Naked_number (ty_naked_number, N.Naked_immediate)
        | N.Naked_float, N.Naked_float ->
          let ty_naked_number =
            Meet_and_join_naked_float.join_ty ~type_of_name
              ty_naked_number1 ty_naked_number2
          in
          Naked_number (ty_naked_number, N.Naked_float)
        | N.Naked_int32, N.Naked_int32 ->
          let ty_naked_number =
            Meet_and_join_naked_int32.join_ty ~type_of_name
              ty_naked_number1 ty_naked_number2
          in
          Naked_number (ty_naked_number, N.Naked_int32)
        | N.Naked_int64, N.Naked_int64 ->
          let ty_naked_number =
            Meet_and_join_naked_int64.join_ty ~type_of_name
              ty_naked_number1 ty_naked_number2
          in
          Naked_number (ty_naked_number, N.Naked_int64)
        | N.Naked_nativeint, N.Naked_nativeint ->
          let ty_naked_number =
            Meet_and_join_naked_nativeint.join_ty ~type_of_name
              ty_naked_number1 ty_naked_number2
          in
          Naked_number (ty_naked_number, N.Naked_nativeint)
        | _, _ ->
          Misc.fatal_errorf "Kind mismatch upon meet: %a versus %a"
            print t1
            print t2
        end
      | Fabricated ty_fabricated1, Fabricated ty_fabricated2 ->
        let ty_fabricated =
          Meet_and_join_fabricated.join_ty ~type_of_name
            ty_fabricated1 ty_fabricated2
        in
        Fabricated ty_fabricated
      | (Value _ | Naked_number _ | Fabricated _ | Phantom _), _ ->
        Misc.fatal_errorf "Kind mismatch upon meet: %a versus %a"
          print t1
          print t2

    let join_typing_environment ~type_of_name
          (t1 : typing_environment) (t2 : typing_environment) =
      let names_to_types =
        Name.Map.inter_merge (fun ty1 ty2 ->
            join ~type_of_name ty1 ty2)
          t1.names_to_types
          t2.names_to_types
      in
      let all_levels_to_names =
        Scope_level.Map.union_merge
          (fun names1 names2 -> Name.Set.union names1 names2)
          t1.levels_to_names
          t2.levels_to_names
      in
      let levels_to_names =
        Scope_level.Map.map (fun names ->
            Name.Set.filter (fun name ->
                Name.Map.mem name names_to_types)
              names)
          all_levels_to_names
      in
      let existentials =
        Name.Set.union t1.existentials t2.existentials
      in
      let existential_freshening =
        t1.existential_freshening (* XXX *)
      in
      { names_to_types;
        levels_to_names;
        existentials;
        existential_freshening;
      }

    let meet_typing_environment ~type_of_name
          (t1 : typing_environment) (t2 : typing_environment) =
      let names_to_types =
        Name.Map.union_merge (fun ty1 ty2 ->
            (* CR mshinwell: Should we make use of these judgements? *)
Format.eprintf "Meeting@ %a and@ %a ...\n%!" print ty1 print ty2;
            let ty, _judgements = meet ~type_of_name ty1 ty2 in
Format.eprintf "...giving %a\n%!" print ty;
            ty)
          t1.names_to_types
          t2.names_to_types
      in
      let all_levels_to_names =
        Scope_level.Map.union_merge
          (fun names1 names2 -> Name.Set.union names1 names2)
          t1.levels_to_names
          t2.levels_to_names
      in
      let levels_to_names =
        Scope_level.Map.map (fun names ->
            Name.Set.filter (fun name ->
                Name.Map.mem name names_to_types)
              names)
          all_levels_to_names
      in
      let existentials =
        Name.Set.inter t1.existentials t2.existentials
      in
      let existential_freshening =
        t1.existential_freshening (* XXX *)
      in
      { names_to_types;
        levels_to_names;
        existentials;
        existential_freshening;
      }
  end

  let meet ~type_of_name t1 t2 =
    let t, judgements = Meet_and_join.meet ~type_of_name t1 t2 in
    let envs =
      List.map (fun (name, t) -> singleton_typing_environment name t)
        judgements
    in
    let env =
      List.fold_left (fun output_env env ->
          Meet_and_join.meet_typing_environment ~type_of_name output_env env)
        (create_typing_environment ())
        envs
    in
    t, env

  let join = Meet_and_join.join
  let join_ty_value = Meet_and_join_value.join_ty

  module Typing_environment = struct
    type t = typing_environment

    (* CR mshinwell: Add invariant check.  First one: symbols should never be
       existential *)

    let print = print_typing_environment
    let create = create_typing_environment

    let add_or_replace t name scope_level ty =
      let names_to_types = Name.Map.add name ty t.names_to_types in
      let levels_to_names =
        Scope_level.Map.update scope_level
          (function
             | None -> Some (Name.Set.singleton name)
             | Some names -> Some (Name.Set.add name names))
          t.levels_to_names
      in
      { t with
        names_to_types;
        levels_to_names;
      }

    let add t name scope_level ty =
      match Name.Map.find name t.names_to_types with
      | exception Not_found -> add_or_replace t name scope_level ty
      | _ty ->
        Misc.fatal_errorf "Cannot rebind %a in environment:@ %a"
          Name.print name
          print t

    let add_or_meet ~type_of_name t name scope_level ty =
      let existing_ty =
        match Name.Map.find name t.names_to_types with
        | exception Not_found -> unknown_like ~type_of_name ty
        | existing_ty -> existing_ty
      in
      (* CR mshinwell: Where should the judgements go? *)
      let ty, _judgements = meet ~type_of_name ty existing_ty in
      add_or_replace t name scope_level ty

    type binding_type = Normal | Existential

    let find t name =
      match Name.Map.find name t.names_to_types with
      | exception Not_found ->
        Misc.fatal_errorf "Cannot find %a in environment:@ %a"
          Name.print name
          print t
      | ty ->
        let binding_type =
          if Name.Set.mem name t.existentials then Existential
          else Normal
        in
        match binding_type with
        | Normal -> ty, Normal
        | Existential ->
     (* XXX     let ty = rename_variables t freshening in *)
          ty, Existential

    let find_opt t name =
      match Name.Map.find name t.names_to_types with
      | exception Not_found -> None
      | ty ->
        let binding_type =
          if Name.Set.mem name t.existentials then Existential
          else Normal
        in
        match binding_type with
        | Normal -> Some (ty, Normal)
        | Existential ->
     (* XXX     let ty = rename_variables t freshening in *)
          Some (ty, Existential)

    let cut t ~existential_if_defined_at_or_later_than =
(*
Format.eprintf "Cutting environment at %a: %a\n%!"
  Scope_level.print existential_if_defined_at_or_later_than
  print_typing_environment t;
*)
      let existentials =
        Scope_level.Map.fold (fun scope_level names resulting_existentials ->
            let will_be_existential =
              Scope_level.(>=)
                scope_level existential_if_defined_at_or_later_than
            in
            if will_be_existential then
              let non_symbols =
                Name.Set.filter (fun (name : Name.t) ->
                    match name with
                    | Var _ -> true
                    | Symbol _ -> false)
                  names
              in
              Name.Set.union non_symbols resulting_existentials
            else
              resulting_existentials)
          t.levels_to_names
          Name.Set.empty
      in
      let existential_freshening =
        Name.Set.fold (fun (name : Name.t) freshening ->
            match name with
            | Symbol _ ->
              Misc.fatal_error "Symbols cannot be existentially bound"
            | Var var ->
              let _new_var, freshening =
                Freshening.add_variable freshening var
              in
              freshening)
          existentials
          t.existential_freshening
      in
let result =
      (* XXX we actually need to rename in the domain of [names_to_types] *)
      { names_to_types = t.names_to_types;
        levels_to_names = t.levels_to_names;
        existentials;
        existential_freshening;
      }
in
(*
Format.eprintf "Result is: %a\n%!"
  print_typing_environment result;
*)
      result

    let meet = Meet_and_join.meet_typing_environment
    let join = Meet_and_join.join_typing_environment
  end

  let add_judgements ~type_of_name t env : t =
    let t, _canonical_name = resolve_aliases ~type_of_name t in
    match t with
    | Value (No_alias (Join of_kind_values)) ->
      let of_kind_values =
        List.map
          (fun (of_kind_value : of_kind_value) : of_kind_value ->
            match of_kind_value with
            | Blocks_and_tagged_immediates { blocks; immediates; } ->
              let blocks =
                Tag.Map.map
                  (fun ((Join { by_length }) : block_cases) : block_cases ->
                    let by_length =
                      Targetint.OCaml.Map.map
                        (fun (block : singleton_block) : singleton_block ->
                          let env_extension =
                            Typing_environment.meet ~type_of_name
                              block.env_extension env
                          in
                          { block with env_extension; })
                        by_length
                    in
                    Join { by_length; })
                  blocks
              in
              let immediates : _ or_unknown =
                match immediates with
                | Unknown -> Unknown
                | Known imm_map ->
                  let imm_map =
                    Immediate.Map.map
                      (fun ({ env_extension; } : immediate_case)
                            : immediate_case ->
                        let env_extension =
                          Typing_environment.meet ~type_of_name
                            env_extension env
                        in
                        { env_extension; })
                      imm_map
                  in
                  Known imm_map
              in
              Blocks_and_tagged_immediates { blocks; immediates; }
            | Boxed_number _ | Closures _ | String _ -> of_kind_value)
          of_kind_values
      in
      Value (No_alias (Join of_kind_values))
    | Fabricated (No_alias (Join of_kind_fabricateds)) ->
      let of_kind_fabricateds =
        List.map
          (fun (of_kind_fabricated : of_kind_fabricated) : of_kind_fabricated ->
            match of_kind_fabricated with
            | Tag tag_map ->
              let tag_map =
                Tag.Map.map (fun ({ env_extension; } : tag_case) : tag_case ->
                    let env_extension =
                      Typing_environment.meet ~type_of_name env_extension env
                    in
                    { env_extension; })
                  tag_map
              in
              Tag tag_map
            | Set_of_closures _
            | Closure _ -> of_kind_fabricated)
          of_kind_fabricateds
      in
      Fabricated (No_alias (Join of_kind_fabricateds))
    | Value (Type _ | Type_of _ | No_alias (Unknown _))
    | Fabricated (Type _ | Type_of _ | No_alias (Unknown _)) -> t
    | Naked_number _ -> t
    | Phantom _ -> t
end
