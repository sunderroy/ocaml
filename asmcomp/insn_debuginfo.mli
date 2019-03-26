(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                  Mark Shinwell, Jane Street Europe                     *)
(*                                                                        *)
(*   Copyright 2019 Jane Street Group LLC                                 *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(** Information attached to Mach and Linearize instructions that is used
    for the emission of debugging information. *)

[@@@ocaml.warning "+a-4-30-40-41-42"]

type t

(** Create a debugging information structure that corresponds to some
    particular instruction.  Values of type [t] are immutable.

    The parameters are as for the documentation on [dbg] and
    [phantom_available_before], below. *)
val create
   : Debuginfo.t
  -> phantom_available_before:Backend_var.Set.t
  -> t

(** The empty debugging information structure. *)
val none : t

(** Information about the source location and the block where the instruction
    is located. *)
val dbg : t -> Debuginfo.t

(** Information about the source location and the block where the instruction
    is located in [Linearize] code. *)
val linear_dbg : t -> Debuginfo.t

(** The source location component of [linear_dbg]. *)
val linear_position : t -> Debuginfo.Code_range.t option

(** Which variables bound by phantom lets are available immediately prior to
    commencement of execution of the instruction. *)
val phantom_available_before : t -> Backend_var.Set.t

(** Which registers are available (in the sense of [Available_regs])
    immediately prior to commencement of execution of the instruction. *)
val available_before : t -> Reg_availability_set.t

(** Which registers are available (in the sense of [Available_regs])
    during execution of the instruction.

    Note that [available_across] may not be a subset of [available_before],
    because [Reg_availability_set.canonicalise] does not preserve this
    property.  (Example: if %rax and %rbx both hold the value of some variable
    [x] before the instruction but %rax is not available across the instruction,
    then the canonicalised sets for [available_before] and [available_after]
    may not name the same register for [x].) *)
val available_across : t -> Reg_availability_set.t option

(** Set which registers are available (in the sense of [Available_regs])
    immediately prior to commencement of execution of the instruction. *)
val with_available_before : t -> Reg_availability_set.t -> t

(** Set which registers are available (in the sense of [Available_regs])
    during execution of the instruction. *)
val with_available_across : t -> Reg_availability_set.t option -> t

(** Change the source location component of [linear_dbg]. *)
val with_linear_position : t -> Debuginfo.Code_range.t -> t

(** Change the [available_before] field according to the given function. *)
val map_available_before
   : t
  -> f:(Reg_availability_set.t -> Reg_availability_set.t)
  -> t
