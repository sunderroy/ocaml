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

[@@@ocaml.warning "+a-4-30-40-41-42"]

type t

type occurrence_kind =
  | In_terms
  | In_types
  | Debug_only

val create : unit -> t

val create_from_set_in_types : Name.Set.t -> t

val add : t -> Name.t -> occurrence_kind -> t

val in_terms : t -> Name.Set.t

val in_types : t -> Name.Set.t

val in_debug_only : t -> Name.Set.t
