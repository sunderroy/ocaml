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

(** Typing environments.  These are usually used through
    [Flambda_type.Typing_env]. *)

[@@@ocaml.warning "+a-4-9-30-40-41-42"]

module Make
    (T : Flambda_type0_internal_intf.S)
    (Typing_env_extension : Typing_env_extension_intf.S with module T := T)
    (Meet_and_join : Meet_and_join_intf.S_both with module T := T)
    (Type_equality : Type_equality_intf.S with module T := T)
  : Typing_env_intf.S with module T := T