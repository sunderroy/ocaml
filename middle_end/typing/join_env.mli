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
    with type 'a ty := 'a T.ty
    with type 'a unknown_or_join := 'a T.unknown_or_join
end) (Typing_env_extension : sig
  include Typing_env_extension_intf.S
    with type env_extension := T.env_extension
    with type typing_environment := T.typing_environment
    with type flambda_type := T.flambda_type
    with type join_env := T.join_env
end) : sig
  include Join_env_intf.S
    with type typing_environment := T.typing_environment
    with type env_extension := Typing_env_extension.t
    with type join_env := T.join_env
end