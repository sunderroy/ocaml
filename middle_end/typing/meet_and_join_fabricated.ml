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

[@@@ocaml.warning "+a-4-9-30-40-41-42"]

module K = Flambda_kind

module Make (T : sig
  include Flambda_type0_internal_intf.S

  val print_ty_fabricated
     : Format.formatter
    -> ty_fabricated
    -> unit

  val is_obviously_bottom : flambda_type -> bool

  val ty_is_obviously_bottom : 'a ty -> bool

  val force_to_kind_fabricated : t -> of_kind_fabricated ty

  val bottom_as_ty_fabricated : unit -> of_kind_fabricated ty

  val bottom_as_ty_value : unit -> of_kind_value ty

  val any_fabricated_as_ty_fabricated : unit -> of_kind_fabricated ty

  val any_value_as_ty_value : unit -> of_kind_value ty
end) (Make_meet_and_join : functor
    (S : sig
      include Meet_and_join_spec_intf.S
        with type flambda_type := T.flambda_type
        with type typing_environment := T.typing_environment
        with type equations := T.equations
        with type 'a ty := 'a T.ty
     end)
  -> sig
       include Meet_and_join_intf.S
         with type of_kind_foo := T.of_kind_fabricated
         with type typing_environment := T.typing_environment
         with type equations := T.equations
         with type 'a ty := 'a T.ty
    end) (Meet_and_join_value : sig
      include Meet_and_join_intf.S
        with type of_kind_foo := T.of_kind_value
        with type typing_environment := T.typing_environment
        with type equations := T.equations
        with type 'a ty := 'a T.ty
    end) (Meet_and_join : sig
      include Meet_and_join_intf.S_for_types
        with type t_in_context := T.t_in_context
        with type equations := T.equations
        with type flambda_type := T.flambda_type
    end) (Typing_environment0 : sig
      include Typing_environment0_intf.S
        with type typing_environment := T.typing_environment
        with type equations := T.equations
        with type flambda_type := T.flambda_type
        with type t_in_context := T.t_in_context
        with type 'a ty := 'a T.ty
        with type 'a unknown_or_join := 'a T.unknown_or_join
    end) (Equations : sig
      include Equations_intf.S
        with type equations := T.equations
        with type typing_environment := T.typing_environment
        with type flambda_type := T.flambda_type
    end) =
struct
  module rec Meet_and_join_fabricated : sig
    include Meet_and_join_intf.S
      with type of_kind_foo := T.of_kind_fabricated
      with type typing_environment := T.typing_environment
      with type equations := T.equations
      with type 'a ty := 'a T.ty
  end = Make_meet_and_join (struct
    open T

    type equations = T.equations

    type of_kind_foo = of_kind_fabricated

    let kind = K.fabricated ()

    let to_type ty : t =
      { descr = Fabricated ty;
        phantom = None;
      }

    let force_to_kind = force_to_kind_fabricated
    let print_ty = print_ty_fabricated

    (* CR mshinwell: We need to work out how to stop direct call
       surrogates from being dropped e.g. when in a second round, a
       function type (with a surrogate) propagated from the first round is
       put into a meet with a type for the same function, but a new
       surrogate. *)
    let meet_closure env1 env2
          (closure1 : closure) (closure2 : closure)
          : (closure * equations) Or_bottom.t =
      if env1 == env2 && closure1 == closure2 then begin
        Ok (closure1, Equations.create ())
      end else begin
        let resolver = env1.resolver in
        let cannot_prove_different ~params1 ~params2
              ~param_names1 ~param_names2 ~result1 ~result2
              ~result_equations1 ~result_equations2 : _ Or_bottom.t =
          let same_arity = List.compare_lengths params1 params2 = 0 in
          let same_num_results = List.compare_lengths result1 result2 = 0 in
          let equations_from_meet = ref (Equations.create ()) in
          let has_bottom params = List.exists is_obviously_bottom params in
          let params_changed = ref Neither in
          let params : _ Or_bottom.t =
            if not same_arity then Bottom
            else
              let params =
                List.map2 (fun t1 t2 ->
                    let t, new_equations_from_meet =
                      Meet_and_join.meet ~bias_towards:(env1, t1) (env2, t2)
                    in
                    if not (t == t1) then begin
                      params_changed := join_changes !params_changed Left
                    end;
                    if not (t == t2) then begin
                      params_changed := join_changes !params_changed Right
                    end;
                    equations_from_meet :=
                      Meet_and_join.meet_equations ~resolver
                        new_equations_from_meet !equations_from_meet;
                    t)
                  params1
                  params2
              in
              if has_bottom params then Bottom
              else Ok params
          in
          let env_for_result env ~params ~param_names =
            match param_names with
            | None -> env
            | Some param_names ->
              List.fold_left2 (fun env param param_ty ->
                  let param_name = Parameter.name param in
                  (* CR mshinwell: This level shouldn't be hard-coded *)
                  let level = Scope_level.initial in
                  Typing_environment0.add_or_replace_meet env
                    param_name level param_ty)
                env
                param_names params
          in
          let result_changed = ref Neither in
          let result : _ Or_bottom.t =
            if not same_num_results then Bottom
            else
              let result =
                List.map2 (fun t1 t2 ->
                    let result_equations1 =
                      Equations.to_typing_environment ~resolver:env1.resolver
                       result_equations1
                    in
                    let result_equations2 =
                      Equations.to_typing_environment ~resolver:env1.resolver
                       result_equations2
                    in
                    let result_env1 =
                      Typing_environment0.meet
                        (env_for_result env1 ~params:params1
                          ~param_names:param_names1)
                        result_equations1
                    in
                    let result_env2 =
                      Typing_environment0.meet
                        (env_for_result env2 ~params:params2
                          ~param_names:param_names2)
                        result_equations2
                    in
                    let t, new_equations_from_meet =
                      Meet_and_join.meet ~bias_towards:(result_env1, t1)
                        (result_env2, t2)
                    in
                    if not (t == t1) then begin
                      result_changed := join_changes !result_changed Left
                    end;
                    if not (t == t2) then begin
                      result_changed := join_changes !result_changed Right
                    end;
                    equations_from_meet :=
                      Meet_and_join.meet_equations ~resolver
                        new_equations_from_meet !equations_from_meet;
                    t)
                  result1
                  result2
              in
              if has_bottom result then Bottom
              else Ok result
          in
          let result_equations =
            Meet_and_join.meet_equations ~resolver:env1.resolver
              result_equations1 result_equations2
          in
          let result_equations_changed : changes =
            let changed1 =
              not (Equations.phys_equal result_equations1 result_equations)
            in
            let changed2 =
              not (Equations.phys_equal result_equations2 result_equations)
            in
            match changed1, changed2 with
            | false, false -> Neither
            | true, false -> Left
            | false, true -> Right
            | true, true -> Both
          in
          match params, result with
          | Ok params, Ok result ->
            let changed =
              join_changes !params_changed
                (join_changes !result_changed result_equations_changed)
            in
            Ok (params, changed, result, result_equations, !equations_from_meet)
          | _, _ -> Bottom
        in
        let function_decls : _ Or_bottom.t =
          match closure1.function_decls, closure2.function_decls with
          | Inlinable inlinable1, Inlinable inlinable2 ->
            let params1 = List.map snd inlinable1.params in
            let params2 = List.map snd inlinable2.params in
            let param_names1 = List.map fst inlinable1.params in
            let param_names2 = List.map fst inlinable2.params in
            let result =
              cannot_prove_different ~params1 ~params2
                ~param_names1:(Some param_names1)
                ~param_names2:(Some param_names2)
                ~result1:inlinable1.result
                ~result2:inlinable2.result
                ~result_equations1:inlinable1.result_equations
                ~result_equations2:inlinable2.result_equations
            in
            begin match result with
            | Ok (params, changed, result, result_equations,
                  equations_from_meet) ->
              (* [closure1.function_decls] and [closure2.function_decls] may be
                 different, but we cannot prove it.  We arbitrarily pick
                 [closure1.function_decls] to return, with parameter and result
                 types refined. *)
              let params =
                List.map2 (fun (param, _old_ty) new_ty ->
                    param, new_ty)
                  inlinable1.params
                  params
              in
              begin match changed with
              | Neither -> Ok (closure1.function_decls, equations_from_meet)
              | Left -> Ok (closure2.function_decls, equations_from_meet)
              | Right -> Ok (closure1.function_decls, equations_from_meet)
              | Both ->
                Ok (Inlinable { inlinable1 with
                  params;
                  result;
                  result_equations;
                }, equations_from_meet)
              end
            | Bottom ->
              (* [closure1] and [closure2] are definitely different. *)
              Bottom
            end
          | Non_inlinable None, Non_inlinable None ->
            Ok (Non_inlinable None, Equations.create ())
          | Non_inlinable (Some non_inlinable), Non_inlinable None
          | Non_inlinable None, Non_inlinable (Some non_inlinable) ->
            (* We can arbitrarily pick one side or the other: we choose the
               side which gives a more precise type. *)
            Ok (Non_inlinable (Some non_inlinable), Equations.create ())
          | Non_inlinable None, Inlinable inlinable
          | Inlinable inlinable, Non_inlinable None ->
            (* Likewise. *)
            Ok (Inlinable inlinable, Equations.create ())
          | Non_inlinable (Some non_inlinable1),
              Non_inlinable (Some non_inlinable2) ->
            let result =
              cannot_prove_different
                ~params1:non_inlinable1.params
                ~params2:non_inlinable2.params
                ~param_names1:None
                ~param_names2:None
                ~result1:non_inlinable1.result
                ~result2:non_inlinable2.result
                ~result_equations1:non_inlinable1.result_equations
                ~result_equations2:non_inlinable2.result_equations
            in
            begin match result with
            | Ok (params, _params_changed, result, result_equations,
                  equations_from_meet) ->
              let non_inlinable_function_decl =
                { non_inlinable1 with
                  params;
                  result;
                  result_equations;
                }
              in
              Ok (Non_inlinable (Some non_inlinable_function_decl),
                equations_from_meet)
            | Bottom ->
              Bottom
            end
          | Non_inlinable (Some non_inlinable), Inlinable inlinable
          | Inlinable inlinable, Non_inlinable (Some non_inlinable) ->
            let params1 = List.map snd inlinable.params in
            let param_names1 = List.map fst inlinable.params in
            let result =
              cannot_prove_different
                ~params1
                ~params2:non_inlinable.params
                ~param_names1:(Some param_names1)
                ~param_names2:None
                ~result1:inlinable.result
                ~result2:non_inlinable.result
                ~result_equations1:inlinable.result_equations
                ~result_equations2:non_inlinable.result_equations
            in
            begin match result with
            | Ok (params, _params_changed, result, result_equations,
                  equations_from_meet) ->
              (* For the arbitrary choice, we pick the inlinable declaration,
                 since it gives more information. *)
              let params =
                List.map2 (fun (param, _old_ty) new_ty -> param, new_ty)
                  inlinable.params
                  params
              in
              let inlinable_function_decl =
                { inlinable with
                  params;
                  result;
                  result_equations;
                }
              in
              Ok (Inlinable inlinable_function_decl, equations_from_meet)
            | Bottom ->
              Bottom
            end
        in
        match function_decls with
        | Bottom -> Bottom
        | Ok (function_decls, equations_from_meet) ->
          if function_decls == closure1.function_decls then
            Ok (closure1, equations_from_meet)
          else if function_decls == closure2.function_decls then
            Ok (closure2, equations_from_meet)
          else
            Ok (({ function_decls; } : closure), equations_from_meet)
      end

    let join_closure env1 env2
          (closure1 : closure) (closure2 : closure)
          : closure =
      if env1 == env2 && closure1 == closure2 then begin
        closure1
      end else begin
        let produce_non_inlinable ~params1 ~params2 ~result1 ~result2
              ~result_equations1 ~result_equations2
              ~direct_call_surrogate1 ~direct_call_surrogate2 =
          let same_arity =
            List.compare_lengths params1 params2 = 0
          in
          let same_num_results =
            List.compare_lengths result1 result2 = 0
          in
          if same_arity && same_num_results then
            let params =
              List.map2 (fun t1 t2 ->
                  Meet_and_join.join (env1, t1) (env2, t2))
                params1
                params2
            in
            (* XXX needs fixing as regards environments for the result, see
               meet function above *)
            let result =
              List.map2 (fun t1 t2 ->
                  Meet_and_join.join
                    (Equations.to_typing_environment ~resolver:env1.resolver
                       result_equations1, t1)
                    (Equations.to_typing_environment ~resolver:env2.resolver
                       result_equations2, t2))
                result1
                result2
            in
            let direct_call_surrogate =
              match direct_call_surrogate1, direct_call_surrogate2 with
              | Some closure_id1, Some closure_id2
                  when Closure_id.equal closure_id1 closure_id2 ->
                Some closure_id1
              | _, _ -> None
            in
            let result_equations =
              Meet_and_join.join_equations ~resolver:env1.resolver
                result_equations1 result_equations2
            in
            let non_inlinable : non_inlinable_function_declarations =
              { params;
                result;
                result_equations;
                direct_call_surrogate;
              }
            in
            Non_inlinable (Some non_inlinable)
          else
            Non_inlinable None
        in
        let function_decls : function_declarations =
          match closure1.function_decls, closure2.function_decls with
          | Non_inlinable None, _ | _, Non_inlinable None -> Non_inlinable None
          | Non_inlinable (Some non_inlinable1),
              Non_inlinable (Some non_inlinable2) ->
            produce_non_inlinable
              ~params1:non_inlinable1.params
              ~params2:non_inlinable2.params
              ~result1:non_inlinable1.result
              ~result2:non_inlinable2.result
              ~result_equations1:non_inlinable1.result_equations
              ~result_equations2:non_inlinable2.result_equations
              ~direct_call_surrogate1:non_inlinable1.direct_call_surrogate
              ~direct_call_surrogate2:non_inlinable2.direct_call_surrogate
          | Non_inlinable (Some non_inlinable), Inlinable inlinable
          | Inlinable inlinable, Non_inlinable (Some non_inlinable) ->
            let params1 = List.map snd inlinable.params in
            produce_non_inlinable
              ~params1
              ~params2:non_inlinable.params
              ~result1:inlinable.result
              ~result2:non_inlinable.result
              ~result_equations1:inlinable.result_equations
              ~result_equations2:non_inlinable.result_equations
              ~direct_call_surrogate1:inlinable.direct_call_surrogate
              ~direct_call_surrogate2:non_inlinable.direct_call_surrogate
          | Inlinable inlinable1, Inlinable inlinable2 ->
            if not (Code_id.equal inlinable1.code_id inlinable2.code_id)
            then begin
              let params1 = List.map snd inlinable1.params in
              let params2 = List.map snd inlinable2.params in
              produce_non_inlinable
                ~params1
                ~params2
                ~result1:inlinable1.result
                ~result2:inlinable2.result
                ~result_equations1:inlinable1.result_equations
                ~result_equations2:inlinable2.result_equations
                ~direct_call_surrogate1:inlinable1.direct_call_surrogate
                ~direct_call_surrogate2:inlinable2.direct_call_surrogate
            end else begin
              if !Clflags.flambda_invariant_checks then begin
                assert (Closure_origin.equal inlinable1.closure_origin
                  inlinable2.closure_origin);
                assert (Continuation.equal inlinable1.continuation_param
                  inlinable2.continuation_param);
                assert (Continuation.equal inlinable1.exn_continuation_param
                  inlinable2.exn_continuation_param);
                assert (Pervasives.(=) inlinable1.is_classic_mode
                  inlinable2.is_classic_mode);
                assert (List.compare_lengths inlinable1.params inlinable2.params
                  = 0);
                assert (List.compare_lengths inlinable1.result inlinable2.result
                  = 0);
                assert (Name_occurrences.equal inlinable1.free_names_in_body
                  inlinable2.free_names_in_body);
                assert (Pervasives.(=) inlinable1.stub inlinable2.stub);
                assert (Debuginfo.equal inlinable1.dbg inlinable2.dbg);
                assert (Pervasives.(=) inlinable1.inline inlinable2.inline);
                assert (Pervasives.(=) inlinable1.specialise
                  inlinable2.specialise);
                assert (Pervasives.(=) inlinable1.is_a_functor
                  inlinable2.is_a_functor);
                assert (Variable.Set.equal
                  (Lazy.force inlinable1.invariant_params)
                  (Lazy.force inlinable2.invariant_params));
                assert (Pervasives.(=)
                  (Lazy.force inlinable1.size)
                  (Lazy.force inlinable2.size));
                assert (Variable.equal inlinable1.my_closure
                  inlinable2.my_closure)
              end;
              (* Parameter types are treated covariantly. *)
              (* CR mshinwell: Add documentation for this -- the types provide
                 information about the calling context rather than the code of
                 the function. *)
              let result_equations =
                Meet_and_join.join_equations ~resolver:env1.resolver
                  inlinable1.result_equations
                  inlinable2.result_equations
              in
              let params =
                List.map2 (fun (param1, t1) (param2, t2) ->
                    assert (Parameter.equal param1 param2);
                    let t = Meet_and_join.join (env1, t1) (env2, t2) in
                    param1, t)
                  inlinable1.params
                  inlinable2.params
              in
              let result =
                List.map2 (fun t1 t2 ->
                    Meet_and_join.join
                      (Equations.to_typing_environment ~resolver:env1.resolver
                         inlinable1.result_equations, t1)
                      (Equations.to_typing_environment ~resolver:env2.resolver
                         inlinable2.result_equations, t2))
                  inlinable1.result
                  inlinable2.result
              in
              let direct_call_surrogate =
                match inlinable1.direct_call_surrogate,
                      inlinable2.direct_call_surrogate
                with
                | Some closure_id1, Some closure_id2
                    when Closure_id.equal closure_id1 closure_id2 ->
                  Some closure_id1
                | _, _ -> None
              in
              Inlinable {
                closure_origin = inlinable1.closure_origin;
                continuation_param = inlinable1.continuation_param;
                exn_continuation_param = inlinable1.exn_continuation_param;
                is_classic_mode = inlinable1.is_classic_mode;
                params;
                code_id = inlinable1.code_id;
                body = inlinable1.body;
                free_names_in_body = inlinable1.free_names_in_body;
                result;
                result_equations;
                stub = inlinable1.stub;
                dbg = inlinable1.dbg;
                inline = inlinable1.inline;
                specialise = inlinable1.specialise;
                is_a_functor = inlinable1.is_a_functor;
                invariant_params = inlinable1.invariant_params;
                size = inlinable1.size;
                direct_call_surrogate;
                my_closure = inlinable1.my_closure;
              }
            end
        in
        { function_decls; }
      end

    let meet_set_of_closures env1 env2
          (set1 : set_of_closures) (set2 : set_of_closures)
          : (set_of_closures * equations) Or_bottom.t =
      let resolver = env1.resolver in
      let equations_from_meet = ref (Equations.create ()) in
      (* CR mshinwell: Try to refactor this code to shorten it. *)
      let closures : _ extensibility =
        match set1.closures, set2.closures with
        | Exactly closures1, Exactly closures2 ->
          let closures =
            Closure_id.Map.inter (fun ty_fabricated1 ty_fabricated2 ->
                let ty_fabricated, new_equations_from_meet =
                  Meet_and_join_fabricated.meet_ty env1 env2
                    ty_fabricated1 ty_fabricated2
                in
                if ty_is_obviously_bottom ty_fabricated then begin
                  None
                end else begin
                  equations_from_meet :=
                    Meet_and_join.meet_equations ~resolver
                      new_equations_from_meet !equations_from_meet;
                  Some ty_fabricated
                end)
              closures1
              closures2
          in
          (* CR mshinwell: Try to move this check into the intersection
             operation above (although note we still need to check the
             cardinality) *)
          let same_as_closures old_closures =
            match
              Closure_id.Map.for_all2_opt (fun ty_fabricated1 ty_fabricated2 ->
                  ty_fabricated1 == ty_fabricated2)
                old_closures closures
            with
            | None -> false
            | Some same -> same
          in
          if same_as_closures closures1 then set1.closures
          else if same_as_closures closures2 then set2.closures
          else Exactly closures
        | Exactly closures1, Open closures2
        | Open closures2, Exactly closures1 ->
          let closures =
            Closure_id.Map.filter_map closures1 ~f:(fun closure_id ty1 ->
              match Closure_id.Map.find closure_id closures2 with
              | exception Not_found -> Some ty1
              | ty2 ->
                let ty_fabricated, new_equations_from_meet =
                  Meet_and_join_fabricated.meet_ty env1 env2 ty1 ty2
                in
                if ty_is_obviously_bottom ty_fabricated then begin
                  None
                end else begin
                  equations_from_meet :=
                    Meet_and_join.meet_equations ~resolver
                      new_equations_from_meet !equations_from_meet;
                  Some ty_fabricated
                end)
          in
          Exactly closures
        | Open closures1, Open closures2 ->
          let closures =
            Closure_id.Map.union_merge (fun ty_fabricated1 ty_fabricated2 ->
                let ty_fabricated, new_equations_from_meet =
                  Meet_and_join_fabricated.meet_ty env1 env2
                    ty_fabricated1 ty_fabricated2
                in
                if ty_is_obviously_bottom ty_fabricated then begin
                  bottom_as_ty_fabricated ()
                end else begin
                  equations_from_meet :=
                    Meet_and_join.meet_equations ~resolver
                      new_equations_from_meet !equations_from_meet;
                  ty_fabricated
                end)
              closures1
              closures2
          in
          Open closures
      in
      let closure_elements =
        match set1.closure_elements, set2.closure_elements with
        | Exactly closure_elements1, Exactly closure_elements2 ->
          let closure_elements =
            Var_within_closure.Map.inter (fun ty_value1 ty_value2 ->
                let ty_value, new_equations_from_meet =
                  Meet_and_join_value.meet_ty env1 env2
                    ty_value1 ty_value2
                in
                if ty_is_obviously_bottom ty_value then begin
                  None
                end else begin
                  equations_from_meet :=
                    Meet_and_join.meet_equations ~resolver
                      new_equations_from_meet !equations_from_meet;
                  Some ty_value
                end)
              closure_elements1
              closure_elements2
          in
          let same_as_closure_elements old_closure_elements =
            match
              Var_within_closure.Map.for_all2_opt (fun ty_value1 ty_value2 ->
                  ty_value1 == ty_value2)
                old_closure_elements closure_elements
            with
            | None -> false
            | Some same -> same
          in
          if same_as_closure_elements closure_elements1 then
            set1.closure_elements
          else if same_as_closure_elements closure_elements2 then
            set2.closure_elements
          else
            Exactly closure_elements
        | Exactly closure_elements1, Open closure_elements2
        | Open closure_elements2, Exactly closure_elements1 ->
          let closure_elements =
            Var_within_closure.Map.filter_map closure_elements1
              ~f:(fun closure_id ty1 ->
                match
                  Var_within_closure.Map.find closure_id closure_elements2
                with
                | exception Not_found -> Some ty1
                | ty2 ->
                  let ty_value, new_equations_from_meet =
                    Meet_and_join_value.meet_ty env1 env2 ty1 ty2
                  in
                  if ty_is_obviously_bottom ty_value then begin
                    None
                  end else begin
                    equations_from_meet :=
                      Meet_and_join.meet_equations ~resolver
                        new_equations_from_meet !equations_from_meet;
                    Some ty_value
                  end)
          in
          Exactly closure_elements
        | Open closure_elements1, Open closure_elements2 ->
          let closure_elements =
            Var_within_closure.Map.union_merge (fun ty_value1 ty_value2 ->
                let ty_value, new_equations_from_meet =
                  Meet_and_join_value.meet_ty env1 env2
                    ty_value1 ty_value2
                in
                if ty_is_obviously_bottom ty_value then begin
                  bottom_as_ty_value ()
                end else begin
                  equations_from_meet :=
                    Meet_and_join.meet_equations ~resolver new_equations_from_meet
                      !equations_from_meet;
                  ty_value
                end)
              closure_elements1
              closure_elements2
          in
          Open closure_elements
      in
      match closures with
      | Exactly map when Closure_id.Map.is_empty map -> Bottom
      | _ ->
        if closures == set1.closures
          && closure_elements == set1.closure_elements
        then Ok (set1, !equations_from_meet)
        else if closures == set2.closures
          && closure_elements == set2.closure_elements
        then Ok (set2, !equations_from_meet)
        else begin
          let set : set_of_closures =
            { closures;
              closure_elements;
            }
          in
          Ok (set, !equations_from_meet)
        end

    let join_set_of_closures env1 env2
          (set1 : set_of_closures) (set2 : set_of_closures)
          : set_of_closures =
      let closures : _ extensibility =
        match set1.closures, set2.closures with
        | Exactly closures1, Exactly closures2 ->
          let closures =
            Closure_id.Map.union_merge
              (fun ty_fabricated1 ty_fabricated2 ->
                Meet_and_join_fabricated.join_ty env1 env2
                  ty_fabricated1 ty_fabricated2)
              closures1
              closures2
          in
          Exactly closures
        | Exactly closures1, Open closures2
        | Open closures1, Exactly closures2 ->
          let closures =
            Closure_id.Map.union_merge
              (fun ty_fabricated1 ty_fabricated2 ->
                Meet_and_join_fabricated.join_ty env1 env2
                  ty_fabricated1 ty_fabricated2)
              closures1
              closures2
          in
          Open closures
        | Open closures1, Open closures2 ->
          let closures =
            Closure_id.Map.union_both
              (fun _ty_fabricated ->
                any_fabricated_as_ty_fabricated ())
              (fun ty_fabricated1 ty_fabricated2 ->
                Meet_and_join_fabricated.join_ty env1 env2
                  ty_fabricated1 ty_fabricated2)
              closures1
              closures2
          in
          Open closures
      in
      let closure_elements : _ extensibility =
        match set1.closure_elements, set2.closure_elements with
        | Exactly closure_elements1, Exactly closure_elements2 ->
          let closure_elements =
            Var_within_closure.Map.union_merge
              (fun ty_value1 ty_value2 ->
                Meet_and_join_value.join_ty env1 env2
                  ty_value1 ty_value2)
              closure_elements1
              closure_elements2
          in
          Exactly closure_elements
        | Exactly closure_elements1, Open closure_elements2
        | Open closure_elements1, Exactly closure_elements2 ->
          let closure_elements =
            Var_within_closure.Map.union_merge
              (fun ty_value1 ty_value2 ->
                Meet_and_join_value.join_ty env1 env2
                  ty_value1 ty_value2)
              closure_elements1
              closure_elements2
          in
          Open closure_elements
        | Open closure_elements1, Open closure_elements2 ->
          let closure_elements =
            Var_within_closure.Map.union_both
              (fun _ty_value ->
                any_value_as_ty_value ())
              (fun ty_value1 ty_value2 ->
                Meet_and_join_value.join_ty env1 env2
                  ty_value1 ty_value2)
              closure_elements1
              closure_elements2
          in
          Open closure_elements
      in
      if closures == set1.closures
        && closure_elements == set1.closure_elements
      then
        set1
      else if closures == set2.closures
        && closure_elements == set2.closure_elements
      then
        set2
      else
        { closures;
          closure_elements;
        }

    let meet_of_kind_foo env1 env2
          (of_kind1 : of_kind_fabricated) (of_kind2 : of_kind_fabricated)
          : (of_kind_fabricated * equations) Or_bottom.t =
      let resolver = env1.resolver in
      match of_kind1, of_kind2 with
      | Discriminant discriminants1, Discriminant discriminants2 ->
        let discriminants =
          Discriminant.Map.inter_merge
            (fun ({ equations = equations1; } : discriminant_case)
                  ({ equations = equations2; } : discriminant_case)
                  : discriminant_case ->
              let equations =
                Meet_and_join.meet_equations ~resolver
                  equations1 equations2
              in
              (* CR mshinwell: Do we ever flip back to [Bottom] here? *)
              { equations; })
            discriminants1
            discriminants2
        in
        begin match Discriminant.Map.get_singleton discriminants with
        | None -> Ok (Discriminant discriminants, Equations.create ())
        | Some (discriminant, discriminant_case) ->
          let equations_from_meet = discriminant_case.equations in
          let discriminants =
            Discriminant.Map.singleton discriminant
              ({ equations = Equations.create (); } : discriminant_case)
          in
          Ok (Discriminant discriminants, equations_from_meet)
        end
      | Set_of_closures set1, Set_of_closures set2 ->
        begin match meet_set_of_closures env1 env2 set1 set2 with
        | Ok (set_of_closures, equations_from_meet) ->
          if set_of_closures == set1 then Ok (of_kind1, equations_from_meet)
          else if set_of_closures == set2 then Ok (of_kind2, equations_from_meet)
          else Ok (Set_of_closures set_of_closures, equations_from_meet)
        | Bottom -> Bottom
        end
      | Closure closure1, Closure closure2 ->
        begin match meet_closure env1 env2 closure1 closure2 with
        | Ok (closure, equations_from_meet) ->
          if closure == closure1 then Ok (of_kind1, equations_from_meet)
          else if closure == closure2 then Ok (of_kind2, equations_from_meet)
          else Ok (Closure closure, equations_from_meet)
        | Bottom -> Bottom
        end
      | (Discriminant _ | Set_of_closures _ | Closure _), _ -> Bottom

    let join_of_kind_foo env1 env2
          (of_kind1 : of_kind_fabricated) (of_kind2 : of_kind_fabricated)
          : of_kind_fabricated Or_unknown.t =
      match of_kind1, of_kind2 with
      | Discriminant discriminants1, Discriminant discriminants2 ->
        let discriminants =
          Discriminant.Map.union_merge
            (fun ({ equations = equations1; } : discriminant_case)
                  ({ equations = equations2; } : discriminant_case)
                  : discriminant_case ->
              let equations =
                Meet_and_join.join_equations ~resolver:env1.resolver
                  equations1 equations2
              in
              { equations; })
            discriminants1
            discriminants2
        in
        Known (Discriminant discriminants)
      | Set_of_closures set1, Set_of_closures set2 ->
        let set_of_closures = join_set_of_closures env1 env2 set1 set2 in
        Known (Set_of_closures set_of_closures)
      | Closure closure1, Closure closure2 ->
        let closure = join_closure env1 env2 closure1 closure2 in
        Known (Closure closure)
      | (Discriminant _ | Set_of_closures _ | Closure _), _ -> Unknown
  end)

  include Meet_and_join_fabricated
end
