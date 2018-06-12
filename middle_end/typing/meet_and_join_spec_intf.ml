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

(** The signature of a module that specifies meet and join operations for
    a particular kind of types. *)
module type S = sig
  type env_extension
  type join_env

  type flambda_type
  type of_kind_foo

  type 'a ty

  val kind : Flambda_kind.t

  val to_type : of_kind_foo ty -> flambda_type

  val force_to_kind : flambda_type -> of_kind_foo ty

  val print_ty : Format.formatter -> of_kind_foo ty -> unit

  val meet_or_join_of_kind_foo
     : join_env
    -> of_kind_foo
    -> of_kind_foo
    -> (of_kind_foo * env_extension) Or_absorbing.t
end