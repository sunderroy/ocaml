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

(** The representation of an abstraction that binds a number of ordered
    parameters along with their kinds.  Equations may be supplied upon the
    parameters together with existential definitions.
*)

module type S = sig
  type env_extension
  type typing_environment
  type join_env
  type flambda_type
  type parameters

  type t = parameters

  val invariant : t -> unit

  val print : Format.formatter -> t -> unit

  val create : Kinded_parameter.t list -> t

  val create_with_env_extension
     : Kinded_parameter.t list
    -> env_extension
    -> t

  val introduce : t -> typing_environment -> t

  val freshened_params : t -> Freshening.t -> t

  type fresh_name_semantics =
    | Fresh
      (** [meet] and [join] will generate fresh names and add equalities to
          make them equal to the names in the [t]s as appropriate.  These
          fresh names will be assigned to the [kinded_params] in the output
          of [meet] and [join]. *)
    | Left
      (** [meet] and [join] will use the names in the left-hand [t] instead
          of generating fresh names.  This means that the results of these
          functions will produce values of type [t] whose [kinded_params]
          correspond to those names. *)
    | Right
      (** As for [left], but uses names from the right-hand [t]. *)

  (** Greatest lower bound of two parameter bindings. *)
  val meet
     : ?fresh_name_semantics:fresh_name_semantics
    -> join_env
    -> t
    -> t
    -> t

  (** Least upper bound of two parameter bindings. *)
  val join
     : ?fresh_name_semantics:fresh_name_semantics
    -> join_env
    -> t
    -> t
    -> t
end
