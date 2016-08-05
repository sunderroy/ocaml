(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           *)
(*                                                                        *)
(*   Copyright 1996 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(* Representation of machine code by sequences of pseudoinstructions *)

type integer_comparison =
    Isigned of Cmm.comparison
  | Iunsigned of Cmm.comparison

type integer_operation =
    Iadd | Isub | Imul | Imulh | Idiv | Imod
  | Iand | Ior | Ixor | Ilsl | Ilsr | Iasr
  | Icomp of integer_comparison
  | Icheckbound

type test =
    Itruetest
  | Ifalsetest
  | Iinttest of integer_comparison
  | Iinttest_imm of integer_comparison * int
  | Ifloattest of Cmm.comparison * bool
  | Ioddtest
  | Ieventest

type phantom_defining_expr =
  | Iphantom_const_int of int
  | Iphantom_const_symbol of Symbol.t
  | Iphantom_var of Ident.t  (** Must not be a phantom identifier. *)
  | Iphantom_read_var_field of phantom_defining_expr * int
  (* CR-soon mshinwell: delete "var" from "read_var_field" *)
  | Iphantom_read_symbol_field of Symbol.t * int
  | Iphantom_offset_var of phantom_defining_expr * int

type operation =
    Imove
  | Ispill
  | Ireload
  | Iconst_int of nativeint
  | Iconst_float of int64
  | Iconst_symbol of string
  | Iconst_blockheader of nativeint
  | Icall_ind
  | Icall_imm of string
  | Itailcall_ind
  | Itailcall_imm of string
  | Iextcall of string * bool    (* false = noalloc, true = alloc *)
  | Istackoffset of int
  | Iload of Cmm.memory_chunk * Arch.addressing_mode
  | Istore of Cmm.memory_chunk * Arch.addressing_mode * bool
                                 (* false = initialization, true = assignment *)
  | Ialloc of int
  | Iintop of integer_operation
  | Iintop_imm of integer_operation * int
  | Inegf | Iabsf | Iaddf | Isubf | Imulf | Idivf
  | Ifloatofint | Iintoffloat
  | Ispecific of Arch.specific_operation
  | Iname_for_debugger of { ident : Ident.t; which_parameter : int option; }
    (** [Iname_for_debugger] has the following semantics:
        (a) The argument register(s) is/are deemed to contain the value of the
            given identifier.
        (b) Any information about other [Reg.t]s that have been previously
            deemed to hold the value of that identifier is forgotten. *)

type instruction =
  { desc: instruction_desc;
    next: instruction;
    arg: Reg.t array;
    res: Reg.t array;
    dbg: Debuginfo.t;
    phantom_available_before: Ident.Set.t;
    mutable live: Reg.Set.t;
    mutable available_before: availability;
  }

and instruction_desc =
    Iend
  | Iop of operation
  | Ireturn
  | Iifthenelse of test * instruction * instruction
  | Iswitch of int array * instruction array
  | Iloop of instruction
  | Icatch of int * instruction * instruction
  | Iexit of int
  | Itrywith of instruction * instruction
  | Iraise of Lambda.raise_kind

type fundecl =
  { fun_name: string;
    fun_args: Reg.t array;
    fun_body: instruction;
    fun_fast: bool;
    fun_dbg : Debuginfo.t;
    fun_human_name : string;
    fun_module_path : Path.t option;
    fun_phantom_lets :
      (Clambda.ulet_provenance option * phantom_defining_expr)
        Ident.Map.t;
  }

val dummy_instr: instruction
val end_instr: unit -> instruction
(* CR mshinwell: make [phantom_available_before] optional *)
val instr_cons:
      instruction_desc -> Reg.t array -> Reg.t array ->
        phantom_available_before:Ident.Set.t -> instruction -> instruction
val instr_cons_debug:
      instruction_desc -> Reg.t array -> Reg.t array -> Debuginfo.t ->
        phantom_available_before:Ident.Set.t -> instruction -> instruction
val instr_iter: (instruction -> unit) -> instruction -> unit
