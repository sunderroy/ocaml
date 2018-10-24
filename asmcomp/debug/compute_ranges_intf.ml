(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                  Mark Shinwell, Jane Street Europe                     *)
(*                                                                        *)
(*   Copyright 2014--2018 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-4-30-40-41-42"]

module L = Linearize

module type S_subrange_state = sig
  type t

  val create : unit -> t
  val advance_over_instruction : t -> L.instruction -> t
end

module type S_subrange_info = sig
  type t
  type key
  type subrange_state

  val create : key -> subrange_state -> t
end

module type S_range_info = sig
  type t
  type key
  type index

  val create
     : L.fundecl
    -> key
    -> start_insn:L.instruction
    -> (index * t) option
end

module type S_functor = sig
  module Index : Identifiable.S

  module Key : Identifiable.S

  module Subrange_state : Compute_ranges_intf.S_subrange_state

  module Subrange_info : Compute_ranges_intf.S_subrange_info
    with type key := Key.t
    with type subrange_state := Subrange_state.t

  module Range_info : Compute_ranges_intf.S_range_info
    with type key := Key.t
    with type index := Index.t

  val available_before : L.instruction -> Key.Set.t

  val available_across : L.instruction -> Key.Set.t

  val must_restart_ranges_upon_any_change : unit -> bool
end

module type S = sig
  module Index : Identifiable.S

  module Key : Identifiable.S

  module Subrange_info : Compute_ranges_intf.S_subrange_info
    with type key := Key.t

  module Range_info : Compute_ranges_intf.S_range_info
    with type key := Key.t
    with type index := Index.t

  module Subrange : sig
    type t

    val info : t -> subrange_info

    val start_pos : t -> Linearize.label
    val end_pos : t -> Linearize.label
    val end_pos_offset : t -> int option
  end

  module Range : sig
    type t

    val info : t -> range_info

    val extremities : t -> Linearize.label * Linearize.label

    val fold
       : t
      -> init:'a
      -> f:('a -> Subrange.t -> 'a)
      -> 'a
  end

  type t

  val create : Linearize.fundecl -> t * Linearize.fundecl

  val iter : t -> f:(index -> Range.t -> unit) -> unit

  val fold : t -> init:'a -> f:('a -> index -> Range.t -> 'a) -> 'a
end
