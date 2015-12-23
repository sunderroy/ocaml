(***********************************************************************)
(*                                                                     *)
(*                                OCaml                                *)
(*                                                                     *)
(*            Xavier Leroy, projet Cristal, INRIA Rocquencourt         *)
(*                                                                     *)
(*  Copyright 2002 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the Q Public License version 1.0.               *)
(*                                                                     *)
(***********************************************************************)

(* The batch compiler *)

open Misc
open Config
open Format
open Typedtree
open Compenv

(* Compile a .mli file *)

(* Keep in sync with the copy in compile.ml *)

let tool_name = "ocamlopt"

let interface ppf sourcefile outputprefix =
  Compmisc.init_path false;
  let modulename = module_of_filename ppf sourcefile outputprefix in
  Env.set_unit_name modulename;
  let initial_env = Compmisc.initial_env () in
  let ast = Pparse.parse_interface ~tool_name ppf sourcefile in
  if !Clflags.dump_parsetree then fprintf ppf "%a@." Printast.interface ast;
  if !Clflags.dump_source then fprintf ppf "%a@." Pprintast.signature ast;
  let tsg = Typemod.type_interface initial_env ast in
  if !Clflags.dump_typedtree then fprintf ppf "%a@." Printtyped.interface tsg;
  let sg = tsg.sig_type in
  if !Clflags.print_types then
    Printtyp.wrap_printing_env initial_env (fun () ->
        fprintf std_formatter "%a@."
          Printtyp.signature (Typemod.simplify_signature sg));
  ignore (Includemod.signatures initial_env sg sg);
  Typecore.force_delayed_checks ();
  Warnings.check_fatal ();
  if not !Clflags.print_types then begin
    let deprecated = Builtin_attributes.deprecated_of_sig ast in
    let sg = Env.save_signature ~deprecated sg modulename (outputprefix ^ ".cmi") in
    Typemod.save_signature modulename tsg outputprefix sourcefile
      initial_env sg ;
  end

(* Compile a .ml file *)

let print_if ppf flag printer arg =
  if !flag then fprintf ppf "%a@." printer arg;
  arg

let (++) x f = f x
let (+++) (x, y) f = (x, f y)

let do_transl modulename modul =
  let id, (lam, size) =
    Translmod.transl_implementation_flambda modulename modul
  in
  (id, size), lam

let implementation ppf sourcefile outputprefix ~backend =
  Compmisc.init_path true;
  let modulename = module_of_filename ppf sourcefile outputprefix in
  Env.set_unit_name modulename;
  let env = Compmisc.initial_env() in
  Compilenv.reset ~source_provenance:(Timings.File sourcefile)
    ?packname:!Clflags.for_package modulename;
  let cmxfile = outputprefix ^ ".cmx" in
  let objfile = outputprefix ^ ext_obj in
  let comp ast =
    let (typedtree, coercion) =
      ast
      ++ print_if ppf Clflags.dump_parsetree Printast.implementation
      ++ print_if ppf Clflags.dump_source Pprintast.structure
      ++ Timings.(time (Typing sourcefile))
          (Typemod.type_implementation sourcefile outputprefix modulename env)
      ++ print_if ppf Clflags.dump_typedtree
          Printtyped.implementation_with_coercion
    in
    if not !Clflags.print_types then begin
      if !Clflags.o3 then begin
        Clflags.simplify_rounds := 3;
        Clflags.use_inlining_arguments_set ~round:1 Clflags.o1_arguments;
        Clflags.use_inlining_arguments_set ~round:2 Clflags.o2_arguments;
        Clflags.use_inlining_arguments_set ~round:3 Clflags.o3_arguments
      end
      else if !Clflags.o2 then begin
        Clflags.simplify_rounds := 2;
        Clflags.use_inlining_arguments_set ~round:1 Clflags.o1_arguments;
        Clflags.use_inlining_arguments_set ~round:2 Clflags.o2_arguments
      end
      else if !Clflags.classic_heuristic then begin
        Clflags.use_inlining_arguments_set Clflags.classic_arguments
      end;
      if Config.flambda then begin
        (typedtree, coercion)
        ++ Timings.(start_id (Transl sourcefile))
        ++ do_transl modulename
        ++ Timings.(stop_id (Transl sourcefile))
        +++ print_if ppf Clflags.dump_rawlambda Printlambda.lambda
        ++ Timings.(start_id (Generate sourcefile))
        +++ Simplif.simplify_lambda
        +++ print_if ppf Clflags.dump_lambda Printlambda.lambda
        ++ (fun ((module_ident, size), lam) ->
            Middle_end.middle_end ppf ~sourcefile ~prefixname:outputprefix
              ~size
              ~module_ident
              ~backend
              ~module_initializer:lam)
        ++ Asmgen.compile_implementation ~sourcefile outputprefix ~backend Asmgen.Flambda ppf;
        Compilenv.save_unit_info cmxfile;
        Timings.(stop (Generate sourcefile));
      end
      else begin
        Clflags.use_inlining_arguments_set Clflags.classic_arguments;
        (typedtree, coercion)
        ++ Timings.(time (Transl sourcefile))
            (Translmod.transl_store_implementation modulename)
        +++ print_if ppf Clflags.dump_rawlambda Printlambda.lambda
        ++ Timings.(time (Generate sourcefile))
            (fun (size, lambda) ->
              (size, Simplif.simplify_lambda lambda)
              +++ print_if ppf Clflags.dump_lambda Printlambda.lambda
              ++ (fun (main_module_block_size, code) -> Asmgen.{ code; main_module_block_size })
              ++ Asmgen.compile_implementation ~sourcefile outputprefix ~backend Asmgen.Lambda ppf;
              Compilenv.save_unit_info cmxfile)
      end
    end;
    Warnings.check_fatal ();
    Stypes.dump (Some (outputprefix ^ ".annot"))
  in
  try comp (Pparse.parse_implementation ~tool_name ppf sourcefile)
  with x ->
    Stypes.dump (Some (outputprefix ^ ".annot"));
    remove_file objfile;
    remove_file cmxfile;
    raise x

let c_file name =
  let output_name = !Clflags.output_name in
  if Ccomp.compile_file ~output_name name <> 0 then exit 2
