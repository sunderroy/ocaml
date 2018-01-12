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

(* CR mshinwell: Add invariant checks, including e.g. on the bodies of
   functions in types. *)

(* CR-someday mshinwell: When disambiguation on GADT constructors works we
   can probably use an existential to combine the "Naked_" kind constructors
   into just one. *)

module type S = sig
  type expr

  type inline_attribute =
    | Always_inline
    | Never_inline
    | Unroll of int
    | Default_inline

  type specialise_attribute =
    | Always_specialise
    | Never_specialise
    | Default_specialise

  type string_contents = private
    (* Known strings are constrained to [Sys.max_string_length] on the machine
       running the compiler. *)
    | Contents of string
    | Unknown_or_mutable

  module String_info : sig
    type t = private {
      contents : string_contents;
      (* CR mshinwell: Enforce the invariant that the [size] really does not
         exceed [Targetint.OCaml.max_string_length] when this structure is
         created. *)
      size : Targetint.OCaml.t;
    }

    include Identifiable.S with type t := t
  end

  type 'a mutable_or_immutable =
    | Immutable of 'a
    | Mutable

  type 'a or_unknown =
    | Known of 'a
    | Unknown

  type 'a or_alias = private
    | No_alias of 'a
    | Type of Export_id.t
    | Type_of of Name.t

  type 'a extensibility =
    | Open of 'a
    | Exactly of 'a

  type typing_environment

  (** Values of type [t] are known as "Flambda types".  Each Flambda type
      has a unique kind. *)
  type t = private
    | Value of ty_value
    | Naked_number :
        'kind ty_naked_number * 'kind Flambda_kind.Naked_number.t -> t
    | Fabricated of ty_fabricated
    | Phantom of ty_phantom

  and flambda_type = t

  (** Types of kind [Value] are equipped with an extra piece of information
      such that when we are at the top element, [Unknown], we still know
      whether a root has to be registered. *)
  and ty_value = (of_kind_value, Flambda_kind.Value_kind.t) ty
  and 'a ty_naked_number = ('a of_kind_naked_number, unit) ty
  and ty_fabricated = (of_kind_fabricated, Flambda_kind.Value_kind.t) ty
  and ty_phantom = (of_kind_phantom, Flambda_kind.Phantom_kind.t) ty

  and ('a, 'u) ty = ('a, 'u) unknown_or_join or_alias

  (** For each kind there is a lattice of types. *)
  and ('a, 'u) unknown_or_join = private
    | Unknown of 'u
    (** "Any value can flow to this point": the top element. *)
    | Join of 'a list
    (** - The list being empty means bottom, the least element: "no value can
          flow to this point".
        - The list containing a single element is the usual case where there is
          no join between incompatible types.
        - If the list contains more than one element:
          A join, between incompatible types, which has been remembered
          in case it is refined by a subsequent meet.  Joins between compatible
          types are immediately pushed down through the top level structure
          of the type.
        Invariant: every member of a [Join] is mutually incompatible with the
        other members. *)

  (* CR mshinwell: There needs to be an invariant function which checks that
     any possible "bottom" case here is represented instead by "Join []".
     (Example: Blocks_and_tagged_immediates with both blocks and
     immediates the empty map.)  This means that to check bottomness it
     suffices to check against "Join []".
     ** But what is the equivalent rule for "Unknown"?
     The check should also ensure that blocks are only ty_value /
     ty_naked_float *)
  and of_kind_value = private
    | Blocks_and_tagged_immediates of blocks_and_tagged_immediates
    | Boxed_number : _ of_kind_value_boxed_number -> of_kind_value
    | Closures of closures
    | String of String_info.Set.t

  and immediate_case = private {
    env_extension : typing_environment;
  }
 
  and singleton_block = private {
    (* CR mshinwell: Should this indicate if the block is an array? *)
    env_extension : typing_environment;
    (* CR mshinwell: We should note explicitly that these are logical fields
       (I think this only matters for float arrays on 32-bit targets) *)
    fields : t mutable_or_immutable array;
  }

  and block_cases = private
    (* CR mshinwell: This should use a different type which is capped at
       max array / block size *)
    | Join of { by_length : singleton_block Targetint.OCaml.Map.t; }
    (** This is similar to the [Join] case at the top level of types:
        no two [singleton_block]s in one of these [Join]s can have a
        compatible structure.
        The only thing which determines the compatibility in this case is
        the length, which we can make explicit using a map.
        Invariant: the map is always non-empty. *)

  and blocks_and_tagged_immediates = private {
    immediates : immediate_case Immediate.Map.t or_unknown;
    blocks : block_cases Tag.Map.t;
  }

  and 'a of_kind_value_boxed_number = private
    | Boxed_float
         : Numbers.Float_by_bit_pattern.Set.t ty_naked_number
        -> Numbers.Float_by_bit_pattern.Set.t ty_naked_number
             of_kind_value_boxed_number
    | Boxed_int32
         : Numbers.Int32.Set.t ty_naked_number
        -> Numbers.Int32.Set.t ty_naked_number of_kind_value_boxed_number
    | Boxed_int64
         : Numbers.Int64.Set.t ty_naked_number
        -> Numbers.Int64.Set.t ty_naked_number of_kind_value_boxed_number
    | Boxed_nativeint
         : Targetint.Set.t ty_naked_number
        -> Targetint.Set.t ty_naked_number of_kind_value_boxed_number

  and inlinable_function_declaration = private {
    closure_origin : Closure_origin.t;
    continuation_param : Continuation.t;
    (* CR-someday mshinwell: [is_classic_mode] should be changed to use a
       new type which records the combination of inlining (etc) options
       applied to the originating source file. *)
    is_classic_mode : bool;
    (** Whether the file from which this function declaration originated was
        compiled in classic mode. *)
    params : (Parameter.t * t) list;
    code_id : Code_id.t;
    body : expr;
    free_names_in_body : Name.Set.t;
    result : t list;  (* CR mshinwell: make plural *)
    (* CR mshinwell: Is this name misleading?  The quantifiers are before
       the parameters *)
    result_env_extension : typing_environment;
    stub : bool;
    dbg : Debuginfo.t;
    inline : inline_attribute;
    specialise : specialise_attribute;
    is_a_functor : bool;
    (* CR mshinwell: try to change these to [Misc.Stdlib.Set_once.t]?
       (ask xclerc) *)
    invariant_params : Variable.Set.t lazy_t;
    size : int option lazy_t;
    (** For functions that are very likely to be inlined, the size of the
        function's body. *)
    direct_call_surrogate : Closure_id.t option;
  }

  and non_inlinable_function_declarations = private {
    params : t list;
    result : t list;
    result_env_extension : typing_environment;
    direct_call_surrogate : Closure_id.t option;
  }

  and function_declarations = private
    | Non_inlinable of non_inlinable_function_declarations option
    | Inlinable of inlinable_function_declaration

  (* CR mshinwell: should the closure types contain environment extensions? *)

  and closures_entry = private {
    set_of_closures : ty_fabricated;
  }

  and closures = private
    closures_entry Closure_id.Map.t

  and 'a of_kind_naked_number = private
    | Immediate : Immediate.Set.t -> Immediate.Set.t of_kind_naked_number
    | Float : Numbers.Float_by_bit_pattern.Set.t
        -> Numbers.Float_by_bit_pattern.Set.t of_kind_naked_number
    | Int32 : Numbers.Int32.Set.t -> Numbers.Int32.Set.t of_kind_naked_number
    | Int64 : Numbers.Int64.Set.t -> Numbers.Int64.Set.t of_kind_naked_number
    | Nativeint : Targetint.Set.t -> Targetint.Set.t of_kind_naked_number

  and tag_case = private {
    env_extension : typing_environment;
  }

  and of_kind_fabricated = private
    (* CR mshinwell: Should tags be represented as naked immediates?  (A bit
       troublesome since the obvious Fabricated_kind.t wouldn't have a unique
       top element) *)
    | Tag of tag_case Tag.Map.t
    | Set_of_closures of set_of_closures
    | Closure of closure

  and set_of_closures = private {
    closures : ty_fabricated Closure_id.Map.t extensibility;
    closure_elements : ty_value Var_within_closure.Map.t extensibility;
  }

  and closure = private {
    function_decls : function_declarations;
  }

  and of_kind_phantom = private
    | Value of ty_value
    | Naked_number
         : 'kind ty_naked_number * 'kind Flambda_kind.Naked_number.t
        -> of_kind_phantom
    | Fabricated of ty_fabricated

  module Name_or_export_id : sig
    type t =
      | Name of Name.t
      | Export_id of Export_id.t

    include Identifiable.S with type t := t
  end

  (** Annotation for functions that may require examination of the current
      simplification environment. *)

  type type_of_name =
       ?local_env:typing_environment
    -> Name_or_export_id.t
    -> t option

  type 'a type_accessor = type_of_name:type_of_name -> 'a

  (** If the given type has kind [Phantom], return it; otherwise form the
      correct type of kind [Phantom] describing the given type. *)
  val phantomize : t -> t

  module Typing_environment : sig
    type t = typing_environment

    val print : Format.formatter -> t -> unit

    val create : unit -> t

    val add : t -> Name.t -> Scope_level.t -> flambda_type -> t

    val add_or_replace : t -> Name.t -> Scope_level.t -> flambda_type -> t

    type binding_type = Normal | Existential

    val find : t -> Name.t -> flambda_type * binding_type

    val find_opt : t -> Name.t -> (flambda_type * binding_type) option

    val cut
       : t
      -> existential_if_defined_later_than:Scope_level.t
      -> t

    val join : (t -> t -> t) type_accessor

    val meet : (t -> t -> t) type_accessor
  end

  val print : Format.formatter -> t -> unit

  val print_ty_value : Format.formatter -> ty_value -> unit

  val print_ty_value_array : Format.formatter -> ty_value array -> unit

  val print_inlinable_function_declaration
     : Format.formatter
    -> inlinable_function_declaration
    -> unit

  val of_ty_value : ty_value -> t

  val of_ty_naked_number
     : 'kind ty_naked_number
    -> 'kind Flambda_kind.Naked_number.t
    -> t

  (** Construction of top types. *)
  val unknown : Flambda_kind.t -> t

  val any_value : Flambda_kind.Value_kind.t -> t

  val any_value_as_ty_value
     : Flambda_kind.Value_kind.t
    -> ty_value

  val any_fabricated_as_ty_fabricated
     : Flambda_kind.Value_kind.t
    -> ty_fabricated

  val any_tagged_immediate : unit -> t

  val any_boxed_float : unit -> t
  val any_boxed_int32 : unit -> t
  val any_boxed_int64 : unit -> t
  val any_boxed_nativeint : unit -> t

  val any_naked_immediate : unit -> t
  val any_naked_float : unit -> t

  val any_naked_float_as_ty_naked_float
     : unit
    -> Numbers.Float_by_bit_pattern.Set.t ty_naked_number

  val any_naked_int32 : unit -> t
  val any_naked_int64 : unit -> t
  val any_naked_nativeint : unit -> t

(*  val any_closure : unit -> t *)

  val any_fabricated : unit -> t
  val any_phantom : unit -> t

  (** Building of types representing tagged / boxed values from specified
      constants. *)
  val this_tagged_immediate : Immediate.t -> t
  val these_tagged_immediates : Immediate.Set.t -> t
  val this_boxed_float : Numbers.Float_by_bit_pattern.t -> t
  val these_boxed_floats : Numbers.Float_by_bit_pattern.Set.t -> t
  val this_boxed_int32 : Int32.t -> t
  val these_boxed_int32s : Numbers.Int32.Set.t -> t
  val this_boxed_int64 : Int64.t -> t
  val these_boxed_int64s : Numbers.Int64.Set.t -> t
  val this_boxed_nativeint : Targetint.t -> t
  val these_boxed_nativeints : Targetint.Set.t -> t
  val this_immutable_string : string -> t
  val this_immutable_float_array : Numbers.Float_by_bit_pattern.t array -> t

  (** Building of types representing untagged / unboxed values from
      specified constants. *)
  val this_naked_immediate : Immediate.t -> t
  val this_naked_float : Numbers.Float_by_bit_pattern.t -> t
  val this_naked_float_as_ty_naked_float
     : Numbers.Float_by_bit_pattern.t
    -> Numbers.Float_by_bit_pattern.Set.t ty_naked_number
  val these_naked_floats : Numbers.Float_by_bit_pattern.Set.t -> t
  val this_naked_int32 : Int32.t -> t
  val these_naked_int32s : Numbers.Int32.Set.t -> t
  val this_naked_int64 : Int64.t -> t
  val these_naked_int64s : Numbers.Int64.Set.t -> t
  val this_naked_nativeint : Targetint.t -> t
  val these_naked_nativeints : Targetint.Set.t -> t

  (** Building of types corresponding to immutable values given only the
      size of such values. *)
  val immutable_string : size:Targetint.OCaml.t -> t

  (** Building of types corresponding to mutable values. *)
  val mutable_string : size:Targetint.OCaml.t -> t

  val mutable_float_array : size:Targetint.OCaml.t -> t

  (** Building of types corresponding to values that did not exist at
      source level. *)

  (** The given block tag. *)
  val this_tag_as_ty_fabricated : Tag.t -> ty_fabricated
  val this_tag : Tag.t -> t

  (** The given block tags coupled with the equations that hold if the
      corresponding block can be shown to have one of the tags. *)
  val these_tags_as_ty_fabricated
     : typing_environment Tag.Map.t
    -> ty_fabricated
  val these_tags
     : typing_environment Tag.Map.t
    -> t

  (** Any block tag. *)
  val any_tag_as_ty_fabricated : unit -> ty_fabricated

(*

  (** Building of types from other types.  These functions will fail with
      a fatal error if the supplied type is not of the correct kind. *)
  (* XXX maybe we should change all of these to the "ty_..." variants, so
     we can avoid the exception case *)
  val tag_immediate : t -> t
*)
  val box_float : t -> t
  val box_int32 : t -> t
  val box_int64 : t -> t
  val box_nativeint : t -> t

  val immutable_float_array
     : Numbers.Float_by_bit_pattern.Set.t ty_naked_number array
    -> t

  val block_of_values
     : Tag.Scannable.t
    -> fields:ty_value mutable_or_immutable array
    -> t

  val block_of_unknown_values
     : Tag.Scannable.t
    -> Flambda_kind.Value_kind.t
    -> size:int
    -> t

  (** The bottom type for the given kind ("no value can flow to this point"). *)
  val bottom : Flambda_kind.t -> t

  val bottom_as_ty_value : unit -> ty_value

  val create_inlinable_function_declaration
     : is_classic_mode:bool
    -> closure_origin:Closure_origin.t
    -> continuation_param:Continuation.t
    -> params:(Parameter.t * t) list
    -> body:expr
    -> result:t list
    -> stub:bool
    -> dbg:Debuginfo.t
    -> inline:inline_attribute
    -> specialise:specialise_attribute
    -> is_a_functor:bool
    -> invariant_params:Variable.Set.t lazy_t
    -> size:int option lazy_t
    -> direct_call_surrogate:Closure_id.t option
    -> function_declarations

  val create_non_inlinable_function_declaration
     : params:t list
    -> result:t list
    -> result_env_extension:typing_environment
    -> direct_call_surrogate:Closure_id.t option
    -> function_declarations

  val create_closure : function_declarations -> closure

  val closure : closure -> t

  val create_set_of_closures
     : closures:ty_fabricated Closure_id.Map.t extensibility
    -> closure_elements:ty_value Var_within_closure.Map.t extensibility
    -> set_of_closures

  val set_of_closures : set_of_closures -> t

  (** Construct a type equal to the type of the given name.  (The name
      must be present in the given environment when calling e.g. [join].) *)
  val alias_type_of : Flambda_kind.t -> Name.t -> t

  val alias_type_of_as_ty_value : Name.t -> ty_value

  val alias_type_of_as_ty_fabricated : Name.t -> ty_fabricated

  val alias_type : Flambda_kind.t -> Export_id.t -> t

  (** Free names in a type. *)
  val free_names : t -> Name.Set.t

  (** Determine the (unique) kind of a type. *)
  val kind : (t -> Flambda_kind.t) type_accessor

  (** Given a type known to be of kind [Value], determine the corresponding
      value kind. *)
  val value_kind_ty_value
     : (ty_value -> Flambda_kind.Value_kind.t) type_accessor

  val add_judgements : (t -> Typing_environment.t -> t) type_accessor

  (** Least upper bound of two types. *)
  val join : (t -> t -> t) type_accessor

  (** Least upper bound of two types known to be of kind [Value]. *)
  val join_ty_value : (ty_value -> ty_value -> ty_value) type_accessor

  (** Greatest lower bound of two types.
      This can introduce new judgements, which are returned as an
      environment. *)
  val meet : (t -> t -> t * typing_environment) type_accessor

  (* CR mshinwell: We may not need to expose all of the following functions *)

  (** Follow chains of [Alias]es until either a [No_alias] type is reached
      or a name cannot be resolved.

      This function also returns the "canonical name" for the given type:
      the furthest-away [Name.t] in any chain of aliases leading from the given
      type.  (The chain may also involve [Export_id.t] links either before or
      after any returned canonical name.) *)
  val resolve_aliases : (t -> t * (Name.t option)) type_accessor

  (** Like [resolve_aliases], but unresolved names at the top level are
      changed into [Unknown]s. *)
  val resolve_aliases_and_squash_unresolved_names
     : (t -> t * (Name.t option)) type_accessor

  (** Like [resolve_aliases], but for use when you have a [ty], not a [t]. *)
  val resolve_aliases_on_ty
     : (force_to_kind:(t -> ('a, 'b) ty)
    -> ('a, 'b) ty
    -> ('a, 'b) ty * (Name.t option)) type_accessor

  (** Like [resolve_aliases_on_ty], but unresolved names at the top level are
      changed into [Unknown]s (with payloads given by [unknown_payload]). *)
  val resolve_aliases_and_squash_unresolved_names_on_ty
     : (force_to_kind:(t -> ('a, 'b) ty)
    -> unknown_payload:'b
    -> ('a, 'b) ty
    -> ('a, 'b) unknown_or_join * (Name.t option)) type_accessor

  val force_to_kind_value : t -> ty_value

  val force_to_kind_naked_number
     : 'kind Flambda_kind.Naked_number.t
    -> t
    -> 'kind ty_naked_number

  val force_to_kind_naked_float
     : t
    -> Numbers.Float_by_bit_pattern.Set.t ty_naked_number

  val force_to_kind_fabricated : t -> ty_fabricated

  val force_to_kind_phantom : t -> ty_phantom

  val check_of_kind : (t -> Flambda_kind.t -> unit) type_accessor
end
