(* simple ring protocol *)
open Mpst_easy

let () = print_endline "start"
let ring = (a --> b) msg @@ (b --> c) msg @@ (c --> a) msg finish3
let () = print_endline "global combinator finished"

let () = print_global ring

let ea = get_ep a ring
let () = print_endline "EPP A finished"
and eb = get_ep b ring
let () = print_endline "EPP B finished"
and ec = get_ep c ring
let () = print_endline "EPP C finished"

let tA = Thread.create (fun () ->
  print_endline "A start";
  let ea = send (ea#msg) () in
  let `msg((), ea) = receive ea in
  print_endline "A done";
  close ea) ()

(* let tA_bad (_:Obj.t) = Thread.create (fun () ->
 *   let `role_C(`msg((), ea)) = Event.sync ea in
 *   let ea = ea#role_B#msg () in
 *   print_endline "A done";
 *   close ea) () *)

let tB = Thread.create (fun () ->
             print_endline "B start";
             let `msg((), eb) = Event.sync eb in
             let eb = send (eb#msg) () in
             print_endline "B done";
             close eb) ()

let tC = Thread.create (fun () ->
             print_endline "C start";
             let `msg((), ec) = Event.sync ec in
             let ec = send (ec#msg) () in
             print_endline "C done";
             close ec) ()

let () = List.iter Thread.join [tA; tB; tC]

(* incompatible branching at C between reception and closing *)
(* let test =
 *   choice_at a left_or_right
 *     (a, (a --> b) left @@ (a --> c) left @@ finish3)
 *     (a, (a --> b) right @@ finish3) *)

(* incompatible branching at C after receiving msg from B (statically detected) *)
(* let test2 =
 *   choice_at a left_or_right
 *     (a, (a --> b) left @@ (b --> c) msg @@ (c --> a) msg @@ finish3)
 *     (a, (a --> b) right @@ (b --> c) msg @@ finish3) *)

(* incompatible branching at C after sending msg to A (statically detected) *)
(* let test3 =
 *   choice_at a left_or_right
 *     (a, (a --> b) left  @@ (b --> c) msg @@ (c --> a) msg @@ (c --> b) msg @@ finish3)
 *     (a, (a --> b) right @@ (b --> c) msg @@ (c --> a) msg @@ finish3) *)

(* receive from multiple roles *)
let test3 () =
  let rec g = lazy (* no type error -- TODO: run-time error should occur instead *)
  (choice_at a left_or_right
   (a, (a --> b) left @@ (b --> c) left @@ goto3 g)
   (a, (a --> c) right @@ (c --> b) right @@ goto3 g))
  in
  g

(* object merging failure *)
(* let test4 =
 *   choice_at a left_or_right
 *   (a, (a --> b) left @@ finish2)
 *   (a, (a --> b) left @@ finish2) *)

(* sending from a non-enabled role (statically detected) *)
(* let test8 =
 *   choice_at a left_or_right
 *   (a, (a --> b) left  @@ (c --> b) left  @@ finish3)
 *   (a, (a --> b) right @@ (c --> b) right @@ finish3) *)

let test10 =
  let rec bogus = lazy (goto2 bogus) in
  let g =
    (a --> b) msg @@
    Lazy.force bogus
  in
  let () =
    try
      ignore (get_ep a g);
      failwith "unexpected"
    with
      UngardedLoop ->
      print_endline "exception correctly occurred"
  and () =
    try
      ignore (get_ep b g);
      failwith "unexpected"
    with
      UngardedLoop ->
      print_endline "exception correctly occurred"
  in
  ()