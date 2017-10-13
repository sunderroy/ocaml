(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2013--2017 OCamlPro SAS                                    *)
(*   Copyright 2014--2017 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-4-9-30-40-41-42"]

(* CR mshinwell: This function is broken, it shouldn't count occurrences
   under lambdas (to match up with [Invariant_params], etc.) *)
let in_function_declarations (_function_decls : Flambda.Function_declarations.t)
      ~backend:_ = Variable.Set.empty

(* XXX needs fixing for the closure change
  let module VCC = Strongly_connected_components.Make (Variable) in
  let directed_graph =
    Flambda.Function_declarations.fun_vars_referenced_in_decls function_decls
      ~backend
  in
  let connected_components =
    VCC.connected_components_sorted_from_roots_to_leaf directed_graph
  in
  Array.fold_left (fun rec_fun -> function
      | VCC.No_loop _ -> rec_fun
      | VCC.Has_loop elts -> List.fold_right Variable.Set.add elts rec_fun)
    Variable.Set.empty connected_components
*)
