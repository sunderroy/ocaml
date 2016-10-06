(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           *)
(*                                                                        *)
(*   Copyright 1996 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(* Selection of pseudo-instructions, assignment of pseudo-registers,
   sequentialization. *)

open Misc
open Cmm
open Reg
open Mach

type environment = {
  idents : (Ident.t, Reg.t array * Clambda.ulet_provenance option) Tbl.t;
  phantom_idents : Ident.Set.t;
}

(* Infer the type of the result of an operation *)

let oper_result_type = function
    Capply ty -> ty
  | Cextcall(_s, ty, _alloc, _) -> ty
  | Cload c ->
      begin match c with
      | Word_val -> typ_val
      | Single | Double | Double_u -> typ_float
      | _ -> typ_int
      end
  | Calloc -> typ_val
  | Cstore (_c, _) -> typ_void
  | Caddi | Csubi | Cmuli | Cmulhi | Cdivi | Cmodi |
    Cand | Cor | Cxor | Clsl | Clsr | Casr |
    Ccmpi _ | Ccmpa _ | Ccmpf _ -> typ_int
  | Caddv -> typ_val
  | Cadda -> typ_addr
  | Cnegf | Cabsf | Caddf | Csubf | Cmulf | Cdivf -> typ_float
  | Cfloatofint -> typ_float
  | Cintoffloat -> typ_int
  | Craise _ -> typ_void
  | Ccheckbound -> typ_void

(* Infer the size in bytes of the result of a simple expression *)

let size_expr env exp =
  let rec size localenv = function
      Cconst_int _ | Cconst_natint _ -> Arch.size_int
    | Cconst_symbol _ | Cconst_pointer _ | Cconst_natpointer _ ->
        Arch.size_addr
    | Cconst_float _ -> Arch.size_float
    | Cblockheader _ -> Arch.size_int
    | Cvar id ->
        begin try
          Tbl.find id localenv
        with Not_found ->
        try
          let regs, _ = Tbl.find id env.idents in
          size_machtype (Array.map (fun r -> r.typ) regs)
        with Not_found ->
          fatal_error("Selection.size_expr: unbound var " ^
                      Ident.unique_name id)
        end
    | Ctuple el ->
        List.fold_right (fun e sz -> size localenv e + sz) el 0
    | Cop(op, _, _) ->
        size_machtype(oper_result_type op)
    | Clet(id, _, arg, body) ->
        size (Tbl.add id (size localenv arg) localenv) body
    | Csequence(_e1, e2) ->
        size localenv e2
    | _ ->
        fatal_error "Selection.size_expr"
  in size Tbl.empty exp

(* Swap the two arguments of an integer comparison *)

let swap_intcomp = function
    Isigned cmp -> Isigned(swap_comparison cmp)
  | Iunsigned cmp -> Iunsigned(swap_comparison cmp)

(* Naming of registers *)

let all_regs_anonymous rv =
  try
    for i = 0 to Array.length rv - 1 do
      if not (Reg.anonymous rv.(i)) then raise Exit
    done;
    true
  with Exit ->
    false

let name_regs id rv =
  if Array.length rv = 1 then
    rv.(0).raw_name <- Raw_name.create_from_ident id
  else
    for i = 0 to Array.length rv - 1 do
      rv.(i).raw_name <- Raw_name.create_from_ident id;
      rv.(i).part <- Some i
    done

let maybe_emit_naming_op ~env ~bound_name seq regs =
  match bound_name with
  | None -> ()
  | Some (bound_name, provenance) ->
    let naming_op =
      Iname_for_debugger { ident = bound_name; provenance;
        which_parameter = None; is_assignment = false; }
    in
    seq#insert_debug env (Iop naming_op) Debuginfo.none regs [| |]

(* "Join" two instruction sequences, making sure they return their results
   in the same registers.

   We also need some special handling relating to names. [Spill] may add spill
   code at the end of code paths just before join points. If the result of the
   (e.g.) conditional is [let]-bound then there will also be a naming operation
   after the join point. However this operation would come after any such spill
   code and cause the spilled registers not to be named. To avoid this, we
   explicitly add the naming operations here after each move we insert.  (They
   are inserted after each move to ensure that the code in [Spill] that
   looks for naming operations recognises them correctly.)
*)

let join env opt_r1 seq1 opt_r2 seq2 ~bound_name =
  let maybe_emit_naming_op = maybe_emit_naming_op ~env ~bound_name in
  match (opt_r1, opt_r2) with
    (None, _) -> opt_r2
  | (_, None) -> opt_r1
  | (Some r1, Some r2) ->
      let l1 = Array.length r1 in
      assert (l1 = Array.length r2);
      let r = Array.make l1 Reg.dummy in
      for i = 0 to l1-1 do
        if Reg.anonymous r1.(i)
          && Cmm.ge_component r1.(i).typ r2.(i).typ
        then begin
          r.(i) <- r1.(i);
          seq2#insert_move env r2.(i) r1.(i);
          maybe_emit_naming_op seq2 [| r1.(i) |]
        end else if Reg.anonymous r2.(i)
          && Cmm.ge_component r2.(i).typ r1.(i).typ
        then begin
          r.(i) <- r2.(i);
          seq1#insert_move env r1.(i) r2.(i);
          maybe_emit_naming_op seq1 [| r2.(i) |]
        end else begin
          let typ = Cmm.lub_component r1.(i).typ r2.(i).typ in
          r.(i) <- Reg.create typ;
          seq1#insert_move env r1.(i) r.(i);
          maybe_emit_naming_op seq1 [| r.(i) |];
          seq2#insert_move env r2.(i) r.(i);
          maybe_emit_naming_op seq2 [| r.(i) |]
        end
      done;
      Some r

(* Same, for N branches *)

let join_array env rs ~bound_name =
  let maybe_emit_naming_op = maybe_emit_naming_op ~env ~bound_name in
  let some_res = ref None in
  for i = 0 to Array.length rs - 1 do
    let (r, _) = rs.(i) in
    match r with
    | None -> ()
    | Some r ->
      match !some_res with
      | None -> some_res := Some (r, Array.map (fun r -> r.typ) r)
      | Some (r', types) ->
        let types =
          Array.map2 (fun r typ -> Cmm.lub_component r.typ typ) r types
        in
        some_res := Some (r', types)
  done;
  match !some_res with
    None -> None
  | Some (template, types) ->
      let size_res = Array.length template in
      let res = Array.make size_res Reg.dummy in
      for i = 0 to size_res - 1 do
        res.(i) <- Reg.create types.(i)
      done;
      for i = 0 to Array.length rs - 1 do
        let (r, s) = rs.(i) in
        match r with
          None -> ()
        | Some r ->
          s#insert_moves env r res;
          maybe_emit_naming_op s res
      done;
      Some res

(* Registers for catch constructs *)
let catch_regs = ref []

(* Name of function being compiled *)
let current_function_name = ref ""

(* All phantom lets seen in the current function *)
let phantom_lets = Ident.Tbl.create 42

(* Phantom lets that have been deleted by this pass *)
let dead_phantom_lets = ref Ident.Set.empty

(* The default instruction selection class *)

class virtual selector_generic = object (self)

(* Says if an expression is "simple". A "simple" expression has no
   side-effects and its execution can be delayed until its value
   is really needed. In the case of e.g. an [alloc] instruction,
   the non-simple arguments are computed in right-to-left order
   first, then the block is allocated, then the simple arguments are
   evaluated and stored. *)

method is_simple_expr = function
    Cconst_int _ -> true
  | Cconst_natint _ -> true
  | Cconst_float _ -> true
  | Cconst_symbol _ -> true
  | Cconst_pointer _ -> true
  | Cconst_natpointer _ -> true
  | Cblockheader _ -> true
  | Cvar _ -> true
  | Ctuple el -> List.for_all self#is_simple_expr el
  | Clet(_id, _, arg, body) ->
      self#is_simple_expr arg && self#is_simple_expr body
  | Csequence(e1, e2) -> self#is_simple_expr e1 && self#is_simple_expr e2
  | Cop(op, args, _) ->
      begin match op with
        (* The following may have side effects *)
      | Capply _ | Cextcall _ | Calloc | Cstore _ | Craise _ -> false
        (* The remaining operations are simple if their args are *)
      | _ ->
          List.for_all self#is_simple_expr args
      end
  | _ -> false

(* Says whether an integer constant is a suitable immediate argument *)

method virtual is_immediate : int -> bool

(* Selection of addressing modes *)

method virtual select_addressing :
  Cmm.memory_chunk -> Cmm.expression -> Arch.addressing_mode * Cmm.expression

(* Default instruction selection for stores (of words) *)

method select_store is_assign addr arg =
  (Istore(Word_val, addr, is_assign), arg)

(* call marking methods, documented in selectgen.mli *)

method mark_call =
  Proc.contains_calls := true

method mark_tailcall = ()

method mark_c_tailcall = ()

method mark_instr = function
  | Iop (Icall_ind _ | Icall_imm _ | Iextcall _) ->
      self#mark_call
  | Iop (Itailcall_ind _ | Itailcall_imm _) ->
      self#mark_tailcall
  | Iop (Ialloc _) ->
      self#mark_call (* caml_alloc*, caml_garbage_collection *)
  | Iop (Iintop (Icheckbound _) | Iintop_imm(Icheckbound _, _)) ->
      self#mark_c_tailcall (* caml_ml_array_bound_error *)
  | Iraise raise_kind ->
    begin match raise_kind with
      | Cmm.Raise_notrace -> ()
      | Cmm.Raise_withtrace ->
          (* PR#6239 *)
          (* caml_stash_backtrace; we #mark_call rather than
             #mark_c_tailcall to get a good stack backtrace *)
          self#mark_call
    end
  | Itrywith _ ->
    self#mark_call
  | _ -> ()

(* Default instruction selection for operators *)

method select_allocation words =
  Ialloc { words; spacetime_index = 0; label_after_call_gc = None; }
method select_allocation_args _env = [| |]

method select_checkbound () =
  Icheckbound { spacetime_index = 0; label_after_error = None; }
method select_checkbound_extra_args () = []

method select_operation op args =
  match (op, args) with
  | (Capply _, Cconst_symbol func :: rem) ->
    let label_after = Cmm.new_label () in
    (Icall_imm { func; label_after; }, rem)
  | (Capply _, _) ->
    let label_after = Cmm.new_label () in
    (Icall_ind { label_after; }, args)
  | (Cextcall(func, _ty, alloc, label_after), _) ->
    let label_after =
      match label_after with
      | None -> Cmm.new_label ()
      | Some label_after -> label_after
    in
    Iextcall { func; alloc; label_after; }, args
  | (Cload chunk, [arg]) ->
      let (addr, eloc) = self#select_addressing chunk arg in
      (Iload(chunk, addr), [eloc])
  | (Cstore (chunk, init), [arg1; arg2]) ->
      let (addr, eloc) = self#select_addressing chunk arg1 in
      let is_assign =
        match init with
        | Lambda.Initialization -> false
        | Lambda.Assignment -> true
      in
      if chunk = Word_int || chunk = Word_val then begin
        let (op, newarg2) = self#select_store is_assign addr arg2 in
        (op, [newarg2; eloc])
      end else begin
        (Istore(chunk, addr, is_assign), [arg2; eloc])
        (* Inversion addr/datum in Istore *)
      end
  | (Calloc, _) -> (self#select_allocation 0), args
  | (Caddi, _) -> self#select_arith_comm Iadd args
  | (Csubi, _) -> self#select_arith Isub args
  | (Cmuli, _) -> self#select_arith_comm Imul args
  | (Cmulhi, _) -> self#select_arith_comm Imulh args
  | (Cdivi, _) -> (Iintop Idiv, args)
  | (Cmodi, _) -> (Iintop Imod, args)
  | (Cand, _) -> self#select_arith_comm Iand args
  | (Cor, _) -> self#select_arith_comm Ior args
  | (Cxor, _) -> self#select_arith_comm Ixor args
  | (Clsl, _) -> self#select_shift Ilsl args
  | (Clsr, _) -> self#select_shift Ilsr args
  | (Casr, _) -> self#select_shift Iasr args
  | (Ccmpi comp, _) -> self#select_arith_comp (Isigned comp) args
  | (Caddv, _) -> self#select_arith_comm Iadd args
  | (Cadda, _) -> self#select_arith_comm Iadd args
  | (Ccmpa comp, _) -> self#select_arith_comp (Iunsigned comp) args
  | (Cnegf, _) -> (Inegf, args)
  | (Cabsf, _) -> (Iabsf, args)
  | (Caddf, _) -> (Iaddf, args)
  | (Csubf, _) -> (Isubf, args)
  | (Cmulf, _) -> (Imulf, args)
  | (Cdivf, _) -> (Idivf, args)
  | (Cfloatofint, _) -> (Ifloatofint, args)
  | (Cintoffloat, _) -> (Iintoffloat, args)
  | (Ccheckbound, _) ->
    let extra_args = self#select_checkbound_extra_args () in
    let op = self#select_checkbound () in
    self#select_arith op (args @ extra_args)
  | _ -> fatal_error "Selection.select_oper"

method private select_arith_comm op = function
    [arg; Cconst_int n] when self#is_immediate n ->
      (Iintop_imm(op, n), [arg])
  | [arg; Cconst_pointer n] when self#is_immediate n ->
      (Iintop_imm(op, n), [arg])
  | [Cconst_int n; arg] when self#is_immediate n ->
      (Iintop_imm(op, n), [arg])
  | [Cconst_pointer n; arg] when self#is_immediate n ->
      (Iintop_imm(op, n), [arg])
  | args ->
      (Iintop op, args)

method private select_arith op = function
    [arg; Cconst_int n] when self#is_immediate n ->
      (Iintop_imm(op, n), [arg])
  | [arg; Cconst_pointer n] when self#is_immediate n ->
      (Iintop_imm(op, n), [arg])
  | args ->
      (Iintop op, args)

method private select_shift op = function
    [arg; Cconst_int n] when n >= 0 && n < Arch.size_int * 8 ->
      (Iintop_imm(op, n), [arg])
  | args ->
      (Iintop op, args)

method private select_arith_comp cmp = function
    [arg; Cconst_int n] when self#is_immediate n ->
      (Iintop_imm(Icomp cmp, n), [arg])
  | [arg; Cconst_pointer n] when self#is_immediate n ->
      (Iintop_imm(Icomp cmp, n), [arg])
  | [Cconst_int n; arg] when self#is_immediate n ->
      (Iintop_imm(Icomp(swap_intcomp cmp), n), [arg])
  | [Cconst_pointer n; arg] when self#is_immediate n ->
      (Iintop_imm(Icomp(swap_intcomp cmp), n), [arg])
  | args ->
      (Iintop(Icomp cmp), args)

(* Instruction selection for conditionals *)

method select_condition = function
    Cop(Ccmpi cmp, [arg1; Cconst_int n], _) when self#is_immediate n ->
      (Iinttest_imm(Isigned cmp, n), arg1)
  | Cop(Ccmpi cmp, [Cconst_int n; arg2], _) when self#is_immediate n ->
      (Iinttest_imm(Isigned(swap_comparison cmp), n), arg2)
  | Cop(Ccmpi cmp, [arg1; Cconst_pointer n], _) when self#is_immediate n ->
      (Iinttest_imm(Isigned cmp, n), arg1)
  | Cop(Ccmpi cmp, [Cconst_pointer n; arg2], _) when self#is_immediate n ->
      (Iinttest_imm(Isigned(swap_comparison cmp), n), arg2)
  | Cop(Ccmpi cmp, args, _) ->
      (Iinttest(Isigned cmp), Ctuple args)
  | Cop(Ccmpa cmp, [arg1; Cconst_pointer n], _) when self#is_immediate n ->
      (Iinttest_imm(Iunsigned cmp, n), arg1)
  | Cop(Ccmpa cmp, [arg1; Cconst_int n], _) when self#is_immediate n ->
      (Iinttest_imm(Iunsigned cmp, n), arg1)
  | Cop(Ccmpa cmp, [Cconst_pointer n; arg2], _) when self#is_immediate n ->
      (Iinttest_imm(Iunsigned(swap_comparison cmp), n), arg2)
  | Cop(Ccmpa cmp, [Cconst_int n; arg2], _) when self#is_immediate n ->
      (Iinttest_imm(Iunsigned(swap_comparison cmp), n), arg2)
  | Cop(Ccmpa cmp, args, _) ->
      (Iinttest(Iunsigned cmp), Ctuple args)
  | Cop(Ccmpf cmp, args, _) ->
      (Ifloattest(cmp, false), Ctuple args)
  | Cop(Cand, [arg; Cconst_int 1], _) ->
      (Ioddtest, arg)
  | arg ->
      (Itruetest, arg)

(* Lowering of phantom lets *)

method private lower_phantom_let
      ~(provenance : Clambda.ulet_provenance option)
      ~(defining_expr : Clambda.uphantom_defining_expr option) =
  match defining_expr with
  | None ->
    (* The defining expression of this phantom let is never
        going to be available, perhaps because it was some expression
        that is not currently supported. *)
    None
  | Some defining_expr ->
    let defining_expr =
      let module C = Clambda in
      match defining_expr with
      | C.Uphantom_const (C.Uconst_ref (symbol, _defining_expr)) ->
        (* It's not actually a "fun_name", but the mangling is the same.
            This should go away if we switch to [Symbol.t] everywhere. *)
        let symbol = Name_laundry.fun_name_to_symbol symbol in
        Some (Mach.Iphantom_const_symbol symbol)
      | C.Uphantom_read_symbol_field (
          C.Uconst_ref (symbol, _defining_expr), field) ->
        let symbol = Name_laundry.fun_name_to_symbol symbol in
        Some (Mach.Iphantom_read_symbol_field (symbol, field))
      | C.Uphantom_read_symbol_field _ ->
        Misc.fatal_errorf "Selectgen.lower_phantom_let: unknown Clambda \
          constant pattern for Uphantom_read_symbol_field"
      | C.Uphantom_const (C.Uconst_int i) | C.Uphantom_const (C.Uconst_ptr i) ->
        Some (Mach.Iphantom_const_int i)
      | C.Uphantom_var defining_ident ->
        if Ident.Set.mem defining_ident !dead_phantom_lets then
          None
        else
          Some (Mach.Iphantom_var defining_ident)
      | C.Uphantom_read_var_field (defining_ident, field) ->
        if Ident.Set.mem defining_ident !dead_phantom_lets then
          None
        else
          Some (Mach.Iphantom_read_var_field (defining_ident, field))
      | C.Uphantom_offset_var_field (defining_ident, offset_in_words) ->
        if Ident.Set.mem defining_ident !dead_phantom_lets then
          None
        else
          Some (Mach.Iphantom_offset_var (defining_ident, offset_in_words))
      | C.Uphantom_block { tag; fields; } ->
        let fields =
          List.map (fun field ->
              if Ident.Set.mem field !dead_phantom_lets then None
              else Some field)
            fields
        in
        Some (Mach.Iphantom_block { tag; fields; })
    in
    match defining_expr with
    | None -> None
    | Some defining_expr -> Some (provenance, defining_expr)

method private env_for_phantom_let env ~ident ~provenance ~defining_expr =
  (* Information about phantom lets is split at this stage:
     1. The phantom identifiers in scope are recorded in the environment
        and subsequently tagged onto Mach instructions.
     2. The defining expressions are recorded separately. *)
  match self#lower_phantom_let ~provenance ~defining_expr with
  | None ->
    dead_phantom_lets := Ident.Set.add ident !dead_phantom_lets;
    env
  | Some (provenance, defining_expr) ->
    Ident.Tbl.add phantom_lets ident (provenance, defining_expr);
    let phantom_idents = Ident.Set.add ident env.phantom_idents in
    { env with phantom_idents; }

(* Return an array of fresh registers of the given type.
   Normally implemented as Reg.createv, but some
   ports (e.g. Arm) can override this definition to store float values
   in pairs of integer registers. *)

method regs_for tys = Reg.createv tys

(* Buffering of instruction sequences *)

val mutable instr_seq = dummy_instr

method insert_debug env desc dbg arg res =
  instr_seq <- instr_cons_debug desc arg res dbg
    ~phantom_available_before:env.phantom_idents instr_seq

method insert env desc arg res =
  instr_seq <- instr_cons desc arg res
    ~phantom_available_before:env.phantom_idents instr_seq

method extract_core ~end_instr =
  let rec extract res i =
    if i == dummy_instr
    then res
    else extract {i with next = res} i.next in
  extract end_instr instr_seq

method extract =
  self#extract_core ~end_instr:(end_instr ())

(* Insert a sequence of moves from one pseudoreg set to another. *)

method insert_move env src dst =
  if src.stamp <> dst.stamp then
    self#insert env (Iop Imove) [|src|] [|dst|]

method insert_moves env src dst =
  for i = 0 to min (Array.length src) (Array.length dst) - 1 do
    self#insert_move env src.(i) dst.(i)
  done

(* Adjust the types of destination pseudoregs for a [Cassign] assignment.
   The type inferred at [let] binding might be [Int] while we assign
   something of type [Val] (PR#6501). *)

method adjust_type src dst =
  let ts = src.typ and td = dst.typ in
  if ts <> td then
    match ts, td with
    | Val, Int -> dst.typ <- Val
    | Int, Val -> ()
    | _, _ -> fatal_error("Selection.adjust_type: bad assignment to "
                                                           ^ Reg.name dst)

method adjust_types src dst =
  for i = 0 to min (Array.length src) (Array.length dst) - 1 do
    self#adjust_type src.(i) dst.(i)
  done

(* Insert moves and stack offsets for function arguments and results *)

method insert_move_args env arg loc stacksize =
  if stacksize <> 0 then begin
    self#insert env (Iop(Istackoffset stacksize)) [||] [||]
  end;
  self#insert_moves env arg loc

method insert_move_results env loc res stacksize =
  if stacksize <> 0 then begin
    self#insert env (Iop(Istackoffset(-stacksize))) [||] [||]
  end;
  self#insert_moves env loc res

(* Add an Iop opcode. Can be overridden by processor description
   to insert moves before and after the operation, i.e. for two-address
   instructions, or instructions using dedicated registers. *)

method insert_op_debug env op dbg rs rd =
  self#insert_debug env (Iop op) dbg rs rd;
  rd

method insert_op env op rs rd =
  self#insert_op_debug env op Debuginfo.none rs rd

method emit_blockheader env n _dbg =
  let r = self#regs_for typ_int in
  Some(self#insert_op env (Iconst_int n) [||] r)

method about_to_emit_call _env _insn _arg = None

(* Prior to a function call, update the Spacetime node hole pointer hard
   register. *)

method private maybe_emit_spacetime_move env ~spacetime_reg =
  Misc.Stdlib.Option.iter (fun reg ->
      self#insert_moves env reg [| Proc.loc_spacetime_node_hole |])
    spacetime_reg

(* Add the instructions for the given expression
   at the end of the self sequence *)

method emit_expr env exp ~bound_name =
  match exp with
    Cconst_int n ->
      let r = self#regs_for typ_int in
      Some(self#insert_op env (Iconst_int(Nativeint.of_int n)) [||] r)
  | Cconst_natint n ->
      let r = self#regs_for typ_int in
      Some(self#insert_op env (Iconst_int n) [||] r)
  | Cconst_float n ->
      let r = self#regs_for typ_float in
      Some(self#insert_op env (Iconst_float (Int64.bits_of_float n)) [||] r)
  | Cconst_symbol n ->
      let r = self#regs_for typ_val in
      Some(self#insert_op env (Iconst_symbol n) [||] r)
  | Cconst_pointer n ->
      let r = self#regs_for typ_val in  (* integer as Caml value *)
      Some(self#insert_op env (Iconst_int(Nativeint.of_int n)) [||] r)
  | Cconst_natpointer n ->
      let r = self#regs_for typ_val in  (* integer as Caml value *)
      Some(self#insert_op env (Iconst_int n) [||] r)
  | Cblockheader(n, dbg) ->
      self#emit_blockheader env n dbg
  | Cvar v ->
      begin try
        Some(fst(Tbl.find v env.idents))
      with Not_found ->
        fatal_error("Selection.emit_expr: unbound var " ^ Ident.unique_name v)
      end
  | Clet(v, provenance, e1, e2) ->
      begin match self#emit_expr env e1 ~bound_name:(Some (v, provenance)) with
        None -> None
      | Some r1 ->
        self#emit_expr (self#bind_let env v r1 ~provenance) e2 ~bound_name
      end
  | Cphantom_let (ident, provenance, defining_expr, body) ->
      let env =
        self#env_for_phantom_let env ~ident ~provenance ~defining_expr
      in
      self#emit_expr env body ~bound_name
  | Cassign(v, e1) ->
      let rv, provenance =
        try
          Tbl.find v env.idents
        with Not_found ->
          fatal_error ("Selection.emit_expr: unbound var " ^ Ident.name v) in
      begin match self#emit_expr env e1 ~bound_name:None with
        None -> None
      | Some r1 ->
        let naming_op =
          Iname_for_debugger { ident = v; provenance;
            which_parameter = None; is_assignment = true; }
        in
        self#insert_debug env (Iop naming_op) Debuginfo.none r1 [| |];
        self#adjust_types r1 rv; self#insert_moves env r1 rv; Some [||]
      end
  | Ctuple [] ->
      Some [||]
  | Ctuple exp_list ->
      begin match self#emit_parts_list env exp_list with
        None -> None
      | Some(simple_list, ext_env) ->
          Some(self#emit_tuple ext_env simple_list)
      end
  | Cop(Craise k, [arg], dbg) ->
      begin match self#emit_expr env arg ~bound_name:None with
        None -> None
      | Some r1 ->
          let rd = [|Proc.loc_exn_bucket|] in
          self#insert env (Iop Imove) r1 rd;
          self#insert_debug env (Iraise k) dbg rd [||];
          None
      end
  | Cop(Ccmpf _, _, _) ->
      self#emit_expr env (Cifthenelse(exp, Cconst_int 1, Cconst_int 0))
        ~bound_name
  | Cop(op, args, dbg) ->
      begin match self#emit_parts_list env args with
        None -> None
      | Some(simple_args, env) ->
          let add_naming_op_for_bound_name regs =
            match bound_name with
            | None -> ()
            | Some (bound_name, provenance) ->
              let naming_op =
                Iname_for_debugger { ident = bound_name; provenance;
                  which_parameter = None; is_assignment = false; }
              in
              self#insert_debug env (Iop naming_op) Debuginfo.none regs [| |]
          in
          let ty = oper_result_type op in
          let (new_op, new_args) = self#select_operation op simple_args in
          match new_op with
            Icall_ind _ ->
              let r1 = self#emit_tuple env new_args in
              let rarg = Array.sub r1 1 (Array.length r1 - 1) in
              let rd = self#regs_for ty in
              let (loc_arg, stack_ofs) = Proc.loc_arguments rarg in
              let loc_res = Proc.loc_results rd in
              let spacetime_reg =
                self#about_to_emit_call env (Iop new_op) [| r1.(0) |]
              in
              self#insert_move_args env rarg loc_arg stack_ofs;
              self#maybe_emit_spacetime_move env ~spacetime_reg;
              self#insert_debug env (Iop new_op) dbg
                          (Array.append [|r1.(0)|] loc_arg) loc_res;
              (* The destination registers (as per the procedure calling
                 convention) need to be named right now, otherwise the result
                 of the function call may be unavailable in the debugger
                 immediately after the call.  This is what necessitates the
                 presence of the [bound_name] argument to [emit_expr]. *)
              add_naming_op_for_bound_name loc_res;
              self#insert_move_results env loc_res rd stack_ofs;
              Some rd
          | Icall_imm _ ->
              let r1 = self#emit_tuple env new_args in
              let rd = self#regs_for ty in
              let (loc_arg, stack_ofs) = Proc.loc_arguments r1 in
              let loc_res = Proc.loc_results rd in
              let spacetime_reg =
                self#about_to_emit_call env (Iop new_op) [| |]
              in
              self#insert_move_args env r1 loc_arg stack_ofs;
              self#maybe_emit_spacetime_move env ~spacetime_reg;
              self#insert_debug env (Iop new_op) dbg loc_arg loc_res;
              add_naming_op_for_bound_name loc_res;
              self#insert_move_results env loc_res rd stack_ofs;
              Some rd
          | Iextcall _ ->
              let spacetime_reg =
                self#about_to_emit_call env (Iop new_op) [| |]
              in
              let (loc_arg, stack_ofs) = self#emit_extcall_args env new_args in
              self#maybe_emit_spacetime_move env ~spacetime_reg;
              let rd = self#regs_for ty in
              let loc_res =
                self#insert_op_debug env new_op dbg
                  loc_arg (Proc.loc_external_results rd) in
              add_naming_op_for_bound_name loc_res;
              self#insert_move_results env loc_res rd stack_ofs;
              Some rd
          | Ialloc { words = _; spacetime_index; label_after_call_gc; } ->
              let rd = self#regs_for typ_val in
              let size = size_expr env (Ctuple new_args) in
              let op =
                Ialloc { words = size; spacetime_index; label_after_call_gc; }
              in
              let args = self#select_allocation_args env in
              self#insert_debug env (Iop op) dbg args rd;
              self#emit_stores env new_args rd;
              Some rd
          | op ->
              let r1 = self#emit_tuple env new_args in
              let rd = self#regs_for ty in
              Some (self#insert_op_debug env op dbg r1 rd)
      end
  | Csequence(e1, e2) ->
      begin match self#emit_expr env e1 ~bound_name:None with
        None -> None
      | Some _ -> self#emit_expr env e2 ~bound_name
      end
  | Cifthenelse(econd, eif, eelse) ->
      let (cond, earg) = self#select_condition econd in
      begin match self#emit_expr env earg ~bound_name:None with
        None -> None
      | Some rarg ->
          let (rif, sif) = self#emit_sequence env eif ~bound_name in
          let (relse, selse) = self#emit_sequence env eelse ~bound_name in
          let r = join env rif sif relse selse ~bound_name in
          self#insert env (Iifthenelse(cond, sif#extract, selse#extract))
                      rarg [||];
          r
      end
  | Cswitch(dbg, esel, index, ecases) ->
      begin match self#emit_expr env esel ~bound_name:None with
        None -> None
      | Some rsel ->
          let rscases =
            Array.map (fun case -> self#emit_sequence env case ~bound_name)
              ecases
          in
          let r = join_array env rscases ~bound_name in
          self#insert_debug env
            (Iswitch(index, Array.map (fun (_, s) -> s#extract) rscases))
            dbg rsel [||];
          r
      end
  | Cloop(ebody) ->
      let (_rarg, sbody) = self#emit_sequence env ebody ~bound_name:None in
      self#insert env (Iloop(sbody#extract)) [||] [||];
      Some [||]
  | Ccatch(nfail, ids, e1, e2) ->
      let rs =
        List.map
          (fun (id, _provenance) ->
            let r = self#regs_for typ_val in name_regs id r; r)
          ids in
      catch_regs := (nfail, Array.concat rs) :: !catch_regs ;
      let (r1, s1) = self#emit_sequence env e1 ~bound_name:None in
      catch_regs := List.tl !catch_regs ;
      let ids_and_rs = List.combine ids rs in
      let new_env_idents =
        List.fold_left
        (fun idents ((id, provenance), r) ->
          Tbl.add id (r, provenance) idents)
        env.idents ids_and_rs in
      let new_env = { env with idents = new_env_idents; } in
      let (r2, s2) =
        self#emit_sequence new_env e2 ~bound_name ~at_start:(fun seq ->
          List.iter (fun ((ident, provenance), r) ->
              let naming_op =
                Iname_for_debugger { ident; provenance;
                  which_parameter = None; is_assignment = false; }
              in
              seq#insert_debug env (Iop naming_op) Debuginfo.none r [| |])
            ids_and_rs)
      in
      let r = join env r1 s1 r2 s2 ~bound_name in
      self#insert env (Icatch(nfail, s1#extract, s2#extract)) [||] [||];
      r
  | Cexit (nfail,args) ->
      begin match self#emit_parts_list env args with
        None -> None
      | Some (simple_list, ext_env) ->
          let src = self#emit_tuple ext_env simple_list in
          let dest =
            try List.assoc nfail !catch_regs
            with Not_found ->
              Misc.fatal_error
                ("Selectgen.emit_expr, on exit("^string_of_int nfail^")") in
          self#insert_moves env src dest ;
          self#insert env (Iexit nfail) [||] [||];
          None
      end
  | Ctrywith(e1, v, provenance, e2) ->
      let (r1, s1) = self#emit_sequence env e1 ~bound_name in
      let rv = self#regs_for typ_val in
      let (r2, s2) =
        let env =
          { env with idents = Tbl.add v (rv, provenance) env.idents; }
        in
        self#emit_sequence env e2 ~bound_name ~at_start:(fun seq ->
          let naming_op =
            Iname_for_debugger { ident = v; provenance;
              which_parameter = None; is_assignment = false; }
          in
          seq#insert_debug env (Iop naming_op) Debuginfo.none rv [| |])
      in
      let r = join env r1 s1 r2 s2 ~bound_name in
      let s2 = s2#extract in
      self#insert env
        (Itrywith(s1#extract,
                  instr_cons (Iop Imove) [|Proc.loc_exn_bucket|] rv
                    ~phantom_available_before:s2.phantom_available_before s2))
        [||] [||];
      r

method private emit_sequence ?at_start env exp ~bound_name =
  let s = {< instr_seq = dummy_instr >} in
  begin match at_start with
  | None -> ()
  | Some f -> f s
  end;
  let r = s#emit_expr env exp ~bound_name in
  (r, s)

method private bind_let env ident r1 ~provenance =
  let result =
    if all_regs_anonymous r1 then begin
      name_regs ident r1;
      { env with idents = Tbl.add ident (r1, provenance) env.idents; }
    end else begin
      let rv = Reg.createv_like r1 in
      name_regs ident rv;
      self#insert_moves env r1 rv;
      { env with idents = Tbl.add ident (rv, provenance) env.idents; }
    end
  in
  let naming_op =
    Iname_for_debugger { ident; which_parameter = None; provenance;
      is_assignment = false; }
  in
  self#insert_debug env (Iop naming_op) Debuginfo.none r1 [| |];
  result

method private emit_parts env exp =
  if self#is_simple_expr exp then
    Some (exp, env)
  else begin
    match self#emit_expr env exp ~bound_name:None with
      None -> None
    | Some r ->
        if Array.length r = 0 then
          Some (Ctuple [], env)
        else begin
          (* The normal case *)
          let id = Ident.create "bind" in
          if all_regs_anonymous r then
            (* r is an anonymous, unshared register; use it directly *)
            Some (Cvar id,
              { env with idents = Tbl.add id (r, None) env.idents; })
          else begin
            (* Introduce a fresh temp to hold the result *)
            let tmp = Reg.createv_like r in
            self#insert_moves env r tmp;
            Some (Cvar id,
              { env with idents = Tbl.add id (tmp, None) env.idents; })
          end
        end
  end

method private emit_parts_list env exp_list =
  match exp_list with
    [] -> Some ([], env)
  | exp :: rem ->
      (* This ensures right-to-left evaluation, consistent with the
         bytecode compiler *)
      match self#emit_parts_list env rem with
        None -> None
      | Some(new_rem, new_env) ->
          match self#emit_parts new_env exp with
            None -> None
          | Some(new_exp, fin_env) -> Some(new_exp :: new_rem, fin_env)

method private emit_tuple_not_flattened env exp_list =
  let rec emit_list = function
    [] -> []
  | exp :: rem ->
      (* Again, force right-to-left evaluation *)
      let loc_rem = emit_list rem in
      match self#emit_expr env exp ~bound_name:None with
        None -> assert false  (* should have been caught in emit_parts *)
      | Some loc_exp -> loc_exp :: loc_rem
  in
  emit_list exp_list

method private emit_tuple env exp_list =
  Array.concat (self#emit_tuple_not_flattened env exp_list)

method emit_extcall_args env args =
  let args = self#emit_tuple_not_flattened env args in
  let arg_hard_regs, stack_ofs =
    Proc.loc_external_arguments (Array.of_list args)
  in
  (* Flattening [args] and [arg_hard_regs] causes parts of values split
     across multiple registers to line up correctly, by virtue of the
     semantics of [split_int64_for_32bit_target] in cmmgen.ml, and the
     required semantics of [loc_external_arguments] (see proc.mli). *)
  let args = Array.concat args in
  let arg_hard_regs = Array.concat (Array.to_list arg_hard_regs) in
  self#insert_move_args env args arg_hard_regs stack_ofs;
  arg_hard_regs, stack_ofs

method emit_stores env data regs_addr =
  let a =
    ref (Arch.offset_addressing Arch.identity_addressing (-Arch.size_int)) in
  List.iter
    (fun e ->
      let (op, arg) = self#select_store false !a e in
      match self#emit_expr env arg ~bound_name:None with
        None -> assert false
      | Some regs ->
          match op with
            Istore(_, _, _) ->
              for i = 0 to Array.length regs - 1 do
                let r = regs.(i) in
                let kind = if r.typ = Float then Double_u else Word_val in
                self#insert env (Iop(Istore(kind, !a, false)))
                            (Array.append [|r|] regs_addr) [||];
                a := Arch.offset_addressing !a (size_component r.typ)
              done
          | _ ->
              self#insert env (Iop op) (Array.append regs regs_addr) [||];
              a := Arch.offset_addressing !a (size_expr env e))
    data

(* Same, but in tail position *)

method private emit_return env exp =
  match self#emit_expr env exp ~bound_name:None with
    None -> ()
  | Some r ->
      let loc = Proc.loc_results r in
      self#insert_moves env r loc;
      self#insert env Ireturn loc [||]

method emit_tail env exp =
  match exp with
    Clet(v, provenance, e1, e2) ->
      let bound_name = Some (v, provenance) in
      begin match self#emit_expr env e1 ~bound_name with
        None -> ()
      | Some r1 -> self#emit_tail (self#bind_let env v r1 ~provenance) e2
      end
  | Cphantom_let (ident, provenance, defining_expr, body) ->
      let env =
        self#env_for_phantom_let env ~ident ~provenance ~defining_expr
      in
      self#emit_tail env body
  | Cop((Capply ty) as op, args, dbg) ->
      begin match self#emit_parts_list env args with
        None -> ()
      | Some(simple_args, env) ->
          let (new_op, new_args) = self#select_operation op simple_args in
          match new_op with
            Icall_ind { label_after; } ->
              let r1 = self#emit_tuple env new_args in
              let rarg = Array.sub r1 1 (Array.length r1 - 1) in
              let (loc_arg, stack_ofs) = Proc.loc_arguments rarg in
              if stack_ofs = 0 then begin
                let call = Iop (Itailcall_ind { label_after; }) in
                let spacetime_reg =
                  self#about_to_emit_call env call [| r1.(0) |]
                in
                self#insert_moves env rarg loc_arg;
                self#maybe_emit_spacetime_move env ~spacetime_reg;
                self#insert_debug env call dbg
                            (Array.append [|r1.(0)|] loc_arg) [||];
              end else begin
                let rd = self#regs_for ty in
                let loc_res = Proc.loc_results rd in
                let spacetime_reg =
                  self#about_to_emit_call env (Iop new_op) [| r1.(0) |]
                in
                self#insert_move_args env rarg loc_arg stack_ofs;
                self#maybe_emit_spacetime_move env ~spacetime_reg;
                self#insert_debug env (Iop new_op) dbg
                            (Array.append [|r1.(0)|] loc_arg) loc_res;
                self#insert env(Iop(Istackoffset(-stack_ofs))) [||] [||];
                self#insert env Ireturn loc_res [||]
              end
          | Icall_imm { func; label_after; } ->
              let r1 = self#emit_tuple env new_args in
              let (loc_arg, stack_ofs) = Proc.loc_arguments r1 in
              if stack_ofs = 0 then begin
                let call = Iop (Itailcall_imm { func; label_after; }) in
                let spacetime_reg =
                  self#about_to_emit_call env call [| |]
                in
                self#insert_moves env r1 loc_arg;
                self#maybe_emit_spacetime_move env ~spacetime_reg;
                self#insert_debug env call dbg loc_arg [||];
              end else if func = !current_function_name then begin
                let call = Iop (Itailcall_imm { func; label_after; }) in
                let loc_arg' = Proc.loc_parameters r1 in
                let spacetime_reg =
                  self#about_to_emit_call env call [| |]
                in
                self#insert_moves env r1 loc_arg';
                self#maybe_emit_spacetime_move env ~spacetime_reg;
                self#insert_debug env call dbg loc_arg' [||];
              end else begin
                let rd = self#regs_for ty in
                let loc_res = Proc.loc_results rd in
                let spacetime_reg =
                  self#about_to_emit_call env (Iop new_op) [| |]
                in
                self#insert_move_args env r1 loc_arg stack_ofs;
                self#maybe_emit_spacetime_move env ~spacetime_reg;
                self#insert_debug env (Iop new_op) dbg loc_arg loc_res;
                self#insert env (Iop(Istackoffset(-stack_ofs))) [||] [||];
                self#insert env Ireturn loc_res [||]
              end
          | _ -> fatal_error "Selection.emit_tail"
      end
  | Csequence(e1, e2) ->
      begin match self#emit_expr env e1 ~bound_name:None with
        None -> ()
      | Some _ -> self#emit_tail env e2
      end
  | Cifthenelse(econd, eif, eelse) ->
      let (cond, earg) = self#select_condition econd in
      begin match self#emit_expr env earg ~bound_name:None with
        None -> ()
      | Some rarg ->
          self#insert env (Iifthenelse(cond, self#emit_tail_sequence env eif,
                                         self#emit_tail_sequence env eelse))
                      rarg [||]
      end
  | Cswitch(dbg, esel, index, ecases) ->
      begin match self#emit_expr env esel ~bound_name:None with
        None -> ()
      | Some rsel ->
          self#insert_debug env
            (Iswitch(index, Array.map (self#emit_tail_sequence env) ecases))
            dbg rsel [||]
      end
  | Ccatch(nfail, ids, e1, e2) ->
       let rs =
        List.map
          (fun (id, _provenance) ->
            let r = self#regs_for typ_val in
            name_regs id r  ;
            r)
          ids in
      catch_regs := (nfail, Array.concat rs) :: !catch_regs ;
      let s1 = self#emit_tail_sequence env e1 in
      catch_regs := List.tl !catch_regs ;
      let ids_and_rs = List.combine ids rs in
      let new_env =
        List.fold_left
        (fun env ((id, provenance), r) ->
          { env with idents = Tbl.add id (r, provenance) env.idents; })
        env ids_and_rs in
      let s2 =
        self#emit_tail_sequence new_env e2 ~at_start:(fun seq ->
          List.iter (fun ((ident, provenance), r) ->
              let naming_op =
                Iname_for_debugger { ident; provenance;
                  which_parameter = None; is_assignment = false; }
              in
              seq#insert_debug env (Iop naming_op) Debuginfo.none r [| |])
            ids_and_rs)
      in
      self#insert env (Icatch(nfail, s1, s2)) [||] [||]
  | Ctrywith(e1, v, provenance, e2) ->
      let (opt_r1, s1) = self#emit_sequence env e1 ~bound_name:None in
      let rv = self#regs_for typ_val in
      let s2 =
        let env =
          { env with idents = Tbl.add v (rv, provenance) env.idents; }
        in
        self#emit_tail_sequence env e2 ~at_start:(fun seq ->
          let naming_op =
            Iname_for_debugger { ident = v; provenance;
              which_parameter = None; is_assignment = false; }
          in
          seq#insert_debug env (Iop naming_op) Debuginfo.none rv [| |])
      in
      self#insert env
        (Itrywith(s1#extract,
                  instr_cons (Iop Imove) [|Proc.loc_exn_bucket|] rv s2
                    ~phantom_available_before:s2.phantom_available_before))
        [||] [||];
      begin match opt_r1 with
        None -> ()
      | Some r1 ->
          let loc = Proc.loc_results r1 in
          self#insert_moves env r1 loc;
          self#insert env Ireturn loc [||]
      end
  | _ ->
      self#emit_return env exp

method private emit_tail_sequence ?at_start env exp =
  let s = {< instr_seq = dummy_instr >} in
  begin match at_start with
  | None -> ()
  | Some f -> f s
  end;
  s#emit_tail env exp;
  s#extract

(* Insertion of the function prologue *)

method insert_prologue f ~loc_arg ~rarg ~num_regs_per_arg
      ~spacetime_node_hole:_ ~env =
  let loc_arg_index = ref 0 in
  assert (List.length f.Cmm.fun_args = List.length f.Cmm.fun_original_params);
  List.iteri (fun param_index ((ident, _ty), original_ident) ->
      let provenance =
        (* CR mshinwell: The location information isn't used here.  Should
           be optional? *)
        match original_ident with
        | None -> None
        | Some original_ident ->
          let provenance =
            { Clambda.
              location = Location.none;
              module_path = Path.Pident (Ident.create_persistent "foo");
              original_ident;
            }
          in
          Some provenance
      in
      let naming_op =
        Iname_for_debugger { ident; provenance;
          which_parameter = Some param_index; is_assignment = false; }
      in
      let num_regs_for_arg = num_regs_per_arg.(param_index) in
      let hard_regs_for_arg =
        Array.init num_regs_for_arg (fun index ->
          loc_arg.(!loc_arg_index + index))
      in
      loc_arg_index := !loc_arg_index + num_regs_for_arg;
      self#insert_debug env (Iop naming_op) Debuginfo.none
        hard_regs_for_arg [| |])
    (List.combine f.Cmm.fun_args f.Cmm.fun_original_params);
  self#insert_moves env loc_arg rarg;
  None

(* Extract phantom lets that occur at the start of the Cmm expression so they
   can be added to the environment at the very top of the function.  We do
   this to avoid the following situation:
     prologue
     moves of hard argument regs into other regs
     phantom let availability starts
   which causes variables to be only available some small number of instructions
   into the function.  (A particular case where this is a nuisance is where
   the phantom lets correspond to other functions in the same mutually
   recursive set.) *)

method private extract_phantom_lets expr =
  match expr with
  | Cphantom_let (ident, provenance, defining_expr, expr) ->
    let phantom_lets, expr = self#extract_phantom_lets expr in
    (ident, provenance, defining_expr) :: phantom_lets, expr
  | _ -> [], expr

(* Sequentialization of a function definition *)

method initial_env () =
  { idents = Tbl.empty;
    phantom_idents = Ident.Set.empty;
  }

method emit_fundecl f =
  Proc.contains_calls := false;
  current_function_name := f.Cmm.fun_name;
  let num_regs_per_arg = Array.make (List.length f.Cmm.fun_args) 0 in
  let rargs =
    List.mapi (fun arg_index (ident, ty) ->
        let r = self#regs_for ty in
        name_regs ident r;
        num_regs_per_arg.(arg_index) <- Array.length r;
        r)
      f.Cmm.fun_args
  in
  let rarg = Array.concat rargs in
  let loc_arg = Proc.loc_parameters rarg in
  (* To make it easier to add the Spacetime instrumentation code, we
     first emit the body and extract the resulting instruction sequence;
     then we emit the prologue followed by any Spacetime instrumentation.  The
     sequence resulting from extracting the latter (prologue + instrumentation)
     together is then simply prepended to the body. *)
  let env =
    List.fold_right2
      (fun (id, _ty) r env ->
         { env with idents = Tbl.add id (r, None) env.idents; })
      f.Cmm.fun_args rargs (self#initial_env ()) in
  let spacetime_node_hole, env =
    if not Config.spacetime then None, env
    else begin
      let reg = self#regs_for typ_int in
      let node_hole = Ident.create "spacetime_node_hole" in
      Some (node_hole, reg),
        { env with idents = Tbl.add node_hole (reg, None) env.idents; }
    end
  in
  let phantom_lets_at_top, body = self#extract_phantom_lets f.Cmm.fun_body in
  let env =
    List.fold_left (fun env (ident, provenance, defining_expr) ->
        self#env_for_phantom_let env ~ident ~provenance ~defining_expr)
      env
      phantom_lets_at_top
  in
  self#emit_tail env body;
  let body = self#extract in
  instr_seq <- dummy_instr;
  let fun_spacetime_shape =
    self#insert_prologue f ~loc_arg ~rarg ~num_regs_per_arg
      ~spacetime_node_hole ~env
  in
  let body = self#extract_core ~end_instr:body in
  instr_iter (fun instr -> self#mark_instr instr.Mach.desc) body;
  let fun_phantom_lets = Ident.Tbl.to_map phantom_lets in
  { fun_name = f.Cmm.fun_name;
    fun_args = loc_arg;
    fun_body = body;
    fun_fast = f.Cmm.fun_fast;
    fun_dbg  = f.Cmm.fun_dbg;
    fun_human_name = f.Cmm.fun_human_name;
    fun_module_path = f.Cmm.fun_module_path;
    fun_phantom_lets;
    fun_spacetime_shape;
  }

end

(* Tail call criterion (estimated).  Assumes:
- all arguments are of type "int" (always the case for OCaml function calls)
- one extra argument representing the closure environment (conservative).
*)

let is_tail_call nargs =
  assert (Reg.dummy.typ = Int);
  let args = Array.make (nargs + 1) Reg.dummy in
  let (_loc_arg, stack_ofs) = Proc.loc_arguments args in
  stack_ofs = 0

let _ =
  Simplif.is_tail_native_heuristic := is_tail_call

let reset () =
  catch_regs := [];
  current_function_name := "";
  Ident.Tbl.clear phantom_lets;
  dead_phantom_lets := Ident.Set.empty
