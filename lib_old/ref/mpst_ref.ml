(** A reference implementation of ocaml-mpst *)

type ('lr, 'l, 'r) disj_merge =
  {disj_merge: 'l -> 'r -> 'lr;
   disj_splitL: 'lr -> 'l;
   disj_splitR: 'lr -> 'r;
  }

type ('la,'va) method_ =
  {make_obj: 'va -> 'la;
   call_obj: 'la -> 'va}

type ('la,'lb,'va,'vb) label =
  {obj: ('la, 'va) method_;
   var: 'vb -> 'lb}

let rec find_physeq : 'a. 'a list -> 'a -> bool = fun xs y ->
  match xs with
  | x::xs -> if x==y then true else find_physeq xs y
  | [] -> false


(** a flag for dynamic linearity checking  *)
module Flag : sig
  type t
  exception InvalidEndpoint
  val use : t -> unit
  val create : unit -> t
end
(*   = struct
 *   type t = Nano_mutex.t
 *   exception InvalidEndpoint
 * 
 *   let create ()  = Nano_mutex.create ()
 *   let try_lock_nano f = match Nano_mutex.try_lock f with Ok `Acquired -> true | Ok `Not_acquired | Error _ -> false
 *   let use f      =
 *     if not (try_lock_nano f) then raise InvalidEndpoint
 *   let try_use f  = try_lock_nano f
 * end *)
  = struct
  type t         = Mutex.t
  exception InvalidEndpoint
  let create ()  = Mutex.create ()
  let use f      = if not (Mutex.try_lock f) then raise InvalidEndpoint
end


(** DynLinear types *)
module DynLin
(*        : sig
 *   (\** linear type constructor *\)
 *   type 'a lin
 * 
 *   (\** extract the value. raises DynLinFlag.InvalidEndpoint if the endpoint is already consumed *\)
 *   val use : 'a lin -> 'a
 * 
 *   (\** a generator for linear values *\)
 *   type 'a gen
 * 
 *   (\** create a generator *\)
 *   val create : 'a -> 'a lin gen
 *   val create_nolin : 'a -> 'a gen
 * 
 *   (\** generate a fresh linear value (possibly wrapped by objects) *\)
 *   val fresh : 'a gen -> 'a
 * 
 *   val map_gen : ('a -> 'b) -> 'a gen -> 'b gen
 *   val merge_gen : ('a -> 'a -> 'a) -> 'a lin gen -> 'a lin gen -> 'a lin gen
 *   val lift_disj_merge : ('lr,'l,'r) disj_merge -> ('lr gen, 'l gen, 'r gen) disj_merge
 * end *)
(*   = struct
 *   type 'a lin = {once:Flag.t; value: 'a}
 *   type 'a gen = Flag.t -> 'a
 *   let use t =
 *     Flag.use t.once;
 *     t.value
 *   let create v = fun once -> {once; value=v}
 *   let create_nolin v = fun _ -> v
 *   let fresh f = f (Flag.create ())
 *   let map_gen f x = fun once -> f (x once)
 *   let merge_gen f x y = fun once -> {once; value=f (x once).value (y once).value}
 * 
 *   let lift_disj_merge : 'lr 'l 'r. ('lr,'l,'r) disj_merge -> ('lr gen, 'l gen, 'r gen) disj_merge = fun mrg ->
 *     {disj_merge=(fun l r once -> mrg.disj_merge (l once) (r once));
 *      disj_splitL=(fun lr -> map_gen mrg.disj_splitL lr);
 *      disj_splitR=(fun lr -> map_gen mrg.disj_splitR lr)}
 * end *)
(* Closure-less implementation (more efficient) *)
  = struct
  type once_store = Flag.t ref
  type 'a lin = {value:'a; store_ref:once_store ref}
  type 'a gen = 'a lin = {value:'a; store_ref:once_store ref}

  let use t =
    Flag.use !(!(t.store_ref));
    t.value

  let create v =
    let store = ref (Flag.create ()) in
    let store_ref = ref store in
    {value={value=v; store_ref}; store_ref}
  let create_nolin v = 
    {value=v; store_ref=ref @@ ref @@ Flag.create ()}

  let extract t = t.value
  let map_gen f x =
    {value=f x.value; store_ref=x.store_ref}
  let merge_gen f l r =
    {value={value=f l.value.value r.value.value; store_ref=l.store_ref}; store_ref=l.store_ref}
  let lift_disj_merge mrg =
    {disj_merge=(fun l r ->
       r.store_ref := !(l.store_ref); (* track and use the same linearity flag *)
       {store_ref=l.store_ref; value=mrg.disj_merge l.value r.value});
     disj_splitL=(fun lr -> map_gen mrg.disj_splitL lr);
     disj_splitR=(fun lr -> map_gen mrg.disj_splitR lr)}
  let refresh t =
    !(t.store_ref) := Flag.create ()
  let fresh t =
    refresh t;
    t.value
end

module Mergeable
(*        : sig
 *   type 'a t
 *   val make : hook:unit lazy_t -> mergefun:('a -> 'a -> 'a) -> value:'a -> 'a t
 *   val make_recvar : 'a t lazy_t -> 'a t
 *   val make_disj_merge : ('lr,'l,'r) disj_merge -> 'l t -> 'r t -> 'lr t
 *   val make_merge : 'a t -> 'a t -> 'a t
 *   val make_merge_list : 'a t list -> 'a t
 *   val map : ('a -> 'b) -> ('b -> 'a) -> 'a t -> 'b t
 *   val resolve : 'a t -> 'a
 * end *)
  = struct

  type 'a t =
    | Single of 'a single
    (** (A) delayed merge involving recvars *)
    | Merge of 'a single list * 'a cache
  and 'a single =
    (** fully resolved merge *)
    | Val : 'a body * hook -> 'a single
    (** (B) disjoint merge involving recvars  (output) *)
    | DisjMerge   : 'l t * 'r t * ('lr,'l,'r) disj_merge * 'lr cache -> 'lr single
    (** (C) a recursion variable *) 
    | RecVar : 'a t lazy_t * 'a cache -> 'a single
  and 'a body =
    {mergefun: 'a -> 'a -> 'a;
     value: 'a}
  and 'a cache = 'a lazy_t
  and hook = unit lazy_t

  exception UnguardedLoop

  let merge_body (ll,hl) (rr,hr) =
    let hook = lazy (Lazy.force hl; Lazy.force hr) in
    ({mergefun=ll.mergefun;
      value=ll.mergefun ll.value rr.value},
     hook)

  let disj_merge_body
      : 'lr 'l 'r. ('lr,'l,'r) disj_merge -> 'l body * hook -> 'r body * hook -> 'lr body * hook =
    fun mrg (bl,hl) (br,hr) ->
    let mergefun lr1 lr2 =
      mrg.disj_merge
        (bl.mergefun (mrg.disj_splitL lr1) (mrg.disj_splitL lr2))
        (br.mergefun (mrg.disj_splitR lr1) (mrg.disj_splitR lr2))
    in
    let value = mrg.disj_merge bl.value br.value
    in
    {value; mergefun},lazy (Lazy.force hl; Lazy.force hr)    

  (**
   * Resolve delayed merges
   *)
  let rec resolve_merge : type x. x t lazy_t list -> x t -> x body * hook = fun hist t ->
    match t with
    | Single s ->
       resolve_merge_single hist s
    | Merge (ss, _) ->
       (* (A) merge involves recursion variables *)
       resolve_merge_list hist ss

  and resolve_merge_single : type x. x t lazy_t list -> x single -> x body * hook = fun hist ->
      function
      | Val (v,hook) ->
         (* already resolved *)
         (v,hook)
      | DisjMerge (l,r,mrg,d) ->
         (* (B) disjoint merge involves recursion variables *)
         (* we can safely reset the history; as the split types are different from the merged one, the same type variable will not occur. *)
         let l, hl = resolve_merge [] l in
         let r, hr = resolve_merge [] r in
         disj_merge_body mrg (l,hl) (r,hr)
      | RecVar (t, d) ->
         (* (C) a recursion variable *)
         if find_physeq hist t then begin
           (* we found μt. .. ⊔ t ⊔ .. *)
           raise UnguardedLoop
         end else
           (* force it, and resolve it. at the same time, check that t occurs again or not by adding t to the history  *)
           let b, _ = resolve_merge (t::hist) (Lazy.force t) in
           b, Lazy.from_val () (* dispose the hook -- recvar is already evaluated *)

  and resolve_merge_list : type x. x t lazy_t list -> x single list -> x body * hook = fun hist ss ->
    (* remove unguarded recursions *)
    let solved : (x body * hook) list =
      List.fold_left (fun acc u ->
          try
            resolve_merge_single hist u :: acc
          with
            UnguardedLoop ->
            prerr_endline "WARNING: an unbalanced loop detected";
            (* remove it. *)
            acc)
        [] ss
    in
    (* then, merge them altogether *)
    match solved with
    | [] ->
       raise UnguardedLoop
    | x::xs ->
       List.fold_left merge_body x xs

  let force_mergeable : 'a. 'a t -> 'a = fun t ->
    let v,hook = resolve_merge [] t in
    Lazy.force hook ;
    v.value
    
  let make ~hook ~mergefun ~value =
    Single (Val ({mergefun;value}, hook))

  let make_recvar_single t =
    let rec d = RecVar (t, lazy (force_mergeable (Single d)))
    in d

  let make_recvar t =
    Single (make_recvar_single t)

  let make_merge_single : 'a. 'a single list -> 'a t = fun us ->
    let rec d = Merge (us, lazy (force_mergeable d))
    in d

  let make_merge : 'a. 'a t -> 'a t -> 'a t = fun l r ->
    match l, r with
    | Single (Val (ll,hl)), Single (Val (rr,hr)) ->
       let blr, hlr = merge_body (ll,hl) (rr,hr) in
       Single (Val (blr, hlr))
    | Single v1, Single v2 ->
       make_merge_single [v1; v2]
    | Single v, Merge (ds,_) | Merge (ds,_), Single v ->
       make_merge_single (v :: ds)
    | Merge (d1, _), Merge (d2, _) ->
       make_merge_single (d1 @ d2)

  let make_merge_list = function
    | [] -> failwith "merge_all: empty"
    | m::ms -> List.fold_left make_merge m ms

  let make_disj_merge : 'lr 'l 'r. ('lr,'l,'r) disj_merge -> 'l t -> 'r t -> 'lr t = fun mrg l r ->
    match l, r with
    | Single (Val (bl, hl)), Single (Val (br, hr)) ->
       let blr,hlr = disj_merge_body mrg (bl,hl) (br,hr) in
       Single (Val (blr, hlr))
    | _ ->
       let rec d = Single (DisjMerge (l,r,mrg, lazy (force_mergeable d)))
       (* prerr_endline "WARNING: internal choice involves recursion variable"; *)
       in d

  let mapbody : 'p 'q 'x. ('p -> 'q) -> ('q -> 'p) -> 'p body -> 'q body = fun f g b ->
    {value=f b.value;
     mergefun=(fun l r -> f (b.mergefun (g l) (g r)))}

  let rec map_single : 'p 'q 'x. ('p -> 'q) -> ('q -> 'p) -> 'p single -> 'q single = fun f g -> function
    | Val (b,h) ->
       Val (mapbody f g b,h)
    | RecVar (t, _) ->
       assert false
       (* make_recvar_single (lazy (map f g (Lazy.force t))) *)
    | DisjMerge (l,r,mrg,d) ->
       assert false

  and map : 'p 'q 'x. ('p -> 'q) -> ('q -> 'p) -> 'p t -> 'q t = fun f g -> function
    | Single s ->
       Single (map_single f g s)
    | Merge (ss, _) ->
       make_merge_list (List.map (fun s -> Single (map_single f g s)) ss)

  let resolve t =
    match t with
    | Single (Val (b,h)) ->
       Lazy.force h;
       b.value
    | Single (RecVar (_,d)) ->
       Lazy.force d
    | Single (DisjMerge (_,_,_,d)) ->
       Lazy.force d
    | Merge (_,d) ->
       Lazy.force d
end

(** DynEP: The endpoint type. An endpoint is a mergeable, linear channel.
  *)   
module DynEP
(*        : sig
 *   type 'a t (\* = 'a DynLin.gen Mergeable.t *\)
 *   val make_lin : hook:unit lazy_t -> mergefun:('a -> 'a -> 'a) -> value:'a -> 'a DynLin.lin t
 *   val make_simple : 'a -> 'a t
 *   val wrap_label : ('o, 'v) method_ -> 'v t -> 'o t
 *   val fresh : 'a t -> 'a
 *   val force_merge : 'a t -> unit
 * 
 *   val make_recvar : 'a t lazy_t -> 'a t
 *   val make_disj_merge : ('lr,'l,'r) disj_merge -> 'l t -> 'r t -> 'lr t
 *   val make_merge : 'a t -> 'a t -> 'a t
 *   val make_merge_list : 'a t list -> 'a t
 * end *)
  = struct
  type 'a t = 'a DynLin.gen Mergeable.t
  let make_lin ~hook ~mergefun ~value =
    Mergeable.make
      ~hook
      ~mergefun:(DynLin.merge_gen mergefun)
      ~value:(DynLin.create value)
  let make_simple v =
    let v = DynLin.create_nolin v in
    Mergeable.make
      ~hook:(Lazy.from_val ())
      ~mergefun:(fun _ _ -> v)
      ~value:v
  let wrap_label meth t =
    Mergeable.map (DynLin.map_gen meth.make_obj) (DynLin.map_gen meth.call_obj) t
  let force_merge t =
    ignore (Mergeable.resolve t)
  let fresh t =
    DynLin.fresh @@ Mergeable.resolve t

  let make_recvar = Mergeable.make_recvar
  let make_merge = Mergeable.make_merge
  let make_merge_list = Mergeable.make_merge_list

  let make_disj_merge mrg = Mergeable.make_disj_merge (DynLin.lift_disj_merge mrg)
end
    
module Inp : sig
  type 'a inp
  val receive : 'a inp DynLin.lin -> 'a
  val create_inp : 'v Event.channel ref -> (_,[>] as 'var,_,'v * 't) label -> 't DynEP.t -> 'var inp DynLin.lin DynEP.t
end = struct
  type 'a inp = 'a Event.event
  let receive ev =
    Event.sync (DynLin.use ev)
  let merge_inp ev1 ev2 =
    Event.choose [ev1; ev2]
  let create_inp ch label cont =
    DynEP.make_lin
      ~hook:(lazy (DynEP.force_merge cont))
      ~mergefun:merge_inp
      ~value:
         (Event.wrap
           (Event.guard (fun () -> Event.receive !ch)) (* dereference of ch is delayed by this Event.guard *)
           (fun v -> label.var (v, DynEP.fresh cont)))
end

module Out : sig
  type ('v, 't) out
  val send : ('v, 't) out DynLin.lin -> 'v -> 't
  val create_out : 'v Event.channel ref -> (< .. > as 'obj, _, ('v, 't) out DynLin.lin, _) label -> 't DynEP.t -> 'obj DynEP.t
end = struct
  type ('v, 'u) out = 'v Event.channel ref * 'u DynEP.t
  let send t v =
    let (ch,cont) = DynLin.use t in
    Event.sync (Event.send !ch v);
    DynEP.fresh cont
  let merge_out (ch1,cont1) (ch2,cont2) =
    ch1 := !ch2;
    (ch1, DynEP.make_merge cont1 cont2)
  let create_out ch label cont =
    let out = 
      DynEP.make_lin
        ~hook:(lazy (DynEP.force_merge cont))
        ~mergefun:merge_out
        ~value:(ch,cont)
    in
    DynEP.wrap_label label.obj out
end

module Close : sig
  type close
  val close : close -> unit
  val mclose : close DynEP.t
end = struct
  type close = unit
  let close _ = ()
  let mclose =
    DynEP.make_simple ()
end

module Seq
       : sig
  type _ t 
  and (_,_,_,_) lens =
    Zero : ('a, 'b, [`cons of 'a * 'tl], [`cons of 'b * 'tl]) lens
  | Succ : ('a, 'b, 'aa, 'bb) lens -> ('a, 'b, [`cons of 'hd * 'aa], [`cons of 'hd * 'bb]) lens

  exception UnguardedLoopSeq

  val lens_get : ('a, _, 'aa, _) lens -> 'aa t -> 'a DynEP.t
  val lens_put : ('a, 'b, 'aa, 'bb) lens -> 'aa t -> 'b DynEP.t -> 'bb t

  val seq_merge : 'a t -> 'a t -> 'a t
  val recvar : 'a t lazy_t -> 'a t
  val all_closed : ([`cons of Close.close * 'a] as 'a) t
  val force_all : 'x t -> unit
  val resolve_merge : 'x t -> 'x t
end
  = struct
  type _ t =
    (* hidden *)
  | SeqCons : 'hd DynEP.t * 'tl t -> [`cons of 'hd * 'tl] t
  | SeqFinish : ([`cons of Close.close * 'a] as 'a) t
  | SeqRecVars : 'a t lazy_t list -> 'a t
  | SeqBottom : 'a t
  and (_,_,_,_) lens =
    Zero : ('a, 'b, [`cons of 'a * 'tl], [`cons of 'b * 'tl]) lens
  | Succ : ('a, 'b, 'aa, 'bb) lens -> ('a, 'b, [`cons of 'hd * 'aa], [`cons of 'hd * 'bb]) lens

  exception UnguardedLoopSeq

  let all_closed = SeqFinish
  let recvar l = SeqRecVars [l]

  let rec seq_head : type hd tl. [`cons of hd * tl] t -> hd DynEP.t =
    function
    | SeqCons(hd,_) -> hd
    | SeqRecVars ds -> DynEP.make_merge_list (List.map seqvar_head ds)
    | SeqFinish -> Close.mclose
    | SeqBottom -> raise UnguardedLoopSeq
  and seqvar_head : type hd tl. [`cons of hd * tl] t lazy_t -> hd DynEP.t = fun d ->
    DynEP.make_recvar (lazy (seq_head (Lazy.force d)))

  let rec seq_tail : type hd tl. [`cons of hd * tl] t -> tl t =
    function
    | SeqCons(_,tl) -> tl
    | SeqRecVars ds -> SeqRecVars(List.map seqvar_tail ds)
    | SeqFinish -> SeqFinish
    | SeqBottom -> raise UnguardedLoopSeq
  and seqvar_tail : type hd tl. [`cons of hd * tl] t lazy_t -> tl t lazy_t = fun d ->
    lazy (seq_tail (Lazy.force d))

  let rec lens_get : type a b xs ys. (a, b, xs, ys) lens -> xs t -> a DynEP.t = fun ln xs ->
    match ln with
    | Zero -> seq_head xs
    | Succ ln' -> lens_get ln' (seq_tail xs)

  let rec lens_put : type a b xs ys. (a,b,xs,ys) lens -> xs t -> b DynEP.t -> ys t =
    fun ln xs b ->
    match ln with
    | Zero -> SeqCons(b, seq_tail xs)
    | Succ ln' -> SeqCons(seq_head xs, lens_put ln' (seq_tail xs) b)

  let rec seq_merge : type x. x t -> x t -> x t = fun l r ->
    match l,r with
    | SeqCons(_,_), _ ->
       let hd = DynEP.make_merge (seq_head l) (seq_head r) in
       let tl = seq_merge (seq_tail l) (seq_tail r) in
       SeqCons(hd, tl)
    | _, SeqCons(_,_) -> seq_merge r l
    (* delayed constructors are left as-is *)
    | SeqRecVars(us1), SeqRecVars(us2) -> SeqRecVars(us1 @ us2)
    (* repeat *)
    | SeqFinish, _ -> SeqFinish
    | _, SeqFinish -> SeqFinish
    (* bottom *)
    | SeqBottom,_  -> raise UnguardedLoopSeq
    | _, SeqBottom -> raise UnguardedLoopSeq

  let rec force_recvar : type x. x t lazy_t list -> x t lazy_t -> x t =
    fun hist w ->
    if find_physeq hist w then begin
        raise UnguardedLoopSeq
      end else begin
        match Lazy.force w with
        | SeqRecVars [w'] -> force_recvar (w::hist) w'
        | s -> s
      end

  let rec resolve_merge : type x. x t -> x t =
    function
    | SeqCons(hd,tl) ->
       let tl =
         try
           resolve_merge tl
         with
           UnguardedLoopSeq ->
           (* we do not raise exception here;
            * in recursion, an unguarded loop will occur in the last part of the sequence.
            * when one tries to take head/tail of SeqBottom, an exception will be raised.
            *)
           SeqBottom
       in
       SeqCons(hd, tl)
    | SeqRecVars [] -> assert false
    | SeqRecVars ((d::ds) as dss) ->
       resolve_merge
         (List.fold_left seq_merge (force_recvar dss d) (List.map (force_recvar dss) ds))
    | SeqFinish -> SeqFinish
    | SeqBottom -> SeqBottom

  let rec force_all : type x. x t -> unit = function
    | SeqCons(hd,tl) ->
       DynEP.force_merge hd;
       force_all tl
    | SeqRecVars [] -> assert false
    | SeqRecVars ((d::ds) as dss) ->
       force_all
         (List.fold_left seq_merge (force_recvar dss d) (List.map (force_recvar dss) ds))
    | SeqFinish -> ()
    | SeqBottom -> ()
end

module Local : sig
  type 'a inp = 'a Inp.inp
  type ('v, 't) out = ('v, 't) Out.out
  type close = Close.close
  val receive : 'a inp DynLin.lin -> 'a
  val send : ('v, 't) out DynLin.lin -> 'v -> 't
  val close : close -> unit
end  = struct
  type 'a lin = 'a DynLin.lin
  include Inp
  include Out
  include Close
end

module Global
(*        : sig
 *   open Close
 *   open Inp
 *   open Out
 * 
 *   type ('r,'v,'a,'b,'aa,'bb) role =
 *     {role_label : ('r,'v) method_;
 *      role_index : ('a,'b,'aa,'bb) Seq.lens}
 * 
 *   val fix : ('a Seq.t -> 'a Seq.t) -> 'a Seq.t
 *   val finish : ([ `cons of close * 'a ] as 'a) Seq.t
 * 
 *   val choice_at :
 *     (_, _, close, 'lr, 'g12, 'g3) role ->
 *     ('lr, 'l, 'r) disj_merge ->
 *     (_, _, 'l, close, 'g1, 'g12) role * 'g1 Seq.t ->
 *     (_, _, 'r, close, 'g2, 'g12) role * 'g2 Seq.t -> 'g3 Seq.t
 * 
 *   val ( --> ) :
 *     (< .. > as 'rA, ([>  ] as 'var) inp DynEP.lin, 'epA, 'rB, 'g1, 'g2) role ->
 *     (< .. > as 'rB, < .. > as 'obj, 'epB, 'rA, 'g0, 'g1) role ->
 *     ('obj, 'var, ('v, 'epA) out DynEP.lin, 'v * 'epB) label -> 'g0 Seq.t -> 'g2 Seq.t
 * 
 *   (\** forces delayed merges. *\)
 *   val gen : 'a Seq.t -> 'a Seq.t
 * 
 *   val get_ch : (_, _, 'ep, _, 'g, _) role -> 'g Seq.t -> 'ep
 * end *)
  = struct
  include Inp
  include Out
  include Close

  type ('r,'v,'a,'b,'aa,'bb) role =
    {role_label : ('r,'v) method_;
     role_index : ('a,'b,'aa,'bb) Seq.lens}
     
  let fix f =
    let rec body = lazy (f (Seq.recvar body)) in
    Seq.resolve_merge (Lazy.force body)

  let finish =
    Seq.all_closed

  let choice_at rA0 mrg (rA1,g1) (rA2,g2) =
    let epA1, epA2 = Seq.lens_get rA1.role_index g1, Seq.lens_get rA2.role_index g2 in
    let g1, g2 = Seq.lens_put rA1.role_index g1 Close.mclose, Seq.lens_put rA2.role_index g2 Close.mclose in
    let epA = DynEP.make_disj_merge mrg epA1 epA2 in
    let g = Seq.seq_merge g1 g2 in
    let g = Seq.lens_put rA0.role_index g epA in
    g

  let (-->) rA rB label g =
    let ch = ref (Event.new_channel ()) in
    let epB = Seq.lens_get rB.role_index g in
    let epB = create_inp ch label epB in
    let epB = DynEP.wrap_label rA.role_label epB in
    let g = Seq.lens_put rB.role_index g epB in
    let epA = Seq.lens_get rA.role_index g in
    let epA = create_out ch label epA in
    let epA = DynEP.wrap_label rB.role_label epA in
    Seq.lens_put rA.role_index g epA


  let gen g =
    Seq.force_all g;
    g
    
  let get_ch r g =
    DynEP.fresh (Seq.lens_get r.role_index g)
end

module Util = struct
  open Global
  open Local

  let a = {role_label={make_obj=(fun v->object method role_A=v end);
                       call_obj=(fun o->o#role_A)};
           role_index=Zero}
  let b = {role_label={make_obj=(fun v->object method role_B=v end);
                       call_obj=(fun o->o#role_B)};
           role_index=Succ Zero}
  let c = {role_label={make_obj=(fun v->object method role_C=v end);
                       call_obj=(fun o->o#role_C)};
           role_index=Succ (Succ Zero)}
  let d = {role_label={make_obj=(fun v->object method role_D=v end);
                       call_obj=(fun o->o#role_D)};
           role_index=Succ (Succ (Succ Zero))}

  let msg =
    {obj={make_obj=(fun f -> object method msg=f end);
          call_obj=(fun o -> o#msg)};
     var=(fun v -> `msg(v))}
  let left =
    {obj={make_obj=(fun f -> object method left=f end);
          call_obj=(fun o -> o#left)};
     var=(fun v -> `left(v))}
  let right =
    {obj={make_obj=(fun f -> object method right=f end);
          call_obj=(fun o -> o#right)};
     var=(fun v -> `right(v))}
  let middle =
    {obj={make_obj=(fun f -> object method middle=f end);
          call_obj=(fun o -> o#middle)};
     var=(fun v -> `middle(v))}
  let ping =
    {obj={make_obj=(fun f -> object method ping=f end);
          call_obj=(fun o -> o#ping)};
     var=(fun v -> `ping(v))}
  let pong =
    {obj={make_obj=(fun f -> object method pong=f end);
          call_obj=(fun o -> o#pong)};
     var=(fun v -> `pong(v))}
  let fini =
    {obj={make_obj=(fun f -> object method fini=f end);
          call_obj=(fun o -> o#fini)};
     var=(fun v -> `fini(v))}

  let left_or_right =
    {disj_merge=(fun l r -> object method left=l#left method right=r#right end);
     disj_splitL=(fun lr -> (lr :> <left : _>));
     disj_splitR=(fun lr -> (lr :> <right : _>));
    }
  let right_or_left =
    {disj_merge=(fun l r -> object method right=l#right method left=r#left end);
     disj_splitL=(fun lr -> (lr :> <right : _>));
     disj_splitR=(fun lr -> (lr :> <left : _>));
    }
  let to_b m =
    {disj_merge=(fun l r ->
       object method role_B=m.disj_merge (l#role_B) (r#role_B) end);
     disj_splitL=(fun lr -> object method role_B=m.disj_splitL (lr#role_B) end);
     disj_splitR=(fun lr -> object method role_B=m.disj_splitR (lr#role_B) end)
    }
    
    

  let to_ m r1 r2 r3 =
    let (!) x = x.role_label in
    {disj_merge=(fun l r -> !r1.make_obj (m.disj_merge (!r2.call_obj l) (!r3.call_obj r)));
     disj_splitL=(fun lr -> !r2.make_obj (m.disj_splitL @@ !r1.call_obj lr));
     disj_splitR=(fun lr -> !r3.make_obj (m.disj_splitR @@ !r1.call_obj lr));
    }
  let to_a m = to_ m a a a
  let to_b m = to_ m b b b
  let to_c m = to_ m c c c

  let left_middle_or_right =
    {disj_merge=(fun l r -> object method left=l#left method middle=l#middle method right=r#right end);
     disj_splitL=(fun lr -> (lr :> <left : _; middle: _>));
     disj_splitR=(fun lr -> (lr :> <right : _>));
    }

  let left_or_middle =
    {disj_merge=(fun l r -> object method left=l#left method middle=r#middle end);
     disj_splitL=(fun lr -> (lr :> <left : _>));
     disj_splitR=(fun lr -> (lr :> <middle : _>));
    }

  let left_or_middle_right =
    {disj_merge=(fun l r -> object method left=l#left method middle=r#middle method right=r#right end);
     disj_splitL=(fun lr -> (lr :> <left : _>));
     disj_splitR=(fun lr -> (lr :> <middle: _; right : _>));
    }

  let middle_or_right =
    {disj_merge=(fun l r -> object method middle=l#middle method right=r#right end);
     disj_splitL=(fun lr -> (lr :> <middle : _>));
     disj_splitR=(fun lr -> (lr :> <right : _>));
    }
end

include Global
include Local
include Util

(* module Example = struct
 *   open Global
 *   open Local
 *   open Util
 * 
 *   let g =
 *     choice_at a (to_b left_or_right)
 *       (a, (a --> b) left @@ finish)
 *       (a, (a --> b) right @@ finish)
 * 
 *   let ea, eb = get_ch a g, get_ch b g
 * 
 *   (\* role B *\)
 *   let (_:Thread.t) =
 *     Thread.create (fun () ->
 *         match receive eb#role_A with
 *         | `left(_, eb) ->
 *            close eb
 *         | `right(_, eb) ->
 *            close eb) ()
 * 
 *   (\* role A *\)
 *   let () =
 *     if true then begin
 *         let ea = send ea#role_B#left () in
 *         close ea
 *       end else begin
 *         let ea = send ea#role_B#right () in
 *         (\* let ea = send ea#role_B#right () in *\)
 *         close ea
 *       end;
 *     print_endline "example1 finished."
 * end *)