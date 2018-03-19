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

(** The interface to [Flambda_type0] once the type system has been
    instantiated for a particular expression language (typically
    [Flambda0]). *)

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
    | Equals of Name.t

  type 'a extensibility =
    | Open of 'a
    | Exactly of 'a

  val extensibility_contents : 'a extensibility -> 'a

  type typing_environment

  type equations

  (** Values of type [t] are known as "Flambda types".  Each Flambda type
      has a unique kind. *)
  type t = private {
    descr : descr;
    phantom : Flambda_kind.Phantom_kind.occurrences option;
  }

  and flambda_type = t

  and t_in_context = typing_environment * t

  and descr = private
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

  (** For each kind there is a lattice of types. *)
  and 'a unknown_or_join = private
    | Unknown
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
    equations : equations;
  }
 
  and singleton_block = private {
    (* CR mshinwell: Should this indicate if the block is an array? *)
    equations : equations;
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
    (** Cases for constant constructors (in the case of variants) and
        arbitrary tagged immediates. *)
    blocks : block_cases Tag.Map.t or_unknown;
    (** Cases for non-constant constructors (in the case of variants) and
        normal blocks. *)
    is_int : Name.t option;
    (** A name that is known to contain the result of the [Is_int]
        primitive on the corresponding block. *)
    (* CR mshinwell: Rename? *)
    get_tag : Name.t option;
    (** A name that is known to contain the result of the [Get_tag]
        or [Discriminant_of_int] primitive on the corresponding block. *)
  }

  (** Boxed integer and floating-point numbers together with the types
      of their contents. *)
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

  (** A function declaration which is inlinable (which in particular implies
      that the code of the function's body is known). *)
  and inlinable_function_declaration = private {
    closure_origin : Closure_origin.t;
    continuation_param : Continuation.t;
    exn_continuation_param : Continuation.t;
    (* CR-someday mshinwell: [is_classic_mode] should be changed to use a
       new type which records the combination of inlining (etc) options
       applied to the originating source file. *)
    is_classic_mode : bool;
    (** Whether the file from which this function declaration originated was
        compiled in classic mode. *)
    params : (Parameter.t * t) list;
    code_id : Code_id.t;
    body : expr;
    free_names_in_body : Name_occurrences.t;
    result : t list;  (* CR mshinwell: make plural *)
    (* CR mshinwell: Is this name misleading?  The quantifiers are before
       the parameters *)
    result_equations : equations;
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
    my_closure : Variable.t;
  }

  (** A function declaration that is not inlinable (typically because the
      code is unknown, possibly due to being deliberately discarded). *)
  and non_inlinable_function_declarations = private {
    params : t list;
    result : t list;
    result_equations : equations;
    direct_call_surrogate : Closure_id.t option;
  }

  and function_declarations = private
    | Non_inlinable of non_inlinable_function_declarations option
    | Inlinable of inlinable_function_declaration

  (* CR mshinwell: should the closure types contain equations? *)

  and closures_entry = private {
    set_of_closures : ty_fabricated;
  }

  (** The various closures which flow to a particular program point. *)
  and closures =
    closures_entry Closure_id.Map.t

  (** Unboxed ("naked") integer and floating-point numbers together with
      any information known about which particular numbers they might be. *)
  and 'a of_kind_naked_number = private
    | Immediate : Immediate.Set.t -> Immediate.Set.t of_kind_naked_number
    | Float : Numbers.Float_by_bit_pattern.Set.t
        -> Numbers.Float_by_bit_pattern.Set.t of_kind_naked_number
    | Int32 : Numbers.Int32.Set.t -> Numbers.Int32.Set.t of_kind_naked_number
    | Int64 : Numbers.Int64.Set.t -> Numbers.Int64.Set.t of_kind_naked_number
    | Nativeint : Targetint.Set.t -> Targetint.Set.t of_kind_naked_number

  (** Judgements known to hold if a particular value has been shown to match
      some discriminant. *)
  and discriminant_case = private {
    equations : equations;
  }

  and of_kind_fabricated = private
    (* CR mshinwell: Should tags be represented as naked immediates?  (A bit
       troublesome since the obvious Fabricated_kind.t wouldn't have a unique
       top element) *)
    | Discriminant of discriminant_case Discriminant.Map.t
      (** Either:
          - a block tag, as returned by the [Get_tag] primitive; or
          - a constant constructor which has undergone a kind-cast to kind
            [Fabricated] using the [Discriminant_of_int] primitive. *)
    | Set_of_closures of set_of_closures
      (** A possibly mutually-recursive collection of closure values, which
          at runtime will be represented by a single block. *)
    | Closure of closure
      (** One element of a set of closures.  (Note that this is distinct
          from the [Closures] case, above, in kind [Value].) *)

  and set_of_closures = private {
    closures : ty_fabricated Closure_id.Map.t extensibility;
    closure_elements : ty_value Var_within_closure.Map.t extensibility;
  }

  and closure = private {
    function_decls : function_declarations;
  }

  module Name_or_export_id : sig
    type t =
      | Name of Name.t
      | Export_id of Export_id.t

    include Identifiable.S with type t := t
  end

  (** If the given type has kind [Phantom], return it; otherwise form the
      correct type of kind [Phantom] describing the given type. *)
  val phantomize
     : t
    -> Flambda_kind.Phantom_kind.occurrences
    -> t

  (** Whether a name bound by the environment is normally-accessible or
      has been made existential (as a result of [cut], below). *)
  type binding_type = private Normal | Existential

  module Typing_environment : sig
    (** A "traditional" typing environment or context: an assignment from
        names to types.  The environment also encapsulates the knowledge,
        via the [resolver], required to import types from .cmx files (or
        other external source).

        Typing environments must be closed.
    *)

    type t = typing_environment

    val create : resolver:(Export_id.t -> flambda_type option) -> t

    val create_using_resolver_from : t -> t

    val add : t -> Name.t -> Scope_level.t -> flambda_type -> t

    (** The same as [add] on a newly-[create]d environment. *)
    val singleton
       : resolver:(Export_id.t -> flambda_type option)
      -> Name.t
      -> Scope_level.t
      -> flambda_type
      -> t

    (** Refine the type of a name that is currently bound in the
        environment.  (It is an error to call this function with a name that
        is not bound in the given environment.) *)
    val replace_meet : t -> Name.t -> t_in_context -> t

    val add_or_replace_meet : t -> Name.t -> Scope_level.t -> flambda_type -> t

    val add_or_replace : t -> Name.t -> Scope_level.t -> flambda_type -> t

    (** Perform a lookup in a type environment.  It is an error to provide a
        name which does not occur in the given environment. *)
    val find : t -> Name.t -> flambda_type * binding_type

    val find_with_scope_level
       : t
      -> Name.t
      -> flambda_type * Scope_level.t * binding_type

    (** Like [find], but returns [None] iff the given name is not in the
        specified environment. *)
    val find_opt : t -> Name.t -> (flambda_type * binding_type) option

    (** Returns [true] if the given name, which must be bound in the given
        environment, is existentially bound. *)
    val is_existential : t -> Name.t -> bool

    (** The continuation scoping level at which the given name, which must
        occur in the given typing context, was declared. *)
    val scope_level : t -> Name.t -> Scope_level.t

    (** Rearrange the given typing environment so that names defined at or
        deeper than the given scope level are made existential.  This means
        that they may be referred to from types but may never occur normally
        in terms (or be produced from a reification of a type, c.f.
        [Flambda_type.reify], etc). *)
    val cut
       : t
      -> existential_if_defined_at_or_later_than:Scope_level.t
      -> t

    (** Least upper bound of two typing environments. *)
    val join : t -> t -> t

    (** Greatest lower bound of two typing environments. *)
    val meet : t -> t -> t

    (** Adjust the domain of the given typing environment so that it only
        mentions the names in the given name occurrences structure. *)
    val restrict_to_names : t -> Name_occurrences.t -> t

    (** Adjust the domain of the given typing environment so that it only
        mentions names which are symbols, not variables. *)
    val restrict_to_symbols : t -> t

    (** The names for which the given typing environment specifies a type
        assignment. *)
    val domain : t -> Name_occurrences.t

    val is_empty : t -> bool

    (** Print the given typing environment to a formatter. *)
    val print : Format.formatter -> t -> unit

    val resolver : t -> (Export_id.t -> flambda_type option)

    val add_alias : t -> canonical_name:Name.t -> alias:Name.t -> t

    val aliases : t -> canonical_name:Name.t -> Name.Set.t
  end

  module Equations : sig
    type t = equations

    val create : unit -> t
  end

  (** Annotation for functions that may require examination of the current
      environment (in particular to resolve [Type] or [Equals] aliases). *)
  type 'a type_accessor = Typing_environment.t -> 'a

  (** Print a type to the given formatter. *)
  val print : Format.formatter -> t -> unit

  (** Like [print] except uses a cache to prevent repeated printing of
      shared sub-components. *)
  val print_with_cache : cache:Printing_cache.t -> Format.formatter -> t -> unit

  val print_ty_value_with_cache
     : cache:Printing_cache.t
    -> Format.formatter
    -> ty_value
    -> unit

  val print_ty_value_array
     : cache:Printing_cache.t
    -> Format.formatter
    -> ty_value array
    -> unit

  val print_inlinable_function_declaration
     : Format.formatter
    -> inlinable_function_declaration
    -> unit

  val of_ty_value : ty_value -> t

  val of_ty_naked_number
     : 'kind ty_naked_number
    -> 'kind Flambda_kind.Naked_number.t
    -> t

  val of_ty_fabricated : ty_fabricated -> t

  (** Construction of top types. *)
  val unknown : Flambda_kind.t -> t

  val any_value : unit -> t
  val any_value_as_ty_value : unit -> ty_value

  val any_fabricated : unit -> t
  val any_fabricated_as_ty_fabricated : unit -> ty_fabricated

  val any_tagged_immediate : unit -> t
  val any_tagged_bool : unit -> t

  val any_boxed_float : unit -> t
  val any_boxed_int32 : unit -> t
  val any_boxed_int64 : unit -> t
  val any_boxed_nativeint : unit -> t

  val any_naked_immediate : unit -> t
  val any_naked_float : unit -> t

  val any_naked_float_as_ty_naked_float
     : unit
    -> Numbers.Float_by_bit_pattern.Set.t ty_naked_number

  (** The top type for unboxed 32-bit numbers. *)
  val any_naked_int32 : unit -> t

  (** The top type for unboxed 64-bit numbers. *)
  val any_naked_int64 : unit -> t

  (** The top type for unboxed "nativeint" numbers. *)
  val any_naked_nativeint : unit -> t

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

  (** A type representing a set of tagged immediates combined with typing
      judgements that will be used if the set contains, or is subsequently
      refined to contain, only a unique element. *)
  val these_tagged_immediates_with_envs : equations Immediate.Map.t -> t

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

  (** The type corresponding to a mutable string of length [size]. *)
  val mutable_string : size:Targetint.OCaml.t -> t

  (** The type corresponding to a mutable float array holding [size]
      naked floats. *)
  val mutable_float_array : size:Targetint.OCaml.t -> t

  (** Building of types corresponding to values that did not exist at
      source level. *)

  (** The given discriminant. *)
  val this_discriminant : Discriminant.t -> t

  (** Like [this_discriminant], but returns the [ty_fabricated], rather than
      a value of type [t]. *)
  val this_discriminant_as_ty_fabricated : Discriminant.t -> ty_fabricated

  (** The given block discriminants coupled with the equations that hold if the
      corresponding block can be shown to have one of the discriminants. *)
  val these_discriminants : equations Discriminant.Map.t -> t

  (** Like [these_discriminants], but returns the [ty_fabricated], rather than
      a value of type [t]. *)
  val these_discriminants_as_ty_fabricated
     : equations Discriminant.Map.t
    -> ty_fabricated

  (** Any discriminant. *)
  val any_discriminant_as_ty_fabricated : unit -> ty_fabricated

  (** Given the type of a naked floating-point number, return the type of the
      corresponding boxed version. *)
  val box_float : t -> t

  (** Given the type of a naked int32 number, return the type of the
      corresponding boxed version. *)
  val box_int32 : t -> t

  (** Given the type of a naked int64 number, return the type of the
      corresponding boxed version. *)
  val box_int64 : t -> t

  (** Given the type of a naked nativeint number, return the type of the
      corresponding boxed version. *)
  val box_nativeint : t -> t

  (** The type of a float array containing the given floating-point numbers. *)
  val immutable_float_array
     : Numbers.Float_by_bit_pattern.Set.t ty_naked_number array
    -> t

  (** The type of a block with a known tag, size and field types. *)
  val block
     : Tag.t
    -> fields:t mutable_or_immutable array
    -> t

  (** Like [block], except that the field types are statically known to be
      of kind [Value]). *)
  val block_of_values
     : Tag.Scannable.t
    -> fields:ty_value mutable_or_immutable array
    -> t

  (** The type of a block with a known tag and size but unknown content,
      save that the contents are all of kind [Value]. *)
  val block_of_unknown_values
     : Tag.Scannable.t
    -> size:int
    -> t

  (** The type of a value [v] for which the result of the [Is_int] primitive on
      [v] is given by the name [is_int] and the result of the [Get_tag]
      primitive on [v] is given by the name [get_tag]. (Used for unboxing
      transformations.) *)
  val variant_whose_discriminants_are
     : is_int:Name.t option
    -> get_tag:Name.t option
    -> t

  (** The bottom type for the given kind ("no value can flow to this point"). *)
  val bottom : Flambda_kind.t -> t

  (** The bottom type for kind [Value] expressed as a type whose kind is
      statically known. *)
  val bottom_as_ty_value : unit -> ty_value

  (** The bottom type for kind [Fabricated] expressed as a type whose kind is
      statically known. *)
  val bottom_as_ty_fabricated : unit -> ty_fabricated

  (** Create an "bottom" type with the same kind as the given type. *)
  val bottom_like : t -> t

  (** Create an "unknown" type with the same kind as the given type. *)
  val unknown_like : t -> t

  (** Create a description of a function declaration whose code is known. *)
  val create_inlinable_function_declaration
     : is_classic_mode:bool
    -> closure_origin:Closure_origin.t
    -> continuation_param:Continuation.t
    -> exn_continuation_param:Continuation.t
    -> params:(Parameter.t * t) list
    -> body:expr
    -> result:t list
    -> result_equations:equations
    -> stub:bool
    -> dbg:Debuginfo.t
    -> inline:inline_attribute
    -> specialise:specialise_attribute
    -> is_a_functor:bool
    -> invariant_params:Variable.Set.t lazy_t
    -> size:int option lazy_t
    -> direct_call_surrogate:Closure_id.t option
    -> my_closure:Variable.t
    -> function_declarations

  (** Create a description of a function declaration whose code is unknown.
      The lack of knowledge about the code will prevent inlining. *)
  val create_non_inlinable_function_declaration
     : params:t list
    -> result:t list
    -> result_equations:equations
    -> direct_call_surrogate:Closure_id.t option
    -> function_declarations

  (** Create a type of kind [Fabricated] describing a closure in terms of
      either non-inlinable or inlinable function declarations.  Note that
      this concept is different from that of closure types of kind [Value]
      (see [closures], below). *)
  val closure : function_declarations -> ty_fabricated

  (** Create a type of kind [Fabricated] describing the given set(s) of
      closures. *)
  val set_of_closures
     : closures:ty_fabricated Closure_id.Map.t extensibility
    -> closure_elements:ty_value Var_within_closure.Map.t extensibility
    -> t

  (** Used to create the data in the map required for the [closures]
      function. *)
  val closures_entry : set_of_closures:ty_fabricated -> closures_entry

  (** Create a type of kind [Value] describing the given possibilities for
      closure value. *)
  val closures : closures_entry Closure_id.Map.t -> t

  (** Construct a type equal to the type of the given name.  (The name
      must be present in the given environment when calling e.g. [join].) *)
  val alias_type_of : Flambda_kind.t -> Name.t -> t

  (** Like [alias_type_of], but for types of kind [Value], and returns the
      [ty] rather than a [t]. *)
  val alias_type_of_as_ty_value : Name.t -> ty_value

  (** Like [alias_type_of_as_ty_value] but for types of [Fabricated] kind. *)
  val alias_type_of_as_ty_fabricated : Name.t -> ty_fabricated

  (** The type that is equal to another type, found in a .cmx file, named
      by export identifier. *)
  val alias_type : Flambda_kind.t -> Export_id.t -> t

  (** Free names in a type. *)
  val free_names : t -> Name_occurrences.t

  (** Determine the (unique) kind of a type. *)
  val kind : t -> Flambda_kind.t

  (** Enforce that a type is of kind [Value], returning the corresponding
      [ty]. *)
  val force_to_kind_value : t -> ty_value

  (** Enforce that a type is of a naked number kind, returning the
      corresponding [ty]. *)
  val force_to_kind_naked_number
     : 'kind Flambda_kind.Naked_number.t
    -> t
    -> 'kind ty_naked_number

  (** Enforce that a type is of naked float kind, returning the corresponding
      [ty]. *)
  val force_to_kind_naked_float
     : t
    -> Numbers.Float_by_bit_pattern.Set.t ty_naked_number

  (** Enforce that a type is of fabricated kind, returning the corresponding
      [ty]. *)
  val force_to_kind_fabricated : t -> ty_fabricated

  (** Enforce that a type is of a given kind. *)
  val check_of_kind : t -> Flambda_kind.t -> unit

  (** Push judgements from the given typing environment down to the
      uppermost places in the type where such information can be hold
      (i.e. underneath tagged immediate, block and tag maps). *)
  val add_judgements : t_in_context -> t

  (** Least upper bound of two types. *)
  val join : t_in_context -> t_in_context -> t

  (** Least upper bound of two types known to be of kind [Value]. *)
  val join_ty_value : ty_value_in_context -> ty_value_in_context -> ty_value

  (** Greatest lower bound of two types.
      When meeting two aliases the returned type will be an alias holding the
      name from the [bias_towards] side.  (A returned judgement will contain an
      equality to the name on the other side.) *)
  val meet
     : output_env:Typing_environment.t
    -> bias_towards:t_in_context
    -> t_in_context
    -> t_in_context

  (** Follow chains of [Alias]es until either a [No_alias] type is reached
      or a name cannot be resolved.

      This function also returns the "canonical name" for the given type:
      the furthest-away [Name.t] in any chain of aliases leading from the given
      type.  (The chain may also involve [Export_id.t] links either before or
      after any returned canonical name.) *)
  val resolve_aliases : t_in_context -> t * (Name.t option)
end
