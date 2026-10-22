# Bitcoin Core Miniscript Fuzz Target Analysis

Scope: `bitcoin-core/src/test/fuzz/miniscript.cpp` (1266 lines), with a brief note on
`bitcoin-core/src/test/fuzz/script_descriptor_cache.cpp`. Read-only analysis; all refs are
`miniscript.cpp:LINE` unless otherwise noted.

---

## 1. Invariants asserted by the fuzz target

The target has four entry points (`miniscript_stable`, `miniscript_smart`, `miniscript_string`,
`miniscript_script`) that all funnel generated or parsed nodes into `TestNode`
(`miniscript.cpp:1030`). The asserted invariants:

### 1.1 String round-trip (node → text → node)

- `node->ToString(parser_ctx)` must succeed: `assert(str)` (`:1037`).
- Re-parse must succeed: `assert(parsed)` (`:1039`).
- **Node equality**: `assert(*parsed == *node)` (`:1040`) — parse(serialize(n)) == n
  (structural equality of the tree, not just of the type).

Standalone string target mirrors this on arbitrary input:

- If `FromString(str)` succeeds, then `str2 = ToString(parsed)` must succeed
  (`assert(str2)`, `:1248`), re-parse must succeed (`assert(parsed2)`, `:1250`), and
  `assert(*parsed == *parsed2)` (`:1251`) — a **normalization** property:
  parse ∘ serialize ∘ parse == parse (idempotence under the second round, plus equality
  with the first parse).

### 1.2 Script round-trip (node → script → node)

- Size coherence: `assert(node->ScriptSize() == script.size())` (`:1044`) — the *computed*
  script-size accounting equals the *actual* serialized script length.
- For a valid top-level node, decoding must succeed: `assert(decoded)` (`:1058`).
- The decoded node's re-encoding is **byte-identical**: `assert(decoded->ToScript(parser_ctx) == script)` (`:1062`).
- The decoded node's **type is identical**: `assert(decoded->GetType() == node->GetType())` (`:1063`).
  Note (`:1059-1061`): tree shape may differ (decoding is not guaranteed to reproduce the
  original tree), so equality is asserted on (script, type) rather than on the tree.

Standalone script target on arbitrary input:

- If `FromScript(script)` succeeds then `assert(ms->ToScript(script_parser_ctx) == *script)`
  (`:1265`) — decode ∘ encode is the identity on scripts.

### 1.3 Type-system / property invariants

- **`x`-property ↔ script suffix consistency** (`:1046-1051`): for non-`K` nodes,
  `!(type << "x")` (the "no trailing verify needed" flag read inversely, i.e. `ends_in_verify`)
  must equal "script's last opcode ∈ {OP_CHECKSIG, OP_CHECKMULTISIG, OP_EQUAL, OP_NUMEQUAL}".
- Construction-time type guarantee (in `GenNode`): if the node has no base type at all it is
  rejected (`:980-983`); otherwise `assert(node.GetType() << type_needed)` (`:985`) — any node
  produced by the generator satisfies the type requested of it. In strict mode
  (`strict_valid`, `miniscript_smart`), even base-type-less construction is asserted
  impossible (`assert(!strict_valid)`, `:981`).
- **Static resource predictions are exact**: after generation,
  `assert(stack[0].GetStaticOps() == ops)` (`:1003`) and
  `assert(stack[0].ScriptSize() == scriptsize)` (`:1004`) — the fuzzer's own incremental
  op-count/size model (plus special-cased `WRAP_V` correction if the child has `x`,
  `:989-992`) matches the library's `GetStaticOps()`/`ScriptSize()`.
- Smart-table soundness premise (asserted implicitly): `ConsumeNodeSmart` asserts the
  requested type has recipes (`assert(recipes_it != table.end())`, `:775`). Table
  construction dedups by super-recipe (`:557-564`, `:659-668`), prunes to types useful for
  BK VW (`:684-704`), and prunes to constructible types (`:711-744`); recipes are sorted
  deterministically with fewer-subnode recipes first (`:746-757`).

### 1.4 Satisfaction invariants (malleable vs non-malleable)

Execution uses `VerifyScript` with `StandardVerifyFlags` and the mocked `CHECKER_CTX`
against a synthesized P2WSH or single-leaf Taproot scriptPubKey (`:1010-1027`, `:1130`,
`:1145`).

- **Stack-size bound**: non-malleable satisfaction stack has
  `stack_nonmal.size() <= *node->GetStackSize() + 1 + IsTapscript(ctx)` (`:1117-1118`) —
  the +1 is the witness script, +1 more for the Taproot control block.
- **Non-mal ⇒ mal, and identical**: if a non-malleable satisfaction exists, the malleable
  algorithm must agree and produce the *same* stack:
  `assert(mal_success); assert(stack_nonmal == stack_mal);` (`:1119-1121`).
- **Witness size bound**: serialized satisfaction size
  `<= *node->GetWitnessSize()` (`:1123-1124`).
- **ValidSatisfactions ⇒ valid execution**: if `node->ValidSatisfactions()` then the
  non-malleable witness must verify: `assert(res)` (`:1132`) under
  `STANDARD_SCRIPT_VERIFY_FLAGS`.
- **Failure-channel classification** (non-mal): verification may only fail due to ops
  limit or stack size, and only when the corresponding static check predicted it:
  `assert(res || (!node->CheckOpsLimit() && serror == SCRIPT_ERR_OP_COUNT) ||
   (!node->CheckStackSize() && serror == SCRIPT_ERR_STACK_SIZE))` (`:1135-1137`).
- **Failure-channel classification (mal)**: malleable witness may only ever fail with
  `SCRIPT_ERR_OP_COUNT` or `SCRIPT_ERR_STACK_SIZE`
  (`assert(res || serror == ... || serror == ...)`, `:1146-1148`) — never any other
  script error. Malleable execution is only exercised when it differs from the
  non-malleable witness (`:1140-1142`).
- **IsSane ⇒ algorithms agree**: `if (node->IsSane()) assert(mal_success == nonmal_success);`
  (`:1151-1154`).
- **Policy-satisfiability predictive correctness**: `IsSatisfiable` over a leaf-level oracle
  (sig available & even-key, timelock parity, known preimages; `:1160-1191`) must match the
  malleable satisfier exactly: `assert(mal_success == satisfiable)` (`:1192`). Comment
  (`:1156-1159`): this implies non-mal satisfaction matches the expected policy for sane
  nodes.

### 1.5 Malleability assumptions (stated, conditionally tested)

- Malleability is *only* exercised for nodes where the malleable witness differs from the
  non-malleable one (`:1140`). The target assumes malleability can arise (via timelock
  parity randomization `:251-252`, and the 50% sig-availability pattern `(i & 1)`
  `:74`, `:77`) but never asserts any specific node is malleable.
- Malleability must never turn a fail-per-policy into a pass except through stack/ops
  resource errors (`:1146-1148`).

### 1.6 `script_descriptor_cache.cpp` (brief)

Unrelated to Miniscript typing; asserts a cache round-trip invariant
(`script_descriptor_cache.cpp:21-42`): after `CacheParentExtPubKey(pos, xpub)` /
`CacheDerivedExtPubKey(pos, idx, xpub)`, the corresponding getter must succeed
(`assert(...GetCached...)`, `:31`, `:36`) and return the identical key
(`assert(xpub == xpub_fetched)`, `:38`). Loops up to 10000 iterations via `LIMITED_WHILE`.

---

## 2. Structure of `LLVMFuzzerTestOneInput` (input-byte → operation mapping)

Via the `FUZZ_TARGET` macro, each target gets the raw buffer and wraps it in
`FuzzedDataProvider provider(buffer.data(), buffer.size())`
(`:1214`, `:1227`, `:1240`, `:1257`).

- **`miniscript_stable`** (`:1210-1219`): the *same* buffer is replayed twice, once with a
  fresh provider per context (P2WSH, then Tapscript) — a fresh `FuzzedDataProvider` is
  constructed inside the loop, so identical bytes drive both contexts. The driver is
  `GenNode(... ConsumeNodeStable ..., root_type = "")`, i.e. any base type allowed.
- **`miniscript_smart`** (`:1222-1232`): one provider; byte 0 → `ConsumeBool()` picks the
  context (`(MsCtx)provider.ConsumeBool()`, `:1228`); next bytes → `PickValue(provider,
  BASE_TYPES)` picks the required root type ∈ {B, V, K, W} (`:1225`, `:1231`); remainder
  drives `ConsumeNodeSmart` with `strict_valid = true`.
- **`miniscript_string`** (`:1235-1252`): all-but-last byte → `ConsumeBytesAsString(
  remaining_bytes() - 1)` becomes the candidate Miniscript text; the **last** byte →
  `ConsumeBool()` picks the context (`:1243`). Pre-filter `is_too_expensive` =
  `HasTooManySubFrag || HasTooManyWrappers` (`:1237`, `:1242`; helpers in
  `util/descriptor.{h,cpp}`) rejects pathological nesting/wrapper density to bound parse
  cost. Empty buffer → early return.
- **`miniscript_script`** (`:1255-1266`): bytes → `ConsumeDeserializable<CScript>`; then
  `ConsumeBool()` picks the context for `ScriptParserContext`.

### Node consumption (`ConsumeNodeStable`, `:387-505`)

A stable byte-level encoding of fragments:

- Byte N → fragment selector via `ConsumeIntegral<uint8_t>` switch (`:393`); type-required
  filtering via `allow_B/K/V/W` derived from `type_needed` (`:388-391`); disallowed
  fragment → `return {}` (abort this generation attempt).
- Fragment payload encoding (documented at `:376-386`):
  - `0`,`1` → `just_0`,`just_1` (B only).
  - `2` → `pk_k` + 1 key-index byte (K only); `3` → `pk_h` + index (K only).
  - `4`,`5` → `older`,`after` + 4-byte timelock; `ConsumeTimeLock` (`:367-371`) rejects
    `k == 0 || k >= 0x80000000` (sign bit reserved — consensus/scriptnum constraint).
  - `6..9` → `sha256/hash256/ripemd160/hash160` + 1 index byte into precomputed test data.
  - `10` → `multi` (P2WSH only; rejected in Tapscript `:431`): 1 byte `k`, 1 byte
    `n_keys`, requires `n_keys ≤ 20`, `1 ≤ k ≤ n_keys`, then `n_keys` key-index bytes.
  - `11` → `andor` (needs B|K|V), subtypes `{B, needed, needed}`; `12` → `and_v`
    `{V, needed}`; `13` → `and_b` `{B, W}`; `15` → `or_b` `{B, W}`; `16` → `or_c`
    `{B, V}`; `17` → `or_d` `{B, B}`; `18` → `or_i` `{needed, needed}` (B|K|V only).
  - `19` → `thresh`: 1 byte `k`, 1 byte `n_subs`, `1 ≤ k ≤ n_subs`; subnode types are
    forced to first-`B`-then-`W`s (`:465-469`).
  - `20..26` → wrappers `a`, `s`, `c`, `d`, `v`, `j`, `n`, each with its fixed required
    child type and parent-type gate (`:471-491`).
  - `27` → `multi_a` (Tapscript only, `:493`): 2-byte `k`, 2-byte `n_keys ≤ 999`,
    `1 ≤ k ≤ n_keys`, then key indices.
  - Selector 14 and `default:` → `{}` (consuming nothing beyond the selector).

Key/hash leaves index into 256-entry precomputed pools via a single byte
(`ConsumeIndex`, `:341-365`) — deliberately *content-stable* across runs (hence "stable").

### Smart consumption (`ConsumeNodeSmart`, `:771-843`)

- Looks up recipes for `type_needed` in the precomputed per-context `SMARTINFO` table
  (assert-fails if absent, `:775`); picks one recipe with `PickValue` (`:777`).
- Fills parameters with *ranged* draws: `multi` n∈[1,20], k∈[1,n] (`:785-786`);
  `multi_a` n∈[1,999] (`:792-793`); timelocks ∈ [1, 0x7FFFFFF] via
  `ConsumeIntegralInRange` (`:800`); hashes via `PickValue` into test data (`:802-808`);
  `thresh` may extend a ≥2-sub recipe to up to `MAX_OPS_PER_SCRIPT / 2` children by
  replicating the last subtype, with k ∈ [1, children] (`:826-838`).
- Falls off the switch as `assert(false)` (`:842`) for impossible fragment/recipe
  combinations.

### GenNode assembly (`:854-1007`)

Worklist algorithm: `todo` stack of `(Type needed, optional<NodeInfo>)`; `stack` of
completed `Node`s; construction in reverse child order (`:954-956`). Interleaves byte
consumption with **predictive resource accounting** (`ops`, `scriptsize`,
`:862-864`, per-fragment op increments `:879-947`), aborting (`return {}`) when predictions
exceed `MAX_STANDARD_P2WSH_SCRIPT_SIZE` (`:878`, `:994`) or `MAX_OPS_PER_SCRIPT`
(`:948`, `:993`) — mirroring `miniscript::internal::Parse`'s anti-runaway technique
(`:874-876`). Terminal asserts: exact ops/size prediction equality (`:1003-1004`),
then `DuplicateKeyCheck(KEY_COMP)` (`:1005`).

Test-phase byte usage: `provider.ConsumeBool()` (`:1068`) decides adversarial **padding**:

- P2WSH: pad script tail with `OP_NOP` up to min(remaining ops budget, remaining size
  budget) (`:1078-1085`) — stress-tests op-count under-accounting.
- Tapscript: pad the *witness stack* to `MAX_STACK_SIZE - GetExecStackSize()` and script
  with `OP_NIP` (`:1089-1096`) — stress-tests execution-stack-size accounting.

---

## 3. Stability logic, signature mocking, execution observation

### Epoch/stability

There is **no `CONSENSUS_CRITICAL` symbol and no epoch-based logic** in this target. The
stability concept here is *seed-encoding stability*: `ConsumeNodeStable`'s comment
(`:376-386`) says the byte format is intended fixed so corpuses survive across versions,
whereas `ConsumeNodeSmart` explicitly accepts corpus fragility when typing rules change
(`:761-770`). Fuzz init is split accordingly: `FuzzInit` (`:1197-1201`) seeds `TEST_DATA`
plus an `ECC_Context`; `FuzzInitSmart` (`:1203-1207`) additionally builds `SMARTINFO`
(compile-time-ish table build calling `miniscript::internal::ComputeType` exhaustively,
`:525-758`). The only time-related "epoch" flavor is the timelock parity mock below.

### Signature mocking

All signatures sign one constant message
`MESSAGE_HASH = 0000…a71065` (`:53`). For 256 deterministic keys
(privkey = 31 zero bytes ‖ i, `:51`, `:57-60`):

- ECDSA: `privkey.Sign(MESSAGE_HASH, sig)` + `SIGHASH_ALL` byte (`:72-73`), stored with
  availability bit `i & 1` (`:74`) — half the keys are "unsatisfiable".
- Schnorr: `assert(privkey.SignSchnorr(MESSAGE_HASH, schnorr_sig, nullptr, EMPTY_AUX))`
  with **zero aux randomness** (`:55`, `:75`), plus sighash byte appended ("maximally-sized
  signature", `:76`), availability also `i & 1` (`:77`).
- `GetSig` dispatches ECDSA vs Schnorr by context via `IsTapscript` (`:99-109`).

The execution-time check is by **exact byte equality in a lookup table**, not
cryptographic verification: `CheckerContext : BaseSignatureChecker` (`:287-306`):

- `CheckECDSASignature`: true iff sig equals the stored dummy sig for that key
  (`:289-296`) — ignores `scriptCode`/`sigversion` entirely.
- `CheckSchnorrSignature`: `std::ranges::equal(stored_sig, sig)` (`:297-303`).
- `CheckLockTime`/`CheckSequence`: `value & 1` (`:304-305`) — matches the satisfier's
  parity oracle `value % 2` (`SatisfierContext::CheckAfter/CheckOlder`, `:251-252`), so
  timelock satisfiability is deterministic per value across satisfier and checker.

Hash preimages: only odd-indexed entries (`i & 1`) get recorded preimages
(`:83`, `:86`, `:91`, `:94`), so each `sha256(...)` etc. is satisfiable with probability
~1/2, mirroring the sig availability pattern.

### Execution observation

Not `CScriptExec`-style tracing; observation is end-to-end through the consensus
verification entry point:

- ScriptPubKey synthesis: P2WSH → `OP_0 <sha256(script)>`; Tapscript → single-leaf
  `TaprootBuilder` under `XOnlyPubKey::NUMS_H` internal key
  (`ScriptPubKey`, `:1010-1018`).
- Witness assembly: satisfaction stack + witness script (+ control block for Taproot)
  (`SatisfactionToWitness`, `:1021-1027`).
- `VerifyScript(DUMMY_SCRIPTSIG = {}, script_pubkey, &witness,
  STANDARD_SCRIPT_VERIFY_FLAGS, CHECKER_CTX, &serror)` (`:1130`, `:1145`); the only
  observed outputs are the boolean result and `ScriptError serror`, which are compared
  against the node's *static* predictions (`CheckOpsLimit`, `CheckStackSize`,
  `ValidSatisfactions`, `GetStackSize`, `GetWitnessSize`) in the assert lattice of
  §1.4. `TaprootBuilder` spend data is fetched via `builder.GetSpendData()` (`:1026`).

---

## 4. Candidate formal Lean theorem statements

Names are suggestions; statements paraphrase the asserted C++ invariants. Order ≈ by
increasing semantic depth.

1. **`tostring_fromString_roundtrip`**
   For any valid node `n : Miniscript ctx` with stringifiable keys:
   `FromString (ToString n) = some n'` → `n' = n`.
   (`miniscript.cpp:1036-1040`.)

2. **`toString_normal_form_idempotent`**
   For any string `s`, if `FromString s = some n` then
   `FromString (ToString n) = some n'` with `n' = n` (parse succeeds and is a fixpoint).
   (`:1244-1251`.)

3. **`scriptSize_exact`**
   `n.ScriptSize = (n.ToScript).size`. (`:1043-1044`.)

4. **`fromScript_roundtrip_script`**
   If `FromScript scr = some m` then `m.ToScript = scr`. (`:1257-1265` and `:1057-1062`.)

5. **`fromScript_type_preserving`**
   If `FromScript (n.ToScript) = some m` then `m.GetType = n.GetType`. (`:1057-1063`.)

6. **`type_x_iff_ends_in_nonverify_opcode`**
   For non-`K` nodes: `¬(n.type ≤ x)` ↔ `lastOpcode(n.script) ∈ {OP_CHECKSIG,
   OP_CHECKMULTISIG, OP_EQUAL, OP_NUMEQUAL}`. (`:1046-1051`.)

7. **`staticOps_exact` / `genNode_accounting_sound`**
   The incremental op-count/size model used during construction equals
   `GetStaticOps`/`ScriptSize`: `static_ops_acct n = n.GetStaticOps` and
   `size_acct n = n.ScriptSize` (including the `WRAP_V`/`x` correction rule).
   (`:879-1004`, esp. `:989-992`.)

8. **`genNode_type_sound`**
   Any node generated with requirement `T` satisfies `n.GetType ≤ T` whenever `T ≠ ⊤`
   (and in strict mode a valid base type always exists). (`:980-985`.)

9. **`satisfy_nonmal_stack_bound`**
   If `Satisfy n σ true = some w` then `|w| ≤ n.GetStackSize` (before adding witness
   script/control block). (`:1113-1118`.)

10. **`satisfy_witness_size_bound`**
    If `Satisfy n σ nonmal = some w` then `serializedSize w ≤ n.GetWitnessSize`.
    (`:1122-1124`.)

11. **`satisfy_mal_nonmal_refinement`**
    `Satisfy n σ true = some w` → `Satisfy n σ false = some w` (same stack).
    Non-malleable success implies malleable success *with identical output*.
    (`:1119-1121`.)

12. **`validSatisfactions_execution_sound`**
    `n.ValidSatisfactions → Satisfy n σ nonmal = some w → VerifyScript (spk n) w flags
    checker = true`. (`:1130-1132`.)

13. **`execution_failure_channels`**
    Non-mal: verification failure ⇒ error ∈ {OP_COUNT, STACK_SIZE} ∧ the corresponding
    static check (`CheckOpsLimit`/`CheckStackSize`) is false. Mal: verification failure ⇒
    error ∈ {OP_COUNT, STACK_SIZE} (unconditionally). (`:1133-1137`, `:1146-1148`.)

14. **`isSane_satisfy_agree`**
    `n.IsSane → (Satisfy n σ mal succeeds ↔ Satisfy n σ nonmal succeeds)`.
    (`:1151-1154`.)

15. **`isSatisfiable_decides_satisfy` (completeness of the policy oracle)**
    For the leaf oracle `sat` (sig availability, timelock parity, preimage membership):
    `n.IsSatisfiable sat ↔ ∃w. Satisfy n σ mal = some w`. (`:1156-1192`; the C++ asserts
    `mal_success == satisfiable`, an iff.)

16. **`descriptor_cache_write_read`** *(from script_descriptor_cache.cpp)*
    `cache k v` then `getCached k` returns `some v`. (`script_descriptor_cache.cpp:31-38`.)

Theorem 15 is the richest single target: it connects the *declarative* satisfiability
predicate to the *algorithmic* satisfier, and via #14 it lifts to the non-malleable
satisfier for sane fragments — the heart of "policy ⇒ spendability".
