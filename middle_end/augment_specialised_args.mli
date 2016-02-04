(**************************************************************************)
(*                                                                        *)
(*                                OCaml                                   *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2013--2016 OCamlPro SAS                                    *)
(*   Copyright 2014--2016 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file ../LICENSE.       *)
(*                                                                        *)
(**************************************************************************)

(** Helper module for adding specialised arguments to sets of closures. *)

module Definition : sig
  type t =
    | Existing_outer_var of Variable.t
    | Projection_from_existing_specialised_arg of Projectee.Var_and_projectee.t
end

module What_to_specialise : sig
  type t

  val create : set_of_closures:Flambda.set_of_closures -> t

  val new_specialised_arg
     : t
    -> fun_var:Variable.t
    -> group:Variable.t
    -> definition:Definition.t
    -> t
end

module type S = sig
  val pass_name : string
  val variable_suffix : string

  val precondition
     : env:Inline_and_simplify_aux.Env.t
    -> set_of_closures:Flambda.set_of_closures
    -> bool

  val what_to_specialise
     : env:Inline_and_simplify_aux.Env.t
    -> set_of_closures:Flambda.set_of_closures
    -> What_to_specialise.t
end

module Make (T : S) : sig
  val rewrite_set_of_closures
     : env:Inline_and_simplify_aux.Env.t
    -> set_of_closures:Flambda.set_of_closures
    -> Flambda.expr option
end
