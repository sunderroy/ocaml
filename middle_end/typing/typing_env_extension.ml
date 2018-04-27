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

module Make (T : sig
  include Flambda_type0_internal_intf.S
end) (Typing_env : sig
  include Typing_env_intf.S
    with type typing_environment := T.typing_environment
    with type env_extension := T.env_extension
    with type flambda_type := T.flambda_type
    with type t_in_context := T.t_in_context
    with type 'a ty = 'a T.ty
    with type 'a unknown_or_join = 'a T.unknown_or_join
end) (Meet_and_join : sig
  include Meet_and_join_intf.S_for_types
    with type typing_environment := T.typing_environment
    with type env_extension := T.env_extension
    with type flambda_type := T.flambda_type
end) (Type_equality : sig
  include Type_equality_intf.S
    with type flambda_type := T.flambda_type
end) = struct
  open T

  type env_extension = T.env_extension
  type typing_environment = T.typing_environment
  type flambda_type = T.flambda_type

  type t = env_extension

  module TE = Typing_env

  let print ppf t = T.print_typing_env_extension ppf t

  let fast_equal t1 t2 = (t1 == t2)

  let equal ~equal_type t1 t2 =
    let equal_names_and_types (name1, ty1) (name2, ty2) =
      Name.equal name1 name2 && equal_type ty1 ty2
    in
    Misc.Stdlib.List.equal equal_names_and_types
        t1.first_definitions t2.first_definitions
      && Scope_level.Map.equal
           (Scope_level.Sublevel.Map.equal
             (fun (name1, (entry1 : typing_environment_entry))
                  (name2, (entry2 : typing_environment_entry)) ->
               Name.equal name1 name2
                 && match entry1, entry2 with
                    | Definition ty1, Definition ty2 ->
                      equal_type ty1 ty2
                    | Equation ty1, Equation ty2 ->
                      equal_type ty1 ty2
                    | CSE prim1, CSE prim2 ->
                      Flambda_primitive.With_fixed_value.equal prim1 prim2
                    | _, _ -> false))
           t1.at_or_after_cut_point
           t2.at_or_after_cut_point
      && Misc.Stdlib.List.equal equal_names_and_types
           t1.last_equations_rev t2.last_equations_rev

  let invariant _t =
    (* CR mshinwell: Work out what to do here.  Probably just a check that
       the ordering is reasonable. *)
    ()

  let empty =
    { first_definitions = [];
      at_or_after_cut_point = Scope_level.Map.empty;
      last_equations_rev = [];
      cse = Flambda_primitive.With_fixed_value.Map.empty;
    }

  let is_empty t = Scope_level.Map.is_empty t.at_or_after_cut_point

  let defined_names t =
    let from_first_definitions =
      Name.Set.of_list (
        List.map (fun (name, _ty) -> name) t.first_definitions)
    in
    Scope_level.Map.fold (fun _level by_sublevel defined_names ->
        Scope_level.Sublevel.Map.fold
          (fun _sublevel (name, (entry : typing_environment_entry))
               defined_names ->
            match entry with
            | Definition _ -> Name.Set.add name defined_names
            | Equation _ | CSE _ -> defined_names)
          by_sublevel
          defined_names)
      t.at_or_after_cut_point
      from_first_definitions

  let equations_on_env t =
    let equations_domain
          { first_definitions = _; at_or_after_cut_point;
            last_equations_rev; } =
      let from_at_or_after_cut_point =
        Scope_level.Map.fold (fun _level by_sublevel domain ->
            Scope_level.Sublevel.Map.fold
              (fun _sublevel (name, (entry : typing_environment_entry))
                   domain ->
                match entry with
                | Definition _ -> domain
                | Equation _ | CSE _ -> Name.Set.add name domain)
              by_sublevel
              domain)
          at_or_after_cut_point
          Name.Set.empty
      in
      let from_last_equations_rev =
        Name.Set.of_list (
          List.map (fun (name, _ty) -> name) last_equations_rev)
      in
      Name.Set.union from_at_or_after_cut_point from_last_equations_rev
    in
    Name.Set.diff (equations_domain t) (defined_names t)

  let free_names_transitive env ty =
    let all_names = ref (Name_occurrences.create ()) in
    let rec loop to_follow =
      all_names := Name_occurrences.union !all_names to_follow;
      match Name_occurrences.choose_and_remove_amongst_everything to_follow with
      | None -> ()
      | Some (name, to_follow) ->
        let ty =
          match TE.find_exn env name with
          | exception Not_found ->
            Misc.fatal_errorf "Unbound name %a whilst finding free names,@ \
                transitively, of %a@ in environment@ %a"
              Name.print name
              T.print ty
              TE.print env
          | ty, _binding_type -> ty
        in
        let names = T.free_names ty in
        loop (Name_occurrences.union to_follow names)
    in
    loop (free_names ty);
    !all_names

  let free_names_transitive_list t env tys =
    let scope_level = Scope_level.next (TE.max_level env) in
    let env = TE.add_or_meet_env_extension env t scope_level in
    List.fold_left (fun names ty ->
        Name_occurrences.union names (free_names_transitive env ty))
      (Name_occurrences.create ())
      tys

  let restrict_to_names t allowed_names =
    let allowed_names = Name_occurrences.everything allowed_names in
    let first_definitions =
      List.filter (fun (name, _ty) ->
          Name.Set.mem name allowed_names)
        t.first_definitions
    in
    let at_or_after_cut_point =
      Scope_level.Map.filter_map (fun _cont_level by_sublevel ->
          let by_sublevel =
            Scope_level.Sublevel.Map.filter_map
              (fun _sublevel ((name, _) as entry) ->
                if Name.Set.mem name allowed_names then Some entry
                else None)
            by_sublevel
          in
          if Scope_level.Sublevel.Map.is_empty by_sublevel then None
          else Some by_sublevel)
        t.at_or_after_cut_point
    in
    let last_equations_rev =
      List.filter (fun (name, _ty) ->
          Name.Set.mem name allowed_names)
        t.last_equations_rev
    in
    let cse =
      Flambda_primitive.With_fixed_value.Map.filter (fun _prim name ->
          Name.Set.mem name allowed_names)
        t.cse
    in
    let t =
      { first_definitions;
        at_or_after_cut_point;
        last_equations_rev;
        cse;
      }
    in
    invariant t;
    t

  let restrict_to_definitions t =
    restrict_to_names t (
      Name_occurrences.create_from_set_in_types (defined_names t))

  let restrict_names_to_those_occurring_in_types t env tys =
    let free_names = free_names_transitive_list t env tys in
    restrict_to_names t free_names

  type fold_info =
    | Definition_in_extension of T.t
    | Equation of T.t

  let fold t ~init ~(f : _ -> Name.t -> fold_info -> _) =
    let acc =
      List.fold_left (fun acc (name, ty) ->
          f acc name (Definition_in_extension ty))
        init
        (List.rev t.first_definitions)
    in
    let acc =
      Scope_level.Map.fold (fun _level by_sublevel acc ->
          Scope_level.Sublevel.Map.fold
            (fun _sublevel (name, (entry : typing_environment_entry)) acc ->
              match entry with
              | Definition ty ->
                f acc name (Definition_in_extension ty)
              | Equation ty ->
                f acc name (Equation ty)
              | CSE _ -> acc)
            by_sublevel
            acc)
        t.at_or_after_cut_point
        acc
    in
    List.fold_left (fun acc (name, ty) ->
        f acc name (Equation ty))
      acc
      t.last_equations_rev

  let add_definition_at_beginning t name ty =
    let first_definitions = (name, ty) :: t.first_definitions in
    { t with first_definitions; }

  let add_equation t name ty =
    let last_equations_rev = (name, ty) :: t.last_equations_rev in
    { t with last_equations_rev; }

  let add_cse t name prim =
    let cse =
      match Flambda_primitive.With_fixed_value.Map.find prim t.cse with
      | exception Not_found ->
        Flambda_primitive.With_fixed_value.Map.add prim name t.cse
      | _name -> t.cse
    in
    { t with cse; }

  (* CR-someday mshinwell: Consider implementing [meet] and [join] directly
     rather than opening up all of the existentials and cutting the
     environment.  However this shouldn't be done until we are sure that the
     semantics are correct and that there is likely to be a notable
     performance increase. *)

  let meet (env : typing_environment) (t1 : t) (t2 : t) : t =
    if fast_equal t1 t2 then t1
    else if is_empty t1 then t2
    else if is_empty t2 then t1
    else
      let scope_level = Scope_level.next (TE.max_level env) in
      let env = TE.add_or_meet_env_extension env t1 scope_level in
      let env = TE.add_or_meet_env_extension env t2 scope_level in
      TE.cut env ~existential_if_defined_at_or_later_than:scope_level

  let join (env : typing_environment) (t1' : t) (t2' : t) (t1 : t) (t2 : t) =
    if fast_equal t1 t2 then t1
    else if is_empty t1 then empty
    else if is_empty t2 then empty
    else
      let t =
        let scope_level = Scope_level.next (TE.max_level env) in
        let env = TE.add_or_join_env_extension env t1' t2' t1 scope_level in
        let env = TE.add_or_join_env_extension env t1' t2' t2 scope_level in
        TE.cut env ~existential_if_defined_at_or_later_than:scope_level
      in
      let equations_in_t1_on_env = equations_on_env t1 in
      let equations_in_t2_on_env = equations_on_env t2 in
      let allowed_names =
        Name_occurrences.create_from_set_in_types (
          Name.Set.inter equations_in_t1_on_env equations_in_t2_on_env)
      in
      let t = restrict_to_names t allowed_names in
      (* We don't need to filter the types within entries ([Equation]s or
         [Definition]s) in [t].  Any entry originally containing a reference
         to a name defined in exactly one of [t1] or [t2] should have had such
         reference removed by the join operation on the type inside the
         entry. *)
      invariant t;
      t

  (* CR mshinwell: This needs to do something with [t.cse] perhaps *)
  let diff t env : t =
    let names_more_precise, _freshening =
      fold t
        ~init:(Name.Set.empty, Variable.Map.empty)
        ~f:(fun (names_more_precise, freshening) (name : Name.t)
                (info : fold_info) ->
          let var =
            match name with
            | Var var -> var
            | Symbol _ ->
              Misc.fatal_errorf "Symbols should not be bound by environment \
                  extensions:@ %a"
                print t
          in
          match info with
          | Definition_in_extension _ty ->
            let fresh_var = Variable.rename var in
            let freshening = Variable.Map.add var fresh_var freshening in
            let names_more_precise =
              Name.Set.add (Name.var fresh_var) names_more_precise
            in
            names_more_precise, freshening
          | Equation ty ->
            let var =
              match Variable.Map.find var freshening with
              | exception Not_found -> var
              | var -> var
            in
            let ty = T.rename_variables ty freshening in
            let name = Name.var var in
            match TE.find_opt env name with
            | None ->
              let names_more_precise =
                Name.Set.add name names_more_precise
              in
              names_more_precise, freshening
            | Some (old_ty, _) ->
              let more_precise_using_old_types_for_free_names =
                T.strictly_more_precise env ty ~than:old_ty
              in
              if more_precise_using_old_types_for_free_names then
                let names_more_precise =
                  Name.Set.add name names_more_precise
                in
                names_more_precise, freshening
              else
                let free_names = T.free_names_set ty in
                let more_precise_using_new_types_for_free_names =
                  not (Name.Set.is_empty (
                    Name.Set.inter free_names names_more_precise))
                in
                if more_precise_using_new_types_for_free_names then
                  let names_more_precise =
                    Name.Set.add name names_more_precise
                  in
                  names_more_precise, freshening
                else
                  names_more_precise, freshening)
    in
    restrict_to_names t
      (Name_occurrences.create_from_set_in_types names_more_precise)

  let rename_variables_not_occurring_in_domain t _freshening =
    (* XXX *)
    t
end
