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

type t =
  | Value
  | Unboxed_float
  | Unboxed_int32
  | Unboxed_int64
  | Unboxed_nativeint
  | Bottom

let value () = Value
let unboxed_float () = Unboxed_float
let unboxed_int32 () = Unboxed_int32

let unboxed_int64 () =
  if Targetint.size < 64 then
    Misc.fatal_errorf "Cannot create values of [Unboxed_int64] kind on this \
        target platform"
  else
    Unboxed_int64

let unboxed_nativeint () = Unboxed_nativeint
let bottom () = Bottom

let compatible t1 t2 =
  match t1, t2 with
  | Bottom, _ | _, Bottom
  | Value, Value
  | Unboxed_float, Unboxed_float
  | Unboxed_int32, Unboxed_int32
  | Unboxed_int64, Unboxed_int64
  | Unboxed_nativeint, Unboxed_nativeint -> true
  | (Value | Unboxed_float | Unboxed_int32 | Unboxed_int64
      | Unboxed_nativeint), _ -> false

let lambda_value_kind t =
  let module L = Lambda in
  match t with
  | Value -> Some L.Pgenval
  | Unboxed_float -> Some L.Pfloatval
  | Unboxed_int32 -> Some (L.Pboxedintval Pint32)
  | Unboxed_int64 -> Some (L.Pboxedintval Pint64)
  | Unboxed_nativeint -> Some (L.Pboxedintval Pnativeint)
  | Bottom -> None

include Identifiable.Make (struct
  type nonrec t = t

  let compare t1 t2 = Pervasives.compare t1 t2
  let equal t1 t2 = (compare t1 t2 = 0)

  let hash = Hashtbl.hash

  let print ppf t =
    match t with
    | Value -> Format.pp_print_string ppf "value"
    | Unboxed_float -> Format.pp_print_string ppf "unboxed_float"
    | Unboxed_int32 -> Format.pp_print_string ppf "unboxed_int32"
    | Unboxed_int64 -> Format.pp_print_string ppf "unboxed_int64"
    | Unboxed_nativeint -> Format.pp_print_string ppf "unboxed_nativeint"
    | Bottom -> Format.pp_print_string ppf "bottom"

  let output _ _ = Misc.fatal_error "Flambda_kind.output not implemented"
end)