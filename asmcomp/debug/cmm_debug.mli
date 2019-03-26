(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                  Mark Shinwell, Jane Street Europe                     *)
(*                                                                        *)
(*   Copyright 2018--2019 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(** Functionality for augmenting Cmm code that does not correspond to
    OCaml source code, such as that generated for the startup file, with
    debugging information. *)

[@@@ocaml.warning "+a-4-30-40-41-42"]

include Ir_debug.S with type ir := Cmm.phrase
