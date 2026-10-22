# Bitcoin BIPs relevant to the Miniscript formalization

Research notes for the `miniscript-lean` project. Fetched 2026-10-21 from
https://raw.githubusercontent.com/bitcoin/bips/master/bip-XXXX.mediawiki, except
BIP 379 (draft, see below). Companion note: `sipa-spec.md` (the
bitcoin.sipa.be/miniscript spec transcription, which pre-dates the BIP draft and
differs from it in some details — the BIP-379 text below is the newer, more
formal target).

Each entry: number / title / status, one paragraph on relevance to the
formalization, then **normative rules a Lean proof must encode**.

---

## BIP 379 (draft): Miniscript — Status: Draft (unmerged)

**Where it lives.** BIP number 379 was assigned 2023-10-10. The full text is
*not* in `bitcoin/bips` master (no `bip-0379.*` file). It reached the bips repo
as **PR bitcoin/bips#1610** ("379: Miniscript", opened 2024-06-06 by Ava Chow,
closed 2024-06-27 *unmerged*; head branch `achow101/bips@miniscript`, adds
`bip-0379.md`). There is a follow-up **PR bitcoin/bips#2240** (open since
2026-08-06, guggero) that modifies `bip-0379.md` and adds test-vector files
(`bip-0379/valid_from_alloy.txt`, `invalid.txt`, `opcodes.txt`,
`limits[_tap].txt`, `props_from_rust[_tap].tsv`, `scripts_from_rust[_tap].tsv`,
`redeem.json`, plus a Go harness). Search caveat: there is **no long-standing
PR authored by sipa or sanket1729 against bitcoin/bips** — the draft circulated
since 2019 via the `sipa/miniscript` repo and the bitcoin.sipa.be/miniscript
website (see `sipa-spec.md`), and was only turned into an official BIP draft by
achow101's #1610. Authors listed in the draft header: Pieter Wuille, Andrew
Poelstra, Sanket Kanjalkar, Antoine Poinsot, Ava Chow. `Requires: 380`.
Text used here: `bip-0379.md` at commit `c923f2e` (PR #2240's head), 543 lines,
which is #1610's file plus test-vector content.

**Relevance.** This is the primary specification the Lean development should
prove things about: it defines the fragment translation table, the correctness
type system (B/V/K/W + modifiers), the timelock-mixing rule, the malleability
type system (s/f/e), the satisfaction/dissatisfaction tables, the non-malleable
satisfaction algorithm, and the resource limits. Its Security section names the
two headline properties: **consensus soundness** (no consensus-valid witness
exists unless the Miniscript spending conditions hold) and **standardness
completeness** (every spending path admits a standardness-valid witness,
assuming resource limits and no timelock mixing) — the natural top-level
theorem statements for this repo.

**Normative rules to encode:**

1. **Contexts.** Applicable to P2WSH (BIP 141) and Tapscript (BIP 342) embedded
   scripts only; P2SH and bare scripts excluded. Fragments are expected inside
   BIP 382 `wsh()` and BIP 386 `tr()` descriptors, with the corresponding key
   expression restrictions (BIP 382 for P2WSH, BIP 386 for P2TR). Translation
   table must be reproduced exactly (including `<20>`-style pushes for the
   `len(x)=32` checks in hash fragments, wrapping `s:`/`a:` alt-stack ops, and
   `v:` being "VERIFY appended or last-opcode replaced by its VERIFY version").
2. **Correctness types.** Four base types **B, V, K, W**; modifiers
   **z (zero-arg), o (one-arg), n (nonzero), d (dissatisfiable), u (unit)**,
   and the document's "k" modifier (**no timelock mixing**). The "Requires"
   column of the type table is part of validity (e.g. `andor` requires
   X:Bdu and Y,Z both B/K/V; `or_b` requires X:Bd, Z:Wd; `thresh(k,…)` requires
   1 ≤ k ≤ n, X₁:Bdu, rest Wdu; wrappers `a:`/`s:`/`c:`/`d:`/`v:`/`j:`/`n:` have
   their own preconditions like X:Bo for `s:`, X:Vz for `d:`, X:Bn for `j:`).
   Expressions failing their Requires → not valid Miniscript (a judgment-level
   rejection, separate from script failure).
3. **Timelock argument bounds.** `older(n)`/`after(n)` require **1 ≤ n < 2³¹**
   (≤ 4-byte minimal script-number push; see BIP 65/112 on the looser 5-byte
   consensus operand). Test-vector boundaries: after() type boundary
   499999999/500000000 (≙2⁹·… = LOCKTIME_THRESHOLD 5·10⁸); older() type
   boundary 4194304/4194305 (2²² = SEQUENCE_LOCKTIME_TYPE_FLAG).
4. **Timelock type mixing rule.** Within `and` combinators (`and_v`, `and_b`,
   `and_n`/`andor` used as and) and `thresh` with **k ≥ 2**: it is illegal for
   both absolute-height and absolute-time timelocks to appear, and illegal for
   both relative-height and relative-time timelocks to appear. Mixing absolute
   with relative (any base) and all mixes inside the other (or-type)
   combinators are legal. This is the property behind the "k" type modifier and
   must be a syntactic invariant in the type checker.
5. **Threshold bounds.** `multi(k,…)` (P2WSH only): 1 ≤ k ≤ n ≤ 20.
   `multi_a(k,…)` (Tapscript only): 1 ≤ k ≤ n (BIP 387 caps n at 999). The two
   fragments must compile to exactly `<k> <key_1> … <key_n> <n> CHECKMULTISIG`
   and `<key_1> CHECKSIG <key_2> CHECKSIGADD … <key_n> CHECKSIGADD <k>
   NUMEQUAL` respectively.
6. **Malleability types.** Modifiers **s (signed), f (forced), e (expressive)**
   with the per-fragment Requires (e.g. `andor` needs e_X ∧ (s_X ∨ s_Y ∨ s_Z);
   `thresh` needs all-e and at most k non-s; `or_b` needs e_X ∧ e_Z ∧ (s_X ∨
   s_Z); `c:X` grants s; hash fragments grant *none* of s/f/e; timelocks grant
   f). Violation ⇒ the expression is malleable and so is everything containing
   it; APIs must report all three as false there. The stated analysis
   assumptions (attacker has no private keys, sees one witness, has only the
   honest users' preimages, no repeated keys in the script, attacker constrained
   by standardness rules) should become hypotheses of the non-malleability
   theorem.
7. **Satisfaction/dissatisfaction tables**, including the struck-through
   *non-canonical* options (e.g. `and_v` dsat `[dsat(Y) sat(X)]`,
   `or_b`/`and_b`/`thresh` overcomplete options) which are consensus-valid but
   must never be produced by the satisfaction algorithm; `multi` dsat is
   k+1 zeroes (NULLDUMMY — see BIP 147); `pk_k` dsat is `0` (empty sig is legal
   even under BIP 66). Hash fragments: dissatisfiable by any 32-byte vector ≠
   preimage (32-byte size enforced by `SIZE 0x20 EQUALVERIFY` in the fragment).
8. **Non-malleable satisfaction algorithm.** Recursive per-fragment solver over
   DSAT/SAT options with DONTUSE and HASSIG markers: hash-fragment dsats are
   treated as DONTUSE; the non-canonical `and_b`/`or_b`/`thresh` options are
   DONTUSE (HASSIG-propagated); DONTUSE contaminates combinations; if more than
   one candidate solution lacks HASSIG the result is DONTUSE; if all
   HASSIG-marked solutions are DONTUSE return DONTUSE-HASSIG; otherwise pick the
   witness-minimal solution. Top level: fail if no solution, or if the script
   uses timelocks but the solution is not HASSIG (preimages/timelocks without a
   signature allow third parties to change nLockTime/nSequence).
9. **Resource limits** (part of "sanity"): P2WSH script ≤ 3600 bytes
   (standardness); P2WSH executed non-push opcodes + participating
   CHECKMULTISIG keys ≤ 201 (consensus); stack+altstack ≤ 1000 elements during
   execution (consensus, both contexts); P2WSH witness ≤ 100 elements excluding
   the script (standardness). Tapscript: no opcode/script-size limits (block
   weight only). Static analysis bounds (`op_count`, `sat_witness_elements`,
   `sat_size`, `exec_stack`) are per-fragment maxima — Lean proofs should show
   the static bounds imply the runtime limits.
10. **Backwards-compat note.** Miniscript is syntax-compatible with BIP 380
    descriptors and is *only* valid in `wsh()`/`tr()` contexts; `pk()`,
    `pkh()`, `multi()`, `multi_a()` overlap with descriptor primitives and must
    produce byte-identical scripts. Test vectors: massive corpora from
    rust-miniscript `src/miniscript/ms_tests.rs @ 698b97f`, cross-checked
    against btcd — usable as Lean evaluation/extraction sanity targets.

---

## BIP 380: Output Script Descriptors General Operation — Status: Deployed

Wuille & Chow, assigned 2021-06-27.

**Relevance.** Miniscript (BIP 379) is explicitly defined as an extension of
this language: a Miniscript expression is a `SCRIPT` expression in descriptor
syntax, and all keys inside it are BIP 380 `KEY` expressions. A Lean
formalization can treat descriptors as the parser/AST layer for the fragments
(wrappers, colons, commas, parentheses) shared with Miniscript. The 8-character
checksum and its BCH-code internals can be left unformalized — see "checksum
deferred" below.

**Normative rules to encode:**

- Top level is a `SCRIPT` expression; optional `#CHECKSUM` suffix of exactly 8
  characters; checksum optional for parsing, applications may require it.
- `KEY` grammar: optional origin `[FINGERPRINT/PATH…]` (exactly 8 hex chars,
  steps `NUM` or `NUMh`, `h` interchangeable with `'`), then one of: hex pubkey
  (66-hex `02`/`03` compressed, or 130-hex `04` uncompressed), WIF private key,
  or `xpub`/`xprv` extended key optionally followed by `/NUM` steps and a
  single trailing `/*h?` wildcard.
- Key-derived scripts must not serialize pubkeys uncompressed
  ("The derived key must be not be serialized as an uncompressed public key");
  script expressions (382/386) impose further serialization restrictions — BIP
  379 inherits these per context.
- Private keys may not have derivation steps appended; wildcard `*` not allowed
  inside origin info; derivation indices < 2³¹ (test vectors assert
  `/2147483648` without a hardened marker is invalid).
- Normalization for hardened derivation on watch-only export (derive xpub at
  last hardened step, adjust/insert origin info).
- Allowed-character set is fixed (3×32 groups) so the checksum retains its
  error guarantees.
- **Checksum — deferred for the Lean formalization.** Recorded for
  completeness: `#` + 8 chars from bech32 charset `qpzry9x8gf2tvdw0s3jn54khce6
  mua7l`; validity iff the `descsum_polymod` BCH code returns 1 over the
  expanded symbol vector; guarantees: 1 symbol error always detected, 2–3
  errors up to 49154 chars, 4 up to 507 chars, 5 up to 77 chars, random errors
  pass with probability 2⁻⁴⁰. Encoding bytes are irrelevant to script
  semantics, so it is out of scope for proofs; keep as an assumption if a
  parser is formalized ("applications may choose to reject descriptors without
  checksum").

---

## BIP 381: Non-Segwit Output Script Descriptors (pk, pkh, sh) — Status: Deployed

Wuille & Chow, 2021-06-27.

**Relevance.** Defines `pk(KEY)`, `pkh(KEY)`, `sh(SCRIPT)`. BIP 379 says
Miniscript's `pk`/`pkh` fragments parse to the same semantic meanings and
produce the same scripts as these descriptor primitives — a theorem to keep:
the Miniscript translation `<key> CHECKSIG` resp. `DUP HASH160 <HASH160(key)>
EQUALVERIFY CHECKSIG` equals BIP 381's templates. `sh()` exclusion from
Miniscript contexts justifies BIP 379's "P2SH excluded".

**Normative rules to encode:**

- `pk(KEY)` → `<KEY> OP_CHECKSIG`; usable at any level.
- `pkh(KEY)` → `OP_DUP OP_HASH160 <HASH160(KEY)> OP_EQUALVERIFY OP_CHECKSIG`;
  top level or inside `sh()`/`wsh()`.
- `sh(SCRIPT)` → `OP_HASH160 <HASH160(SCRIPT)> OP_EQUAL`; top level only;
  emits the redeemScript = script of the argument.
- Type discipline: `pk`/`pkh` take only KEY, `sh` takes only SCRIPT (parse
  errors otherwise, per invalid test vectors).

## BIP 382: Segwit Output Script Descriptors (wpkh, wsh) — Status: Deployed

Wuille & Chow, 2021-06-27.

**Relevance.** This is the normative source of the P2WSH context for
Miniscript: `wsh(SCRIPT)` carries the witnessScript that Miniscript compiles
to, and pins the key-serialization restriction BIP 379 defers to: every key
expression inside any script under `wsh()` must produce **compressed (33-byte,
`02`/`03`) public keys**. For the Lean model: the fragment layer applies only
when all keys are compressed.

**Normative rules to encode:**

- `wpkh(KEY)` → `OP_0 <HASH160(KEY)>`, keys compressed-only; top level or
  inside `sh()`.
- `wsh(SCRIPT)` → `OP_0 <SHA256(SCRIPT)>`; top level or inside `sh()`; the
  witnessScript = argument's produced script; **every key expression anywhere
  inside → compressed keys only**; `wsh()` may not nest inside `wsh()`,
  `wpkh()` not inside `wsh()` (invalid test vectors).

## BIP 383: Multisig Output Script Descriptors (multi, sortedmulti) — Status: Deployed

Wuille & Chow, 2021-06-27.

**Relevance.** `multi()`/Miniscript-`multi()` produce identical scripts by BIP
379's backwards-compat clause, so BIP 383 supplies the canonical template and
the number-encoding requirement the translation table inherits (and the lean
type checker's `1 ≤ k ≤ n ≤ 20` bound for P2WSH multi). Also defines the
lockstep-derivation convention for multiple xpubs (relevant if key derivation
is modeled).

**Normative rules to encode:**

- Script template `<k> KEY₁ … KEYₙ <n> OP_CHECKMULTISIG`, `k ≤ n`; k and n are
  **minimally encoded**: OP_0…OP_16 for values ≤ 16, otherwise a push of the
  signed little-endian value without padding (CScriptNum minimal encoding).
- Key-count limits by context: top level n ≤ 3; under `sh()` n ≤ 15 compressed
  (resp. 7 uncompressed) because the redeemScript push ≤ 520 bytes (consensus
  push limit); elsewhere (i.e. in `wsh()`) **n ≤ 20** — the CHECKMULTISIG
  consensus maximum, same as BIP 379's multi bound.
- `sortedmulti()` = multi with keys sorted lexicographically *after* all
  derivation (lexicographic on the on-script serialization).
- Multiple extended keys in one expression derive in lockstep (same child
  index for all).

## BIP 384: combo() Output Script Descriptors — Status: Deployed

Wuille & Chow, 2021-06-27.

**Relevance.** Marginal: `combo(KEY)` yields the legacy P2PK/P2PKH (and P2WPKH,
P2SH-P2WPKH for compressed keys) templates. No Miniscript interaction (top
level only); only worth noting so the formalization can exclude it from the
fragment grammar.

**Normative rules to encode:** top-level only; produces P2PK and P2PKH always,
plus P2WPKH and P2SH-P2WPKH iff the key is compressed; no `SCRIPT` argument
allowed.

## BIP 385: raw() and addr() Output Script Descriptors — Status: Deployed

Wuille & Chow, 2021-06-27.

**Relevance.** Escape hatches: `raw(HEX)` wraps an arbitrary script; `addr()`
wraps an address. Both are top-level-only and by construction outside the
Miniscript fragment grammar — they delimit the region of descriptor space the
formalization *doesn't* cover.

**Normative rules to encode:** `raw(HEX)` → the hex-decoded script, `addr(ADDR)`
→ the scriptPubKey the address decodes to; both top-level only (nesting under
`sh`/`wsh` is invalid).

## BIP 386: tr() Output Script Descriptors — Status: Deployed

Wuille & Chow, 2021-06-27.

**Relevance.** Normative source of the Tapscript/P2TR context for Miniscript:
`tr(KEY, TREE)` holds a tapleaf-full of Miniscript. It introduces the TREE
expression grammar (`{A,B}` braces nesting) and the **x-only key expression**
BIP 379's Tapscript fragments rely on. Note BIP 386's "Backwards Compatibility"
section explicitly names BIP 379's Miniscript expressions (and BIP 387's
`multi_a`/`sortedmulti_a`) as the script expressions usable inside TREE.

**Normative rules to encode:**

- `tr(KEY)` and `tr(KEY, TREE)` are top-level only; every key expression under a
  `tr()` must produce **x-only public keys** (a 64-hex-char (= 32-byte) key
  expression is defined for this context; uncompressed keys forbidden;
  compressed keys implicitly truncated to x-only; derived keys serialize
  x-only).
- `tr(KEY)`: scriptPubKey = `OP_1 <32-byte Q>` where `Q = lift_x(KEY) +
  int(hash_TapTweak(bytes(lift_x-sometic)))`... precisely `Q = P +
  int(HashTapTweak(bytes(P)))G`, i.e. the output key **commits to an
  unspendable script path** (never a bare key) — mirrors BIP 341's
  recommendation and is a security-relevant construct to model when key-path is
  irrelevant (as in Miniscript-in-tapscript usage).
- `tr(KEY, TREE)`: `merkle_root = HashTapBranch(TREE)`, `Q = P +
  int(HashTapTweak(bytes(P) ‖ merkle_root))G`, scriptPubKey `OP_1
  <32-byte output key>`.
- TREE grammar: a leaf is any script expression legal at that level; a node is
  `{TREE, TREE}`.

## BIP 387: Tapscript Multisig Output Script Descriptors (multi_a, sortedmulti_a) — Status: Deployed

Wuille & Chow, assigned 2024-04-17. (Not on the original task list; included
because it is directly Miniscript-adjacent: it is the descriptor-standardized
form of BIP 379's `multi_a`.)

**Relevance.** Gives the exact `multi_a` script template and its k-encoding
subtleties (threshold > 16 is a CScriptNum push, ≤ 16 is OP_N), and proves the
phrase "CHECKMULTISIG-replacement with CHECKSIGADD" used throughout
Miniscript-Tapscript. For the Lean model this is the normative counterpart of
the BIP-379 Tapscript multisig fragment.

**Normative rules to encode:**

- `multi_a(k, KEY₁…KEYₙ)` → `KEY₁ OP_CHECKSIG KEY₂ OP_CHECKSIGADD … KEYₙ
  OP_CHECKSIGADD OP_k OP_NUMEQUAL` (k ≤ 16), resp. `… <k> OP_NUMEQUAL`
  (minimal-push `<k>`) for k > 16; `k ≤ n`; **usable only inside `tr()`**;
  `n ≤ 999` (bounded by the 1000-element stack limit, not by 201-op).
- `sortedmulti_a()` sorts x-only keys lexicographically after derivation;
  lockstep derivation for multiple extended keys, as in BIP 383.

---

## BIP 340: Schnorr Signatures for secp256k1 — Status: Deployed

Wuille, Nick, Ruffing, assigned 2020-01-19.

**Relevance.** Signature scheme verified by Tapscript's CHECKSIG /
CHECKSIGADD (BIP 342), i.e. by every `pk`, `pk_h` (via `c:`), `multi_a` in BIP
379's Tapscript translation table. A formalization needs: the x-only public-key
format (which BIPS 386/387 key expressions denote), the verification equation,
and the fact that signatures are fixed-size 64 bytes (+ optional sighash byte)
— used by BIP 379's witness-size analysis (66-byte Schnorr sig incl. length
prefix and sighash… vs 73-byte ECDSA). Non-malleability of Schnorr (SUF-CMA)
removes the ECDSA (r, n−s) malleability class that BIP 62/146 worried about —
one fewer malleability channel to model on the Tapscript side.

**Normative rules to encode:**

- Public keys are 32-byte x-only encodings of secp256k1 points with *even* Y
  (`lift_x(x)`: x < p, c = x³+7, y = c^((p+1)/4), y² ≡ c, choose even y).
- Signatures are 64-byte (r ‖ s); *Verify*: r < p, s < n, e =
  hash_BIP0340/challenge(r ‖ P ‖ m), R = sG − eP, fail if R infinite or y(R)
  odd or x(R) ≠ r.
- Every public key has two secret keys (`sk` and `n − sk`); key prefixing makes
  sigs for tweaked keys non-transferable (protects against related-key attacks
  — matters because Taproot keys are tweaked, BIP 341).
- Tagged hashes: hash_name(x) = SHA256(SHA256(name) ‖ SHA256(name) ‖ x).
- Batch verification agrees with individual verification except with negligible
  probability (justifies modeling CHECKSIGADD as "ordinary" addition).

## BIP 341: Taproot: SegWit v1 spending rules — Status: Deployed

Wuille, Nick, Towns, assigned 2020-01-19. Activated at block 709632.

**Relevance.** The transaction-envelope that surrounds BIP 379 Miniscript in
tapscript context: how `tr()` outputs are built (tweak `Q = P +
int(hash_TapTweak(P ‖ m))G`), how the *script path* witness reveals exactly one
leaf, and the sighash commitment structure (common signature message incl.
`nLockTime`, per-input `nSequence` — which is what makes "timelocks committed
by the witness iff a signature exists" true, an assumption in BIP 379's
malleability analysis). Also provides the 65-byte sighash-suffix rule relevant
to witness-size bounds.

**Normative rules to encode:**

- Taproot output = segwit version 1 with exactly 32-byte witness program,
  non-P2SH-wrapped; otherwise BIP341 rules don't apply.
- Witness ≥ 2 elements and last begins with 0x50 ⇒ annex, removed (reserved;
  should not appear). Exactly 1 element left ⇒ key path: that element is a
  BIP340 schnorr signature for `q`. Otherwise script path: second-to-last is
  the tapscript `s`, last is control block `c`.
- **Control block:** `len(c) = 33 + 32m`, 0 ≤ m ≤ 128; `c[0] & 0xfe` = leaf
  version (even, ≠ 0x50); `c[1:33]` = internal key `p` (must lift_x); Merkle
  path `c[33+32j:65+32j]` hashed pairwise with *lexicographically sorted*
  children via hash_TapBranch; leaf hash = hash_TapLeaf(v ‖
  compact_size(len(s)) ‖ s); tweak t = hash_TapTweak(p ‖ merkle root) must be
  < curve order; `Q = P + tG` must satisfy `q = x(Q)` and parity bit `c[0]&1 =
  y(Q) mod 2`.
- Script-path execution uses BIP 342 rules for leaf version 0xc0; unknown leaf
  versions must *succeed* (future soft-fork hook).
- Key-path signature: 64 bytes ⇒ SIGHASH_DEFAULT (0x00) implied; 65 bytes ⇒
  last byte ≠ 0x00 (0x00 forbidden there to prevent third-party malleation to
  65-byte form); any other length invalid. hash_type restricted to defined set
  (0x00–0x03, 0x81–0x83); SIGHASH_SINGLE requires a corresponding output.
- SigMsg commits to nVersion, nLockTime, prevouts, amounts, scriptPubKeys,
  sequences, outputs (per hash_type bits), spend_type (incl. annex presence),
  and input index or outpoint — i.e. a valid signature fixes the witness's
  nLockTime/nSequence, the fact BIP 379's satisfier relies on.

## BIP 342: Validation of Taproot Scripts — Status: Deployed

Wuille, Nick, Towns, 2020-01-19. (Not on the original list; mandatory context
for BIP 379's Tapscript column, referenced by the draft itself.)

**Relevance.** Defines the execution semantics of scripts produced by BIP
379's Tapscript translation table (CHECKSIGADD sig-op semantics, MINIMALIF,
stack limits). In particular it changes several facts relative to P2WSH that
the formalization must keep context-dependent: no 201-op limit, no 10000-byte
script limit, no OP_CHECKMULTISIG, sigops budget per input.

**Normative rules to encode:**

- Applies to BIP341 script-path spends with leaf version 0xc0 (`c[0]` ∈
  {0xc0, 0xc1}).
- OP_CHECKMULTISIG / OP_CHECKMULTISIGVERIFY disabled (fail when executed,
  ignored in unexecuted branches); OP_CHECKSIG/VERIFY verify BIP340 schnorr
  against the tapscript sig-hash extension (ext with tapleaf_hash, key_version
  0x00, codesep_pos); new opcode 186 = **OP_CHECKSIGADD**: pops pubkey (top),
  CScriptNum n (2nd, **≤ 4 bytes**), sig (3rd); empty sig ⇒ push n; valid ⇒
  push n + 1 and counts 50 against the sigops budget.
- **MINIMALIF is consensus:** OP_IF/OP_NOTIF input must be exactly the empty
  vector or exactly the one-byte 0x01 vector. (This legitimizes BIP 379's
  branch-selector witnesses `or_i`/`andor`/`d:`/`j:` row entries "1"/"0" —
  and kills the alternative nonzero-truthy encodings a malleator might try.)
- OP_SUCCESSx set makes scripts unconditionally valid (Miniscript fragment
  translations never emit or rely on it — worth a theorem for the parser).
- Resource limits: 10000-byte script and 201 non-push-opcode limits removed;
  stack+altstack ≤ 1000 (incl. initial stack); stack elements ≤ 520 bytes;
  sigops budget = 50 + total witness bytes, −50 per executed non-empty-sig
  sigop.
- Two-signature-length rule for tapscript sigs: 64 bytes (SIGHASH_DEFAULT) or
  65 with non-0x00 sighash byte; other lengths fail.

---

## BIP 65: OP_CHECKLOCKTIMEVERIFY — Status: Deployed

Peter Todd, v4-block activation (2014 proposal; deployed Dec 2015 network-wide).
BIP 379 dependency for `after()`.

**Relevance.** Semantics of the `after(n)` fragment (`<n> CHECKLOCKTIMEVERIFY`):
it pins the five failure conditions, the height/time namespace split at
LOCKTIME_THRESHOLD = 500 000 000, and the operand's **5-byte** acceptance which
BIP 379 then *tightens* to `1 ≤ n < 2³¹`. A Lean model of `after` should model
the comparison `n ≤ tx.nLockTime`, same-type namespace, and non-finality, not
just "time passed".

**Normative rules to encode (CLTV fails iff):**
- stack empty; or top item `< 0`; or locktime *type* (height vs time) of arg
  and tx.nLockTime differ (arg < 5·10⁸ ⇔ tx.nLockTime < 5·10⁸); or argument
  `> tx.nLockTime`; or this input's **nSequence = 0xffffffff** (final input
  disables nLockTime).
- Operand is a CScriptNum accepted at up to **5 bytes** (nLockTime is a uint32 —
  the 4-byte script-number default would clip it); Miniscript restricts to
  1 ≤ n < 2³¹ so the fragment's push is a minimal ≤ 4-byte encoding.

## BIP 112: CHECKSEQUENCEVERIFY — Status: Deployed

BtcDrak, Friedenbach, Lombrozo, assigned 2015-08-10; deployed with BIP 68/113
(versionbits). BIP 379 dependency for `older()`.

**Relevance.** Semantics of the `older(n)` fragment (`<n> CHECKSEQUENCEVERIFY`):
relative locktime against this input's nSequence, with the type flag
(512-second units vs block-height units) and the 16-bit value mask — the exact
ground rules for the timelock typing/`older(n)` bounds in BIP 379.

**Normative rules to encode (CSV fails iff):**
- stack empty; or top `< 0`; and (only if operand's disable flag `1<<31` is
  *unset*): tx version < 2; or input nSequence has disable flag `1<<31`; or
  masked types differ (`SEQUENCE_LOCKTIME_TYPE_FLAG = 1<<22` must match between
  operand and nSequence); or masked operand > masked input nSequence
  (`SEQUENCE_LOCKTIME_MASK = 0x0000ffff`).
- Operand with the disable flag `1<<31` set behaves as a **NOP** (soft-fork
  hook).
- Operand accepted as CScriptNum up to **5 bytes**; Miniscript again tightens
  to 1 ≤ n < 2³¹. BIP 68 (referenced, same deployment) defines the tx-level
  enforcement of relative locktime these flags implement.

## BIP 113: Median time-past as endpoint for lock-time calculations — Status: Deployed

Kerin & Friedenbach, 2015-08-10.

**Relevance.** Fixes the clock used by both absolute (`after`, time-case) and
relative (`older`, time-case) checks: the median of the last 11 block
timestamps (MTP), monotonic by construction. For Miniscript policy
reasoning this means "time" comparisons in the formal model are w.r.t. MTP of
the previous block, not the current block's claimed time.

**Normative rules to encode:**
- `IsFinalTx` (and hence CLTV/CSV time comparisons) uses
  `GetMedianTimePast(pindexPrev)`, median of up to 11 preceding block times;
  applies to all transactions incl. coinbase.

---

## BIP 66: Strict DER signatures — Status: Deployed

Pieter Wuille, 2015-01-10.

**Relevance.** Underpins BIP 379's `s` ("signed") property and witness-size
bounds on the P2WSH side: malleability-instrumented signatures must be strict
DER, while empty vectors stay legal so the satisfier can push "false" (this is
exactly why dsat(pk_k) = `0` etc. are non-malleable-by-construction under
standardness).

**Normative rules to encode:**
- Every signature actually ECDSA-verified by CHECKSIG/VERIFY or
  CHECKMULTISIG/VERIFY must be strict-DER (`0x30 len 0x02 lenR R 0x02 lenS S
  sighash`, R/S shortest-positive): total size **9–73 bytes** (the 73-byte
  bound BIP 379's `sat_size` counting uses); non-DER makes the **script fail
  immediately**, non-DER is not merely "false".
- Empty (zero-length) signature vectors are exempt — legal encoding of a
  deliberate "false"; mandatory for Miniscript's dissatisfaction semantics and
  for multisig unused-slot placeholders.

## BIP 147: NULLDUMMY — Status: Deployed

Johnson Lau, 2016-09-02 (deployed with segwit).

**Relevance.** Anchor for the `multi()` satisfaction shape in BIP 379: the
witness vector is `0 <sigs…>`, and the same rule makes the *dissatisfaction*
`0 … 0` (k+1 zeroes) the *unique* legal all-false witness — exactly the "e"
(expressive/unique-dsat) property Miniscript needs to prove `multi` is `s, e`.

**Normative rules to encode:**
- The extra dummy stack element consumed by OP_CHECKMULTISIG /
  OP_CHECKMULTISIGVERIFY **must be the empty byte array**; anything else fails
  the script immediately; applies to pre-segwit scripts and P2WSH alike.
  (`multi_a` has no dummy element at all — see BIP 387 — so this rule is
  P2WSH-side only.)

## BIP 62: Dealing with malleability — Status: Closed (withdrawn)

Pieter Wuille, assigned 2014-03-12; superseded piecewise (never deployed as
such) — the catalogue that BIPs.66/147 and segwit each carry a piece of.

**Relevance.** Background justification of BIP 379's malleability type
properties and of its five analysis assumptions. Its taxonomy of malleability
sources (non-DER encoding, padded scriptSigs, ECDSA S-negation, saturating
scriptSig extras, ignored scriptSig inputs, sighash masks, signer's own
re-signing) is the checklist the Miniscript analysis delegitimizes per
construction; rules #1 and #7 became BIP 66 and BIP 147, while the low-S rule
survived as *standardness* only — hence BIP 379's explicit assumption that the
attacker is constrained by standardness rules and its caveat that a miner could
still malleate a Miniscript considered non-malleable.

**Normative rules to encode:** none directly (dead BIP), but its taxonomy is the
specification of the attacker model in BIP 379's "Malleability" section: a
formal non-malleability theorem should quantify over witnesses that are
strict-DER, NULLDUMMY-compliant, minimally-encoded push data, with low-S sigs,
no superfluous/misdirected witness elements, and a fixed sighash type — the
six preventable sources — while treating "sender produces a new signature" as
out of scope (rule #9 in BIP 62 acknowledged as unfixable).

---

## Cross-cutting notes for the formalization

- **Contexts a theorem must distinguish:** P2WSH (33-byte compressed keys,
  ECDSA, CHECKMULTISIG w/ dummy, 201-op + 3600-byte + 100-element limits) vs
  Tapscript (32-byte x-only keys, Schnorr, CHECKSIGADD, sigops budget, MINIMALIF
  consensus, no opcode limit) — BIP 379 is deliberately a single type system
  parametrized by context; keep a `Context` parameter rather than two systems.
- **Timelock typing stack:** BIP 65 (absolute: nLockTime + ≥/types + non-final
  input) × BIP 112/68 (relative: nSequence + version ≥ 2 + flags/mask) × BIP 113
  (MTP clock) × BIP 379 (fragment bounds 1 ≤ n < 2³¹ and the and/thresh mixing
  restriction). The 5-byte-vs-4-byte CScriptNum subtlety (consensus accepts
  5-byte operands; Miniscript restricts to 4-byte encodable values) must be
  part of the `older`/`after` well-formedness predicate.
- **Witness-counting conventions differ by implementation** (BIP 379 test
  vectors count rust-miniscript's way, Bitcoin Core counts otherwise; e.g.
  whether the witnessScript counts toward the 100-element limit). Choose Core
  semantics for the theorems and document the off-by-one.
- **Deferred / out of scope:** descriptor checksum BCH code (BIP 380) — parser
  correctness only; BIP 32/xpub derivation internals — treat keys opaquely;
  MuSig/BIP 327 — not in the fragment set (BIP 390 `musig()` is a later,
  separate descriptor BIP); BIP 388 wallet policies (references BIP 379 but is
  a higher layer).
- **Not covered here but adjacent** (seen during research): BIP 68 (embedded in
  BIP 112's constants), BIP 141 (P2WSH shell of `wsh()`, 100-element limit),
  BIP 141/143 sighash vs BIP 341 SigMsg, BIP 146 (low-S: standardness channel
  behind BIP 379's standardness assumption), BIP 174/PSBT hash-preimage fields
  (bips PR #955, added "to solve miniscripts").

## Provenance

- Draft BIP 379 text: PR bitcoin/bips#2240 head commit
  c923f2e961c0bae99a7b777cc15bb91601ed3bd9 (`bip-0379.md`), which builds on PR
  #1610 (achow101/bips@miniscript, commit 4b321d72). Test-vector files exist
  under `bip-0379/` in the same branch.
- All other BIPs: raw mediawiki from `bitcoin/bips@master`, fetched 2026-10-21:
  bip-0062/0065/0066/0112/0113/0147/0340/0341/0342/0380–0387.
