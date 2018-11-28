(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                  Mark Shinwell, Jane Street Europe                     *)
(*                                                                        *)
(*   Copyright 2016--2018 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-4-30-40-41-42"]

module A = Asm_directives

let emit ~compilation_unit_proto_die ~start_of_code_symbol
      ~end_of_code_symbol ~compilation_unit_header_label
      ~debug_loc_table ~debug_ranges_table =
  (* CR-soon mshinwell: the [compilation_unit_die] member of the record
     returned from [Assign_abbrevs.run] is now unused *)
  let assigned_abbrevs =
    Profile.record "assign_abbrevs" (fun () ->
        Assign_abbrevs.run ~proto_die_root:compilation_unit_proto_die)
      ()
  in
  let debug_abbrev_label = Asm_section.label (DWARF Debug_abbrev) in
  let debug_info_label = Asm_section.label (DWARF Debug_info) in
  let debug_info =
    Profile.record "debug_info_section" (fun () ->
        Debug_info_section.create ~dies:assigned_abbrevs.dies
          ~debug_abbrev_label
          ~compilation_unit_header_label)
      ()
  in
  let aranges_table =
    Profile.record "create_aranges_table" (fun () ->
        Aranges_table.create ~start_of_code_symbol:start_of_code_symbol
          ~end_of_code_symbol:end_of_code_symbol
          ~debug_info_label)
      ()
  in
  Profile.record "dwarf_world_emit" (fun () ->
      A.switch_to_section (DWARF Debug_info);
      Profile.record "debug_info_section"
        Debug_info_section.emit debug_info;
      A.switch_to_section (DWARF Debug_abbrev);
      Profile.record "abbreviations_table"
        Abbreviations_table.emit assigned_abbrevs.abbrev_table;
      A.switch_to_section (DWARF Debug_aranges);
      Profile.record "aranges_table"
        Aranges_table.emit aranges_table;
      A.switch_to_section (DWARF Debug_loc);
      Profile.record "debug_loc_table"
        Debug_loc_table.emit debug_loc_table;
      A.switch_to_section (DWARF Debug_ranges);
      Profile.record "debug_ranges_table"
        Debug_ranges_table.emit debug_ranges_table;
      A.switch_to_section (DWARF Debug_line);
      A.switch_to_section (DWARF Debug_str);
      A.emit_cached_strings ())
    ()
