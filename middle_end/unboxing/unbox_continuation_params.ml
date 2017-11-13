(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2017 OCamlPro SAS                                          *)
(*   Copyright 2017 Jane Street Group LLC                                 *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-4-9-30-40-41-42"]

module H = Unbox_one_variable.How_to_unbox
(*module CAV = Invariant_params.Continuations.Continuation_and_variable*)

let find_unboxings ~continuation_uses ~handlers =
  Continuation.Map.filter_map handlers
    ~f:(fun cont (handler : Flambda.Continuation_handler.t) ->
      if handler.stub then
        None
      else
        match handler.params with
        | [] -> None
        | params ->
          match Continuation.Map.find cont continuation_uses with
          | exception Not_found ->
(*
Format.eprintf "No definition for %a\n%!" Continuation.print cont;
*)
            None
          | args_tys ->
            let params = Parameter.List.vars params in
            let params_to_approxs =
              Variable.Map.of_list (List.combine params args_tys)
            in
            let unboxings =
              Variable.Map.filter_map params_to_approxs
                ~f:(fun param approx ->
                  (* Don't unbox variables that already have projections. *)
                  let already_has_projection =
                    match Variable.Map.find param handler.specialised_args with
                    | exception Not_found -> false
                    | spec_to ->
                      match spec_to.projection with
                      | None -> false
                      | Some _ -> true
                  in
                  if already_has_projection then None
                  else
                    Unbox_one_variable.how_to_unbox ~being_unboxed:param
                      ~being_unboxed_approx:approx ~unbox_returns:false)
            in
            if Variable.Map.is_empty unboxings then None
            else Some unboxings)

(* CR mshinwell: If we get everything using [Unbox_one_variable] then
   this function should be able to move to [Invariant_params] *)
let propagate_invariant_params_flow ~handlers:_ ~backend:_ ~unboxings_by_cont =
  unboxings_by_cont
  (* CR mshinwell: This needs fixing and re-enabling.  It needs altering to
     have the correct names for other continuations the information is being
     propagated to.  It's possibly easiest just to call [Unbox_one_variable]
     again with the original approximation but the other continuation's
     parameters to get the [how_to_unbox] record with the right names. *)
(*
  let invariant_params_flow =
    Invariant_params.Continuations.invariant_param_sources handlers ~backend
  in
Format.eprintf "Invariant params:\n@;%a\n"
(Variable.Map.print
  Invariant_params.Continuations.Continuation_and_variable.Set.print)
  invariant_params_flow;
  let unboxings_by_cont' =
    Continuation.Map.fold (fun cont unboxings_by_param unboxings_by_cont' ->
        Variable.Map.fold (fun param unboxing unboxings_by_cont' ->
            match Variable.Map.find param invariant_params_flow with
            | exception Not_found -> unboxings_by_cont'
            | flow ->
              CAV.Set.fold (fun (target_cont, target_param)
                      unboxings_by_cont' ->
                  if Continuation.equal cont target_cont then
                    unboxings_by_cont'
                  else
                    let target_unboxings =
                      match
                        Continuation.Map.find target_cont unboxings_by_cont'
                      with
                      | exception Not_found -> Variable.Map.empty
                      | target_unboxings -> target_unboxings
                    in
                    Continuation.Map.add target_cont
                      (Variable.Map.add target_param unboxing
                        target_unboxings)
                      unboxings_by_cont')
                flow
                unboxings_by_cont')
          unboxings_by_param
          unboxings_by_cont')
      unboxings_by_cont
      Continuation.Map.empty
  in
  Continuation.Map.union (fun _cont unboxings1 unboxings2 ->
      Some (Variable.Map.disjoint_union unboxings1 unboxings2))
    unboxings_by_cont unboxings_by_cont'
*)

let for_continuations ~continuation_uses ~handlers ~backend
      : Flambda_utils.with_wrapper Continuation.Map.t option =
(*
Format.eprintf "Unbox_continuation_params starting with continuations %a\n%!"
  Continuation.Set.print (Continuation.Map.keys handlers);
*)
  let unboxings_by_cont = find_unboxings ~continuation_uses ~handlers in
  if Continuation.Map.is_empty unboxings_by_cont then begin
    None
  end else begin
    let unboxings_by_cont =
      propagate_invariant_params_flow ~handlers ~backend ~unboxings_by_cont
    in
    let with_wrappers =
      Continuation.Map.fold (fun cont handler new_handlers ->
          let do_not_unbox () =
            let with_wrapper : Flambda_utils.with_wrapper =
              Unchanged { handler; }
            in
            Continuation.Map.add cont with_wrapper new_handlers
          in
          match Continuation.Map.find cont unboxings_by_cont with
          | exception Not_found -> do_not_unbox ()
          | unboxings ->
            let handler : Flambda.Continuation_handler.t =
              match Continuation.Map.find cont handlers with
              | exception Not_found -> assert false
              | handler -> handler
            in
            let new_cont = Continuation.create () in
            let how_to_unbox = H.merge_variable_map unboxings in
            let _wrapper_params_map, wrapper_params, wrapper_specialised_args =
              let freshening_already_assigned =
                Variable.Map.fold (fun var1 var2 being_unboxed ->
                    let param1 = Parameter.wrap var1 in
                    let param2 = Parameter.wrap var2 in
                    Parameter.Map.add param1 param2 being_unboxed)
                  how_to_unbox.being_unboxed_to_wrapper_params_being_unboxed
                  Parameter.Map.empty
              in
              Flambda_utils.create_wrapper_params ~params:handler.params
                ~specialised_args:handler.specialised_args
                ~freshening_already_assigned
            in
            (* Make sure we don't keep unboxing the same variable over and over
               by checking that we have increased the known-projections
               information. *)
            (* CR mshinwell: make sure this is really needed.  (Does this
               depend on the order of simplification of the handlers or
               something horrid?  The only reference when the result of this
               unboxing transformation gets simplified the first time, to the
               new continuation (the renamed original one), will be in the
               stub. *)
            let new_specialised_args =
              Variable.Map.filter (fun _arg
                      (spec_to : Flambda.specialised_to) ->
                  match spec_to.projection with
                  | None -> true
                  | Some projection ->
                    Variable.Map.for_all (fun _arg
                            (existing_spec_to : Flambda.specialised_to) ->
                        match existing_spec_to.projection with
                        | None -> true
                        | Some existing_projection ->
                          not (Projection.equal projection
                            existing_projection))
                      handler.specialised_args)
              (H.new_specialised_args how_to_unbox)
            in
            if Variable.Map.is_empty new_specialised_args then
              do_not_unbox ()
            else
(*
              let () =
                Format.eprintf "Existing spec args %a New spec args %a Handler:\n@ %a -> %a\n%!"
                  Flambda.print_specialised_args handler.specialised_args
                  Flambda.print_specialised_args new_specialised_args
                  Variable.print_list handler.params
                  Flambda.Expr.print handler.handler
              in
*)
              let specialised_args =
                Variable.Map.disjoint_union handler.specialised_args
                  new_specialised_args
              in
              let wrapper_body =
                let initial_body : Flambda.Expr.t =
                  Apply_cont (new_cont, None,
                    Parameter.List.vars wrapper_params
                      @ how_to_unbox.new_arguments_for_call_in_wrapper)
                in
                how_to_unbox.add_bindings_in_wrapper initial_body
              in
              assert (not handler.is_exn_handler);
              let with_wrapper : Flambda_utils.with_wrapper =
                let params =
                  handler.params
                    @ (List.map (fun (param, _proj) -> Parameter.wrap param)
                      how_to_unbox.new_params)
                in
(*
  Format.eprintf "Unbox_continuation_params has unboxed:\n@;%a\n%!"
    Flambda.print_let_cont_handlers (Flambda.Recursive
      (Continuation.Map.add cont handler Continuation.Map.empty));
  Format.eprintf "Unboxed version has \
      wrapper (params %a, spec args %a)\n@ %a = %a\n@ and \
      new handler (params %a, spec args %a):\n@ %a = %a\n%!"
    Parameter.print_list wrapper_params
    Flambda.print_specialised_args wrapper_specialised_args
    Continuation.print cont
    Flambda.Expr.print wrapper_body
    Parameter.print_list params
    Flambda.print_specialised_args specialised_args
    Continuation.print new_cont
    Flambda.Expr.print handler.handler;
*)
                With_wrapper {
                  new_cont;
                  new_handler = {
                    params;
                    stub = handler.stub;
                    is_exn_handler = false;
                    handler = handler.handler;
                    specialised_args;
                  };
                  wrapper_handler = {
                    params = wrapper_params;
                    stub = true;
                    is_exn_handler = false;
                    handler = wrapper_body;
                    specialised_args = wrapper_specialised_args;
                  };
                }
            in
            Continuation.Map.add cont with_wrapper new_handlers)
        handlers
        Continuation.Map.empty
    in
    Some with_wrappers
  end

let for_non_recursive_continuation ~name ~handler ~args_tys ~backend
      : Flambda_utils.with_wrapper =
(*
Format.eprintf "Unbox_continuation_params starting: nonrecursive %a\n%!"
  Continuation.print name;
*)
  let handlers =
    Continuation.Map.add name handler Continuation.Map.empty
  in
  let continuation_uses =
    Continuation.Map.add name args_tys Continuation.Map.empty
  in
  let result = for_continuations ~continuation_uses ~handlers ~backend in
  match result with
  | None -> Unchanged { handler; }
  | Some wrappers ->
    match Continuation.Map.bindings wrappers with
    | [name', with_wrapper] ->
      assert (Continuation.equal name name');
      with_wrapper
    | _ -> assert false

let for_recursive_continuations ~handlers ~args_tys ~backend =
(*
Format.eprintf "Unbox_continuation_params starting: recursive %a\n%!"
  Continuation.Set.print (Continuation.Map.keys handlers);
*)
  let result =
    for_continuations ~continuation_uses:args_tys ~handlers ~backend
  in
  match result with
  | None ->
    Continuation.Map.map (fun handler : Flambda_utils.with_wrapper ->
          Unchanged { handler; })
      handlers
  | Some with_wrappers -> with_wrappers