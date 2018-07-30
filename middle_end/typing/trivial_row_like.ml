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

[@@@ocaml.warning "+a-4-30-40-41-42"]

module Make (Thing_without_names0 : Map.With_set) (T : Typing_world.S) = struct
  module Flambda_type = T.Flambda_type
  module Join_env = T.Join_env
  module Typing_env = T.Typing_env
  module Typing_env_extension = T.Typing_env_extension

  module Thing_without_names = struct
    include Thing_without_names0

    let apply_name_permutation t _ = t
    let freshen t _ = t
  end

  module TEE = struct
    include Typing_env_extension

    let add_or_meet_equations t env t' = meet env t t'
  end

  module RL = Row_like.Make (Thing_without_names) (Unit) (TEE) (T)

  type t = RL.t

  let create_with_equations things_with_env_extensions =
    let things_with_env_extensions =
      Thing_without_names.Map.fold (fun thing extension result ->
          RL.Tag_and_index.Map.add (thing, ()) extension result)
        things_with_env_extensions
        RL.Tag_and_index.Map.empty
    in
    RL.create_exactly_multiple things_with_env_extensions

  let create things =
    let things_with_env_extensions =
      Thing_without_names.Map.of_set (fun _thing -> TEE.empty) things
    in
    create_with_equations things_with_env_extensions

  let invariant = RL.invariant
  let meet = RL.meet
  let join = RL.join
  let apply_name_permutation t = RL.apply_name_permutation
  let freshen t = RL.freshen
end
