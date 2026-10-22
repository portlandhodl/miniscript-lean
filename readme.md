# miniscript-lean

A Lean 4 formalization of **Miniscript** (BIP 379 / sipa's spec at
<https://bitcoin.sipa.be/miniscript/>) type systems, built as the executable
intersection of the two live implementations:

* **Bitcoin Core**'s C++ implementation (`src/script/miniscript.{h,cpp}`,
  commit [`f86c614e`](https://github.com/bitcoin/bitcoin/commit/f86c614e69256b9814c27b0dd096ee46daa71aa3)),
* **rust-miniscript** v13.0.0
  (commit [`96a1c917`](https://github.com/rust-bitcoin/rust-miniscript/commit/96a1c917dacc539f57c13bbcf9dc8e4fd443377a)).

Plus a synthesis of the two: a proof-grade, bitmask-exact model of each
implementation's Miniscript type system, and a growing library of crosswalk
theorems pinning down where they coincide, differ, and diverge.

Built entirely with **Lean 4.35.0**, no mathlib.

```
lake build   # fresh: elan required (stable toolchain via lean-toolchain)
```

## Research corpus (`notes/`)

| file | content |
|---|---|
| `sipa-spec.md` | verbatim extract of Peter Wuille's Miniscript spec (fragment tables, type-system letters, satisfactions, resource limits) |
| `bips.md` | BIP 379 draft text + all related BIPs (380–387, 65, 112, 113, 340, 341, 342, 62, 66, 147) with the normative rules a formalization needs |
| `core-types.md` | Bitcoin Core's type system, bit-for-bit, with file:line references |
| `core-parsing.md` | Bitcoin Core's parser, validity predicates, sanity rules |
| `core-tests.md` | random property tests, reference satisfier model |
| `core-fuzz.md` | fuzz invariants and candidate theorem sketches |
| `core-opcodes.md` | interpreter semantics + consensus limits cheat sheet |
| `rust-*.md` (9 files) | rust-miniscript's type layer, contexts, limits, decode, satisfier, policy compiler, descriptors, interpreter |
| `divergences-typing.md` | typing divergences table (9 entries, classified) |
| `divergences-limits.md` | resource-limit accounting divergences (real bugs inside) |
| `divergences-timelocks.md` | timelock semantics divergences |

## The Lean formalization (`MiniscriptLean/`)

Every mask and formula traces back to a quoted line of C++ or Rust source.
Zero `sorry`/`axiom`. Final build is green.

| Module | Content |
|---|---|
| `Type.lean` | `MSType = BitVec 19` isomorphic to Core's bitmask; `opOr`, `opAnd`, `hasAll` (`<<` matching Core's direction), `sanitize`; algebraic facts via `bv_decide` |
| `Fragment.lean` | 27-fragment `ComputeType` ported line-for-line from `miniscript.cpp`; the `thresh` fold; 37 mask-literal certificates; `coreType` node typer |
| `Rust/Types.lean` | `Base/Input/Correctness/Dissat/Malleability` with every constructor rule from `correctness.rs` / `malleability.rs`; **subtype lattice (reflexive+transitive) proved at all 5 layers**; sanity preservation for all constructors |
| `Crosswalk.lean` | the bridge to `MSType` (`toBits`, `restrict12`, `letters_of_agree`, `agreed`), 13 per-letter lemmas, divergence D1 witness pack |
| `Steps.lean` | wrapper step lemma `wrapA_step` (both directions) |
| `StepsLeaves.lean` | all-leaf equivalence (12 fragments incl. parameterized `older n`/`after n`, both contexts) |
| `StepsWrappers.lean` | `wrapS` success-direction; failure-directions for wrapS/C/V/N/J/D |
| `Master.lean` | `FragSteps` — the obligations table launched the whole-tree proof sits inside |
| `MasterAssembly.lean` | `NodeCorr` predicate and entry-point shape |

### What's proved

* Both implementations' type systems, exactly bit-faithful.
* Their leaf typing agrees and is identical (under the 12 shared letters).
* The wrapper fragments' type rules agree as far as proven (`a:` in full, `s:` + failure-direction of all seven), via a reusable bv_decide pipeline.
* **D1 formalized:** the two implementations differ on exactly one letter of
  the shared alphabet — rust's `d:` wrapper never grants `u`, the spec grants
  it under Tapscript. Witness set `andor(dv:older(1),pk(K),pk(K))` proves
  Core-Tapscript types it, both reject in P2WSH, and masks differ only at `u`.

### What's scaffolded (the honest remainder)

`Master.lean` defines the per-fragment obligations (`FragSteps`) and a custom
tree eliminator (`MsNode.induction`), and `crosswalk_master` composes them into
the whole-tree statement — the induction's remaining step-lemmas (most wrapper
succ directions, the 7 combinators, `thresh`) are mechanical repetitions of the
`wrapA_step` template. They are not yet written; the obligations table is the
formal work list.

## Divergences catalogued for review

ID'd, both sides cited, classified `[harmless-encoding]`, `[accept-set-differs]`,
or `[real bug]`. Notables:

1. **D1** — rust's `d:` wrapper has `u=false` even under Tapscript, where the
   spec/Core grant `u` (all-else identical; proven witness statement).
2. **D2** — rust's `wsh()` descriptor parse skips local limit checks
   (accepts >201-op scripts; `Miniscript::from_str` correctly rejects).
   Looks like a bug at `rust-miniscript/src/descriptor/segwitv0.rs`.
3. **D3** — rust's interpreter omits CSV's `tx.version ≥ 2` rule and CLTV's
   `nSequence ≠ final` rule; PSBT wiring is aware, the direct interpreter isn't.
4. **D4** — `older(0)` can be constructed programmatically in rust
   (`RelLockTime::ZERO` + unchecked constructor), no validation gate.
5. Core has no `main`/`taproot`-free parity: bare/legacy contexts exist only
   in rust; `RawPkH`/`SortedMulti`/`SortedMultiA` likewise.

## Sources

* Spec: <https://bitcoin.sipa.be/miniscript/> (by Pieter Wuille)
* BIP 379 draft (PR #2240): Miniscript BIP text
* Bitcoin Core — <https://github.com/bitcoin/bitcoin>
* rust-miniscript — <https://github.com/rust-bitcoin/rust-miniscript>
