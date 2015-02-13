(***********************************************************************)
(*                                                                     *)
(*                               OCaml                                 *)
(*                                                                     *)
(*                 Mark Shinwell, Jane Street Europe                   *)
(*                                                                     *)
(*  Copyright 2013--2015, Jane Street Holding                          *)
(*                                                                     *)
(*  Licensed under the Apache License, Version 2.0 (the "License");    *)
(*  you may not use this file except in compliance with the License.   *)
(*  You may obtain a copy of the License at                            *)
(*                                                                     *)
(*      http://www.apache.org/licenses/LICENSE-2.0                     *)
(*                                                                     *)
(*  Unless required by applicable law or agreed to in writing,         *)
(*  software distributed under the License is distributed on an        *)
(*  "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,       *)
(*  either express or implied.  See the License for the specific       *)
(*  language governing permissions and limitations under the License.  *)
(*                                                                     *)
(***********************************************************************)

type t =
  | DW_ATE_address
  | DW_ATE_boolean
  | DW_ATE_complex_float
  | DW_ATE_float
  | DW_ATE_signed
  | DW_ATE_signed_char
  | DW_ATE_unsigned
  | DW_ATE_unsigned_char
  | DW_ATE_imaginary_float
  | DW_ATE_packed_decimal
  | DW_ATE_numeric_string
  | DW_ATE_edited
  | DW_ATE_signed_fixed
  | DW_ATE_unsigned_fixed
  | DW_ATE_decimal_float
  | DW_ATE_UTF
  | User of Int8.t

let dw_ate_lo_user = 0x80
let dw_ate_hi_user = 0xff

let signed = DW_ATE_signed

let encode = function
  | DW_ATE_signed -> 0x05
  | DW_ATE_address -> 0x01
  | DW_ATE_boolean -> 0x02
  | DW_ATE_complex_float -> 0x03
  | DW_ATE_float -> 0x04
  | DW_ATE_signed -> 0x05
  | DW_ATE_signed_char -> 0x06
  | DW_ATE_unsigned -> 0x07
  | DW_ATE_unsigned_char -> 0x08
  | DW_ATE_imaginary_float -> 0x09
  | DW_ATE_packed_decimal -> 0x0a
  | DW_ATE_numeric_string -> 0x0b
  | DW_ATE_edited -> 0x0c
  | DW_ATE_signed_fixed -> 0x0d
  | DW_ATE_unsigned_fixed -> 0x0e
  | DW_ATE_decimal_float -> 0x0f
  | DW_ATE_UTF -> 0x10
  | User code ->
    assert (code >= dw_ate_lo_user && code <= dw_ate_hi_user);
    code

let size _t = 1

let as_dwarf_value t =
  Value.as_byte (encode t)
