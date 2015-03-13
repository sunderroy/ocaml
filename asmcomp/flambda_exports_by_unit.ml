(***********************************************************************)
(*                                                                     *)
(*                               OCaml                                 *)
(*                                                                     *)
(*                 Pierre Chambart and Mark Shinwell                   *)
(*                                                                     *)
(*  Copyright 2014--2015, OCamlPro                                     *)
(*  Copyright 2015, Jane Street Group                                  *)
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

open Abstract_identifiers

module Compilation_unit = Symbol.Compilation_unit
module E = Flambdaexport.Exported





let core_is_closure_constant t (id : Closure_id.t) =
  match find_in_any_unit t id E.fundecls_for_set_of_closures_id with
  | Some (Current_unit (exported, fundecls)) ->
    Some (Current_unit (E.is_set_of_closures_constant exported fundecls.ident))
  | Some (Imported_unit (exported, fundecls)) ->
    Some (Imported_unit (E.is_set_of_closures_constant exported fundecls.ident))
  | None ->
    Misc.fatal_errorf "(is_closure_constant) could not find function
        declarations corresponding to closure ID: %a"
      Closure_id.print id

let is_closure_local_and_constant t (id : Closure_id.t) =
  match find_in_any_unit t id E.fundecls_for_set_of_closures_id with
  | Some (Current_unit (exported, fundecls)) ->
    E.is_set_of_closures_constant exported fundecls.ident
  | Some (Imported_unit _) -> false
  | None ->
    Misc.fatal_errorf "(is_closure_constant) could not find function
        declarations corresponding to closure ID: %a"
      Closure_id.print id

let is_closure_local_and_constant t (id : Closure_id.t) =
  match closure_declaration_position t id with
  | Current_unit decls ->
    E.is_set_of_closures_constant t.current_unit decls.ident
  | External _ -> false

let is_set_of_closures_constant t (id : Set_of_closures_id.t) =
  match set_of_closures_declaration_position t id with
  | Current_unit decls ->
    E.is_set_of_closures_constant t.current_unit decls.ident
  | External decls ->
    E.is_set_of_closures_constant t.external_units decls.ident

let is_set_of_closures_local_and_constant t (id : Set_of_closures_id.t) =
  E.is_set_of_closures_constant t.current_unit id

(*
let function_arity t (closure_id : Closure_id.t) =
(* [find_declaration] is in Flambdautils, this is wrong *)
  match E.find_declaration t.current_unit closure_id with
  | decl -> Flambdautils.function_arity decl
  | exception Not_found ->
    match E.find_declaration t.exported_units closure_id with
    | decl -> Flambdautils.function_arity decl
    | exception Not_found ->
      Misc.fatal_error "cannot find declaration of closure to compute \
          arity: %a"
        Closure_id.print fun_id
*)

(*
  let not_constants = P.not_constants
  let is_constant id =
    not (Variable.Set.mem id not_constants.Flambdaconstants.not_constant_id)
*)

(* [find_approx_descr t approx] obtains the approximation description
   referenced by [approx] by looking in the maps of exported approximations
   for the current and the imported compilation units. *)
(* CR mshinwell: I inlined all the cases here and wrote out all the Not_found
   cases explicitly, to try to make it clearer what's going on.  However it
   still seems really complicated.  Can this be simplified?  It seems like
   we're mixing up stages in some way (export IDs vs. symbols); also, the
   Value_symbol case in particular seems dubious.  For exmaple, if we find
   an export ID in [t.symbol_to_export_id] then why isn't the failure to
   find the export ID in [t.ex_table] a fatal error?
*)
let find_approx_descr t (approx : Flambdaexport.approx) =
  match approx with
  | Value_unknown -> None
  | Value_id export_id ->
    (* For export IDs, look in the table of values that the current unit
       exports, and then in the table that contains the values that all
       imported units export. *)
    let module Export_id = Flambdaexport.Export_id in
    begin match Export_id.Map.find export_id t.current_unit
    | descr -> Some descr
    | exception Not_found ->
      begin match
        Flambdaexport.find_description export_id t.external_units
      with
      | descr -> Some descr
      | exception Not_found -> None
      end
    end
  | Value_symbol symbol ->
    let descr =
      match Symbol.Map.find symbol t.symbol_to_export_id with
      | export_id ->
        begin match Export_id.Map.find export_id t.ex_table with
        | descr -> Some descr
        | exception Not_found -> None
        end
      | exception Not_found -> None
    in
    match descr with
    | Some descr -> descr
    | None ->
      if Compilenv.is_predefined_exception sym then None
      else
        let exported = Compilenv.approx_for_global sym.sym_unit in
        match Symbol.Map.find sym export.symbol_id with
        | Some export_id ->
          begin match Flambdaexport.find_description export_id exported with
          | Some descr -> descr
          | None -> None
          end
        | None -> None
