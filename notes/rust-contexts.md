# rust-miniscript: `ScriptContext` + limits analysis

Source: `/home/qrsnap/git/miniscript-lean/rust-miniscript` @ `96a1c91` (v13.0.0, master).
All `file:line` refs are relative to `src/`.

## 0. Terminology mapping (this version vs. older names)

Several names from older rust-miniscript revisions **do not exist** in this checkout:

- `check_witness` / `is_valid` / `sanity_check` (on Miniscript) — gone. Replaced by:
  - per-context hooks on the `ScriptContext` trait (`check_global_consensus_validity`,
    `check_global_policy_validity`, `check_local_consensus_validity`, `check_local_policy_validity`
    — `miniscript/context.rs:220-259`),
  - parameter-driven validation via `Miniscript::validate(&ValidationParams)`
    (`miniscript/mod.rs:349-380`, struct in `validation.rs:16-70`),
  - `Miniscript::within_resource_limits()` = `Ctx::check_local_validity(self).is_ok()`
    (`miniscript/analyzable.rs:42`).
- `check_taproot` — gone; Taproot checks are `impl ScriptContext for Tap` (`context.rs:619-737`).
- `check_size_validity` — no such function (see §4 for the aggregation points).
- `MAX_STANDARD_P2WSH_STACK_ITEM_SIZE` — no such constant; the equivalent is
  `MAX_SCRIPT_ELEMENT_SIZE = 520` (limits.rs:22). (Core's p2wsh 80-byte *stack item*
  standardness limit is not modeled here at all.)
- "magic/pin" behaviors — none exist in `context.rs`/`limits.rs`. The only "magic bytes" in the
  tree are xpub version bytes in `descriptor/key.rs:1669` (unrelated). `MAX_BLOCK_WEIGHT`
  (`limits.rs:31`) is **declared but never used**; Tap uses `bitcoin::Weight::MAX_BLOCK` directly.
- `check_terminal_non_malleable` exists and is documented as "currently only used in compiler
  code" (`context.rs:193-194`) but has **no call sites** in `src/` anymore — it is effectively
  vestigial; non-malleability is instead enforced through `ValidationParams.allow_dup_if /
  allow_or_i / allow_malleability`.

## 1. The `ScriptContext` trait

Defined at `context.rs:168-350`. It is a **sealed** trait
(`private::Sealed`, `context.rs:169, 957-968`; impls for the 5 contexts at 963-967), so no
downstream implementations are possible.

Associated types / consts / methods (`context.rs:176-349`):

```rust
type Key: ParseableKey;                    // context.rs:177
const CONSENSUS: ValidationParams;         // context.rs:181
const SANE: ValidationParams;              // context.rs:188
fn check_terminal_non_malleable(..)        // :198  (unused, see §0)
fn check_pk<Pk>(pk: &Pk)                   // :206
fn max_satisfaction_size<Pk>(ms)           // :209
fn check_global_consensus_validity(..)     // :220  default Ok(())
fn check_global_policy_validity(..)        // :234  default Ok(())
fn check_local_consensus_validity(..)      // :244  default Ok(())
fn check_local_policy_validity(..)         // :255  default Ok(())
fn check_global_validity(..)               // :263  = global consensus + global policy
fn check_local_validity(..)                // :273  = all four
fn top_level_type_check(..)                // :284  (multipath-length consistency only)
fn other_top_level_checks(..)              // :319  default Ok(())
fn top_level_checks(..)                    // :332  = type_check + other
fn sig_type() -> SigType                   // :340  (Ecdsa|Schnorr, :354-359)
fn pk_len<Pk>(pk: &Pk) -> usize            // :346
fn name_str() -> &'static str              // :349
```

Note on naming: `top_level_type_check` *says* "Check whether the top-level is type B"
(`context.rs:283`) but its body only checks BIP389 multipath-length consistency
(`context.rs:285-315`); the top-level-`B` check moved into `Miniscript::validate`
(`mod.rs:362-365`, gated on `params.allow_non_b`).

Error enum: `ScriptContextError` (`context.rs:21-63`) — variants `MalleableOrI`,
`MalleableDupIf`, `CompressedOnly`, `XOnlyKeysNotAllowed`, `UncompressedKeysNotAllowed`,
`MaxWitnessItemsExceeded`, `MaxOpCountExceeded`, `MaxWitnessScriptSizeExceeded`,
`MaxRedeemScriptSizeExceeded`, `MaxBareScriptSizeExceeded`, `MaxScriptSigSizeExceeded`,
`ImpossibleSatisfaction`, `TaprootMultiDisabled`, `StackSizeLimitExceeded`, `MultiANotAllowed`.

### 1.1 `Legacy` (p2sh) — `context.rs:366-484`

- `type Key = bitcoin::PublicKey` (369); `sig_type() = Ecdsa` (483); `name_str() = "Legacy/p2sh"` (481).
- `pk_len`: 66 uncompressed else 34 (473-479).
- `CONSENSUS` (371-381):
  ```rust
  allow_compressed_keys: true, allow_dup_if: false, allow_uncompressed_keys: true,
  allow_multi_a: false, allow_or_i: false, allow_x_only_keys: false,
  max_opcode_count: MAX_OPS_PER_SCRIPT,      // 201
  max_script_size: MAX_SCRIPT_ELEMENT_SIZE,  // 520  (P2SH redeem-script push limit)
  ..ValidationParams::CONSENSUS
  ```
  `SANE = CONSENSUS ∩ ValidationParams::SANE` (382).
- Forbidden fragments:
  - **`or_i`** and **`d:` (DupIf)** — rejected by `check_terminal_non_malleable` (384-392)
    *and* by `allow_or_i/allow_dup_if: false` in CONSENSUS.
  - **`multi_a` / `sortedmulti_a`** — `Err(ScriptContextError::MultiANotAllowed)` in
    `check_global_consensus_validity` (415-417) + `allow_multi_a: false`.
  - **x-only keys** — `check_pk` (395-401) → `XOnlyKeysNotAllowed`. Uncompressed allowed.
- Size checks:
  - global consensus: `ms.ext.pk_cost > MAX_SCRIPT_ELEMENT_SIZE` → `MaxRedeemScriptSizeExceeded` (423-427).
  - local consensus: `sat_op_count() > MAX_OPS_PER_SCRIPT` (201) → `MaxOpCountExceeded`,
    `None` → `ImpossibleSatisfaction` (439-447).
  - local policy: `max_satisfaction_size() > MAX_SCRIPTSIG_SIZE` (1650) →
    `MaxScriptSigSizeExceeded` (457-465).
  - 1000-stack-element limit deliberately **not** checked: "520 bytes consensus limits on P2SH
    size, it is not possible to reach the 1000 elements limit" (454-456).
- No global policy override; `max_satisfaction_size` = `sat_data.max_script_sig_size` (469-471).

### 1.2 `Segwitv0` (wsh / sh-wsh) — `context.rs:488-613`

- `Key = bitcoin::PublicKey` (491); `SigType::Ecdsa` (612); `pk_len = 34` always (608);
  `name_str() = "Segwitv0"` (610).
- `CONSENSUS` (493-501): `allow_uncompressed_keys: false, allow_multi_a: false,
  allow_x_only_keys: false, max_opcode_count: 201, max_exec_stack_size: MAX_STACK_SIZE(1000)`.
- `SANE` (502-506) adds `max_script_size: MAX_STANDARD_P2WSH_SCRIPT_SIZE(3600)`,
  `max_witness_items: MAX_STANDARD_P2WSH_STACK_ITEMS(100)` on top of CONSENSUS ∩ SANE.
- Forbidden fragments/keys:
  - **`multi_a`/`sortedmulti_a`** → `MultiANotAllowed` (537-539).
  - **uncompressed keys** → `check_pk` → `UncompressedKeysNotAllowed` (516-517).
  - **x-only keys** → `XOnlyKeysNotAllowed` (518-519).
  - `or_i`/`d:` are *allowed* (segwit enforces minimal IF).
- Size/witness checks:
  - global consensus: `pk_cost > MAX_SCRIPT_SIZE` (10 000) → `MaxWitnessScriptSizeExceeded` (545).
  - global policy: `pk_cost > MAX_STANDARD_P2WSH_SCRIPT_SIZE` (3600) (576-581). **Policy-only**,
    so `Segwitv0::CONSENSUS`-validated scripts may exceed 3600 bytes.
  - local consensus: sat op count ≤ 201 (561-569).
  - local policy: `max_satisfaction_witness_elements() ≤ 100`, where the count is
    `sat_data.max_witness_stack_count + 1` (the +1 is the witness script itself,
    `mod.rs:586-590`); comment at 588-590 explains it need not distinguish p2wsh from other v0
    programs.
- `max_satisfaction_size` = `sat_data.max_witness_stack_size` (604-606).

### 1.3 `Tap` (tapscript, BIP-342) — `context.rs:617-737`

- `Key = bitcoin::secp256k1::XOnlyPublicKey` (620); `SigType::Schnorr` (732); `pk_len = 33`
  (734 — 32-byte key + 1 push opcode).
- `CONSENSUS` (622-628): `allow_compressed_keys: false, allow_uncompressed_keys: false,
  allow_multi: false, allow_x_only_keys: true`; everything else inherited (so **no** op-count,
  script-size, witness-item limits at the params level).
- `SANE` (629-635) adds only `max_exec_stack_size: MAX_STACK_SIZE(1000)`:
  "no script size limit (though maybe we should enforce a 4mb limit?) and no policy limit on
  number of initial stack items" (630-632).
- Forbidden fragments/keys:
  - **`multi` / `sortedmulti`** → `TaprootMultiDisabled` (666-668) + `allow_multi: false`.
  - **uncompressed keys** → `UncompressedKeysNotAllowed` (646-652). (`check_pk` does not reject
    compressed 33-byte keys; in practice when *decoding script* a 33/65-byte push fails earlier
    in `XOnlyPublicKey::from_slice` → `Error::PubKeyCtxError`, decode.rs:353-361 + 39-43.)
  - **`multi_a`/`sortedmulti_a` allowed**, each key `check_pk`'d (660-665).
  - **`pk_h` / `expr_raw_pkh` are NOT forbidden by the Tap context** — they fall through
    `_ => Ok(())` at 669. `RawPkH` is excluded instead by validation params:
    `ValidationParams::SANE.allow_raw_pkh: false` (validation.rs:112), and the `tr(...)` parser
    validates each leaf with `{ allow_raw_pkh: false, ..Tap::CONSENSUS }` as an explicit "FIXME
    hack" (`descriptor/tr/mod.rs:380-384`) and again with `Tap::SANE` in
    `Descriptor::from_str` (`descriptor/mod.rs:1170-1176`).
- Size/stack checks:
  - global consensus: only a 4-MWU block-weight bound — `ms.ext.pk_cost as u64 >
    Weight::MAX_BLOCK.to_wu()` → `MaxWitnessScriptSizeExceeded` (679-683). Leaf size is otherwise
    unbounded (BIP-342 dropped the 10 000-byte limit; taproot tree depth 128 is enforced at the
    descriptor layer, see §2).
  - local consensus: `max_witness_stack_count + max_exec_stack_count > MAX_STACK_SIZE(1000)` →
    `StackSizeLimitExceeded` (704-711). The 201-op limit is replaced by the sigops-budget
    argument spelled out at 695-703 ("sigops budget = witness_script.len() + witness.size() +
    50; each 64-byte signature covers its own 50").
  - global/local policy: none (715-726): "No script rules, rules are subject to entire tx rules".

### 1.4 `BareCtx` — `context.rs:744-860`

- `Key = bitcoin::PublicKey`; `SigType::Ecdsa` (859); `pk_len` 66/34 (849-855);
  `name_str() = "BareCtx"`.
- `CONSENSUS` (749-759): like Legacy but `max_script_size: MAX_SCRIPT_SIZE(10 000)`, still
  `allow_dup_if: false, allow_multi_a: false, allow_or_i: false, allow_x_only_keys: false`.
- Forbidden: `multi_a` → `MultiANotAllowed` (793-795); x-only keys → 773-779; uncompressed OK.
- Checks: global consensus `pk_cost > 10 000` → `MaxBareScriptSizeExceeded` (801-805);
  local consensus op count ≤ 201 (817-825).
- **No local policy** (no 1650 scriptSig check — bare satisfaction lives in scriptSig, but the
  whole construct is gated by the top-level standardness whitelist instead):
  ```rust
  // context.rs:829-841
  fn other_top_level_checks<Pk>(ms: &Miniscript<Pk, Self>) -> Result<(), Error> {
      match &ms.node {
          Terminal::Check(ref ms) => match &ms.node {
              Terminal::RawPkH(_pkh) => Ok(()),
              Terminal::PkK(_pk) | Terminal::PkH(_pk) => Ok(()),
              _ => Err(Error::NonStandardBareScript),
          },
          Terminal::Multi(ref thresh) | Terminal::SortedMulti(ref thresh) if thresh.n() <= 3 => Ok(()),
          _ => Err(Error::NonStandardBareScript),
      }
  }
  ```
  i.e. top-level may only be `c:pk(k)`, `c:pk_h(k)`, `c:expr_raw_pkh(h)` (P2PK/P2PKH), or
  bare (sorted)multi with **n ≤ 3**. ("thresh_m(k,...) up to n=3", docs at 326-328, error text
  lib.rs:526-531.)

### 1.5 `NoChecks` — `context.rs:862-954`

```rust
/// Used by the "satisfied constraints" iterator, which is intended to read
/// scripts off of the blockchain without doing any sanity checks on them.
pub enum NoChecks {}
```
- `Key = bitcoin::PublicKey`; `CONSENSUS = SANE = ValidationParams::MAX` (873-874).
- Every check returns `Ok(())`; `top_level_type_check`/`other_top_level_checks` overridden to no-ops
  (940-952).
- `max_satisfaction_size` and `pk_len` **panic** (909-915): the context has "forgotten" key
  sizes. This is why `Miniscript::validate_non_top_level` gates the script-size check behind
  `params.max_script_size < usize::MAX` (mod.rs:455-468, FIXME comment).
- Actual use: the interpreter converts any miniscript into `Miniscript<BitcoinKey, NoChecks>`
  (`interpreter/inner.rs:82, 344-372`) so it can execute chain-sourced scripts without
  re-running limits; key-shape ambiguity is fixed by `TypedHash160` (inner.rs:344-346).

### 1.6 Summary matrix

| check / limit | Legacy | Segwitv0 | Tap | BareCtx | NoChecks |
|---|---|---|---|---|---|
| x-only keys | ✗ (395) | ✗ (518) | ✓ (only kind) | ✗ (773) | whatever |
| uncompressed keys | ✓ | ✗ (516) | ✗ (647) | ✓ | ✓ |
| `multi`/`sortedmulti` | ✓ | ✓ | **✗** (666) | ✓ (top-lvl n≤3: 836) | ✓ |
| `multi_a`/`sortedmulti_a` | **✗** (415) | **✗** (537) | ✓ | **✗** (793) | ✓ |
| `or_i` | ✗ (388, 377) | ✓ | ✓ | ✗ (754) | ✓ |
| `d:` (DupIf) | ✗ (389, 374) | ✓ | ✓ | ✗ (751) | ✓ |
| `pk_h` / `expr_raw_pkh` | ✓ / SANE-only ✗ (val.rs:112) | ✓ / SANE ✗ | ✓(ctx) / SANE ✗ + tr() hack | ✓ top-level only | ✓ |
| script size (global consensus) | ≤ 520 (pk_cost, 423) | ≤ 10 000 (545) | ≤ 4 MWU (679) | ≤ 10 000 (801) | — |
| script size (policy) | — | ≤ 3600 (576) | — | — | — |
| sat op count (local consensus) | ≤ 201 (441) | ≤ 201 (563) | sigops-budget argument only (695-711) | ≤ 201 (819) | — |
| witness/scriptSig (local policy) | scriptSig ≤ 1650 (459) | witness items ≤ 100 (+1 script, 594) | — | — | — |
| exec stack (local consensus) | — (unreachable, 454-456) | 1000 via params (499) | 1000 (705, via SANE 633) | — | — |
| satisfaction-size query | `max_script_sig_size` (470) | `max_witness_stack_size` (605) | `max_witness_stack_size` (729) | `max_script_sig_size` (846) | panics (910) |
| sig type | ECDSA | ECDSA | Schnorr | ECDSA | ECDSA |

## 2. limits.rs constants and where each fires

`miniscript/limits.rs` (whole file is 38 lines):

| constant (limits.rs) | value | kind / Core source cited | applied in rust-miniscript at |
|---|---|---|---|
| `MAX_OPS_PER_SCRIPT` (:9) | 201 | consensus, script.h#L26 | `CONSENSUS.max_opcode_count` of Legacy:378, Segwitv0:498, BareCtx:756; hardcoded in `check_local_consensus_validity` Legacy:441 / Segwitv0:563 / BareCtx:819; `Miniscript::validate` mod.rs:488. **Parse/validate-time.** |
| `MAX_STANDARD_P2WSH_STACK_ITEMS` (:12) | 100 | policy, policy.h#L40 | Segwitv0 `SANE.max_witness_items` (ctx:504) + `check_local_policy_validity` (ctx:585-602, +1 for the witness script, mod.rs:586-590); `validate` mod.rs:471-482. **Policy only — not in `Segwitv0::CONSENSUS`.** |
| `MAX_SCRIPT_SIZE` (:15) | 10 000 | consensus, script.h#L32 | Segwitv0 global consensus (ctx:545), BareCtx global consensus (801), `BareCtx::CONSENSUS.max_script_size` (757). |
| `MAX_STANDARD_P2WSH_SCRIPT_SIZE` (:18) | 3 600 | policy, policy.h#L44 | Segwitv0 global policy (ctx:573-583) + SANE (503). |
| `MAX_SCRIPT_ELEMENT_SIZE` (:22) | 520 | consensus, script.h#L23 | Legacy global consensus as max P2SH redeemScript (ctx:423) + `Legacy::CONSENSUS.max_script_size` (379); runtime assert in `witness_to_scriptsig` (`util.rs:61`). **This is the constant that plays the role of "MAX_STANDARD_P2WSH_STACK_ITEM_SIZE".** |
| `MAX_SCRIPTSIG_SIZE` (:25) | 1 650 | policy, policy.cpp#L102 | Legacy local policy only (ctx:457-466). |
| `MAX_STACK_SIZE` (:29) | 1 000 | consensus, script.h#L35 ("applies for initial stack satisfaction") | `Segwitv0::CONSENSUS.max_exec_stack_size` (499), `Tap::SANE.max_exec_stack_size` (633), hardcoded Tap local consensus check `max_witness_stack_count + max_exec_stack_count > 1000` (ctx:705); `validate` mod.rs:495-506. |
| `MAX_BLOCK_WEIGHT` (:31) | 4 000 000 | BIP141 | **unused constant**; Tap instead compares against `bitcoin::Weight::MAX_BLOCK.to_wu()` (ctx:679). |
| `MAX_PUBKEYS_PER_MULTISIG` (:35) | 20 | consensus, script.h#L30 | type parameter `Threshold<Pk, 20>` on `Terminal::Multi/SortedMulti` (decode.rs:155-157); pre-check at script decode `validate_k_n::<20>(1, n)` (decode.rs:520); `Threshold::new` re-check (decode.rs:537); constructors `Miniscript::multi/sortedmulti` (mod.rs:270,281); descriptor `*_sortedmulti` ctors (descriptor/segwitv0.rs:48, sh.rs:123,138, mod.rs:212-229); compiler (policy/compiler.rs:545); size accounting (extra_props.rs:270,310). |
| `MAX_PUBKEYS_IN_CHECKSIGADD` (:38) | 999 | consensus, script.h#L36 | type parameter `Threshold<Pk, 999>` on `Terminal::MultiA/SortedMultiA` (decode.rs:159-161); pre-check `validate_k_n::<999>(k, k)` at decode (decode.rs:545, valid since ≥ k keys must follow); `Miniscript::multi_a/sortedmulti_a` (mod.rs:292,303); compiler gate (policy/compiler.rs:553). |

### Recursion limits (`MAX_RECURSION_DEPTH = 402`)

Defined in **`lib.rs:499`**, *not* limits.rs: `const MAX_RECURSION_DEPTH: u32 = 402;` with
comment pointing to sipa/miniscript#5 (history: segwit-v0-script-derived stack-overflow bound,
"TODO: This recursion depth is based on segwitv0" mod.rs:323-326). Three separate enforcement
points:

1. **Expression (string) parse**: max *paren-nesting* depth of the textual tree —
   ```rust
   // expression/mod.rs:593-598
   if u32::try_from(max_depth).unwrap_or(u32::MAX) > MAX_RECURSION_DEPTH {
       return Err(ParseTreeError::MaxRecursionDepthExceeded {
           actual: max_depth, maximum: MAX_RECURSION_DEPTH });
   }
   ```
2. **AST construction / decode** (every `from_ast`, i.e. every fragment node, bottom-up):
   `if (res.ext.tree_height as u32) > MAX_RECURSION_DEPTH { return Err(Error::MaxRecursiveDepthExceeded) }`
   (miniscript/mod.rs:327-329). `ext.tree_height` is computed per node (`extra_props.rs:159`).
3. **Post-hoc validation**: `ValidationParams.max_recursive_depth` (= 402 in `MAX`, `SANE`,
   `CONSENSUS`; validation.rs:94,125,154) checked in `validate_non_top_level`
   (mod.rs:391-395 → `ValidationError::MaxRecursiveDepthExceeded`).

Parse vs construction vs descriptor application, per limit:

- **Script-decode** (`decode/decode_with_validation_params`, mod.rs:724-745): lex (`lex.rs` —
  `Tk::Num(u32)` from minimal script-int ≥ 0, lex.rs:217-224; only 20/32/33/65-byte pushes become
  keys/hashes, 207-225) → per-token multi/multi_a/locktime checks (decode.rs:447-450, 520, 545)
  → `Ctx::check_global_validity` (737) → `Type::type_check` → `top.validate(params)` (742).
  `decode()` uses `Ctx::SANE` (780), `decode_consensus()` uses `Ctx::CONSENSUS` (724-726).
- **String parse** (`from_str_with_validation_params`, mod.rs:980-989; `from_str` = SANE
  (1196-1199); `from_str_insane` = CONSENSUS + `allow_raw_pkh: false` (974-977)):
  recursion pre-check → `from_tree` (fragments built via `from_ast`, so recursion + global
  validity per node, and again post-hoc over every node at 1187-1189) → `ms.validate(params)`.
- **Construction**: `Miniscript::from_ast` (mod.rs:315-331) — types, ExtData, recursion, global
  context validity. The compiler additionally prunes candidates via `Ctx::check_local_validity`
  (`policy/compiler.rs:817`); concrete policy tree capped at `MAX_COMPILATION_LEAVES = 1024`
  (`policy/concrete.rs:39`).
- **Descriptor layer**: constructors run `Ctx::top_level_checks` (`descriptor/segwitv0.rs:43`,
  `sh.rs:91,117`, `bare.rs:40,170`); `tr()` tree depth ≤ 128 via `TapTreeDepthError` /
  `TAPROOT_CONTROL_MAX_NODE_COUNT` from rust-bitcoin (`descriptor/tr/taptree.rs:16-20,44,260`),
  each `tr` leaf validated with `{allow_raw_pkh:false, ..Tap::CONSENSUS}` at parse
  (tr/mod.rs:383) and re-validated with `Tap::SANE` by `Descriptor::from_str`
  (descriptor/mod.rs:1170-1176). Note: e.g. `Wsh::from_str` goes through
  `from_tree` + `top_level_checks` **without** a `Ctx::SANE` `validate()` call
  (segwitv0.rs:184-213, 207-213) — for sh/wsh contexts the SANE check only happens on the
  bare-Miniscript `FromStr` path; the context checks in `from_ast` still apply.

## 3. Numeric limits per fragment

### 3.1 `after(n)` — `primitives/absolute_locktime.rs`

```rust
pub const MAX_ABSOLUTE_LOCKTIME: u32 = 0x7FFF_FFFF;   // :10
pub const MIN_ABSOLUTE_LOCKTIME: u32 = 1;             // :17 ("0 … is not [allowed], because we
                                                      //  (ab)use the locktime value as a boolean")
pub fn from_consensus(n: u32) -> Result<Self, AbsLockTimeError> {
    if n >= MIN_ABSOLUTE_LOCKTIME && n <= MAX_ABSOLUTE_LOCKTIME { … } else { Err(…) }
}                                                     // :51-57
```
So **`after(0)` is invalid** (error text: "absolute locktimes in Miniscript have a minimum value
of 1", :27-29), max `0x7FFF_FFFF` (= 2³¹−1). Applied identically in string parse
(`verify_after`, expression/mod.rs:347-357), script decode (decode.rs:449-450), and direct
construction (`Miniscript::after` takes `AbsLockTime`, mod.rs:553 cites `to_consensus_u32`).

### 3.2 `older(n)` — `primitives/relative_locktime.rs`

```rust
// :85-94
impl convert::TryFrom<Sequence> for RelLockTime {
    fn try_from(seq: Sequence) -> Result<Self, RelLockTimeError> {
        if seq.is_relative_lock_time() && seq != Sequence::ZERO { Ok(Self(seq)) }
        else { Err(RelLockTimeError { value: seq.to_consensus_u32() }) }
    }
}
```
So **`older(0)` is invalid** ("relative locktimes in Miniscript have a minimum value of 1",
:17-18) and any value that is not a valid BIP-68 relative locktime (i.e. bit-31 disable flag
set) is rejected (:20-24). Helpers: `from_height(u16)` (:51), `from_512_second_intervals(u16)`
(:59). A `RelLockTime::ZERO` const *exists* (:38-39) as an internal "no relative locktime"
sentinel (used in policy/timelock accounting), but it can never come from parsing.

### 3.3 `thresh(k, …)` — `primitives/threshold.rs`

`Terminal::Thresh` is `Threshold<Arc<Miniscript>, 0>` (**type-level MAX = 0 = unbounded**,
decode.rs:153). Check (`threshold.rs:46-52`):
```rust
pub fn validate_k_n<const MAX: usize>(k: usize, n: usize) -> Result<(), ThresholdError> {
    if k == 0 || k > n || (MAX > 0 && n > MAX) { Err(...) } else { Ok(()) }
}
```
So only k ≥ 1, k ≤ n, n ≥ 1 ("thresholds must be nonempty / k > 0 / cannot have k > n",
:25-30). **No per-context numeric bound on `thresh`** — it is constrained only indirectly
through script-size/opcount/witness/stack limits. (Bare's n ≤ 3 whitelist applies only to
top-level `multi`/`sortedmulti`, not to `thresh`; no fragment-level cap besides the 미 compile-time
`MAX_COMPILATION_LEAVES = 1024` for concrete policies, `policy/concrete.rs:39`.)

`thresh` n/k are bounded at the ExtData layer only for accounting: `sat_dissat_vec` etc.
(extra_props.rs:820-940), `pk_cost += … + (n-1)` ADDs (937).

### 3.4 `multi`/`sortedmulti` and `multi_a`/`sortedmulti_a`

- `multi/sortedmulti`: `Threshold<Pk, MAX_PUBKEYS_PER_MULTISIG=20>`; `k ≥ 1, k ≤ n ≤ 20`
  (decode.rs:155-157, 520, 537). Context gating as in §1 (forbidden in Tap only).
- `multi_a/sortedmulti_a`: `Threshold<Pk, MAX_PUBKEYS_IN_CHECKSIGADD=999>` — 999 mirrors Core's
  999-op tapscript budget scaling (limits.rs:36-38); `k ≥ 1, k ≤ n ≤ 999`
  (decode.rs:159-161, 545, 562). Forbidden everywhere except Tap.
- ExtData sanity figures (extra_props.rs):
  - `multi`: `pk_cost = num_cost + Σ(65|34 per key) + 1`, sat witness `1 + 73k` bytes / `k+1`
    items, **`max_exec_op_count: n`** — "Multi is the only fragment which has additional executed
    opcodes" (269-305).
  - `multi_a`: `pk_cost = num_cost + 33n + (n-1) + 1`, `static_ops: 0 // irrelevant; no ops
    limit in Taproot` (316-347).
  - `sat_op_count() = static_ops + max_exec_op_count` (1022-1025) — this is what the 201-op
    checks consume.

### 3.5 Pushes / script numbers at the lexer

`Tk::Num(u32)` only: `read_scriptint` must succeed, be `>= 0`, and is truncated `as u32`
(lex.rs:217-224); negative → `Error::NegativeInt`, bad encoding → `Error::InvalidInt`. Minimal
push sizes 20/32/33/65 are special-cased to hashes/keys (lex.rs:207-215).

## 4. Where the limits come together ("check_size_validity" equivalents)

There is no `check_size_validity`; the aggregation points are, in order of invocation:

1. **`Miniscript::from_ast`** (mod.rs:315-331) — per-node: `Type::type_check`, `ExtData`
   computation, recursion cap, `Ctx::check_global_validity(&res)`. Runs on *every* construction
   path (parse-from-script via `TerminalStack::reduce0`, decode.rs:304-333; parse-from-string;
   translation; compiler). The **input data for all limit checks is `ExtData`**
   (`types/extra_props.rs:143-160`):
   ```rust
   pub struct ExtData {
       pub pk_cost: usize,            // encoded script size bytes (:145)  → script-size checks
       pub has_free_verify: bool,
       pub static_ops: usize,         // Irrelevant in Taproot (:148-150) → 201-op check
       pub sat_data: Option<SatData>, // None ⇒ impossible satisfaction
       pub dissat_data: Option<SatData>,
       pub timelock_info: TimelockInfo,
       pub tree_height: usize,        // → 402 recursion check (:157-159)
   }
   ```
   with `SatData { max_witness_stack_size, max_witness_stack_count, max_script_sig_size,
   max_exec_stack_count, max_exec_op_count }` (:93-112) feeding the 100-item / 1650-byte /
   1000-stack / 201-op checks respectively.
2. **`Ctx::check_global_validity`** (context.rs:263-269) = global consensus + global policy;
   **`Ctx::check_local_validity`** (273-281) = those + local consensus + local policy — the
   latter exposed to users as `within_resource_limits()` (analyzable.rs:39-42).
3. **`Miniscript::validate(&ValidationParams)`** (mod.rs:349-509) — the modern unified check:
   non-top-level part validates per-node fragment/key/mixed-timelock/duplicate-key/multipath
   rules (mod.rs:418-453) plus numeric limits: `max_script_size` (463-468), `max_witness_items`
   (471-482), `max_opcode_count` (484-493), `max_exec_stack_size` (495-506). Top-level-only:
   malleability (`is_non_malleable`, 358-360), base-type B (`NonBase`, 362-365), sigless-branch
   (367-370), unsatisfiable (372-376 — note: still allowed even by SANE due to compat FIXME,
   validation.rs:116-118).
4. **Descriptor constructors/from_str** — top-level checks + tr-leaf validation as in §2.

### NoChecks ↔ ExtData interaction ("NoChecks-satisfying")

- NoChecks scripts are still built via `from_ast`, so `ExtData` **is computed** and `sat_data`
  may be `Some` — but no caller should consume size bounds: `NoChecks::max_satisfaction_size`
  and `NoChecks::pk_len` **panic** (context.rs:909-915).
- `ValidationParams::MAX` sets every numeric param to `usize::MAX` (validation.rs:74-95), so
  `validate()`'s limit arms never trigger; the script-size arm is additionally *gated*:
  ```rust
  // mod.rs:455-468
  // FIXME we have to gate this check on params.max_script_size being finite
  // because otherwise we'll attempt to call self.script_size(), which calls
  // Ctx::pk_len, when validating NoChecks scripts. But NoChecks::pk_len just
  // panics because we've forgotten the length of keys once we're in the
  // NoChecks context.
  if params.max_script_size < usize::MAX && self.script_size() > params.max_script_size { … }
  ```
- Practically, NoChecks exists to *satisfy/read* existing chain scripts: `satisfy`'s "satisfied
  constraints" iteration and the interpreter (`interpreter/inner.rs:82,347-372`) — not to assert
  anything about limits; `within_resource_limits()` on a NoChecks miniscript trivially holds
  (`check_local_validity` = Ok, context.rs:930-938). Note interpreter/mod.rs:80-81 acknowledges a
  single ECDSA-flavoured NoChecks key storage hack (stored with explicit hash type,
  `TypedHash160`) — NoChecks with x-only keys exists only in tests (interpreter/mod.rs:1567).

## Appendix: things deliberately absent / notable quirks

- No per-item 80-byte p2wsh stack-item standardness check anywhere (Core policy not modeled).
- `Segwitv0::CONSENSUS` accepts > 100 witness items / > 3600-byte scripts (both are policy/SANE
  only) — `decode_consensus` will succeed on such scripts.
- `check_terminal_non_malleable` has no call sites (see §0).
- Tap `check_global_consensus_validity` size comment admits the 4 MWU block check is knapsack-
  fragile (context.rs:674-678).
- `from_str_insane` = `Ctx::CONSENSUS` except `allow_raw_pkh: false` (mod.rs:974-977) — the
  only way `expr_raw_pkh` is produced is script decode (`Term::expr_raw_pkh` string form is
  normally rejected by SANE anyway, validation.rs:112).
