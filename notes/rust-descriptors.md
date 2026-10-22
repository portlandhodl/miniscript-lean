# rust-miniscript: how Miniscript trees are embedded into output descriptors

Analysis of `rust-miniscript/src/descriptor/` (+ `src/plan.rs`, `src/miniscript/context.rs`,
`src/validation.rs`), read-only. All refs are `path:line`.

**Version caveat:** empirical results marked [VERIFIED] were produced by compiling a scratch
binary against this checkout (`Descriptor::<PublicKey>::from_str` etc.).

---

## 0. The construction pipeline (shared by all descriptors)

Every Miniscript node goes through `Miniscript::from_ast` (`src/miniscript/mod.rs:315-332`):

1. `Type::type_check` (fragment typing rules) and `ExtData::type_check` (size/op/stack accounting).
2. `ext.tree_height > MAX_RECURSION_DEPTH (402)` rejected (`mod.rs:327-329`).
3. `Ctx::check_global_validity(&res)` (`mod.rs:330`) — consensus + policy checks *at full-node
   level* (key forms, forbidden fragments, script-size caps), computed from `ext.pk_cost`.

On top of that, each descriptor constructor runs `Ctx::top_level_checks(&ms)`
(`src/miniscript/context.rs:332-335`) = `top_level_type_check` + `other_top_level_checks`:

- `top_level_type_check` (`context.rs:284-316`): despite the stale doc-comment ("Check whether the
  top-level is type B"), it currently **only** checks that all BIP-389 multipath keys in the
  miniscript have the same number of derivation paths → `Error::MultipathDescLenMismatch`
  (`context.rs:312-314`).
- `other_top_level_checks` is a no-op everywhere **except `BareCtx`**.

The "everything else" checks (duplicate keys, malleability, mixed timelocks, sigless branches,
top-level `B` type, op-count, exec-stack size, witness-item count) live in
`Miniscript::validate(&ValidationParams)` (`src/miniscript/mod.rs:349-509`) driven by
`ValidationParams::SANE` / `::CONSENSUS` (`src/validation.rs:103-155`). They are applied by:
`Miniscript::from_str` (`miniscript/mod.rs:1196-1198`, via `from_str_with_validation_params:980-989`),
`Miniscript::decode*` (with `Ctx::SANE`: `mod.rs:779-782`, `Ctx::CONSENSUS`: `724-726`),
the policy compiler (`policy/compiler.rs:817` uses `check_local_validity`), and the user-callable
`Miniscript::within_resource_limits()` (`analyzable.rs:42` → `check_local_validity`).

**Crucially: the descriptor constructors/parsers generally do NOT call `validate(SANE)`** (see
per-type sections and the gaps table in §5). The old-style `check_extdata`/`check_witness`
functions no longer exist under those names; what remains is:

- per-node `check_global_validity` during `from_ast` / parse (`miniscript/mod.rs:330`, and the
  full-tree re-pass at `mod.rs:1187-1189`),
- `top_level_checks` at descriptor level,
- local consensus/policy checks (`check_local_consensus_validity` / `check_local_policy_validity`)
  which are only invoked by the compiler and `within_resource_limits()` — **never by
  `Descriptor::from_str` or `Wsh::new` etc.**

Limits constants: `src/miniscript/limits.rs:9-38` (`MAX_OPS_PER_SCRIPT=201`,
`MAX_STANDARD_P2WSH_STACK_ITEMS=100`, `MAX_SCRIPT_SIZE=10_000`,
`MAX_STANDARD_P2WSH_SCRIPT_SIZE=3600`, `MAX_SCRIPT_ELEMENT_SIZE=520`,
`MAX_SCRIPTSIG_SIZE=1650`, `MAX_STACK_SIZE=1000`, `MAX_PUBKEYS_PER_MULTISIG=20`,
`MAX_PUBKEYS_IN_CHECKSIGADD=999`).

---

## 1. Wsh / SortedMulti / SegwitV0 (`src/descriptor/segwitv0.rs`)

### 1.1 `Wsh::new` / `Wsh::from_tree`

- `Wsh::new(ms)` → `Segwitv0::top_level_checks(&ms)` only (`segwitv0.rs:41-45`). Same for
  `FromTree` (`segwitv0.rs:184-195`). So on top of per-node global checks, Wsh adds only the
  multipath-length consistency check.

What `Segwitv0`'s checks do (`src/miniscript/context.rs:490-613`):

- `check_pk` (`515-523`): reject uncompressed keys (`UncompressedKeysNotAllowed`) and x-only keys
  (`XOnlyKeysNotAllowed`). Applied during `from_ast` to every `PkK`/`PkH`... actually `PkK`,
  `Multi`, `SortedMulti` nodes: see `check_global_consensus_validity` (`525-556`), which also caps
  script size: `ms.ext.pk_cost > MAX_SCRIPT_SIZE (10_000)` → `MaxWitnessScriptSizeExceeded`
  (`545-549`), and bans `MultiA`/`SortedMultiA` (`537-539`).
- `check_global_policy_validity` (`573-583`): `pk_cost > 3600` → rejected.
- `check_local_consensus_validity` (`558-571`): satisfaction op-count `> 201` rejected; no
  satisfaction data → `ImpossibleSatisfaction`.
- `check_local_policy_validity` (`585-602`): `max_satisfaction_witness_elements > 100` rejected
  (`MAX_STANDARD_P2WSH_STACK_ITEMS`).

**But** the two `check_local_*` items are not invoked from `Wsh::new`/descriptor parsing.
[VERIFIED]: `Descriptor::from_str("wsh(<211-op script>)")` succeeds while
`Miniscript::<_,Segwitv0>::from_str` of the same script fails with
`Validation(MaxOpCountExceeded{201})`; `within_resource_limits()` on the resulting Wsh returns
`false`. Practically this mainly means an over-limit descriptor scans/parses fine; the
satisfaction code still works but the witness would be non-standard/consensus-invalid when spent.

### 1.2 `Wsh::new_sortedmulti` (`segwitv0.rs:48-50`)

```rust
pub fn new_sortedmulti(thresh: Threshold<Pk, MAX_PUBKEYS_PER_MULTISIG>) -> Result<Self, Error> {
    Ok(Self { ms: Miniscript::sortedmulti(thresh) })
}
```

- `Miniscript::sortedmulti` (`miniscript/mod.rs:281-288`) builds `Terminal::SortedMulti` with
  pre-made `Type`/`ExtData` — **no `from_ast`, no `check_pk`, no top-level check**.
- Only `Threshold::new`'s structural check runs: `k>0 && k<=n && n<=20`
  (`src/primitives/threshold.rs:46-52, 67-70`).
- [VERIFIED]: `Wsh::new_sortedmulti` with a 65-byte uncompressed `bitcoin::PublicKey` returns
  `Ok` — it produces a descriptor that would be rejected by the `wsh(pk(uncompressed))` parse
  path. (Mitigated in practice for `DescriptorPublicKey` since derived keys are always
  compressed, but raw uncompressed `PublicKey`s are possible.)
- Same shape for `Sh::new_sortedmulti` (`sh.rs:123-125`, fine there since Legacy allows
  uncompressed) and `Sh::new_wsh_sortedmulti` (`sh.rs:137-143`, delegates to Wsh's).

### 1.3 `Wpkh`

`Wpkh::new` → `Segwitv0::check_pk` (`segwitv0.rs:230-236`): only compressed full keys allowed.
`translate_pk` re-runs `Wpkh::new` after translation (`segwitv0.rs:274-283`), so a translation
that yields an uncompressed key fails with `TranslateErr::OuterError`. The `.expect(...)`s at
`segwitv0.rs:290-291, 300-301` ("wpkh descriptors have compressed keys") are justified by this
invariant.

### 1.4 Satisfaction/planning note

`get_satisfaction` pushes the witness script last (`segwitv0.rs:135-144`);
`max_weight_to_satisfy` accounts for stack-count varint deltas (`segwitv0.rs:66-80`).

---

## 2. Tr (`src/descriptor/tr/{mod.rs, taptree.rs, spend_info.rs}`)

### 2.1 Structure & construction

- `Tr { internal_key: Pk, tree: Option<TapTree<Pk>>, spend_info: Mutex<Option<Arc<TrSpendInfo>>> }`
  (`tr/mod.rs:30-43`). `spend_info` is a lazily-populated cache (`tr/mod.rs:127-140`); equality
  ignores it (`tr/mod.rs:64-68`).
- `Tr::new(internal_key, tree)` → **only** `Tap::check_pk(&internal_key)` (`tr/mod.rs:95-98`).
  `Tap::check_pk` (`context.rs:646-652`) rejects uncompressed keys; it accepts both x-only
  (32-byte) and compressed (33-byte) full keys — the latter are converted at use time via
  `ToPublicKey::to_x_only_pubkey()` (e.g. `spend_info.rs:177`, parity dropped). Descriptor tests
  confirm: `tr(comp)` and `tr(xonly)` parse; `tr(uncompressed)` is rejected
  (`descriptor/mod.rs` test at `mod.rs:2166-2179` region; also `test_xonly_keys`, `mod.rs` near
  2166).
- Leaf miniscripts are `Miniscript<Pk, Tap>`, i.e. `ScriptContext = Tap`:

  - `Tap::CONSENSUS` (`context.rs:622-628`): `allow_uncompressed_keys: false`,
    `allow_multi: false` (old `multi` banned; `TaprootMultiDisabled` at `666-668`),
    `allow_compressed_keys: false`, `allow_x_only_keys: true`; no script-size cap except
    block-weight bound in `check_global_consensus_validity` (`679-686`).
  - `Tap::SANE` (`629-635`): adds `max_exec_stack_size: 1000` but no script-size/witness-item
    policy caps (taproot has none; BIP-342 sigops always satisfied — see comment at
    `context.rs:695-703`).
  - `check_local_consensus_validity`: `max_witness_stack_count + max_exec_stack_count > 1000`
    rejected (`context.rs:704-712`).

### 2.2 Taptree depth limits (`tr/taptree.rs`)

- Storage is flat: `Vec<(u8 depth, Arc<Miniscript<Pk, Tap>>)>` (`taptree.rs:29-31`).
- `TapTree::leaf` (depth 0, `taptree.rs:35-37`); `TapTree::combine` errors with
  `TapTreeDepthError` when any resulting depth exceeds `TAPROOT_CONTROL_MAX_NODE_COUNT - 1 =
  127` new-depth (`taptree.rs:40-50`); error type at `taptree.rs:13-25` ("maximum Taproot tree
  depth (128) exceeded").
- Parser path: `Tr::from_tree` (`tr/mod.rs:343-391`) drives `TapTreeBuilder`
  (`taptree.rs:240-296`): `{`-branches call `push_inner_node()` which increments the current
  height and errors past 128 (`taptree.rs:258-264`); leaves are pushed at the current height
  (`taptree.rs:267-289`); `finalize` asserts non-empty (`taptree.rs:292-295`).
  Test: depth-128 parses, depth-129 → `Error::TapTreeDepthError` (`tr/mod.rs:578-591`).
- Any tree shape (including fully unbalanced) is allowed; `fmt::Display` reconstructs braces from
  depths (`taptree.rs:87-121`).

### 2.3 Leaf validation levels

- `Tr::from_tree` per leaf: `Miniscript::from_tree` (per-node global checks) **plus**
  `script.validate(&ValidationParams { allow_raw_pkh: false, ..Tap::CONSENSUS })`
  (`tr/mod.rs:380-386`) — this is the documented "FIXME hack for #734": raw `expr_raw_pkh` is
  paradoxical in taproot (hash collision vs key) and is rejected; test at `tr/mod.rs:560-575`.
  Note this uses *consensus-only* params otherwise: dup keys/malleability within a leaf pass.
- `Descriptor::<Pk>::from_str` then re-validates **every Tr leaf** with `Tap::SANE`
  (`descriptor/mod.rs:1165-1179`, specifically `1170-1175`): dup keys in one leaf, malleability
  (none possible in Tap per `Top` / `check_terminal_non_malleable` at `context.rs:637-643`),
  sigless branches, exec-stack>1000, etc. are caught here.
  [VERIFIED]: `Descriptor::from_str("tr(k1,and_v(v:pk(k2),pk(k2)))")` →
  `Err(Validation(DuplicateKeys))`, but `Tr::from_str` (bypassing `Descriptor::from_str`) on the
  same string → `Ok`.
- [VERIFIED] `Tr::new(k, Some(TapTree::leaf(ms)))` with an uncompressed leaf key returns `Ok`
  for a compressed internal key — i.e. programmatic `Tr::new` never checks the leaves.

### 2.4 What is *not* checked

- **Duplicate scripts / repeated keys across leaves:** explicitly allowed — the
  `tr({pk:0,0})` / `tr({pk,{0,0}})` unit tests (`spend_info.rs:451-474`, "Two-leaf tree,
  repeated leaf") hard-code this: both leaves hash identically and both get control blocks.
  [VERIFIED]: `tr(k1,{pk(k2),pk(k2)})` via `Descriptor::from_str` → `Ok`; SANE duplication check
  is per-leaf only (`validate_non_top_level` runs per miniscript, `miniscript/mod.rs:396-398`
  via `has_repeated_keys`, `analyzable.rs:48-56`).
- **Key overlap between internal key and tree:** nothing stops `tr(k1, pk(k1))`
  [VERIFIED: `Ok`]. Lifting treats it as `or(Key(internal), tree)` (`tr/mod.rs:417-425`).
- **Multipath length consistency between internal key and leaves:** `top_level_type_check`
  (which enforces this for bare/sh/wsh) is not run by `Tr::new`; per-leaf SANE validation only
  checks each leaf's internal consistency (`miniscript/mod.rs:403-417` via `multipath_check`).
  [VERIFIED]: `tr(<2-path xpub>,pk(<3-path xpub>))` via `Descriptor::from_str` → `Ok`, while
  `wsh(and_v(v:pk(<2-path>),pk(<3-path>)))` → `Err(MultipathDescLenMismatch)`.
- **Internal-key lingers-unspendable check:** rust-miniscript does not (by design) require the
  BIP-341 "provably unspendable internal key" ritual; `TrSpendInfo::from_tr` just tweaks
  whatever key it is given (`spend_info.rs:176-189`, `tap_tweak` at `184-186`).

### 2.5 Spend info (`tr/spend_info.rs`)

- `TrSpendInfo` stores the pre-order node list with sibling hashes (`spend_info.rs:91-97`,
  `nodes_from_tap_tree` at `100-173`, carefully keeps a stack capped by
  `TAPROOT_CONTROL_MAX_NODE_COUNT` via `ParentStack`/`BitStack128` at `22-84`).
- Output key = `internal_key.tap_tweak(secp, merkle_root)` (`spend_info.rs:184-186`);
  `merkle_root()` reads the root's recorded "sibling hash" trick (`192-196`).
- `leaves()` (`spend_info.rs:220-227`) yields per-leaf `{script, miniscript, leaf_hash,
  control_block}`; control block built on the fly, merkle-branch length guaranteed ≤ 128
  (`spend_info.rs:315-322`). Depth reconstructed from branch length (`355-357`).
- Fixed test vectors incl. repeated-leaf trees and fuzz vectors at `spend_info.rs:411-712`.

### 2.6 Satisfaction

`best_tap_spend` (`tr/mod.rs:444-510`): try key-spend path first (single 64/65-byte schnorr sig,
`455-465`), else iterate *all* leaves and keep the minimum-weight satisfaction, appending
`Placeholder::TapScript` + `Placeholder::TapControlBlock` (`496-497`).
`max_weight_to_satisfy` takes max over key-spend vs. all leaf paths incl. control block size
`33 + 32*depth` (`control_block_len`, `tr/mod.rs:438-440`) — the only place leaf depth feeds
back into weight accounting.

---

## 3. Bare / Sh (`src/descriptor/bare.rs`, `src/descriptor/sh.rs`)

### 3.1 Contexts

| Descriptor | Miniscript context | check space |
|---|---|---|
| `Bare` | `BareCtx` (`context.rs:746-760`) | `Bare::new` → `top_level_checks` (`bare.rs:38-42`); `other_top_level_checks` is the strict one |
| `ShInner::Ms` | `Legacy` (`context.rs:368-483`) | `Sh::new` → `Legacy::top_level_checks` (`sh.rs:115-119`) |
| `ShInner::Wsh/Wpkh` | `Segwitv0` | delegates to `Wsh::new`/`Wpkh::new` (`sh.rs:128-148`) |
| `Pkh` | n/a (key only) | `Pkh::new` → `BareCtx::check_pk` (`bare.rs:198-204`) — only x-only keys rejected; **uncompressed allowed in pkh** |

`BareCtx::other_top_level_checks` (`context.rs:829-841`) whitelists the standard bare forms:
top node must be `Check(PkK)` (P2PK), `Check(PkH)`/`Check(RawPkH)` (P2PKH-like), or
`Multi`/`SortedMulti` with `n ≤ 3`; anything else → `Error::NonStandardBareScript`.
(Multipath note: this whitelisting is enforced in `Bare::new`, `Bare::from_tree`
(`bare.rs:167-173`) and in `translate_pk`, since `Bare::translate_pk` re-runs `Bare::new`
(`bare.rs:92-97`). `Sh::translate_pk` for `ShInner::Ms` does *not* re-run
`Legacy::top_level_checks` (`sh.rs:236-241`) — only per-node checks re-run inside
`Miniscript::translate_pk`'s `from_ast` calls (`miniscript/mod.rs:908`).)

### 3.2 P2SH-specific limits (Legacy context)

- `check_pk` (`context.rs:395-401`): x-only keys rejected; **uncompressed keys allowed**
  (P2SH predates segwit; consensus permits them). `Legacy::pk_len` accounts for 66 vs 34
  (`context.rs:473-479`).
- Global consensus: redeem script (`pk_cost`) ≤ `MAX_SCRIPT_ELEMENT_SIZE = 520`
  (`context.rs:422-429`) — this is the *P2SH-specific* caps-anchor; `MultiA` banned (`415-417`).
- Local (only via compiler/`within_resource_limits`, not descriptor parse):
  opcount ≤ 201 (`context.rs:439-447`), scriptSig satisfaction ≤ 1650 bytes
  (`context.rs:454-464`).
- `Sh` variants dispatch weight/signature-hash logic per inner type
  (`sh.rs:168-200`, `285-294`); `unsigned_script_sig` builds the wrapped-redeem push
  (`sh.rs:303-320`).
- `Sh::address` can only fail if redeem script > 520 bytes, impossible after construction:
  `assert!(addr.is_ok())` at `sh.rs:256-262`.

### 3.3 Parse dispatch

`Sh::from_tree` (`sh.rs:79-97`): peeks at inner name — `"wsh"`/`"wpkh"` nest into
`ShInner::Wsh`/`Wpkh`; anything else parses as `Legacy` miniscript + `top_level_checks`.
`Descriptor::from_tree` dispatches on names `pkh|wpkh|sh|wsh|tr`, default = Bare
(`descriptor/mod.rs:1151-1163`).

---

## 4. plan.rs — the satisfier-as-assets abstraction (`src/plan.rs`)

### 4.1 Purpose & types

Module docs (`plan.rs:3-17`): a `Plan` is a *chosen spending path* on a descriptor, computed
without producing signatures — used for coin-selection weight estimates, knowing which keys /
preimages / timelocks to gather, and later for actually filling a `TxIn`/PSBT.

- `trait AssetProvider<Pk>` (`plan.rs:45-106`): boolean/size-only mirror of `Satisfier`
  (`provider_lookup_ecdsa_sig`, `provider_lookup_tap_key_spend_sig`,
  `provider_lookup_*preimage`, `check_older/check_after`, ...). Blanket impl for any
  `T: Satisfier` (`plan.rs:141-204`).
- `struct Assets` (`plan.rs:509-531`): `keys: BTreeSet<(KeySource, CanSign)>` + 4 preimage sets
  + max `absolute_timelock`/`relative_timelock`. Key lookup matches by master fingerprint and a
  "direct child" path rule (`plan.rs:538-556`).
- `CanSign` (`plan.rs:439-448`) / `TaprootCanSign` (`plan.rs:450-470`) /
  `TaprootAvailableLeaves={None|Any|Single|Many}` (`plan.rs:484-506`): per-key capability model —
  ecdsa yes/no, key-spend yes/no, which tapleaves it can script-spend for, and
  `sighash_default` (drives 64 vs 65-byte sig size at `463-470`).
- `has_ecdsa_key` / `has_taproot_internal_key` / `has_taproot_script_key`
  (`plan.rs:559-595`) feed the `AssetProvider` impl (`598-646`). `IntoAssets` conversions
  (`660-704`), builder-style `add`/`older`/`after` (`706-738`).
- `LoggerAssetProvider` (`plan.rs:108-139`, std-only) dbg!-traces queries.

### 4.2 Flow

1. `Descriptor::into_plan(provider)` (`descriptor/mod.rs:552-575`) dispatches to each
   descriptor's `plan_satisfaction*` → `Miniscript::build_template/_mall`
   (`miniscript/satisfy/mod.rs:946+`; wrapper at `miniscript/mod.rs:676-700`) →
   `Satisfaction<Placeholder<Pk>>` with `witness stack template + timelocks`
   (`miniscript/satisfy/mod.rs:873+`); for Tr, `best_tap_spend` (§2.6). Failure (no available
   path) returns the descriptor back as error.
2. `Plan { template: Vec<Placeholder<Pk>>, absolute/relative timelock, descriptor }`
   (`plan.rs:212-222`). `Placeholder` variants (`satisfy/mod.rs:577-608`): EcdsaSigPk,
   SchnorrSigPk(with `SchnorrSigType::{KeySpend,ScriptSpend}`, size), preimages, hash
   dissatisfactions, `PushOne/PushZero`, `TapScript`, `TapControlBlock` — i.e. a witness with
   holes.
3. Metrics: `satisfaction_weight` (`plan.rs:235`) = `witness_size() + 4*scriptsig_size()`;
   per-`DescriptorType` scriptsig constants (`239-252`); witness adds the witness script for
   Wsh (`258-277`).
4. Completion: `Plan::satisfy(&Satisfier)` resolves placeholders → `(witness, script_sig)`,
   handling Tr/Wpkh/Wsh/ShWsh/ShWpkh/Bare-Sh-Pkh placement (`plan.rs:280-317`).
   `update_psbt_input` fills BIP-174 fields (tap_* for Tr: merkle root, internal key, leaf data,
   key origins (`plan.rs:327-403`); witness_script/redeem_script/bip32_derivation elsewhere
   (`405-431`)) — only data *actually needed by this plan*.

Wallet role: lets a wallet answer "given what I hold, which branch is cheapest, what weight
should I reserve, what must my signer fetch/sign" without touching private keys.

---

## 5. Invariants descriptors add on top of Miniscript type-safety

Type-safety (`Type::type_check`, `ExtData`) already guarantees: correct stack-type flow
(B/K/V/W/F), static satisfaction bounds (ops, witness size/items, exec-stack), timelock
consistency per-path, non-malleability analysis. Descriptor construction adds:

1. **Context binding**: a miniscript is pinned to `BareCtx`/`Legacy`/`Segwitv0`/`Tap` and every
   node passes that context's global consensus+policy rules (key forms, fragment availability —
   e.g. `multi` vs `multi_a` per era, `RawPkH`, script-size caps 520/10k/3600/max-block-weight).
2. **Top-level form checks** (only non-trivial for Bare): miniscript must be one of the
   standard bare templates (P2PK/P2PKH/multisig n≤3) — `Error::NonStandardBareScript`
   (`context.rs:829-841`).
3. **Top-level cross-key consistency**: BIP-389 multipath keys must all have equal path counts
   (`context.rs:284-316`) — applied to bare/sh/wsh, **not across a tr's internal key↔leaves**
   (§2.4).
4. **Structural container limits**: Tr taptree depth ≤ 128 and well-formed brace/leaf structure
   (`tr/taptree.rs`); `tr(...)` arity 1–2, `wsh/sh(...)` arity 1 (`tr/mod.rs:347`,
   `segwitv0.rs:187`, `sh.rs:82`); internal key must be a bare terminal, not a tree.
5. **Leaf freshness rules (tr)**: per-leaf consensus + no-raw-pkh at parse (`tr/mod.rs:380-386`),
   and full `Tap::SANE` per leaf (dup keys in-leaf, sigless branches, exec stack) when coming
   through `Descriptor::from_str` (`descriptor/mod.rs:1170-1175`).
6. **Non-satisfiability awareness**: `max_weight_to_satisfy` errors with
   `ImpossibleSatisfaction` for unsatisfiable descriptors (e.g. `descriptor/mod.rs:342-346`),
   and `Tr::spend_info` caching makes address computation cheap/idempotent.
7. **Key-derivation safety**: `DefiniteDescriptorKey` separates "still templated" descriptors
   from concrete ones (`descriptor/mod.rs:703-722`, `key.rs:122`); `xkey_network()` guards
   mainnet/testnet mixing (`descriptor/mod.rs:1041-1058`); BIP-32 depth cap
   (`key.rs:757-761`).

### 5.1 Gaps worth knowing (all [VERIFIED] on this checkout)

| Check | Miniscript::from_str | Descriptor::from_str (wsh/sh/bare) | Descriptor::from_str (tr leaves) | programmatic `new` |
|---|---|---|---|---|
| dup keys (within one ms) | ✔ rejected | ✖ accepted | ✔ rejected (per-leaf SANE) | ✖ |
| mixed timelocks / sigless branches / non-B top / malleability | ✔ | ✖ | ✔ (per-leaf) | ✖ |
| op-count ≤ 201 / witness items ≤ 100 (v0) | ✔ | ✖ | n/a (tap: exec stack ✔ per-leaf via SANE) | ✖ |
| uncompressed keys in wsh | ✔ (per-node global) | ✔ (id.) | n/a | ✖ in `new_sortedmulti` (!) |
| cross-leaf dup scripts / keys in tr | n/a | allowed | allowed | allowed |
| internal key ∈ leaf keys | n/a | allowed | allowed | allowed |
| multipath len mismatch (tr internal vs leaves) | n/a | ✖ | ✖ | ✖ |
| raw `expr_raw_pkh` in tr | n/a | ✔ rejected | ✔ rejected | ✖ (needs `Drop` of hack #734) |

These gaps are largely deliberate design drift: resource/sanity limits were consolidated into
`ValidationParams` and `within_resource_limits()`, leaving descriptor construction "type-correct
+ globally consensus-safe", with full standardness/sanity enforced on the `Miniscript` string
parse path instead. Users constructing `Tr` programmatically (`Tr::new`) get only
uncompressed-key rejection on the internal key and the tapdepth cap — everything else rests on
the `Miniscript<Pk, Tap>` leaves having been built through checked constructors
(`from_ast` per-node global checks at `miniscript/mod.rs:330`).

### 5.2 NoChecks context

`miniscript::context::NoChecks` (`context.rs:867-954`): all validity fns return `Ok`,
`CONSENSUS = SANE = ValidationParams::MAX` (`validation.rs:74-95`, used at `context.rs:873-874`),
and `pk_len`/`max_satisfaction_size` *panic* (`context.rs:909-915`) since the key sizes were
forgotten — it's only for the interpreter (`src/interpreter/`) to mechanically read on-chain
scripts. Descriptors **never embed a `NoChecks` miniscript** — the `Descriptor` enum is closed
over {BareCtx, Legacy, Segwitv0, Tap}. (There is an explainable FIXME in
`miniscript/mod.rs:455-462` guarding `script_size()` computation for NoChecks in `validate`.)

---

## Appendix: files read

- `src/descriptor/mod.rs` (2960 lines) — enum/dispatch, `new_*` ctors, `into_plan` (552-575),
  `FromStr` with tr-SANE pass (1165-1179), derivation/multipath utilities, tests.
- `src/descriptor/segwitv0.rs` — Wsh/Wpkh.
- `src/descriptor/sh.rs` — Sh, ShInner.
- `src/descriptor/bare.rs` — Bare, Pkh.
- `src/descriptor/tr/mod.rs` — Tr, from_tree plan, best_tap_spend.
- `src/descriptor/tr/taptree.rs` — TapTree/TapTreeBuilder/TapTreeDepthError.
- `src/descriptor/tr/spend_info.rs` — TrSpendInfo, control-block iterator, test vectors.
- `src/descriptor/key.rs` (superficial) — `DescriptorPublicKey` enum (23-30),
  `SinglePubKey::FullKey|XOnly` (113-118), key parsing incl. 64-hex x-only (779-804),
  `DefiniteDescriptorKey` (122), `is_x_only_key`/`is_uncompressed` (235-241, 1419-1437).
- `src/plan.rs` — §4.
- `src/miniscript/context.rs` — ScriptContext + the five contexts.
- `src/validation.rs` — `ValidationParams::{MAX,SANE,CONSENSUS}`, `validate_pk` (236-260).
- `src/miniscript/mod.rs` — `from_ast` (315-332), `validate*` (349-509),
  `from_str_with_validation_params` (980-989), `FromTree` with per-node global re-check
  (1183-1190), `Miniscript::from_str` SANE (1194-1200).
- `src/miniscript/limits.rs`, `src/primitives/threshold.rs` (46-70),
  `src/miniscript/analyzable.rs` (`within_resource_limits` 42, `has_repeated_keys` 48-56),
  `src/miniscript/satisfy/mod.rs` (`Placeholder` 577-608, `Satisfaction` 873+, template
  builders 946+).
