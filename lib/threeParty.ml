include Base
include Session
include Global
include Util.Labels

let obj3 a b c =
  lazy (object
        method a=Lazy.force a
        method b=Lazy.force b
        method c=Lazy.force c
      end)

let lval = Lazy.from_val
         
let finish =
  lazy (object
        method a=(Close : (<a:unit; b:unit; c:unit>, close) prot)
        method b=(Close : (<a:unit; b:unit; c:unit>, close) prot)
        method c=(Close : (<a:unit; b:unit; c:unit>, close) prot)
      end)

type a = A
type b = B
type c = C

let force = Lazy.force
                           
let merge3 c1 c2 =
  obj3
    (lazy (Internal.merge (force c1)#a (force c2)#a))
    (lazy (Internal.merge (force c1)#b (force c2)#b))
    (lazy (Internal.merge (force c1)#c (force c2)#c))

let a = {role=A; lens={get=(fun (lazy c) -> c#a); put=(fun s v -> obj3 (lval v) (lazy (force s)#b) (lazy (force s)#c))}}
let b = {role=B; lens={get=(fun (lazy c) -> c#b); put=(fun s v -> obj3 (lazy (force s)#a) (lval v) (lazy (force s)#c))}}
let c = {role=C; lens={get=(fun (lazy c) -> c#c); put=(fun s v -> obj3 (lazy (force s)#a) (lazy (force s)#b) (lval v))}}

let get_sess r m =
  let p = r.lens.get m in
  Sess((object method a=() method b=() method c=() end), p)

let choice_at x = Global.choice_at merge3 x
