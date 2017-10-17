(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2013--2016 OCamlPro SAS                                    *)
(*   Copyright 2014--2016 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-4-9-30-40-41-42"]

(** Knowledge that the middle end needs about the backend. *)

module type S = sig
  (** Compute the symbol for the given identifier. *)
  val symbol_for_global' : (Ident.t -> Symbol.t)

  (** Importing of types from .cmx files. *)
  include Flambda_type.Importer

  (** All predefined exception symbols. *)
  val all_predefined_exception_symbols : unit -> Symbol.Set.t

  (** The symbol for the given closure. *)
  val closure_symbol : Closure_id.t -> Symbol.t

  (** The natural size of an integer on the target architecture
      (cf. [Arch.size_int] in the native code backend). *)
  (* CR mshinwell: use [Targetint] methods *)
  val size_int : int

  (** [true] iff the target architecture is big endian. *)
  val big_endian : bool

  (** The maximum number of arguments that is reasonable for a function
      to have.  This should be fewer than the threshold that causes non-self
      tail call optimization to be inhibited (in particular, if it would
      entail passing arguments on the stack; see [Selectgen]). *)
  val max_sensible_number_of_arguments : int

  (** See comments in flambda_type0_intf.ml. *)
  val import_export_id : Export_id.t -> Flambda_type.t option
  val import_symbol : Symbol.Of_kind_value.t -> Flambda_type.t option
  val symbol_is_predefined_exception : Symbol.Of_kind_value.t -> string option
end
