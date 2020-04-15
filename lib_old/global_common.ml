open Base
open Common
module Make(EP:S.ENDPOINTS) = struct
module Seq = Seq.Make(EP)

type 'k env = {metainfo: 'k role_metainfo Table.t; default:int -> 'k}

type ('k, 'g) t = Global of ('k env -> 'g Seq.t)
let unglobal_ = function
    Global f -> f

let fix : type e g. ((e,g) t -> (e,g) t) -> (e,g) t = fun f ->
  Global (fun e ->
      let rec body =
        lazy (unglobal_ (f (Global (fun _ -> Seq.recvar body))) e)
      in
      (* A "fail-fast" approach to detect unguarded loops.
       * Seq.partial_force tries to fully evaluate unguarded recursion variables
       * in the body.
       *)
      Seq.resolve_merge (Lazy.force body))

let gen_with_param p g = unglobal_ g p

let get_ch_raw : 'ep 'x2 't 'x3 't 'ep. ('ep, 'x2, 't, 'x3) lens -> 't Seq.t -> 'ep = fun lens g ->
  let ep = Seq.lens_get lens g in
  match EP.fresh_all ep with
  | [e] -> e
  | [] -> assert false
  | _ -> failwith "get_ch: there are more than one endpoints. use get_ch_list."

let get_ch : ('x0, 'x1, 'ep, 'x2, 't, 'x3) role -> 't Seq.t -> 'ep = fun r g ->
  get_ch_raw r.role_index g

let get_ch_list : ('x0, 'x1, 'ep, 'x2, 't, 'x3) role -> 't Seq.t -> 'ep list = fun r g ->
  let ep = Seq.lens_get r.role_index g in
  EP.fresh_all ep

let munit = EP.make_simple [()]

let choice_at : 'e 'ep 'ep_l 'ep_r 'g0_l 'g0_r 'g1 'g2.
                  (_, _, unit, (< .. > as 'ep), 'g1, 'g2) role ->
                ('ep, < .. > as 'ep_l, < .. > as 'ep_r) disj_merge ->
                (_, _, 'ep_l, unit, 'g0_l, 'g1) role * ('e,'g0_l) t ->
                (_, _, 'ep_r, unit, 'g0_r, 'g1) role * ('e,'g0_r) t ->
                ('e,'g2) t
  = fun r merge (r',Global g0left) (r'',Global g0right) ->
  Global (fun env ->
      let g0left, g0right = g0left env, g0right env in
      let epL, epR =
        Seq.lens_get r'.role_index g0left,
        Seq.lens_get r''.role_index g0right in
      let g1left, g1right =
        Seq.lens_put r'.role_index g0left munit,
        Seq.lens_put r''.role_index g0right munit in
      let g1 = Seq.seq_merge g1left g1right in
      let ep = EP.make_disj_merge merge epL epR
      in
      let g2 = Seq.lens_put r.role_index g1 ep
      in
      g2)

end