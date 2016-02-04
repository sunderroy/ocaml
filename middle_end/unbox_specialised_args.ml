(**************************************************************************)
(*                                                                        *)
(*                                OCaml                                   *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2013--2016 OCamlPro SAS                                    *)
(*   Copyright 2014--2016 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file ../LICENSE.       *)
(*                                                                        *)
(**************************************************************************)

module ASA = Augment_specialised_args
module W = ASA.What_to_specialise

module Transform = struct
  let pass_name = "unbox-specialised-args"
  let variable_suffix = "_unbox_spec_args"

  let precondition ~env ~(set_of_closures : Flambda.set_of_closures) =
    (* !Clflags.unbox_specialised_args *) true
      && not (Variable.Map.is_empty set_of_closures.specialised_args)

  let what_to_specialise ~env ~(set_of_closures : Flambda.set_of_closures) =
    let projections_by_function =
      Variable.Map.filter_map set_of_closures.function_decls.funs
        ~f:(fun _fun_var (function_decl : Flambda.function_declaration) ->
            if function_decl.stub then None
            else
              Extract_projections.from_function_decl ~env ~function_decl
                ~which_variables:set_of_closures.specialised_args)
    in
    (* CR-soon mshinwell: consider caching the Invariant_params *relation*
       as well as the "_in_recursion" map *)
    (* CR-soon mshinwell: consider whether we should not unbox specialised
       arguments when there remains a reference to the boxed version (same
       for [Unbox_free_vars_of_closures]. *)
    let invariant_params_flow =
      Invariant_params.invariant_param_sources set_of_closures.function_decls
        ~backend:(Inline_and_simplify_aux.Env.backend env)
    in
    Variable.Map.fold (fun fun_var extractions what_to_specialise ->
        List.fold_left (fun what_to_specialise (projection : Projection.t) ->
            let group = Projection.being_projected_from projection in
            assert (Variable.Map.mem group.being_projected_from
                set_of_closures.specialised_args);
            let what_to_specialise =
              W.new_specialised_arg what_to_specialise ~fun_var ~group
                ~definition:(Projection_from_existing_specialised_arg
                    projection)
            in
            match Variable.Map.find group invariant_params_flow with
            | exception Not_found ->
            | flow ->
              (* If for function [f] we would extract a projection expression
                 [e] from some specialised argument [x] of [f], and we know
                 from [Invariant_params] that a specialised argument [y] of
                 another function [g] flows to [x], we will add add [e] with
                 [y] substituted for [x] throughout as a newly-specialised
                 argument for [g].  This should help reduce the number of
                 simplification rounds required for mutually-recursive
                 functions. *)
              Variable.Pair.Set.fold (fun (target_fun_var, target_spec_arg)
                        what_to_specialise ->
                  if Variable.equal fun_var target_fun_var
                    || not (Variable.Map.mem target_spec_arg
                        set_of_closures.specialised_args)
                  then begin
                    what_to_specialise
                  end else begin
                    (* Rewrite the projection (that was in terms of a
                       specialised arg of [fun_var]) to be in terms of the
                       corresponding specialised arg of [target_fun_var].
                       (The outer vars referenced in the projection remain
                       unchanged.) *)
                    let projection =
                      Projection.map_projecting_from projection ~f:(fun var ->
                          assert (Variable.equal var group);
                          target_spec_arg)
                    in
                    W.new_specialised_arg what_to_specialise
                      ~fun_var:target_fun_var ~group
                      ~definition:
                        (Projection_from_existing_specialised_arg projection)
                  end)
                flow
                first_fun_var_and_group)
          what_to_specialise
          extractions)
      ~projections_by_function
      (W.create ~set_of_closures)
end

include ASA.Make (Transform)
