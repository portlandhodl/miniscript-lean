# `rust-miniscript` interpreter — formalization-oriented analysis

Scope: `rust-miniscript/src/interpreter/` (crate `miniscript` v13.0.0, `rust-bitcoin` 0.32).

| File | Lines | Role |
|---|---|---|
| `src/interpreter/mod.rs` | 1571 | `Interpreter` struct, `Iter` = the structured "machine", `NodeEvaluationState`, `SatisfiedConstraint`, `KeySigPair`, sig verification dispatch |
| `src/interpreter/inner.rs` | 819 | `from_txdata`: classify the spk (p2pk/p2pkh/p2wpkh/p2wsh/p2tr/p2sh/bare), build `Inner` + initial `Stack` from scriptSig+witness, script_code for sighash |
| `src/interpreter/stack.rs` | 378 | `Stack<'txin>` = `Vec<Element>`; `Element` algebra; per-fragment leaf evaluators (`evaluate_pk/pkh/after/older/sha256/hash256/hash160/ripemd160/multi`) |
| `src/interpreter/error.rs` | 282 | `interpreter::Error` (the full `InterpreterError` enum), `PkEvalErrInner` |

Public surface: `lib.rs:115` `pub mod interpreter;`, `lib.rs:136` `pub use crate::interpreter::Interpreter;`.

---

## 1. Reimplemented vs delegated to rust-bitcoin

### 1.1 What is reimplemented: a structural (fragment-level) machine, not a `Machine`-style opcode VM

There is **no opcode-level interpreter, no altstack, no program counter, no `ExecutionState`**. Instead, `Iter::iter_next` (`mod.rs:572-996`) walks the `Miniscript<BitcoinKey, NoChecks>` AST with an explicit continuation stack:

```rust
// mod.rs:504-511
struct NodeEvaluationState<'intp> {
    ///The node which is being evaluated
    node: &'intp Miniscript<BitcoinKey, NoChecks>,
    ///number of children evaluated
    n_evaluated: usize,
    ///number of children satisfied
    n_satisfied: usize,
}
```

The main loop (`mod.rs:573`) `while let Some(node_state) = self.state.pop()` then match-dispatches on `node_state.node.node` (the `Terminal`). Each opcode-op of the compiled script is only handled **indirectly**, via the miniscript fragment it belongs to. Opcodes natively simulated (one per fragment; the wire encodings live in `miniscript/astelem.rs`):

| `Terminal` arm (`mod.rs:575+`) | Compiled opcodes simulated | Semantics implemented natively |
|---|---|---|
| `True` / `False` (576-585) | push 1 / Ø | push `Satisfied`/`Dissatisfied` |
| `PkK` (586) | `<pk> CHECKSIG` | pop sig, `evaluate_pk` (stack.rs:108) |
| `PkH` / `RawPkH` (594, 606) | `DUP HASH160 <h> EQUALVERIFY CHECKSIG` | pop pubkey, hash-check, pop sig, `evaluate_pkh` (stack.rs:142) |
| `After` (616) | `<n> CHECKLOCKTIMEVERIFY [0NOTEQUAL]` | `evaluate_after` (stack.rs:205) — no stack I/O |
| `Older` (626) | `<n> CHECKSEQUENCEVERIFY` | `evaluate_older` (stack.rs:232) |
| `Sha256`/`Hash256`/`Hash160`/`Ripemd160` (634-665) | `SIZE 32 EQUALVERIFY <HASH> <h> EQUAL` | `evaluate_*` (stack.rs:252-348), pop 32-byte preimage |
| `Alt`/`Swap`/`Check` (666) | `TOALTSTACK X FROMALTSTACK` / `SWAP X` / `X CHECKSIG` | **transparent**: just schedule the sub — wrappers are optimizations invisible to satisfaction semantics |
| `DupIf` (671-686) | `DUP IF [X] ENDIF` (`d:`) | pop guard; Ø ⇒ push Ø; 1 ⇒ run sub (V-typed) then push 1 |
| `Verify` (687, 693) | `[X] VERIFY` (`v:`) | child must push exactly `Satisfied`; `()` returned, **nothing pushed** (V-type) |
| `ZeroNotEqual` (687, 700) | `[X] 0NOTEQUAL` (`n:`) | bool-normalize child result |
| `NonZero` (709) | `SIZE 0NOTEQUAL IF [X] ENDIF` (`j:`; encoding confirmed `astelem.rs:104-109`) | peek top: Ø ⇒ skip child; else run child |
| `AndV` (718) | `X Y` sequencing | push `right` state first, then `left` — LIFO ⇒ left evaluates first |
| `OrB`/`AndB` (724-775) | `X Y BOOLOR` / `X Y BOOLAND` | **both children always evaluated**; combine two booleans |
| `OrC` / `OrD` (757-800) | `X NOTIF Y ENDIF` / `X IFDUP NOTIF Y ENDIF` | left runs, right runs only if left dissat |
| `AndOr` / `OrI` (757, 802) | `X IF Y ELSE Z ENDIF` / `IF X ELSE Y ENDIF` | guard pop selects branch |
| `Thresh` (814-870) | `X1 X2 ADD … <k> EQUAL` and variants | counter `n_satisfied` folded over children; ADDs collapsed into counter |
| `MultiA`/`SortedMultiA` (871-911) | `<pk_i> CHECKSIGADD …` (taproot-only) | one sig per key, **in order**; pop-then-push-boolean per key, finally compare `n_satisfied == k` |
| `Multi`/`SortedMulti` (912-992) | `<k> pks… <n> CHECKMULTISIG` | sig↔key ordered matching; **extra-zero element enforced** (`MissingExtraZeroMultiSig`, mod.rs:963-968) |

The catch-all `_ => Some(Err(Error::CouldNotEvaluate))` (mod.rs:995) covers state-machine patterns unreachable in a type-checked miniscript.

Success criterion (the CLEANSTACK+truthiness terminal check), `mod.rs:1016-1022`:

```rust
if self.stack.pop() == Some(stack::Element::Satisfied) && self.stack.is_empty() {
    None   // iteration ends: success
} else {
    Some(Err(Error::ScriptSatisfactionError))
}
```

For plain key descriptors (`Inner::PublicKey`), the post-loop epilogue pops a `Push(sig)` and runs `verify_sersig` (mod.rs:1001-1014).

**Iterator contract** (docs mod.rs:288-297): yields each `SatisfiedConstraint`, *including redundant ones* ("if a signature were provided for an `and_b(Pk,false)` fragment, that signature will be returned"); on dissatisfaction "this may return several values before ultimately returning an error". After the first `Err`, `has_errored` (mod.rs:543-549) latches and iteration stops.

### 1.2 What is delegated to rust-bitcoin / libsecp256k1

| Concern | Delegated API | Site |
|---|---|---|
| spk classification | `Script::is_p2pk/is_p2pkh/is_p2wpkh/is_p2wsh/is_p2tr/is_p2sh` | inner.rs:110-326 |
| spk reconstruction (for equality checks) | `ScriptBuf::new_p2pk/new_p2pkh/new_p2wpkh/new_p2sh/new_p2wsh` | inner.rs:132,155,179,250,263,291,… |
| script→AST parse (insane) | `Miniscript::decode_consensus` under `Legacy`/`Segwitv0`/`Tap`/`BareCtx`, then `ToNoChecks` translation (inner.rs:347-388) | inner.rs:46,175,221,286,309,329 |
| AST→script re-encode for hash checks | `Miniscript::encode` | inner.rs:176,225,287,310 |
| hashes | `hash160/sha256/hash256/ripemd160::Hash::hash` | stack.rs:161,260,285,310,335; inner.rs:178,249,289,313 |
| ECDSA sig parse (DER + sighash byte + *standardness* of sighash) | `bitcoin::ecdsa::Signature::from_slice` | mod.rs:1035 |
| Schnorr sig parse | `bitcoin::taproot::Signature::from_slice` | mod.rs:1044 |
| sighash computation | `SighashCache::{legacy_signature_hash (deprecated), p2wsh_signature_hash, taproot_key_spend_signature_hash, taproot_script_spend_signature_hash}` | mod.rs:225,233,253,267 |
| EC verification | `secp256k1::Secp256k1::{verify_ecdsa, verify_schnorr}` | mod.rs:246,280 |
| taproot control-block merkle+tweak proof | `ControlBlock::decode` + `verify_taproot_commitment` | inner.rs:220,226 |
| locktime algebra | `absolute::LockTime` ordering, `Sequence::to_relative_lock_time`, `relative::LockTime::is_implied_by` | stack.rs:210-216,237-238 |
| witness iteration, script instructions | `Witness::iter`, `Script::instructions_minimal` | inner.rs:99,103 |

### 1.3 Timelock execution state: what is tracked, exact formulas

There is **no memoization / no ExecutionState struct**. The `Interpreter` stores exactly two scalar tx facts (mod.rs:38-39):

```rust
sequence: Sequence,               // txin.sequence (for CSV)
lock_time: absolute::LockTime,    // tx.nLockTime (for CLTV)
```

plus `script_code: Option<ScriptBuf>` (mod.rs:37; leaf script for tr script-spends — the "hack" documented at inner.rs:230-236). They are threaded into `Iter` (mod.rs:177-178) and handed to the leaf checkers per encountered fragment.

**CLTV (`after`) — `evaluate_after`, stack.rs:205-224:**

```rust
let is_satisfied = match (*n, lock_time) {
    (Blocks(n), Blocks(lock_time)) => n <= lock_time,
    (Seconds(n), Seconds(lock_time)) => n <= lock_time,
    _ => return Some(Err(Error::AbsoluteLockTimeComparisonInvalid(*n, lock_time))),
};
```

So the formula is exactly: **same-unit and `script_const ≤ tx.nLockTime`** — pure raw comparison between the *script-embedded constant* and the *tx field*. Notably **absent** relative to BIP-65/113 consensus code:

- no non-negativity / 5-byte CScriptNum stack read (vacuous: the value sits in the script, miniscript typechecking + `absolute::LockTime` newtype guarantee validity);
- no MTP — the interpreter never sees mediantime/height; BIP-113's "tx finality vs MTP" is a transaction-level (mempool/block) property, not part of BIP-65's script-local check;
- no "tx locktime enabled" check (in consensus there isn't one inside CLTV either).

**CSV (`older`) — `evaluate_older`, stack.rs:232-248:**

```rust
if let Some(tx_locktime) = sequence.to_relative_lock_time() {
    if n.is_implied_by(tx_locktime) {
        self.push(Element::Satisfied);
        Some(Ok(SatisfiedConstraint::RelativeTimelock { n: *n }))
    } else {
        Some(Err(Error::RelativeLockTimeNotMet(*n)))
    }
} else {
    // BIP 112: if the tx locktime has the disable flag set, fail CSV.
    Some(Err(Error::RelativeLockTimeDisabled(*n)))
}
```

Widened to rust-bitcoin 0.32 (`blockdata/transaction.rs:486-498`, `locktime/relative.rs:221-229`):

- `Sequence::to_relative_lock_time() = None` iff disable flag (bit 31) set → `RelativeLockTimeDisabled`;
- else low 16 bits → `Blocks(h)` (bit 22 clear) or `Time(t)` (bit 22 set, 512-s units);
- `n.is_implied_by(tx_locktime)` ⇔ `(Blocks(a),Blocks(b)) ↦ a≤b; (Time(a),Time(b)) ↦ a≤b; mixed ↦ false`.

**Deviation vs BIP-112 consensus:** the interpreter does **not** check `tx.version >= 2` — `Interpreter::from_txdata` never receives the tx version (mod.rs:144-153). This check exists only in the *satisfier* (`PsbtInputSatisfier::check_older`, psbt/mod.rs:336-345: `if self.psbt.unsigned_tx.version < transaction::Version::TWO || !seq.is_relative_lock_time() { return false; }`). A finalized witness for an `older(n)` fragment inside a version-1 (or 0) transaction **passes** `interpreter_check` but **fails** consensus. This is the single most significant gap to model/repair in a formalization claiming consensus faithfulness.

### 1.4 Signature-type checks

- `KeySigPair` (mod.rs:47-52): exactly two variants —
  `Ecdsa(bitcoin::PublicKey, bitcoin::ecdsa::Signature)` / `Schnorr(XOnlyPublicKey, bitcoin::taproot::Signature)`.
- Context → sig-type mapping via `Interpreter::sig_type()` (mod.rs:423-436): everything `Tr` ⇒ `SigType::Schnorr`, all else ⇒ `SigType::Ecdsa`. `SigType` itself comes from `crate::miniscript::context` (mod.rs:17).
- `verify_sersig` (mod.rs:1028-1053) dispatch on key variant: full key → `ecdsa::Signature::from_slice` (rust-bitcoin validates DER *and* standardness of the sighash byte, errors become `Error::EcdsaSig`); x-only key → `taproot::Signature::from_slice` (→ `Error::SchnorrSig`). Then the caller-supplied closure `verify_sig(&KeySigPair) -> bool` decides validity; `false` ⇒ `InvalidEcdsaSignature(pk)` / `InvalidSchnorrSignature(pk)`.
- The closure is injected via `iter_custom` (mod.rs:158-160); default `iter` wires `self.verify_sig(secp, tx, input_idx, prevouts, sig)` (mod.rs:305-313); `iter_assume_sigs` is `|_| true` (mod.rs:316-318).
- `verify_sig` (mod.rs:195-286) reimplements **dispatch only**: legacy ⇒ BIP143-predecessor `legacy_signature_hash` with the scriptCode; segwit-v0 ⇒ `p2wsh_signature_hash` **with the prevout amount** (false if missing, mod.rs:228-231); taproot ⇒ BIP341 key/script-spend sighash over `Prevouts::All` (script-spend uses the stored leaf script to build `TapLeafHash::from_script(script, LeafVersion::TapScript)`, mod.rs:263-266). Wrong-context crypto (schnorr sig in ecdsa spend and vice versa) ⇒ returns `false` (mod.rs:240-242, 273-275), i.e. **not a hard error, just an invalid signature**.
- Key parsing for `pk_h` under `NoChecks` is guided by `sig_type` (stack.rs:153-159): 32-byte x-only for Schnorr, 33/65-byte full key for ECDSA. Key-witness hash equality is checked first (`PkHashVerifyFail`, stack.rs:161-164).

---

## 2. Formalization standpoint

### 2.1 Stack-element algebra

```rust
// stack.rs:21-30
pub enum Element<'txin> {
    Satisfied,                 // canonical truth;    translated from vec![1]
    Dissatisfied,              // canonical falsity;  translated from vec![]
    Push(&'txin [u8]),         // any other witness bytes
}
```

**Ingress conversion (witness items and scriptSig pushes), stack.rs:36-46:**

```rust
if *v == [1] { Element::Satisfied }
else if v.is_empty() { Element::Dissatisfied }
else { Element::Push(v) }
```

and for the scriptSig, `Element::from_instruction` (stack.rs:52-61): `PushBytes` → same conversion (empty push counts as Dissatisfied); `OP_PUSHNUM_1` ⇒ `Satisfied`; **anything else ⇒ `Error::ExpectedPush`** — numeric pushes other than 1 are rejected up front ("Supports OP_1 but no other numbers since these are not used by Miniscript"), and `instructions_minimal()` additionally rejects non-minimal pushes (the MINIMALDATA policy) at parse time.

So the interpreter's value domain is the 3-point algebra `𝔹_⊥ = {0, 1, push b}` with strict typing: consumers of booleans (`DupIf`, `OrI`, `AndOr`, `AndB`/`OrB` second-stage pops, combiner pops in `Thresh`) raise `UnexpectedStackElementPush` on `Push` (e.g. mod.rs:679-680); consumers of data (`evaluate_pk`'s sig, hashlock preimages) raise `UnexpectedStackBoolean` on `Satisfied`/`Dissatisfied` (stack.rs:64-70, 372).

**Evaluation context** = `Vec<NodeEvaluationState>` — a defunctionalized continuation: `(node, n_evaluated, n_satisfied)`. Guards like `if node_state.n_evaluated == 0 / 1 / 2` and threshold counters encode resumption points. `debug_assert_eq!(node_state.n_* , 0)` on leaves (mod.rs:577-668) are unchecked in release — soundness rests on miniscript **type-checking at parse**, which happens before interpretation (`script_from_stack_elem` parses under a real `ScriptContext`, then `to_no_checks_ms`, inner.rs:41-51).

Type-system reliance worth stating formally:

- `Verify` (`v:`) pops the child result and pushes **nothing** (mod.rs:693-698) — parents like `AndV` or the top-level must not expect a value; correct only because type V fragments are guaranteed to wrap a B.
- `DupIf` (`d:`) at `n_evaluated == 1` pushes `Satisfied` **without inspecting the child's stack effect** (mod.rs:684-686). This is sound only because `d:X` requires `X : V` (encoding `DUP IF [X] ENDIF`), so a *satisfied* V-child leaves nothing and the simulated stack is exactly the dup'd `1`. A dissatisfaction is only possible via the Ø-guard path.
- `NonZero` (`j:`, `SIZE 0NOTEQUAL IF X ENDIF`) **peeks** at the top (does not pop) and skips the child when top is `Dissatisfied` (mod.rs:709-717), faithfully reproducing "size 0 ⇒ IF skips"; the `SIZE 0NOTEQUAL` redundancy check result is elided.
- `NonZero`/`AndV` never pop: sequencing is pure continuation juggling.

### 2.2 Boolean conversion / CScriptNum semantics

**There is no CScriptNum anywhere.** Zero script-number parsing exists because miniscript never *reads* numbers from the witness — numbers (timelock values) are constants baked into the script by construction, and witness data is only ever consumed as: signatures, public keys, hash preimages. This is stated explicitly in the leaf checkers (stack.rs:199-204, 226-231):

```
"Ideally this should return int value as n: build_scriptint(t as i64)),
 The reason we don't need to copy the Script semantics is that
 Miniscript never evaluates integers and it is safe to treat them as booleans"
```

Consequences for the boolean conversion semantics a formalization must adopt:

1. **Truthiness collapses to set membership**: `Satisfied ⟺ [0x01]`, `Dissatisfied ⟺ []`. Bitcoin's general `CastToBool` (`v ≠ 0` with the ±0 exception) and CScriptNum read bounds (≤4 bytes, sign-magnitude, minimal-encoding policy) are *replaced* — a witness element like `[0x81]` (−0 in CScriptNum, false in consensus) or `[0x02]` (true in consensus) is here an opaque `Push`, and any boolean consumer errors out on it.
2. Hence **MINIMALIF is enforced, not merely simulated**: in `DupIf`/`OrI`/`AndOr`, a `Push(_)` guard — including any non-canonical truthy value — is `Error::UnexpectedStackElementPush` (mod.rs:679-680, 742-743, 782-784, 808-810). Minimal-IF violations are therefore unrepresentable in success paths, at the cost of hard errors where consensus would merely mis-branch.
3. **`Verify` on push**: `Terminal::Verify` requires exactly `Satisfied`; a `Push` raises `VerifyFailed` (mod.rs:693-698, error.rs:111-113: "This error is raised even if the stack top is `stack::Element::Push`"). Matches OP_VERIFY's fail-on-anything-not-strictly-true.
4. **CHECKSIG truthiness**: empty sig ⇒ `Dissatisfied` (matches consensus: CHECKSIG of zero-length sig ⇒ 0); non-empty invalid sig ⇒ **hard `PkEvaluationError`** (stack.rs:113-134) — a *standardness* (NULLFAIL-style) assumption, documented on the error variants: "This is network standardness assumption and miniscript only supports standard scripts" (error.rs:61-65, 70-76). `MultiA` (CHECKSIGADD path) profits specifically: comment at mod.rs:879-881 "evaluate_pk will error on non-empty incorrect sigs".
5. **CHECKMULTISIG extra element**: the consensus bug-element is enforced: final count must be preceded by a `Dissatisfied` (mod.rs:962-968) else `MissingExtraZeroMultiSig`; all-`Dissatisfied` prefix of length k+1 ⇒ plain dissatisfaction; anything else ⇒ `MultiSigEvaluationError` (mod.rs:921-937, 969-970).
6. **Hashlocks**: preimage length ≠ 32 ⇒ `HashPreimageLengthMismatch` (stack.rs:257-259) — models `SIZE 32 EQUALVERIFY` as a hard error; wrong hash ⇒ push `Dissatisfied` (models `EQUAL` ⇒ 0); match ⇒ push `Satisfied` and yield `SatisfiedConstraint::HashLock`.
7. **Final truth check**: exactly one `Satisfied` and an empty stack (mod.rs:1018) — the joint modeling of top-true + CLEANSTACK.

### 2.3 What this buys a Lean formalization

- The interpreter is evidence that for the miniscript fragment language, consensus script semantics admit a **sound boolean abstraction**: the machine state is `(state-stack of contexts, 𝔹_⊥-stack, seq, lt)` and the step relation is small-step on `Terminal` — much simpler than an opcode machine.
- Non-goals to state explicitly in the model: tx-version≥2 (CSV), MTP/height (CLTV activation vs in-block finality), sigop counting, policy limits (checkable via `inferred_descriptor` + `from_str`, per mod.rs:320-330 docs: "the interpreter … does not [check standardness and consensus limits] on its own").

---

## 3. `InterpreterError` — every variant and its raise sites

`error.rs:17-114`, `pub use self::error::Error as interpreter::Error` re-export via `mod.rs:26` and `psbt/mod.rs:96` (`InputError::Interpreter`):

| # | Variant (error.rs) | Raised when / where |
|---|---|---|
| 1 | `AbsoluteLockTimeNotMet(absolute::LockTime)` (:19) | `after(n)`: same units but `n > tx.lock_time` (stack.rs:221-222) |
| 2 | `AbsoluteLockTimeComparisonInvalid(absolute::LockTime, absolute::LockTime)` (:21) | `after(n)`: height↔time unit mismatch vs `tx.lock_time` (stack.rs:215) |
| 3 | `CannotInferTrDescriptors` (:26) | tr-related descriptor inference (declared; `inferred_descriptor_string` mod.rs:339-345/350-354 prints placeholders instead) |
| 4 | `ControlBlockParse(taproot::TaprootError)` (:28) | tr script-spend control block decodes fail (inner.rs:219-220) |
| 5 | `ControlBlockVerificationError` (:30) | merkle proof+tweak against output key fails (inner.rs:226-239) |
| 6 | `CouldNotEvaluate` (:32) | fallthrough arm of the step function, unreachable for type-checked miniscript (mod.rs:993-995) |
| 7 | `EcdsaSig(bitcoin::ecdsa::Error)` (:34) | DER parse or non-standard sighash byte inside `from_slice` (mod.rs:1035, via `From` at error.rs:242-244) |
| 8 | `ExpectedPush` (:36) | scriptSig contained an opcode other than pushes/`OP_1` (stack.rs:59) |
| 9 | `HashPreimageLengthMismatch` (:38) | hashlock preimage ≠ 32 bytes (stack.rs:257,282,307,332) |
| 10 | `IncorrectPubkeyHash` (:40) | p2pkh: hash160(scriptSig key) ∉ spk (inner.rs:140) |
| 11 | `IncorrectScriptHash` (:42) | p2sh: redeem script hash mismatch (inner.rs:251,317) |
| 12 | `IncorrectWPubkeyHash` (:44) | p2wpkh / sh-wrapped wpkh key hash mismatch (inner.rs:162) |
| 13 | `IncorrectWScriptHash` (:46) | wsh/sh-wsh witness-script hash mismatch (inner.rs:182,272,300) |
| 14 | `InsufficientSignaturesMultiSig` (:48) | `multi(k,…)`: stack has < k+1 elements (mod.rs:916-917) |
| 15 | `InvalidSchnorrSighashType(Vec<u8>)` (:50) | declared; in v13 raised through `SchnorrSig`/`From` paths instead (psbt-level parsing covers standardness) |
| 16 | `InvalidEcdsaSignature(bitcoin::PublicKey)` (:52) | DER parses but EC verify closure returns false (mod.rs:1040) |
| 17 | `InvalidSchnorrSignature(XOnlyPublicKey)` (:54) | ibid. for Schnorr (mod.rs:1049) |
| 18 | `NonStandardSighash(Vec<u8>)` (:56) | wired in `psbt::sanity_check` for a partial sig whose sighash byte is non-standard (psbt/mod.rs:392-401) |
| 19 | `Miniscript(crate::Error)` (:58) | script→miniscript decode failures forwarded (inner.rs:46 etc. via `Error::from`) |
| 20 | `MissingExtraZeroMultiSig` (:60) | `CHECKMULTISIG` bug-element absent/misplaced (mod.rs:933, 967) |
| 21 | `MultiSigEvaluationError` (:65) | key order exhausted before k sigs matched (mod.rs:969-970); docs: non-standard dissatisfaction shapes |
| 22 | `NonEmptyWitness` (:67) | witness items on a pre-segwit spend (inner.rs:111,126,320,333) |
| 23 | `NonEmptyScriptSig` (:69) | scriptSig on native segwit / leftover scriptSig items in wrapped segwit (inner.rs:148,171,190,257,282) |
| 24 | `PkEvaluationError(PkEvalErrInner)` (:76) | `pk_k`: witness was `Satisfied` (i.e. `1`) where a sig belongs (stack.rs:129,186; mod.rs:1010 for bare-pk epilogue) |
| 25 | `PkHashVerifyFail(hash160::Hash)` (:79) | `pk_h`: hash160(witness key) ≠ scripted hash (stack.rs:163) |
| 26 | `PubkeyParseError` (:82) | full-key bytes don't parse (inner.rs:23,34; stack.rs:192 via `bitcoin_key_from_slice` None for ECDSA) |
| 27 | `XOnlyPublicKeyParseError` (:84) | tr spk x-only key parse failure (inner.rs:193-194) |
| 28 | `RelativeLockTimeNotMet(relative::LockTime)` (:86) | `older(n)`: sequence parseable but not `is_implied_by` (stack.rs:242) |
| 29 | `RelativeLockTimeDisabled(relative::LockTime)` (:88) | `older(n)`: sequence disable-flag set (stack.rs:245-246) |
| 30 | `Secp(secp256k1::Error)` (:90) | `From` plumbing (error.rs:232-234) |
| 31 | `ScriptSatisfactionError` (:92) | top-level result ≠ single `Satisfied` on empty stack (mod.rs:1021) |
| 32 | `SchnorrSig(bitcoin::taproot::SigFromSliceError)` (:94) | schnorr sig slice parse (mod.rs:1044, `From` error.rs:247-249) |
| 33 | `SighashError(sighash::InvalidSighashTypeError)` (:96) | `From` plumbing (error.rs:237-239) |
| 34 | `TapAnnexUnsupported` (:98) | annex present (`TAPROOT_ANNEX_PREFIX` on last witness item, len≥2) — sighash unsupported (inner.rs:195-206) |
| 35 | `UncompressedPubkey` (:101) | 65-byte key in segwit/tr contexts (`require_compressed`) (inner.rs:17-18) |
| 36 | `UnexpectedStackBoolean` (:104) | boolean where a push expected (`as_push` stack.rs:64-70; `evaluate_multi` stack.rs:372; control block `as_push` inner.rs:217) |
| 37 | `UnexpectedStackEnd` (:106) | stack exhausted mid-evaluation — the "stack underflow" analog (≈20 sites, e.g. mod.rs:682,697,706; stack.rs:132,189,271,…) |
| 38 | `UnexpectedStackElementPush` (:110) | push where a boolean expected (mod.rs:679,742,782,796,808,833,865) |
| 39 | `VerifyFailed` (:113) | `v:` child result ≠ `Satisfied` (mod.rs:693-697) |

Plus `PkEvalErrInner` (error.rs:259-273), the public mirror of the private `BitcoinKey` used inside `PkEvaluationError`.

---

## 4. Usage: psbt/finalizer wiring

Chain (all in `src/psbt/`):

1. `PsbtExt::finalize_mut` → `finalize_helper` (finalizer.rs:349-362): `sanity_check(psbt)` first (psbt/mod.rs:379-417: input count, sighash-type standardness — mapping to `interpreter::Error::NonStandardSighash`, psbt/mod.rs:396-399), then per-input `finalize_input`.
2. `finalize_input` (finalizer.rs:404-431): skips already-finalized inputs; calls `finalize_input_helper`; on success writes `final_script_sig`/`final_script_witness` and *drops all other input fields* ("we cannot error after this point", :419-428).
3. `finalize_input_helper` (finalizer.rs:366-402): computes `(witness, script_sig)` — tr via `construct_tap_witness` (:33-97, key-spend sig preferred, else iterate `tap_scripts` control blocks picking the min-size satisfaction); everything else via `get_descriptor` (:136-266 — reconstructs a `Descriptor` from spk + psbt fields) and `desc.get_satisfaction[_mall](PsbtInputSatisfier)`.
4. **The interpreter is the acceptance gate**: still inside `finalize_input_helper`, before returning —

   ```rust
   // finalizer.rs:396-401
   let witness = bitcoin::Witness::from_slice(&witness);
   let utxos = prevouts(psbt)?;
   let utxos = &Prevouts::All(&utxos);
   interpreter_inp_check(psbt, secp, index, utxos, &witness, &script_sig)?;
   ```

   `interpreter_inp_check` (finalizer.rs:295-320) wires tx facts (`let cltv = psbt.unsigned_tx.lock_time; let csv = psbt.unsigned_tx.input[index].sequence;`, :309-310) into

   ```rust
   let interpreter =
       interpreter::Interpreter::from_txdata(&spk, script_sig, witness, csv, cltv)
           .map_err(|e| Error::InputError(InputError::Interpreter(e), index))?;
   let iter = interpreter.iter(secp, &psbt.unsigned_tx, index, utxos);
   if let Some(error) = iter.filter_map(Result::err).next() {
       return Err(Error::InputError(InputError::Interpreter(error), index));
   };
   ```

   so finalization **fails if any constraint iteration errors** — signatures are genuinely verified here (not `iter_assume_sigs`), with real sighashes over `Prevouts::All`.
5. Public `interpreter_check` (finalizer.rs:274-292, re-exported psbt/mod.rs:32) repeats the same check standalone on an already-finalized psbt, defaulting missing fields to empty scriptSig/witness.

So, to the question "does finalization call the interpreter to check the witness?": **yes — `finalize_input_helper` runs the full verifying interpreter on its own freshly-produced witness before mutating the psbt**, and `finalize_helper`'s comment "Interpreter is already run inside finalize_input for each input" (finalizer.rs:360) documents that no second pass is needed after the loop.

Note the asymmetry this creates: the psbt-side *satisfier* checks `tx.version >= 2` for `older` (psbt/mod.rs:339) and `enables_lock_time()` for `after` (:327), so `get_satisfaction` won't *produce* timelock-violating witnesses; but the interpreter-verify step (§1.3) re-checks only the raw `≤`/disable-flag comparisons, not version/MTP — the version-2 requirement would be a consensus-vs-interpreter divergence in a formal model.
