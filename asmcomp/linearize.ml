(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           *)
(*                   Mark Shinwell, Jane Street Europe                    *)
(*                                                                        *)
(*   Copyright 1996 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*   Copyright 2019 Jane Street Group LLC                                 *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(* Transformation of Mach code into a list of pseudo-instructions. *)

open Reg
open Mach

module RAS = Reg_availability_set
module RD = Reg_with_debug_info

type label = Cmm.label

type internal_affinity =
  | Previous
  | Irrelevant

type instruction =
  { mutable desc: instruction_desc;
    mutable next: instruction;
    arg: Reg.t array;
    res: Reg.t array;
    live: Reg.Set.t;
    mutable dbg : Insn_debuginfo.t;
    affinity : internal_affinity;
  }

and instruction_desc =
  | Lprologue
  | Lend
  | Lop of operation
  | Lreloadretaddr
  | Lreturn
  | Llabel of label
  | Lbranch of label
  | Lcondbranch of test * label
  | Lcondbranch3 of label option * label option * label option
  | Lswitch of label array
  | Lsetuptrap of label
  | Lpushtrap
  | Lpoptrap
  | Lraise of Cmm.raise_kind

let has_fallthrough = function
  | Lreturn | Lbranch _ | Lswitch _ | Lraise _
  | Lop Itailcall_ind _ | Lop (Itailcall_imm _) -> false
  | _ -> true

type fundecl =
  { fun_name: Backend_sym.t;
    fun_body: instruction;
    fun_fast: bool;
    fun_dbg : Debuginfo.Function.t;
    fun_arity : int;
    fun_spacetime_shape : Mach.spacetime_shape option;
    fun_phantom_lets :
      (Backend_var.Provenance.t option * Mach.phantom_defining_expr)
        Backend_var.Map.t;
    fun_tailrec_entry_point_label : label;
  }

(* Invert a test *)

let invert_integer_test = function
    Isigned cmp -> Isigned(Cmm.negate_integer_comparison cmp)
  | Iunsigned cmp -> Iunsigned(Cmm.negate_integer_comparison cmp)

let invert_test = function
    Itruetest -> Ifalsetest
  | Ifalsetest -> Itruetest
  | Iinttest(cmp) -> Iinttest(invert_integer_test cmp)
  | Iinttest_imm(cmp, n) -> Iinttest_imm(invert_integer_test cmp, n)
  | Ifloattest(cmp) -> Ifloattest(Cmm.negate_float_comparison cmp)
  | Ieventest -> Ioddtest
  | Ioddtest -> Ieventest

(* Registers clobbered by an instruction, either across ("during") the
   execution of the instruction itself, or when the results are written out. *)

let regs_clobbered_by (insn : instruction) =
  let clobbered =
    match insn.desc with
    | Lop op -> Proc.destroyed_at_oper (Iop op)
    | Lreloadretaddr -> Proc.destroyed_at_reloadretaddr
    | Lprologue | Lend | Lreturn | Lpushtrap | Lpoptrap | Llabel _ | Lbranch _
    | Lcondbranch _ | Lcondbranch3 _ | Lswitch _ | Lsetuptrap _
    | Lraise _ -> [| |]
  in
  Array.concat [clobbered; insn.res]

(* Register availability calculations.  We try to assign proper availability
   information to new instructions to avoid "holes" where variables vanish
   in the debugger when stepping by instruction. *)

let available_before_new_insn ~arg_of_new_insn ~res_of_new_insn
      ~(next : instruction) =
  let available_before_next = Insn_debuginfo.available_before next.dbg in
  (* Before the new instruction, we can be sure that the following registers
     are available: all those available immediately after the new instruction,
     minus the result registers of the new instruction, plus the argument
     registers of the new instruction. Other registers may also be available,
     but we cannot be sure. *)
  let without_args_of_new_insn =
    RAS.made_unavailable_by_clobber available_before_next
      ~regs_clobbered:res_of_new_insn
      ~register_class:Proc.register_class
  in
  let args_of_new_insn =
    Array.map (fun reg -> RD.create_without_debug_info ~reg) arg_of_new_insn
  in
  RAS.map without_args_of_new_insn ~f:(fun regs ->
    RD.Availability_set.union (RD.Availability_set.of_array args_of_new_insn) regs)

let available_after0 ~available_before (insn : instruction) =
  RAS.made_unavailable_by_clobber available_before
    ~regs_clobbered:(regs_clobbered_by insn)
    ~register_class:Proc.register_class

let available_after (insn : instruction) =
  available_after0 ~available_before:(Insn_debuginfo.available_before insn.dbg)
    insn

(* The "end" instruction *)

let rec end_instr =
  { desc = Lend;
    next = end_instr;
    arg = [||];
    res = [||];
    dbg = Insn_debuginfo.none;
    live = Reg.Set.empty;
    affinity = Irrelevant;
  }

(* [cons_instr] is documented in the .mli. *)

type affinity =
  | Previous
  | Next

let cons_instr ?(arg = [| |]) ?(res = [| |]) (affinity : affinity) desc next =
  let dbg, affinity =
    match affinity with
    | Previous -> Insn_debuginfo.none, (Previous : internal_affinity)
    | Next ->
      match next.affinity with
      | Irrelevant ->
        let available_before_new_insn =
          available_before_new_insn ~arg_of_new_insn:arg ~res_of_new_insn:res
            ~next
        in
        let dbg =
          Insn_debuginfo.with_available_before next.dbg
            available_before_new_insn
        in
        let dbg =
          (* This should be conservative. *)
          Insn_debuginfo.with_available_across dbg None
        in
        dbg, Irrelevant
      | Previous -> Insn_debuginfo.none, Irrelevant
  in
  { desc;
    next;
    arg;
    res;
    dbg;
    live = Reg.Set.empty;
    affinity;
  }

(* Build an instruction with [arg], [res], and [live] taken from the given
   [Mach.instruction] and cons it onto the supplied [next] instruction.
   The debuginfo is taken from the given instruction and propagated (having
   made any necessary updates to register availability information) to any
   immediately-subsequent instructions that have been marked with affinity
   [Previous]. *)

let copy_instr desc (to_copy : Mach.instruction) next =
  let rec propagate_debuginfo_to_next_insns insn ~available_before =
    match insn.affinity with
    | Previous ->
      let dbg =
        Insn_debuginfo.with_available_before to_copy.dbg available_before
      in
      let dbg =
        (* This should be conservative. *)
        Insn_debuginfo.with_available_across dbg None
      in
      let next =
        let available_before = available_after0 ~available_before insn in
        propagate_debuginfo_to_next_insns insn.next ~available_before
      in
      { insn with
        next;
        dbg;
      }
    | Irrelevant -> insn
  in
  let proto_insn =
    { desc = desc;
      next;
      arg = to_copy.arg;
      res = to_copy.res;
      dbg = to_copy.dbg;
      live = to_copy.live;
      affinity = Irrelevant;
    }
  in
  let next =
    propagate_debuginfo_to_next_insns next
      ~available_before:(available_after proto_insn)
  in
  { proto_insn with next; }

let to_list_rev insn =
  let rec to_list_rev insn acc =
    match insn.desc with
    | Lend -> acc
    | _ -> to_list_rev insn.next (insn :: acc)
  in
  to_list_rev insn []

let map_debuginfo insn ~f =
  List.fold_left (fun next insn ->
      { insn with
        dbg = f insn.dbg;
        next;
      })
    end_instr
    (to_list_rev insn)

(*
   Label the beginning of the given instruction sequence.
   - If the sequence starts with a branch, jump over it.
   - If the sequence is the end, (tail call position), just do nothing
*)

let get_label n = match n.desc with
    Lbranch lbl -> (lbl, n)
  | Llabel lbl -> (lbl, n)
  | Lend -> (-1, n)
  | _ ->
    let lbl = Cmm.new_label () in
    (lbl, cons_instr Next (Llabel lbl) n)

(* Check the fallthrough label *)
let check_label n = match n.desc with
  | Lbranch lbl -> lbl
  | Llabel lbl -> lbl
  | _ -> -1

(* Discard all instructions up to the next label.
   This function is to be called before adding a non-terminating
   instruction. *)

let rec discard_dead_code n =
  match n.desc with
    Lend -> n
  | Llabel _ -> n
(* Do not discard Lpoptrap/Lpushtrap or Istackoffset instructions,
   as this may cause a stack imbalance later during assembler generation. *)
  | Lpoptrap | Lpushtrap -> n
  | Lop(Istackoffset _) -> n
  | _ -> discard_dead_code n.next

(*
   Add a branch in front of a continuation.
   Discard dead code in the continuation.
   Does not insert anything if we're just falling through
   or if we jump to dead code after the end of function (lbl=-1)
*)

let add_branch lbl n =
  if lbl >= 0 then
    let n1 = discard_dead_code n in
    match n1.desc with
    | Llabel lbl1 when lbl1 = lbl -> n1
    | _ -> cons_instr Previous (Lbranch lbl) n1
  else
    discard_dead_code n

let try_depth = ref 0

(* Association list: exit handler -> (handler label, try-nesting factor) *)

let exit_label = ref []

let find_exit_label_try_depth k =
  try
    List.assoc k !exit_label
  with
  | Not_found -> Misc.fatal_error "Linearize.find_exit_label"

let find_exit_label k =
  let (label, t) = find_exit_label_try_depth k in
  assert(t = !try_depth);
  label

let is_next_catch n = match !exit_label with
| (n0,(_,t))::_  when n0=n && t = !try_depth -> true
| _ -> false

let local_exit k =
  snd (find_exit_label_try_depth k) = !try_depth

(* Linearize an instruction [i]: add it in front of the continuation [n] *)

let rec linear i n =
  match i.Mach.desc with
    Iend -> n
  | Iop(Itailcall_ind _ | Itailcall_imm _ as op) ->
      if not Config.spacetime then
        copy_instr (Lop op) i (discard_dead_code n)
      else
        copy_instr (Lop op) i (linear i.Mach.next n)
  | Iop(Imove | Ireload | Ispill)
    when i.Mach.arg.(0).loc = i.Mach.res.(0).loc ->
      linear i.Mach.next n
  | Iop (Iname_for_debugger _) ->
      (* These aren't needed any more, so to simplify matters, just drop
         them. *)
      linear i.Mach.next n
  | Iop op ->
      copy_instr (Lop op) i (linear i.Mach.next n)
  | Ireturn ->
      assert (Insn_debuginfo.available_across i.Mach.dbg = None);
      let n1 = copy_instr Lreturn i (discard_dead_code n) in
      if !Proc.contains_calls then begin
        (* Make sure that a value still in the "return address register"
           isn't marked as available at the return instruction if it has to
           be reloaded immediately prior. *)
        n1.dbg <-
          Insn_debuginfo.map_available_before n1.dbg
            ~f:(fun available_before ->
              RAS.map available_before
                ~f:(fun set ->
                  Reg_with_debug_info.Set.made_unavailable_by_clobber set
                    ~regs_clobbered:Proc.destroyed_at_reloadretaddr
                    ~register_class:Proc.register_class));
        cons_instr Next Lreloadretaddr n1
      end else begin
        n1
      end
  | Iifthenelse(test, ifso, ifnot) ->
      let n1 = linear i.Mach.next n in
      (* The following cases preserve existing availability information
         when inserting non-clobbering instructions (specifically
         [Lcondbranch]).  These instructions receive the same "available
         before" set as [i] because they are inserted at the start of the
         linearised equivalent of [i] (just like various other similar cases
         in this file).  Moreover, they also receive the same "available
         across" set as [i], because any register that is available across [i]
         (i.e. the whole if-then-else construct) must also be available across
         any sub-part of the linearised form of [i]. *)
      begin match (ifso.Mach.desc, ifnot.Mach.desc, n1.desc) with
        Iend, _, Lbranch lbl ->
          copy_instr (Lcondbranch(test, lbl)) i (linear ifnot n1)
      | _, Iend, Lbranch lbl ->
          copy_instr (Lcondbranch(invert_test test, lbl)) i (linear ifso n1)
      | Iexit nfail1, Iexit nfail2, _
            when is_next_catch nfail1 && local_exit nfail2 ->
          let lbl2 = find_exit_label nfail2 in
          copy_instr
            (Lcondbranch (invert_test test, lbl2)) i (linear ifso n1)
      | Iexit nfail, _, _ when local_exit nfail ->
          let n2 = linear ifnot n1
          and lbl = find_exit_label nfail in
          copy_instr (Lcondbranch(test, lbl)) i n2
      | _,  Iexit nfail, _ when local_exit nfail ->
          let n2 = linear ifso n1 in
          let lbl = find_exit_label nfail in
          copy_instr (Lcondbranch(invert_test test, lbl)) i n2
      | Iend, _, _ ->
          let (lbl_end, n2) = get_label n1 in
          copy_instr (Lcondbranch(test, lbl_end)) i (linear ifnot n2)
      | _,  Iend, _ ->
          let (lbl_end, n2) = get_label n1 in
          copy_instr (Lcondbranch(invert_test test, lbl_end)) i
                     (linear ifso n2)
      | _, _, _ ->
        (* Should attempt branch prediction here *)
          let (lbl_end, n2) = get_label n1 in
          let (lbl_else, nelse) = get_label (linear ifnot n2) in
          copy_instr (Lcondbranch(invert_test test, lbl_else)) i
            (linear ifso (add_branch lbl_end nelse))
      end
  | Iswitch(index, cases) ->
      let lbl_cases = Array.make (Array.length cases) 0 in
      let (lbl_end, n1) = get_label(linear i.Mach.next n) in
      let n2 = ref (discard_dead_code n1) in
      for i = Array.length cases - 1 downto 0 do
        let (lbl_case, ncase) =
                get_label(linear cases.(i) (add_branch lbl_end !n2)) in
        lbl_cases.(i) <- lbl_case;
        n2 := discard_dead_code ncase
      done;
      (* Switches with 1 and 2 branches have been eliminated earlier.
         Here, we do something for switches with 3 branches. *)
      if Array.length index = 3 then begin
        let fallthrough_lbl = check_label !n2 in
        let find_label n =
          let lbl = lbl_cases.(index.(n)) in
          if lbl = fallthrough_lbl then None else Some lbl in
        copy_instr (Lcondbranch3(find_label 0, find_label 1, find_label 2))
                   i !n2
      end else
        copy_instr (Lswitch(Array.map (fun n -> lbl_cases.(n)) index)) i !n2
  | Iloop body ->
      let lbl_head = Cmm.new_label() in
      let n1 = linear i.Mach.next n in
      let n1 = cons_instr Previous (Lbranch lbl_head) n1 in
      let n2 = linear body n1 in
      cons_instr Next (Llabel lbl_head) n2
  | Icatch(_rec_flag, handlers, body) ->
      let (lbl_end, n1) = get_label(linear i.Mach.next n) in
      (* CR mshinwell for pchambart:
         1. rename "io"
         2. Make sure the test cases cover the "Iend" cases too *)
      let labels_at_entry_to_handlers = List.map (fun (_nfail, handler) ->
          match handler.Mach.desc with
          | Iend -> lbl_end
          | _ -> Cmm.new_label ())
          handlers in
      let exit_label_add = List.map2
          (fun (nfail, _) lbl -> (nfail, (lbl, !try_depth)))
          handlers labels_at_entry_to_handlers in
      let previous_exit_label = !exit_label in
      exit_label := exit_label_add @ !exit_label;
      let n2 = List.fold_left2 (fun n (_nfail, handler) lbl_handler ->
          match handler.Mach.desc with
          | Iend -> n
          | _ -> cons_instr Next (Llabel lbl_handler) (linear handler n))
          n1 handlers labels_at_entry_to_handlers
      in
      let n3 = linear body (add_branch lbl_end n2) in
      exit_label := previous_exit_label;
      n3
  | Iexit nfail ->
      let lbl, t = find_exit_label_try_depth nfail in
      (* We need to re-insert dummy pushtrap (which won't be executed),
         so as to preserve stack offset during assembler generation.
         It would make sense to have a special pseudo-instruction
         only to inform the later pass about this stack offset
         (corresponding to N traps).
       *)
      let rec loop i tt =
        if t = tt then i
        else loop (cons_instr Next Lpushtrap i) (tt - 1)
      in
      let n1 = loop (linear i.Mach.next n) !try_depth in
      let rec loop i tt =
        if t = tt then i
        else loop (cons_instr Previous Lpoptrap i) (tt - 1)
      in
      loop (add_branch lbl n1) !try_depth
  | Itrywith(body, handler) ->
      let (lbl_join, n1) = get_label (linear i.Mach.next n) in
      incr try_depth;
      assert (i.Mach.arg = [| |] || Config.spacetime);
      let (lbl_body, n2) =
        let body = linear body (cons_instr Previous Lpoptrap n1) in
        get_label (cons_instr Next Lpushtrap ~arg:i.Mach.arg body)
      in
      decr try_depth;
      cons_instr Next (Lsetuptrap lbl_body) ~arg:i.Mach.arg
        (linear handler (add_branch lbl_join n2))
  | Iraise k ->
      copy_instr (Lraise k) i (discard_dead_code n)

let add_prologue first_insn =
  (* The prologue needs to come after any [Iname_for_debugger] operations that
     refer to parameters.  (Such operations always come in a contiguous
     block, cf. [Selectgen].) *)
  let rec skip_naming_ops (insn : instruction) : label * instruction =
    match insn.desc with
    | Lop (Iname_for_debugger _) ->
      let tailrec_entry_point_label, next = skip_naming_ops insn.next in
      tailrec_entry_point_label, { insn with next; }
    | _ ->
      let tailrec_entry_point_label = Cmm.new_label () in
      let tailrec_entry_point =
        { desc = Llabel tailrec_entry_point_label;
          next = insn;
          arg = [| |];
          res = [| |];
          dbg = insn.dbg;
          live = insn.live;
          affinity = Irrelevant;
        }
      in
      (* We expect [Lprologue] to expand to at least one instruction---as such,
         if no prologue is required, we avoid adding the instruction here.
         The reason is subtle: an empty expansion of [Lprologue] can cause
         two labels, one either side of the [Lprologue], to point at the same
         location.  This means that we lose the property (cf. [Coalesce_labels])
         that we can check if two labels point at the same location by
         comparing them for equality.  This causes trouble when the function
         whose prologue is in question lands at the top of the object file
         and we are emitting DWARF debugging information:
           foo_code_begin:
           foo:
           .L1:
           ; empty prologue
           .L2:
           ...
         If we were to emit a location list entry from L1...L2, not realising
         that they point at the same location, then the beginning and ending
         points of the range would be both equal to each other and (relative to
         "foo_code_begin") equal to zero.  This appears to confuse objdump,
         which seemingly misinterprets the entry as an end-of-list entry
         (which is encoded with two zero words), then complaining about a
         "hole in location list" (as it ignores any remaining list entries
         after the misinterpreted entry). *)
      if Proc.prologue_required () then
        let prologue =
          { desc = Lprologue;
            next = tailrec_entry_point;
            arg = [| |];
            res = [| |];
            dbg = tailrec_entry_point.dbg;
            (* CR mshinwell: live sets here and above should be empty? *)
            live = tailrec_entry_point.live;
            affinity = Irrelevant;
          }
        in
        tailrec_entry_point_label, prologue
      else
        tailrec_entry_point_label, tailrec_entry_point
  in
  skip_naming_ops first_insn

let fundecl f =
  let fun_tailrec_entry_point_label, fun_body =
    add_prologue (linear f.Mach.fun_body end_instr)
  in
  { fun_name = f.Mach.fun_name;
    fun_body;
    fun_fast = not (List.mem Cmm.Reduce_code_size f.Mach.fun_codegen_options);
    fun_dbg  = f.Mach.fun_dbg;
    fun_phantom_lets = f.Mach.fun_phantom_lets;
    fun_arity = Array.length f.Mach.fun_args;
    fun_spacetime_shape = f.Mach.fun_spacetime_shape;
    fun_tailrec_entry_point_label;
  }

let map_debuginfo_fundecl fundecl ~f ~f_function =
  { fundecl with
    fun_body = map_debuginfo fundecl.fun_body ~f;
    fun_dbg = f_function fundecl.fun_dbg;
  }
