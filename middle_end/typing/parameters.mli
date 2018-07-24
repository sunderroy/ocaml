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

(* CR mshinwell: This needs a more appropriate name than "Parameters". *)

(** The representation of an abstraction that existentially binds a number of
    logical variables whilst at the same time holding equations upon such
    variables.

    The external view of this structure is determined by the caller.  This is
    done by providing a type of "external variables", which will be in
    bijection with the logical variables, and an algebraic structure upon
    them that provides a container (typically lists or sets).  External
    variables are treated as bound names; they must be maintained fresh by
    the caller.
*)

[@@@ocaml.warning "+a-4-9-30-40-41-42"]

include Parameters_intf.S
