(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2016--2017 OCamlPro SAS                                    *)
(*   Copyright 2016--2017 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(** Approximations of continuations.  Used during simplification. *)

(* To be fixed later... *)

type t

type continuation_handlers =
  | Non_recursive of Flambda.Non_recursive_let_cont_handler.t
  | Recursive of Flambda.Recursive_let_cont_handlers.t

val create
   : name:Continuation.t
  -> continuation_handlers
  -> t

(* CR mshinwell: Bad name.  Only the code of the continuation itself is
   unknown. *)
val create_unknown
   : name:Continuation.t
(* Maybe the arity should be:  Flambda_arity.t Continuation.Map.t?
  -> Flambda_arity.t
*)
  -> t

val name : t -> Continuation.t

(*val params : t -> Kinded_parameter.t list
val arity : t -> Flambda_arity.t
*)
val handlers : t -> continuation_handlers option

val is_alias : t -> Continuation.t option

val print : Format.formatter -> t -> unit
