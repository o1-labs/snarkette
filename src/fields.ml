open Core_kernel
open Fold_lib
open Tuple_lib

let ( = ) = `Don't_use_polymorphic_equality

module type Intf = sig
  type t [@@deriving eq, bin_io, sexp, compare]

  val gen : t Quickcheck.Generator.t

  val one : t

  val zero : t

  val ( + ) : t -> t -> t

  val ( * ) : t -> t -> t

  val ( - ) : t -> t -> t

  val ( / ) : t -> t -> t

  val negate : t -> t

  val inv : t -> t

  val square : t -> t
end

module type Fp_intf = sig
  include Intf

  include Stringable.S with type t := t

  type nat

  include Stringable.S with type t := t

  val of_int : int -> t

  val of_bits : bool list -> t option

  val order : nat

  val to_bigint : t -> nat

  val fold_bits : t -> bool Fold.t

  val fold : t -> bool Triple.t Fold.t

  val length_in_bits : int

  val is_square : t -> bool

  val equal : t -> t -> bool

  val sqrt : t -> t

  val random : unit -> t

  val ( ** ) : t -> nat -> t
end

module type Extension_intf = sig
  type base

  include Intf

  val scale : t -> base -> t

  val of_base : base -> t

  val project_to_base : t -> base

  val to_base_elements : t -> base list
end

module Make_fp
    (N : Nat_intf.S) (Info : sig
        val order : N.t
    end) : Fp_intf with type nat := N.t = struct
  include Info

  (* TODO version *)
  type t = N.t [@@deriving bin_io, sexp, compare]

  let to_bigint = Fn.id

  let zero = N.of_int 0

  let one = N.of_int 1

  let length_in_bits = N.num_bits N.(Info.order - one)

  let gen =
    let length_in_int32s = (length_in_bits + 31) / 32 in
    Quickcheck.Generator.(
      map
        (list_with_length length_in_int32s
           (Int32.gen_incl Int32.zero Int32.max_value))
        ~f:(fun xs ->
          List.foldi xs ~init:zero ~f:(fun i acc x ->
              N.log_or acc
                (N.shift_left (N.of_int (Int32.to_int_exn x)) (32 * i)) )
          |> fun x -> N.(x % order) ))

  let fold_bits n : bool Fold_lib.Fold.t =
    { fold=
        (fun ~init ~f ->
          let rec go acc i =
            if Int.(i = length_in_bits) then acc
            else go (f acc (N.test_bit n i)) (i + 1)
          in
          go init 0 ) }

  let fold n = Fold_lib.Fold.group3 ~default:false (fold_bits n)

  let of_bits bits =
    let rec go acc i = function
      | [] ->
          acc
      | b :: bs ->
          let acc = if b then N.log_or acc (N.shift_left one i) else acc in
          go acc (i + 1) bs
    in
    let r = go zero 0 bits in
    if N.( < ) r Info.order then Some r else None

  open N

  let of_int = N.of_int

  let of_string = N.of_string

  let to_string = N.to_string

  let rec extended_euclidean a b =
    if equal b zero then (a, one, zero)
    else
      match extended_euclidean b (a % b) with
      | d, x, y ->
          (d, y, x - (a // b * y))

  let ( + ) x y = (x + y) % Info.order

  let negate x = N.( - ) Info.order x

  let ( - ) x y = (x - y) % Info.order

  let ( * ) x y = x * y % Info.order

  let square x = x * x

  let ( ** ) x n =
    let k = N.num_bits n in
    let rec go acc i =
      if Int.(i < 0) then acc
      else
        let acc = acc * acc in
        let acc = if N.test_bit n i then acc * x else acc in
        go acc Int.(i - 1)
    in
    go one Int.(k - 1)

  let%test_unit "exp test" = [%test_eq: t] (of_int 8) (of_int 2 ** of_int 3)

  let is_square =
    let euler = N.((Info.order - one) // of_int 2) in
    fun x -> N.equal (x ** euler) one

  let inv_no_mod x =
    let _, a, _b = extended_euclidean x Info.order in
    a

  let inv x = inv_no_mod x % Info.order

  let ( / ) x y = x * inv_no_mod y

  module Sqrt_params = struct
    let two_adicity n =
      let rec go i = if N.test_bit n i then i else go Int.(i + 1) in
      go 0

    type nonrec t =
      {two_adicity: int; quadratic_non_residue_to_t: t; t_minus_1_over_2: t}

    let first f =
      let rec go i = match f i with Some x -> x | None -> go Int.(i + 1) in
      go 1

    let create () =
      let p_minus_one = N.(Info.order - one) in
      let s = two_adicity p_minus_one in
      let t = N.shift_right p_minus_one s in
      let quadratic_non_residue =
        first (fun i ->
            let i = of_int i in
            Option.some_if (not (is_square i)) i )
      in
      { two_adicity= s
      ; quadratic_non_residue_to_t= quadratic_non_residue ** t
      ; t_minus_1_over_2= (t - one) / of_int 2 }

    let t = lazy (create ())
  end

  let rec loop ~while_ ~init f =
    if while_ init then loop ~while_ ~init:(f init) f else init

  let equal x y =
    N.equal (x % Info.order) (y % Info.order)

  let ( = ) = equal

  let random () = N.random Info.order

  let rec pow2 b n = if n > 0 then pow2 (square b) Int.(n - 1) else b

  let%test_unit "pow2" =
    let b = 7 in
    if N.(of_int Int.(7 ** 8) < order) then
      [%test_eq: t] (pow2 (of_int b) 3) (of_int Int.(7 ** 8))
    else ()

  let sqrt =
    let pow2_order b =
      loop
        ~while_:(fun (b2m, _) -> not (b2m = one))
        ~init:(b, 0)
        (fun (b2m, m) -> (square b2m, Int.succ m))
      |> snd
    in
    let module Loop_params = struct
      type nonrec t = {z: t; b: t; x: t; v: int}
    end in
    let open Loop_params in
    fun a ->
      let { Sqrt_params.two_adicity= v
          ; quadratic_non_residue_to_t= z
          ; t_minus_1_over_2 } =
        Lazy.force Sqrt_params.t
      in
      let w = a ** t_minus_1_over_2 in
      let x = a * w in
      let b = x * w in
      let {x; _} =
        loop
          ~while_:(fun p -> not (p.b = one))
          ~init:{z; b; x; v}
          (fun {z; b; x; v} ->
            let m = pow2_order b in
            let w = pow2 z Int.(v - m - 1) in
            let z = square w in
            {z; b= b * z; x= x * w; v= m} )
      in
      x

  let%test_unit "sqrt agrees with integer square root on small values" =
    let rec mem a = function
      | [] ->
          ()
      | x :: xs -> (
        try [%test_eq: t] a x with _ -> mem a xs )
    in
    let gen = Int.gen_incl 1 Int.max_value_30_bits in
    Quickcheck.test ~trials:10 gen ~f:(fun n ->
        let n = abs n in
        let n2 = Int.(n * n) in
        mem (sqrt (of_int n2)) [of_int n; Info.order - of_int n] )
end

module type Degree_2_extension_intf = sig
  type base

  include Extension_intf with type base := base and type t = base * base
end

module type Degree_3_extension_intf = sig
  type base

  include Extension_intf with type base := base and type t = base * base * base
end

let ( % ) x n =
  let r = x mod n in
  if r < 0 then r + n else r

let find_wnaf (type t) (module N : Nat_intf.S with type t = t) window_size
    scalar =
  let one = N.of_int 1 in
  let first_k_bits c k =
    let k_bits = N.(shift_left one k - one) in
    N.to_int_exn (N.log_and k_bits c)
  in
  let length = N.num_bits scalar in
  let res = Array.init (length + 1) ~f:(fun _ -> 0) in
  let zero = N.of_int 0 in
  let rec go c j =
    if N.equal zero c then ()
    else
      let u, c =
        if N.test_bit c 0 then
          let u =
            let u = first_k_bits c (window_size + 1) in
            if u > 1 lsl window_size then u - (1 lsl (window_size + 1)) else u
          in
          let c = N.(c - of_int u) in
          (u, c)
        else (0, c)
      in
      res.(j) <- u ;
      go (N.shift_right c 1) (j + 1)
  in
  go scalar 0 ; res

module Make_fp3
    (Fp : Intf) (Info : sig
        val non_residue : Fp.t

        val frobenius_coeffs_c1 : Fp.t array

        val frobenius_coeffs_c2 : Fp.t array
    end) : sig
  include Degree_3_extension_intf with type base = Fp.t

  val non_residue : Fp.t

  val frobenius : t -> int -> t
end = struct
  include Info

  type base = Fp.t

  type t = Fp.t * Fp.t * Fp.t [@@deriving eq, bin_io, sexp, compare]

  let gen = Quickcheck.Generator.tuple3 Fp.gen Fp.gen Fp.gen

  let to_base_elements (x, y, z) = [x; y; z]

  let componentwise f (x1, x2, x3) (y1, y2, y3) = (f x1 y1, f x2 y2, f x3 y3)

  let of_base x = (x, Fp.zero, Fp.zero)

  let project_to_base (x, _, _) = x

  let one = of_base Fp.one

  let zero = of_base Fp.zero

  let scale (x1, x2, x3) s = Fp.(s * x1, s * x2, s * x3)

  let negate (x1, x2, x3) = Fp.(negate x1, negate x2, negate x3)

  let ( + ) = componentwise Fp.( + )

  let ( - ) = componentwise Fp.( - )

  let ( * ) (a1, b1, c1) (a2, b2, c2) =
    let a = Fp.(a1 * a2) in
    let b = Fp.(b1 * b2) in
    let c = Fp.(c1 * c2) in
    let open Fp in
    ( a + (non_residue * (((b1 + c1) * (b2 + c2)) - b - c))
    , ((a1 + b1) * (a2 + b2)) - a - b + (non_residue * c)
    , ((a1 + c1) * (a2 + c2)) - a + b - c )

  let square (a, b, c) =
    let s0 = Fp.square a in
    let ab = Fp.(a * b) in
    let s1 = Fp.(ab + ab) in
    let s2 = Fp.(square (a - b + c)) in
    let bc = Fp.(b * c) in
    let s3 = Fp.(bc + bc) in
    let s4 = Fp.square c in
    let open Fp in
    (s0 + (non_residue * s3), s1 + (non_residue * s4), s1 + s2 + s3 - s0 - s4)

  let inv (a, b, c) =
    let open Fp in
    let t0 = square a in
    let t1 = square b in
    let t2 = square c in
    let t3 = a * b in
    let t4 = a * c in
    let t5 = b * c in
    let c0 = t0 - (non_residue * t5) in
    let c1 = (non_residue * t2) - t3 in
    let c2 = t1 - t4 in
    let t6 = (a * c0) + (non_residue * ((c * c1) + (b * c2))) |> inv in
    (t6 * c0, t6 * c1, t6 * c2)

  let ( / ) x y = x * inv y

  let frobenius (c0, c1, c2) power =
    let open Fp in
    let open Info in
    let i = power mod 3 in
    (c0, frobenius_coeffs_c1.(i) * c1, frobenius_coeffs_c2.(i) * c2)
end

module Make_fp2
    (Fp : Intf) (Info : sig
        val non_residue : Fp.t
    end) : sig
  include Degree_2_extension_intf with type base = Fp.t
end = struct
  type base = Fp.t

  type t = Fp.t * Fp.t [@@deriving eq, bin_io, sexp, compare]

  let gen = Quickcheck.Generator.tuple2 Fp.gen Fp.gen

  let of_base x = (x, Fp.zero)

  let to_base_elements (x, y) = [x; y]

  let project_to_base (x, _) = x

  let one = of_base Fp.one

  let zero = of_base Fp.zero

  let componentwise f (x1, x2) (y1, y2) = (f x1 y1, f x2 y2)

  let ( + ) = componentwise Fp.( + )

  let ( - ) = componentwise Fp.( - )

  let scale (x1, x2) s = Fp.(s * x1, s * x2)

  let negate (a, b) = Fp.(negate a, negate b)

  let square (a, b) =
    let open Info in
    let ab = Fp.(a * b) in
    Fp.(((a + b) * (a + (non_residue * b))) - ab - (non_residue * ab), ab + ab)

  let ( * ) (a1, b1) (a2, b2) =
    let open Fp in
    let a = a1 * a2 in
    let b = b1 * b2 in
    (a + (Info.non_residue * b), ((a1 + b1) * (a2 + b2)) - a - b)

  let inv (a, b) =
    let open Fp in
    let t0 = square a in
    let t1 = square b in
    let t2 = t0 - (Info.non_residue * t1) in
    let t3 = inv t2 in
    let c0 = a * t3 in
    let c1 = negate (b * t3) in
    (c0, c1)

  let ( / ) x y = x * inv y
end

module Make_fp6
    (N : Nat_intf.S)
    (Fp : Intf)
    (Fp2 : Degree_2_extension_intf with type base = Fp.t) (Fp3 : sig
        include Degree_3_extension_intf with type base = Fp.t

        val frobenius : t -> int -> t

        val non_residue : Fp.t
    end) (Info : sig
      val non_residue : Fp.t

      val frobenius_coeffs_c1 : Fp.t array
    end) : sig
  include Degree_2_extension_intf with type base = Fp3.t

  val mul_by_2345 : t -> t -> t

  val frobenius : t -> int -> t

  val cyclotomic_exp : t -> N.t -> t

  val unitary_inverse : t -> t
end = struct
  type t = Fp3.t * Fp3.t [@@deriving eq, bin_io, sexp, compare]

  type base = Fp3.t

  let gen = Quickcheck.Generator.tuple2 Fp3.gen Fp3.gen

  let to_base_elements (x, y) = [x; y]

  let int_sub = ( - )

  let of_base x = (x, Fp3.zero)

  let project_to_base (x, _) = x

  let zero = of_base Fp3.zero

  let one = of_base Fp3.one

  let componentwise f (x1, x2) (y1, y2) = (f x1 y1, f x2 y2)

  let ( + ) = componentwise Fp3.( + )

  let ( - ) = componentwise Fp3.( - )

  let scale (x1, x2) s = Fp3.(s * x1, s * x2)

  let mul_by_non_residue ((c0, c1, c2) : Fp3.t) =
    Fp.(Info.non_residue * c2, c0, c1)

  let mul_by_2345 (a1, b1) (a2, b2) =
    let open Info in
    let a1_0, a1_1, a1_2 = a1 in
    let _, _, a2_2 = a2 in
    (let a2_0, a2_1, _ = a2 in
     assert (Fp.(equal a2_0 zero)) ;
     assert (Fp.(equal a2_1 zero))) ;
    let a =
      Fp.(a1_1 * a2_2 * non_residue, a1_2 * a2_2 * non_residue, a1_0 * a2_2)
    in
    let b = Fp3.(b1 * b2) in
    let beta_b = mul_by_non_residue b in
    Fp3.(a + beta_b, ((a1 + b2) * (a2 + b2)) - a - b)

  let square (a, b) =
    let ab = Fp3.(a * b) in
    let open Fp3 in
    ( ((a + b) * (a + mul_by_non_residue b)) - ab - mul_by_non_residue ab
    , ab + ab )

  let negate (a, b) = Fp3.(negate a, negate b)

  let ( * ) (a1, b1) (a2, b2) =
    let a = Fp3.(a1 * a2) in
    let b = Fp3.(b1 * b2) in
    let beta_b = mul_by_non_residue b in
    Fp3.(a + beta_b, ((a1 + b1) * (a2 + b2)) - a - b)

  let inv (a, b) =
    let t1 = Fp3.square b in
    let t0 = Fp3.(square a - mul_by_non_residue t1) in
    let new_t1 = Fp3.inv t0 in
    Fp3.(a * new_t1, negate (b * new_t1))

  let ( / ) x y = x * inv y

  let unitary_inverse (x, y) = (x, Fp3.negate y)

  let cyclotomic_square ((c00, c01, c02), (c10, c11, c12)) =
    let a : Fp2.t = (c00, c11) in
    let b : Fp2.t = (c10, c02) in
    let c : Fp2.t = (c01, c12) in
    let asq = Fp2.square a in
    let bsq = Fp2.square b in
    let csq = Fp2.square c in
    let a_a =
      let open Fp in
      let a_a = fst asq - fst a in
      a_a + a_a + fst asq
    in
    let a_b =
      let open Fp in
      let a_b = snd asq + snd a in
      a_b + a_b + snd asq
    in
    let b_a =
      let open Fp in
      let b_tmp = Fp3.non_residue * snd csq in
      let b_a = b_tmp + fst b in
      b_a + b_a + b_tmp
    in
    let b_b =
      let open Fp in
      let b_b = fst csq - snd b in
      b_b + b_b + fst csq
    in
    let c_a =
      let open Fp in
      let c_a = fst bsq - fst c in
      c_a + c_a + fst bsq
    in
    let c_b =
      let open Fp in
      let c_b = snd bsq + snd c in
      c_b + c_b + snd bsq
    in
    ((a_a, c_a, b_b), (b_a, a_b, c_b))

  let cyclotomic_exp x exponent =
    let x_inv = inv x in
    let naf = find_wnaf (module N) 1 exponent in
    let rec go found_nonzero res i =
      if i < 0 then res
      else
        let res = if found_nonzero then cyclotomic_square res else res in
        if naf.(i) <> 0 then
          let found_nonzero = true in
          let res = if naf.(i) > 0 then res * x else res * x_inv in
          go found_nonzero res (int_sub i 1)
        else go found_nonzero res (int_sub i 1)
    in
    go false one (int_sub (Array.length naf) 1)

  let frobenius (c0, c1) power =
    ( Fp3.frobenius c0 power
    , Fp3.(scale (frobenius c1 power) Info.frobenius_coeffs_c1.(power mod 6))
    )
end
