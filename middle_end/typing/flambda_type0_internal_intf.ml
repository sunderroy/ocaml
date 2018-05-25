(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2018 OCamlPro SAS                                          *)
(*   Copyright 2018 Jane Street Group LLC                                 *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-4-9-30-40-41-42"]

module Float_by_bit_pattern = Numbers.Float_by_bit_pattern
module Int32 = Numbers.Int32
module Int64 = Numbers.Int64

type binding_type = Normal | Was_existential

module S_impl (Expr : sig
  type t
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

    include Hashtbl.Make_with_map (struct
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

  type 'a or_alias =
    | No_alias of 'a
    | Type of Export_id.t
    | Equals of Name.t

  type 'a extensibility =
    | Open of 'a
    | Exactly of 'a

  let extensibility_contents (e : _ extensibility) =
    match e with
    | Open contents | Exactly contents -> contents

  type t = {
    descr : descr;
    phantom : Flambda_kind.Phantom_kind.occurrences option;
  }

  and flambda_type = t

  and t_in_context = typing_environment * t

  and descr =
    | Value of ty_value
    | Naked_number :
        'kind ty_naked_number * 'kind Flambda_kind.Naked_number.t -> descr
    | Fabricated of ty_fabricated

  and ty_value = of_kind_value ty
  and ty_value_in_context = typing_environment * ty_value
  and 'a ty_naked_number = 'a of_kind_naked_number ty
  and ty_fabricated = of_kind_fabricated ty

  and 'a ty = 'a unknown_or_join or_alias
  and 'a ty_in_context = typing_environment * ('a ty)

  and 'a unknown_or_join =
    | Unknown
    | Join of 'a list

  and of_kind_value =
    | Blocks_and_tagged_immediates of blocks_and_tagged_immediates
    | Boxed_number : _ of_kind_value_boxed_number -> of_kind_value
    | Closures of closures
    | String of String_info.Set.t

  and immediate_case = {
    (* Environment extensions have an [option] type so that the information
       required to create a typing environment isn't required for various
       trivial functions such as [these_tagged_immediates]. *)
    env_extension : env_extension;
  }
 
  and singleton_block = {
    env_extension : env_extension;
    fields : t mutable_or_immutable array;
  }

  and block_cases =
    | Blocks of { by_length : singleton_block Targetint.OCaml.Map.t; }

  and blocks_and_tagged_immediates = {
    immediates : immediate_case Immediate.Map.t Or_unknown.t;
    blocks : block_cases Tag.Map.t Or_unknown.t;
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
    free_names_in_body : Name_occurrences.t;
    return_values : Kinded_parameter.t list;
    return_env_extension : env_extension;
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
    result_env_extension : env_extension;
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

  and discriminant_case = {
    env_extension : env_extension;
  }

  and of_kind_fabricated =
    | Discriminant of discriminant_case Discriminant.Map.t
    | Set_of_closures of set_of_closures
    | Closure of closure

  and set_of_closures = {
    closures : ty_fabricated Closure_id.Map.t extensibility;
    closure_elements : ty_value Var_within_closure.Map.t extensibility;
  }

  and closure = {
    function_decls : function_declarations;
  }

  (* CR mshinwell: rename "typing_environment" -> "typing_env" *)

  and typing_environment_entry0 =
    | Definition of t
    | Equation of t

  and typing_environment_entry =
    | Definition of t
    | Equation of t
    | CSE of Flambda_primitive.With_fixed_value.t

  and levels_to_entries =
    (Name.t * typing_environment_entry)
      Scope_level.Sublevel.Map.t Scope_level.Map.t

  and typing_environment = {
    resolver : (Export_id.t -> t option);
    aliases : Name.Set.t Simple.Map.t;
    (* CR mshinwell: Rename names_to_types -> names_to_entries *)
    names_to_types :
      (Scope_level.With_sublevel.t * typing_environment_entry0) Name.Map.t;
    cse : Simple.t Flambda_primitive.With_fixed_value.Map.t;
    levels_to_entries : levels_to_entries;
    next_sublevel_by_level : Scope_level.Sublevel.t Scope_level.Map.t;
    were_existentials : Name.Set.t;
  }

  and env_extension = {
    first_definitions : (Name.t * t) list;
    at_or_after_cut_point : levels_to_entries;
    last_equations_rev : (Name.t * t) list;
    cse : Simple.t Flambda_primitive.With_fixed_value.Map.t;
  }

  and parameters = {
    params : Kinded_parameter.t list;
    env_extension : env_extension;
  }

  type join_env = {
    env : typing_environment;
    env_plus_extension1 : typing_environment;
    env_plus_extension2 : typing_environment;
    extension1 : env_extension;
    extension2 : env_extension;
  }

  module Name_or_export_id = struct
    type t =
      | Name of Name.t
      | Export_id of Export_id.t

    include Hashtbl.Make_with_map (struct
      type nonrec t = t

      let compare t1 t2 =
        match t1, t2 with
        | Name _, Export_id _ -> -1
        | Export_id _, Name _ -> 1
        | Name name1, Name name2 -> Name.compare name1 name2
        | Export_id id1, Export_id id2 -> Export_id.compare id1 id2
 
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

  type changes = Neither | Left | Right | Both

  let join_changes (changes1 : changes) (changes2 : changes) =
    match changes1, changes2 with
    | Neither, Neither -> Neither
    | Neither, Left -> Left
    | Neither, Right -> Right
    | Neither, Both -> Both
    | Left, Neither -> Left
    | Left, Left -> Left
    | Left, Right -> Both
    | Left, Both -> Both
    | Right, Neither -> Right
    | Right, Left -> Both
    | Right, Right -> Right
    | Right, Both -> Both
    | Both, Neither -> Both
    | Both, Left -> Both
    | Both, Right -> Both
    | Both, Both -> Both
end

module type S = sig
  type expr

  include module type of struct include S_impl (struct type t = expr end) end
    with type expr := expr

  val print : Format.formatter -> t -> unit

  val print_typing_environment_entry
     : Format.formatter
    -> typing_environment_entry
    -> unit

  val print_typing_environment
     : Format.formatter
    -> typing_environment
    -> unit

  val print_typing_env_extension
     : Format.formatter
    -> env_extension
    -> unit

  val free_names : flambda_type -> Name_occurrences.t

  val free_names_set : flambda_type -> Name.Set.t

  val unknown : Flambda_kind.t -> t

  val force_to_kind_value : t -> of_kind_value ty

  val force_to_kind_naked_number
     : 'a Flambda_kind.Naked_number.t
    -> t
    -> 'a of_kind_naked_number ty

  val force_to_kind_naked_int32 : t -> Int32.Set.t ty_naked_number

  val force_to_kind_naked_int64 : t -> Int64.Set.t ty_naked_number

  val force_to_kind_naked_nativeint : t -> Targetint.Set.t ty_naked_number

  val force_to_kind_naked_float
     : t
    -> Numbers.Float_by_bit_pattern.Set.t ty_naked_number

  val force_to_kind_naked_immediate : t -> Immediate.Set.t ty_naked_number

  val force_to_kind_fabricated : t -> of_kind_fabricated ty

  val kind : flambda_type -> Flambda_kind.t

  val is_empty_typing_environment : typing_environment -> bool

  val as_or_more_precise : typing_environment -> t -> than:t -> bool

  val strictly_more_precise : typing_environment -> t -> than:t -> bool

  val rename_variables : t -> Name.t Name.Map.t -> t

  val rename_variables_env_extension
     : ?for_join:unit
    -> Name.t Name.Map.t
    -> env_extension
    -> env_extension

  val any_value_as_ty_value : unit -> ty_value

  val any_fabricated_as_ty_fabricated : unit -> ty_fabricated

  val bottom_as_ty_value : unit -> ty_value

  val bottom_as_ty_fabricated : unit -> ty_fabricated

  val get_alias : flambda_type -> Name.t option

  (** Least upper bound of two types. *)
  val join
     : env:typing_environment
    -> env_plus_extension1:typing_environment
    -> env_plus_extension2:typing_environment
    -> extension1:env_extension
    -> extension2:env_extension
    -> t
    -> t
    -> t
end