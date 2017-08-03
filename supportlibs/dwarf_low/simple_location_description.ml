(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                  Mark Shinwell, Jane Street Europe                     *)
(*                                                                        *)
(*   Copyright 2014--2017 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

module Operator = Dwarf_operator

(* Iff the boolean is [false] we must add [DW_op_stack_value] to the end
   of the calculation. *)
type t = bool * description


let compile (do_not_add_stack_value_op, desc) =
  let sequence =
    let compiled = compile_to_yield_value desc in
    if do_not_add_stack_value_op then
      compiled
    else
      compiled @ [Operator.stack_value ()]
  in
(*
  Format.eprintf "SLE.compile non-optimized: %a\n"
    (Format.pp_print_list Operator.print) sequence;
*)
  let optimized = Operator.optimize_sequence sequence in
(*
  Format.eprintf "  --> optimized: %a\n%!"
    (Format.pp_print_list Operator.print) optimized;
*)
  optimized

let size t =
  List.fold_left (fun size op -> Int64.add size (Operator.size op)) 0L
    (compile t)

let emit t asm =
  List.iter (fun op -> Operator.emit op asm) (compile t)
