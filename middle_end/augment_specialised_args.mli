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

type new_specialised_arg = {
  definition : Flambda.expr;
  (** [definition], if referencing specialised args of the function,
      must use the "outer variables" in the range of the specialised
      argument map in the set of closures rather than the current parameters
      of the function (which are the "inner variables", the domain of that
      map).
      There is no support yet for these [definition]s being dependent on
      each other in any way. *)
}

(** This maps from new names (chosen by the client of this module) used
    inside the rewritten function body and which will form the augmented
    specialised argument list on the main function. *)
type add_all_or_none_of_these_specialised_args =
  new_specialised_arg Variable.Map.t

type what_to_specialise = {
  new_function_body : Flambda.expr;
  new_specialised_args : add_all_or_none_of_these_specialised_args list;
}

module type S = sig
  val variable_suffix : string

  val precondition : set_of_closures:Flambda.set_of_closures -> bool

  val what_to_specialise
     : closure_id:Closure_id.t
    -> function_decl:Flambda.function_declaration
    -> set_of_closures:Flambda.set_of_closures
    -> what_to_specialise option
end

module type Result = sig
  val rewrite_set_of_closures
     : backend:(module Backend_intf.S)
    -> set_of_closures:Flambda.set_of_closures
    -> Flambda.expr option
end

module Make (T : S) : Result

module Make_pass (T : sig
  include S
  val pass_name : string
end) : Result
