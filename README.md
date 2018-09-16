# snarkette

Snarkette is a pure OCaml implementation of the Groth-Maller SNARK verifier
(and all the requisite number-theoretic primitives), suitable for compiliing
to Javascript using `js_of_ocaml` to be deployed in SNARK-enabled web-apps.

In the service of the Groth-Maller SNARK verifier, it implements the following primitives:

- Prime order finite fields
- Degree 2 field extensions
- Degree 3 field extensions
- Degree 6 field extensions
- Weierstrass curves over arbitrary fields
- The ate pairing

The code has not yet undergone extensive review or testing and as such should not
be used in critical systems.
