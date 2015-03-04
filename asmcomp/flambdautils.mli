(***********************************************************************)
(*                                                                     *)
(*                                OCaml                                *)
(*                                                                     *)
(*                     Pierre Chambart, OCamlPro                       *)
(*                                                                     *)
(*  Copyright 2014 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the Q Public License version 1.0.               *)
(*                                                                     *)
(***********************************************************************)

open Abstract_identifiers

(** Intermediate language used to perform closure conversion and inlining.
    See flambdatypes.ml for documentation.
*)

(** Access functions *)

val find_declaration :
  Closure_id.t -> 'a Flambda.function_declarations -> 'a Flambda.function_declaration
(** [find_declaration f decl] raises [Not_found] if [f] is not in [decl]. *)

val find_declaration_variable :
  Closure_id.t -> 'a Flambda.function_declarations -> Variable.t
(** [find_declaration_variable f decl] raises [Not_found] if [f] is not in
    [decl]. *)

val find_free_variable :
  Var_within_closure.t -> 'a Flambda.fset_of_closures -> 'a Flambda.t
(** [find_free_variable v clos] raises [Not_found] if [c] is not in [clos]. *)

(** Utility functions *)

val function_arity : 'a Flambda.function_declaration -> int

val variables_bound_by_the_closure :
  Closure_id.t -> 'a Flambda.function_declarations -> Variable.Set.t
(** Variables "bound by a closure" are those variables free in the
    corresponding function's body that are neither:
    - bound as parameters of that function; nor
    - bound by the [let] binding that introduces the function declaration(s).
    In particular, if [f], [g] and [h] are being introduced by a
    simultaneous, possibly mutually-recursive [let] binding then none of
    [f], [g] or [h] are bound in any of the closures for [f], [g] and [h].
*)

(** All variables used by a given expression that are defined within
    closures.  (In other words, the union of all variables contained within
    [Fvariable_in_closure] nodes.) *)
(* CR mshinwell: we should fix the naming of [Fvariable_in_closure] vs.
   [Var_within_closure]. *)
val all_used_vars_defined_within_closures
   : _ Flambda.t
  -> Var_within_closure.Set.t

val can_be_merged : 'a Flambda.t -> 'a Flambda.t -> bool
(** If [can_be_merged f1 f2] is [true], it is safe to merge switch
    branches containing [f1] and [f2]. *)

val data_at_toplevel_node : 'a Flambda.t -> 'a

val description_of_toplevel_node : 'a Flambda.t -> string

val recursive_functions : 'a Flambda.function_declarations -> Variable.Set.t
(** Recursive functions are the one that can call themselves or call
    a function that can.

    for instance in this simultaneous definition of [f] [g] and [h],
    [f] and [g] are recursives, but not [h]
      [let rec f x = g x
       and g x = f x
       and h x = g x]
*)

(** Sharing key *)
(* CR mshinwell for pchambart: this needs a proper comment as discussed *)
type sharing_key
val make_key : 'a Flambda.t -> sharing_key option

(* Fold over the variables bound by a given closure, at the same time
   creating [Fvariable_in_closure] expressions to access them. *)
val fold_over_exprs_for_variables_bound_by_closure
   : fun_id:Closure_id.t
  -> clos_id:Variable.t
  -> clos:'a Flambda.function_declarations
  -> init:'b
  -> f:(acc:'b -> var:Variable.t -> expr:Expr_id.t Flambda.t -> 'b)
  -> 'b

(* Given an expression, freshen all variables within it, and form a function
   whose body is the resulting expression.  The variables specified by
   [params] will become the parameters of the function; the closure will be
   identified by [id].  [params] must only reference variables that are
   free variables of [body]. *)
val make_closure_declaration
   : id:Variable.t
  -> body:Expr_id.t Flambda.t
  -> params:Variable.t list
  -> debuginfo:Debuginfo.t
  -> Expr_id.t Flambda.t

(* [unchanging_params_in_recursion] calculates the set of parameters whose
   values are known not to change during the execution of a recursive
   function.  As such, occurrences of the parameters may always be replaced
   by the corresponding values.

   For example, [x] would be in [unchanging_params] for both of the following
   functions:

     let rec f x y = (f x y) + (f x (y+1))

     let rec f x l = List.iter (f x) l
*)
val unchanging_params_in_recursion
   : _ Flambda.function_declarations
  -> Variable.Set.t

val free_variables : _ Flambda.t -> Variable.Set.t

val expression_free_variables : _ Flambda.t -> Variable.Set.t

val subexpression_bound_variables
   : 'a Flambda.t
  -> (Variable.Set.t * 'a Flambda.t) list

(* [list_closures expr ~closures] adds all closure identifiers defined in
   [expr] to [closures]. *)
val list_closures
   : 'a Flambda.t
  -> closures:'a Flambda.function_declarations Closure_id.Map.t ref
  -> unit

val all_closures : _ Flambda.t -> Set_of_closures_id.Set.t

val list_used_variables_within_closure
   : _ Flambda.t
  -> Var_within_closure.Set.t
