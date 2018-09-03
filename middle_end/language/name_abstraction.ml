(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2013--2018 OCamlPro SAS                                    *)
(*   Copyright 2014--2018 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-4-30-40-41-42"]

module type Name = sig
  include Contains_names.S
  val rename : t -> t
  val permutation_to_swap : t -> t -> Name_permutation.t
end

module Make (Name : Name) (Term : Contains_names.S) = struct
  type t = Name.t * Term.t

  let create name term = name, term

  let pattern_match (name, term) ~f =
    let fresh_name = Name.rename name in
    let perm = Name.permutation_to_swap name fresh_name in
    let fresh_term = Term.apply_name_permutation term perm in
    f fresh_name fresh_term

  let apply_name_permutation (name, term) perm =
    let name = Name.apply_name_permutation name perm in
    let term = Term.apply_name_permutation term perm in
    name, term

  let free_names (name, term) =
    let bound = Name.free_names name in
    let free_in_term = Term.free_names term in
    Name_occurrences.diff free_in_term bound
end

module Make2 (Name0 : Name) (Name1 : Name) (Term : Contains_names.S) = struct
  type t = Name0.t * Name1.t * Term.t

  let create name0 name1 term = name0, name1, term

  let pattern_match (name0, name1, term) ~f =
    let fresh_name0 = Name0.rename name0 in
    let perm0 = Name0.permutation_to_swap name0 fresh_name0 in
    let fresh_name1 = Name1.rename name1 in
    let perm1 = Name1.permutation_to_swap name1 fresh_name1 in
    let perm = Name_permutation.compose perm0 perm1 in
    let fresh_term = Term.apply_name_permutation term perm in
    f fresh_name0 fresh_name1 fresh_term

  let apply_name_permutation (name0, name1, term) perm =
    let name0 = Name0.apply_name_permutation name0 perm in
    let name1 = Name1.apply_name_permutation name1 perm in
    let term = Term.apply_name_permutation term perm in
    name0, name1, term

  let free_names (name0, name1, term) =
    let bound =
      Name_occurrences.union (Name0.free_names name0) (Name1.free_names name1)
    in
    let free_in_term = Term.free_names term in
    Name_occurrences.diff free_in_term bound
end
