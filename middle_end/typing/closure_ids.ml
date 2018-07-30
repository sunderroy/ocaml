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

module Make (T : Typing_world.S) = struct
  module Flambda_type = T.Flambda_type
  module Join_env = T.Join_env
  module Relational_product = T.Relational_product
  module Typing_env = T.Typing_env
  module Typing_env_extension = T.Typing_env_extension

  module RL =
    Row_like.Make (Unit) (Closure_id.Set)
      (Flambda_type.Set_of_closures_entry) (T)

  module TEE = Typing_env_extension

  type t = RL.t

  type open_or_closed = Open | Closed

  let create closure_ids_map open_or_closed =
    match open_or_closed with
    | Open -> RL.create_at_least_multiple closure_ids_map
    | Closed ->
      let closure_ids_map =
        Closure_id.Map.fold (fun closure_ids set_of_closures_entry result ->
            RL.Tag_and_index.Map.add ((), closure_ids) set_of_closures_entry
              result)
          closure_ids_map
          RL.Tag_and_index.Map.empty
      in
      RL.create_exactly () closure_ids_map

  let invariant = RL.invariant
  let meet = RL.meet
  let join = RL.join
  let apply_name_permutation t = RL.apply_name_permutation
  let freshen t = RL.freshen
end
