# rust-miniscript — Satisfier / witness-construction analysis

Scope: READ-ONLY analysis of
`/home/qrsnap/git/miniscript-lean/rust-miniscript/src/miniscript/satisfy/mod.rs` (1408 lines)
and `/home/qrsnap/git/miniscript-lean/rust-miniscript/src/miniscript/satisfy/sat_dissat.rs` (495 lines),
with cross-references to the supporting types it depends on
(`plan.rs`, `util.rs`, `context.rs`, `primitives/*locktime.rs`, descriptor code, `psbt/mod.rs`).

All refs below are relative to `/home/qrsnap/git/miniscript-lean/rust-miniscript/` unless noted.
`mod.rs:` means `src/miniscript/satisfy/mod.rs`, `sat.rs:` means `src/miniscript/satisfy/sat_dissat.rs`.

## 0. Version-alignment caveat (important for interpreting the questions)

This tree is a **modern** rust-miniscript (Cargo.toml pins `bitcoin = "0.32.6"`); several APIs
the questions reference **no longer exist under those names** (verified by full-tree grep):

- `Error::InvalidTimelock` — **absent**. Timelock failures flow through `Witness::Impossible` /
  `Witness::Unavailable` and eventually surface as `Error::CouldNotSatisfy`
  (`src/lib.rs:447`, `src/miniscript/mod.rs:669-671`) or `Error::ImpossibleSatisfaction`
  (`src/lib.rs:469`).
- `Miniscript::multiple_satisfactions()` — **absent** (removed upstream ~5.x). Replaced by the
  single-best-template pipeline (`build_template` / `build_template_mall`) and the `plan` module
  (see §5).
- `max_satisfaction_cost` — **absent**. Size estimation is now `Miniscript::max_satisfaction_size`
  (`src/miniscript/mod.rs:605`), `Miniscript::max_satisfaction_witness_elements`
  (`src/miniscript/mod.rs:586`) and per-descriptor `max_weight_to_satisfy` (§5).
- Old enum-shaped `Satisfaction` (variants `Empty`, `EcdsaSig`, ...) — gone; `Satisfaction<T>` is
  now a *struct* over a generic witness (§2).

Also note the two files under analysis **no longer call the public `Satisfier` trait at all**:
`sat_dissat` is generic over `crate::plan::AssetProvider` (`sat.rs:11`, `sat.rs:312`), which is the
bool/size-only mirror of `Satisfier`. A blanket impl adapts any `Satisfier` into an
`AssetProvider` (`src/plan.rs:141-204`).

---

## 1. The `Satisfier` trait (`mod.rs:31-111`)

```rust
pub trait Satisfier<Pk: MiniscriptKey + ToPublicKey> { ... }
```

Doc comment: *"Trait describing a lookup table for signatures, hash preimages, etc. Every method
has a default implementation that simply returns `None` on every query."* (`mod.rs:26-30`)

Full associated-item list (all methods, all defaulted):

| Method | Signature body | Line |
|---|---|---|
| `lookup_ecdsa_sig` | `(&self, _: &Pk) -> Option<bitcoin::ecdsa::Signature>` | `mod.rs:33` |
| `lookup_tap_key_spend_sig` | `(&self, _: &Pk) -> Option<bitcoin::taproot::Signature>` | `mod.rs:36` |
| `lookup_tap_leaf_script_sig` | `(&self, _: &Pk, _: &TapLeafHash) -> Option<bitcoin::taproot::Signature>` | `mod.rs:39-45` |
| `lookup_tap_control_block_map` | `-> Option<&BTreeMap<ControlBlock, (ScriptBuf, LeafVersion)>>` | `mod.rs:48-52` |
| `lookup_raw_pkh_pk` | `(&self, _: &hash160::Hash) -> Option<bitcoin::PublicKey>` | `mod.rs:55` |
| `lookup_raw_pkh_x_only_pk` | `(&self, _: &hash160::Hash) -> Option<XOnlyPublicKey>` | `mod.rs:58` |
| `lookup_raw_pkh_ecdsa_sig` | `(&self, _: &hash160::Hash) -> Option<(PublicKey, ecdsa::Signature)>` | `mod.rs:65-70` |
| `lookup_raw_pkh_tap_leaf_script_sig` | `(&self, _: &(hash160::Hash, TapLeafHash)) -> Option<(XOnlyPublicKey, taproot::Signature)>` | `mod.rs:77-82` |
| `lookup_sha256` | `(&self, _: &Pk::Sha256) -> Option<Preimage32>` | `mod.rs:85` |
| `lookup_hash256` | `(&self, _: &Pk::Hash256) -> Option<Preimage32>` | `mod.rs:88` |
| `lookup_ripemd160` | `(&self, _: &Pk::Ripemd160) -> Option<Preimage32>` | `mod.rs:91` |
| `lookup_hash160` | `(&self, _: &Pk::Hash160) -> Option<Preimage32>` | `mod.rs:94` |
| `check_older` | `(&self, _: relative::LockTime) -> bool` | `mod.rs:102` |
| `check_after` | `(&self, _: absolute::LockTime) -> bool` | `mod.rs:110` |

where `pub type Preimage32 = [u8; 32];` (`mod.rs:25`). Hash types are per-key-type associated types
(`Pk::Sha256` etc.) so `Miniscript`/`Tapscript` key types can carry raw digests.

There is **no** `OlderSatisfier`/`AfterSatisfier`-style sub-trait split (old API) — `check_older` /
`check_after` are methods on the same trait. Their doc comments spell out the mixed-timelock
contract:

```rust
/// Composite satisfiers may expose both height- and time-based locktimes.
/// If a single witness path would require incompatible timelock kinds
/// simultaneously, satisfaction for that path becomes [`Witness::Impossible`]
/// and plan building fails or selects another path.
```
(`mod.rs:96-110`).

### 1.1 Concrete impls provided in `mod.rs`

| Impl | Behaviour | Lines |
|---|---|---|
| `Satisfier<Pk> for ()` | empty: all defaults → "no conditions available" satisfier | `mod.rs:114` |
| `Satisfier<Pk> for Sequence` | `check_older` via `self.to_relative_lock_time()` then delegation; `false` if not a valid BIP68 sequence | `mod.rs:116-124` |
| `Satisfier<Pk> for RelLockTime` | converts to `relative::LockTime`, delegates | `mod.rs:126-130` |
| `Satisfier<Pk> for relative::LockTime` | `n.is_implied_by(*self)` | `mod.rs:132-134` |
| `Satisfier<Pk> for absolute::LockTime` | `check_after`: `n.is_implied_by(*self)` | `mod.rs:136-138` |
| `BTreeMap<Pk, ecdsa::Signature>` (+ `HashMap` under `std`) | only overrides `lookup_ecdsa_sig` (`self.get(key).copied()`) | `mod.rs:140-160` |
| `BTreeMap<(Pk, TapLeafHash), taproot::Signature>` (+HashMap) | only `lookup_tap_leaf_script_sig`; comment notes the clone-then-get: *"there is no way to get a &(a, b) from &a and &b without allocating … We use this signature to optimize for the psbt common use case."* | `mod.rs:162-190` |
| `BTreeMap<hash160::Hash, (Pk, ecdsa::Signature)>` (+HashMap) | overrides `lookup_ecdsa_sig`, `lookup_raw_pkh_pk`, `lookup_raw_pkh_ecdsa_sig` | `mod.rs:192-226` |
| `BTreeMap<(hash160::Hash, TapLeafHash), (Pk, taproot::Signature)>` (+HashMap) | overrides `lookup_tap_leaf_script_sig`, `lookup_raw_pkh_tap_leaf_script_sig` | `mod.rs:228-263` |
| `&S` / `&mut S` | full pass-through delegation for **every** trait method | `mod.rs:265-383` |
| Tuples `(A)`, `(A,B)`, … up to 8 | see precedence below | `mod.rs:385-556` |
| `PsbtInputSatisfier<'_>` | lives in `src/psbt/mod.rs:261` — pulls `partial_sigs`, `tap_key_sig`, `tap_script_sigs`, `bip32_derivation`, `tap_scripts`, preimage maps, plus tx `lock_time`/`sequence` (§4.4) | psbt |

### 1.2 Tuple impl precedence

`impl_tuple_satisfier!` (`mod.rs:385-547`) is instantiated for 1..=8 elements
(`mod.rs:549-556`: `A` through `(A,B,C,D,E,F,G,H)`). Each lookup method destructures the tuple and
returns the **first `Some`, scanning left-to-right**:

```rust
let &($(ref $ty,)*) = self;
$(
    if let Some(result) = $ty.lookup_ecdsa_sig(key) {
        return Some(result);
    }
)*
None
```
(`mod.rs:393-401`, same shape for every lookup).

For the boolean timelock methods precedence is effectively **OR**: the first `true` short-circuits
(`mod.rs:526-544`):

```rust
fn check_older(&self, n: relative::LockTime) -> bool {
    let &($(ref $ty,)*) = self;
    $( if $ty.check_older(n) { return true; } )*
    false
}
```

Consequence: two tuple elements of the same kind never "conflict" — the leftmost wins for lookups,
and any satisfied element suffices for timelocks. The regression test builds e.g.
`(signatures_map, absolute::LockTime, relative::LockTime)` (`mod.rs:1230-1234`) and
`(map, absolute::LockTime::from_height(1000), absolute::LockTime::from_time(2_000_000_000))`
(`mod.rs:1339-1343`) — the latter exposes *both* a height and a time lock; which one satisfies is
settled downstream by unit comparison, not by the tuple.

### 1.3 `AssetProvider` mirror trait (`src/plan.rs:45-106`)

The template builder never takes `Satisfier`; it takes `AssetProvider<Pk>`, whose methods return
presence (`bool`), a size (`Option<usize>` for schnorr sigs), or the key (`Option<PublicKey>` /
`Option<XOnlyPublicKey>`) instead of the value itself. Blanket impl for any `Satisfier`
(`plan.rs:141-204`); sig sizes come from the *actual* signature:

```rust
fn provider_lookup_tap_leaf_script_sig(&self, pk: &Pk, leaf_hash: &TapLeafHash) -> Option<usize> {
    Satisfier::lookup_tap_leaf_script_sig(self, pk, leaf_hash).map(|s| s.serialize().len())
}
```
(`plan.rs:154-160`; key-spend equivalent at `plan.rs:150-152`).

---

## 2. `Satisfaction` / `Witness` / `Placeholder` data model

### 2.1 `Satisfaction<T>` — a struct, not an enum (`mod.rs:871-883`)

```rust
pub struct Satisfaction<T> {
    pub stack: Witness<T>,
    /// Whether or not this (dis)satisfaction has a signature somewhere in it
    pub has_sig: bool,
    /// The absolute timelock used by this satisfaction
    pub absolute_timelock: Option<AbsLockTime>,
    /// The relative timelock used by this satisfaction
    pub relative_timelock: Option<RelLockTime>,
}
```

`has_sig` is the run-time equivalent of the spec's **HASSIG** marker (see §3.6). `T` is either
`Placeholder<Pk>` (template phase) or `Vec<u8>` (final concrete witness).

### 2.2 `Witness<T>` — the tri-state enum (`mod.rs:702-713`)

```rust
pub enum Witness<T> {
    /// Witness Available and the value of the witness
    Stack(Vec<T>),
    /// Third party can possibly satisfy the fragment but we cannot
    /// Witness Unavailable
    Unavailable,
    /// No third party can produce a satisfaction without private key
    /// Witness Impossible
    Impossible,
}
```

This replaces the old `Result<_, Error>` flow and is the moral successor of the spec's
*DONTUSE / not-available* states:

- `Impossible` — *no one* can satisfy (missing private key; conflicting timelocks on one path;
  deficit of sigs below a threshold k, etc.).
- `Unavailable` — we can't satisfy but an attacker might (missing preimage, missing pubkey for
  `RawPkH`, or unmet timelock on a witness that the attacker could re-time if nothing is signed).

Ordering (`mod.rs:719-735`), used by `min_fn` for the `(true, true)` case:

```rust
(Self::Stack(v1), Self::Stack(v2)) => {
    let w1 = witness_size(v1);
    let w2 = witness_size(v2);
    w1.cmp(&w2) }
(Self::Stack(_), _)          => cmp::Ordering::Less,   // any Stack cheapest
(Self::Impossible, Self::Unavailable) => cmp::Ordering::Less, // Impossible < Unavailable
...
```

i.e. `Stack < Impossible < Unavailable` — *available* things count as cheapest.

### 2.3 `Placeholder<Pk>` — per-stack-item data (`mod.rs:573-608`)

| Variant | Payload | Final bytes (`satisfy_self`, `mod.rs:645-700`) |
|---|---|---|
| `Pubkey(Pk, usize)` | key + its *total* item size incl. push | `pk.to_x_only_pubkey().serialize()` if `size == 33`, else `to_public_key().to_bytes()` (`mod.rs:649-655`) |
| `PubkeyHash(hash160, usize)` | pkh + size | `lookup_raw_pkh_pk` → fallback `lookup_raw_pkh_ecdsa_sig` (`mod.rs:656-665`) |
| `EcdsaSigPk(Pk)` | key | `lookup_ecdsa_sig(pk).map(|s| s.to_vec())` |
| `EcdsaSigPkHash(hash160)` | pkh | `lookup_raw_pkh_ecdsa_sig` (`mod.rs:671`) |
| `SchnorrSigPk(Pk, SchnorrSigType, usize)` | key, `KeySpend { merkle_root }` / `ScriptSpend { leaf_hash }` (enum at `mod.rs:558-571`), recorded sig size | `ScriptSpend` → `lookup_tap_leaf_script_sig(pk, leaf_hash)`; else `lookup_tap_key_spend_sig` (`mod.rs:672-685`), each `debug_assert!(s.len() == *size)` |
| `SchnorrSigPkHash(hash160, TapLeafHash, usize)` | pkh, leaf hash, size | `lookup_raw_pkh_tap_leaf_script_sig` (`mod.rs:686-692`) |
| `Sha256Preimage / Hash256Preimage / Ripemd160Preimage / Hash160Preimage` | digest | `lookup_*` → 32 bytes (`mod.rs:666-669`) |
| `HashDissatisfaction` | — | fixed `vec![0; 32]` (`mod.rs:693`) |
| `PushOne` / `PushZero` | — | `vec![1]` / `vec![]` (`mod.rs:694-695`) |
| `TapScript(ScriptBuf)` | script | `s.to_bytes()` |
| `TapControlBlock(ControlBlock)` | cb | `cb.serialize()` |

The two-phase design: `build_template{,_mall}` runs `sat_dissat` over the AST against an
`AssetProvider`, returning `Satisfaction<Placeholder<Pk>>` (`mod.rs:946-970`); `try_completing`
(substituting placeholders through a real `Satisfier`) yields `Satisfaction<Vec<u8>>`
(`mod.rs:1152-1170`). `Satisfaction<Vec<u8>>::satisfy`/`satisfy_mall` chain both steps and
`.expect()` that the same satisfier can complete its own template (`mod.rs:1173-1206`), called by
`Miniscript::satisfy`/`satisfy_malleable` (`src/miniscript/mod.rs:631-661`).

---

## 3. Per-`Terminal` sat/dissat logic

Driver: `sat_dissat` (`sat.rs:303-494`), a **post-order iterative fold** (`node.post_order_iter()`,
`let mut stack = Vec::with_capacity(128)` at `sat.rs:327-328`) computing a `SatDissat { dissat,
sat }` pair per node. Chooses at the top:

```rust
let min_fn = if malleable { Self::minimum_mall } else { Self::minimum };
let thresh_fn = if malleable { Self::thresh_mall } else { Self::thresh };
```
(`sat.rs:314-323`)

Below, witness elements are listed **bottom→top** (left-to-right), matching the spec table
(`notes/sipa-spec.md:187` — dsats/sats per fragment) and the code's concatenate order.
`X`, `Y`, `Z`/`W` name children; the stack separator is space.

### 3.1 `Terminal::True` / `Terminal::False` (`sat.rs:330-331`)

```rust
Terminal::False => SatDissat { dissat: Self::TRIVIAL, sat: Self::IMPOSSIBLE },
Terminal::True  => SatDissat { dissat: Self::IMPOSSIBLE, sat: Self::TRIVIAL },
```

- `0` (False): sat — impossible; dsat — empty stack `""` (TRIVIAL, `sat.rs:24-29`).
- `1` (True): sat — `""`; dsat — impossible. Matches spec exactly.

### 3.2 `Terminal::PkK` (`pk_k`, `sat.rs:35-47`)

```rust
SatDissat {
    dissat: Self::push_0(),                             // dsat: 0
    sat: Self {
        stack: Witness::signature(stfr, pk, leaf_hash), // sat: sig
        has_sig: true,                                  // HASSIG
        ..Self::TRIVIAL
    },
}
```

`Witness::signature` (`mod.rs:739-758`): with `leaf_hash` present (Tap context) it records
`SchnorrSigPk(pk, ScriptSpend { leaf_hash }, size)` — `Impossible` if lookup fails
(*"Signatures cannot be forged"*); without it, `EcdsaSigPk(pk)` or `Impossible`.

### 3.3 `Terminal::PkH` (`pk_h`, `sat.rs:49-73`)

- sat: `sig pk` — `Witness::combine(wit_sig, Stack([Pubkey(pk, Ctx::pk_len(pk))]))`, `has_sig: true`.
- dsat: `0 pk` — `Witness::combine(push_0(), Stack([Pubkey(...)]))`.
- `Ctx::pk_len`: Segwitv0 → 34 (`context.rs:608`), Tap → 33 (`context.rs:734`), Bare → 66
  uncompressed / 34 (`context.rs:473-479`); i.e. key bytes +1 push-opcode.

Dsat always carries the *real* pubkey (needed: no hash dissatisfaction is possible for `pk_h`
because `DUP` keeps the pushed key around — it must still hash correctly).

### 3.4 `Terminal::RawPkH` (`raw_pk_h`, `sat.rs:76-99`)

- sat (`Witness::pkh_signature`, `mod.rs:780-802`):
  `sig pk` via `provider_lookup_raw_pkh_tap_leaf_script_sig` (Tap) →
  `[SchnorrSigPkHash(pkh, leaf_hash, size), PubkeyHash(pkh, pk_len)]`; ECDSA →
  `[EcdsaSigPkHash(pkh), PubkeyHash(pkh, pk_len)]`; `Impossible` on lookup failure.
- dsat: `0 pk` where the key comes from `Witness::pkh_public_key` (`mod.rs:761-777`), which yields
  **`Unavailable`** (not Impossible) when only the hash is known:
  *"public key hashes are assumed to be unavailable instead of impossible since it is the same
  as pub-key hashes"* (`mod.rs:765-767`).

### 3.5 `Terminal::Multi` / `SortedMulti` (`multi`, `sat.rs:102-152`)

SortedMulti is BIP67-sorted then handed to `multi` (`sat.rs:336-339`).

```rust
let dissat = Self {
    stack: Witness::Stack(vec![Placeholder::PushZero; thresh.k() + 1]),
    ..Self::TRIVIAL };                 // dsat: 0 0 ... 0 (k+1 times, includes CHECKMULTISIG bug slot)
```

Sat: iterate keys in order; `Witness::signature` with `leaf_hash: None` (ECDSA-only fragment);
`Witness::Unavailable` here is `unreachable!("Signature satisfaction without witness must be
impossible")` (`sat.rs:122`). If `sig_count < k` ⇒ `Self::IMPOSSIBLE`; otherwise prune:

```rust
// Throw away the most expensive ones
for _ in 0..sig_count - thresh.k() {
    let max_idx = sigs.iter().enumerate().max_by_key(|&(_, v)| v.len()).unwrap().0;
    sigs[max_idx] = vec![];
}
```
(`sat.rs:130-139`)

then fold `fold(Witness::push_0(), ...)` → final stack `0 sig_i1 … sig_ik` (dummy `0` first, sigs
in key order). Note: `v.len()` is the *count of Placeholder vec entries*; every signature
placeholder stack is length 1, so "most expensive" is degenerate — pruning simply drops the
**last** (per `Iterator::max_by_key` last-max tiebreak) surplus sigs. `has_sig: true`.

### 3.6 `Terminal::MultiA` / `SortedMultiA` (`multi_a`, `sat.rs:154-205`)

Dissat `0 … 0` (n zeros: `vec![Placeholder::PushZero; thresh.n()]`). Sat: iterate keys **in
reverse** and take the *first k available* signatures, filling a slot vector initialised to all
`PushZero`:

```rust
for (i, pk) in thresh.iter().rev().enumerate() {
    match Witness::signature(stfr, pk, Some(leaf_hash)) {
        Witness::Stack(sig) => {
            sigs[i] = sig;
            sig_count += 1;
            // This a privacy issue, we are only selecting the first available
            // sigs. Incase pk at pos 1 is not selected, we know we did not have access to it
            // bitcoin core also implements the same logic for MULTISIG, so I am not bothering
            // permuting the sigs for now
            if sig_count == thresh.k() { break; }
        }
        ...
```
(`sat.rs:171-183`)

`sig_count < k` ⇒ `IMPOSSIBLE`. Final stack = the slot vector as-is, i.e.
`sig/0(pk_n) … sig/0(pk_1)` (n elements, exactly k sigs) — the BIP342 `multi_a` order, matching
the spec row `sig/0 … (#sig = k, total n)`. Keys are looked up as **script-spend** schnorr sigs
(`leaf_hash.expect("leaf_hash is present when Ctx = Tap…")`, `sat.rs:340-343`). `has_sig: true`.

### 3.7 `Terminal::After` (`after`, `sat.rs:207-228`) and `Terminal::Older` (`older`, `sat.rs:230-251`)

Identical structure; `older` asks `check_older`, `after` asks `check_after`:

```rust
let (stack, absolute_timelock) = if stfr.check_after(t.into()) {
    (Witness::empty(), Some(t))
} else if root_has_sig {
    // If the root terminal has signature, the
    // signature covers the nLockTime and nSequence
    // values. The sender of the transaction should
    // take care that it signs the value such that the
    // timelock is not met
    (Witness::Impossible, None)
} else {
    (Witness::Unavailable, None)
};
SatDissat {
    dissat: Self::IMPOSSIBLE,          // spec table: "-" (no dissatisfaction)
    sat: Self { stack, has_sig: false, relative_timelock: None, absolute_timelock },
}
```
(`sat.rs:212-227`)

Key points:

- A satisfied timelock contributes an **empty stack** (`""` in the spec) and records
  `absolute_timelock`/`relative_timelock = Some(t)` so it gets merged upward (§4.2).
- **DONTUSE synthesis**: an *unmet* timelock is `Impossible` exactly when `root_has_sig` (the
  signature pins `nLockTime`/`nSequence`, so an unmet lock can never be fixed by a counterparty or
  attacker ⇒ nobody can satisfy). Without a signature it is only `Unavailable` — a third party may
  be able to change the tx's lock fields, hence malleable path-tracking relies on `has_sig`
  elsewhere (§3.8-§3.9, §4.4).
- `root_has_sig` passed in from `Miniscript::satisfy` is `self.non_malleable_and_requires_sig()`
  (`src/miniscript/mod.rs:639,657`), defined as the type marker
  `Malleability::NonMalleable { signed: true, .. }` (`src/miniscript/analyzable.rs:14-33`) —
  the old "s/Uniq" property. Regression test `regression_1037` (`mod.rs:1219-1270`) shows the
  failure mode: for `and_v(v:pk(k),or_i(older(100),older(200)))` the root *is* type-malleable so
  unmet `older(200)` comes back `Unavailable` instead of `Impossible`, making the non-malleable
  satisfier reject a genuinely unforgeable witness:
  `assert!(matches!(ms.satisfy(&satisfier), Err(crate::Error::CouldNotSatisfy)));` (`mod.rs:1257`).

### 3.8 Hashlock terminals `Sha256` / `Hash256` / `Ripemd160` / `Hash160` (`sat.rs:253-295`)

All four share one shape (e.g. `sat.rs:275-284`):

```rust
SatDissat {
    dissat: Self { stack: Witness::hash_dissatisfaction(), ..Self::TRIVIAL },
    sat:    Self { stack: Witness::sha256_preimage(stfr, h), ..Self::TRIVIAL },
}
```

- dsat: a **fixed 32-byte zero push** — `Witness::hash_dissatisfaction()`
  → `Stack([Placeholder::HashDissatisfaction])` (`mod.rs:846-847`) → `vec![0; 32]`
  (`mod.rs:693`). This is the spec's "any 32-byte vector except the preimage", canonicalised.
- sat: the 32-byte preimage, or `Unavailable` if unknown — *"Note hash preimages are
  unavailable instead of impossible"* (`mod.rs:805-842`): unlike signatures, preimages may be
  possessed by a counterparty without us being able to prove they aren't revealed later.

### 3.9 Wrappers `Alt(a:)` `Swap(s:)` `Check(c:)` `ZeroNotEqual(n:)` (`sat.rs:351-355`)

Identity pass-through: pop the child's `SatDissat` unchanged. (Spec table: `dsat(X)`/`sat(X)`.)

### 3.10 `DupIf(d:)` (`sat.rs:356-365`)

```rust
dissat: Self::push_0(),                                             // dsat: 0
sat: Self { stack: Witness::combine(sub.stack, Witness::push_1()),  // sat: sat(X) 1
            ..sub },
```

### 3.11 `Verify(v:)` / `NonZero(j:)` (`sat.rs:366-373`)

Both: `dissat: Self::IMPOSSIBLE`, `sat: sub` unchanged — the spec's `dsat: -` for `v:X`
(and the `j:X` row is canonicalised to `0 …` via its `DupIf`-wrapped inner form; here `NonZero`
itself simply has no dissatisfaction).

### 3.12 `AndB` (`and_b`, `sat.rs:374-381`)

```rust
SatDissat {
    dissat: l_dis.concatenate_rev(r_dis),   // dsat: dsat(Y) dsat(X)
    sat:    l_sat.concatenate_rev(r_sat),   // sat:  sat(Y) sat(X)
}
```

(`X = l`eft so `concatenate_rev` stacks right-then-left; both alternatives composed with
timelock-merging, §4.2.)

### 3.13 `AndV` (`and_v`, `sat.rs:382-390`)

```rust
// Left child is a `v` and must be satisfied for both sat and dissat.
SatDissat {
    dissat: l_sat.clone().concatenate_rev(r_dis),  // dsat: dsat(Y) sat(X)
    sat:    l_sat.concatenate_rev(r_sat),          // sat:  sat(Y) sat(X)
}
```

This is the **unique fragment whose dissatisfaction contains a child satisfaction** — surfaced in
the `regression_895` test comment (`mod.rs:1273-1284`): dissatisfactions must also propagate
timelocks since an `and_v`-dsat can drag an `after/older` requirement into the witness; pre-#895
the timelock carried by such a dsat was silently dropped, giving wrong `Plan.absolute_timelock`s.

### 3.14 `AndOr` (`andor(X,Y,Z)`, `sat.rs:391-400`)

```rust
dissat: a_dis.clone().concatenate_rev(c_dis),           // dsat(Z) dsat(X)
sat: min_fn(a_sat.concatenate_rev(b_sat),               // sat(Y) sat(X)
            a_dis.concatenate_rev(c_sat)),              // sat(Z) dsat(X)
```

`min_fn` chooses between the two satisfactions per §3.16.

### 3.15 `OrB`/`OrC`/`OrD`/`OrI` (`sat.rs:401-460`)

```rust
Terminal::OrB(_, _) => {
    ... assert!(!l_dis.has_sig); assert!(!r_dis.has_sig);
    dissat: l_dis.clone().concatenate_rev(r_dis.clone()),        // dsat(Z) dsat(X)
    sat: min_fn( Self::concatenate_rev(l_dis, r_sat),            // sat(Z) dsat(X)
                 Self::concatenate_rev(l_sat, r_dis) ),          // dsat(Z) sat(X)
}
Terminal::OrC(_, _) => { assert!(!l_dis.has_sig);
    dissat: Self::IMPOSSIBLE,                                    // spec: -
    sat: min_fn(l_sat, Self::concatenate_rev(l_dis, r_sat)),     // sat(X); sat(Z) dsat(X)
}
Terminal::OrD(_, _) => { assert!(!l_dis.has_sig);
    dissat: l_dis.clone().concatenate_rev(r_dis),                // dsat(Z) dsat(X)
    sat: min_fn(l_sat, Self::concatenate_rev(l_dis, r_sat)),     // sat(X); sat(Z) dsat(X)
}
Terminal::OrI(_, _) => {
    dissat: min_fn(l_dis ++ [1], r_dis ++ [0]),                  // dsat(X) 1 ; dsat(Z) 0
    sat:    min_fn(l_sat ++ [1], r_sat ++ [0]),                  // sat(X) 1 ; sat(Z) 0
}
```

The `push_1`/`push_0` discriminators are the trailing `1`/`0` of the `or_i` rows.
**HASSIG-style enforcement**: the `assert!(!l_dis.has_sig)` / `assert!(!r_dis.has_sig)` are
runtime guarantees that every dissatisfaction used inside an `or_*` satisfaction is signature-free
— the run-time check of the spec's *"d"* property (a `d` fragment has a signature-free dsat) and
of the "reason 2" rule (attacker-available options are exactly the HASSIG-free ones). A violation
panics rather than producing a wrong witness.

### 3.16 `Thresh` (`sat.rs:461-486`) and the choosers

dsat = concat of *all n* child dsats; if `k == n` sat = concat all sats (an `and`). Otherwise
`thresh`/`thresh_mall` run the quota sel:

**Non-malleable `thresh` (`mod.rs:973-1041`)**: children sorted by key
`(is_impossible, has_sig, stack_weight_diff)` where

```rust
sat_indices.sort_by_key(|&i| {
    let stack_weight = match (&sats[i].stack, &ret_stack[i].stack) {
        (&Witness::Unavailable, _) | (&Witness::Impossible, _) => i64::MAX,
        (_, &Witness::Unavailable) | (_, &Witness::Impossible) => i64::MIN,
        (Witness::Stack(s), Witness::Stack(d)) =>
            witness_size(s) as i64 - witness_size(d) as i64
    };
    let is_impossible = sats[i].stack == Witness::Impossible;
    // by any party. Among those first consider the ones that have no sig
    // because third party can malleate them if they are not chosen.
    // Lastly, choose by weight.
    (is_impossible, sats[i].has_sig, stack_weight)
});
```
(`mod.rs:980-997`)

then the k cheapest-by-this-order slots are swapped from dsat → sat. Post-conditions:

```rust
if sats[sat_indices[k - 1]].stack == Witness::Impossible {
    Self::IMPOSSIBLE                       // not enough satisfiable children (spec: whole thresh impossible)
}
else if !sats[sat_indices[k]].has_sig && sats[sat_indices[k]].stack != Witness::Impossible {
    // too many attacker-available (sig-less) alternatives remain unchosen →
    // "If we cannot find `k` satisfactions that are not impossible ..."
    Self { stack: Witness::Unavailable, has_sig: false, ... }   // = spec's DONTUSE(-noHASSIG)
}
else {
    ret_stack.into_iter().fold(Self::empty(), Self::concatenate_rev)
}
```
(`mod.rs:1003-1040`, plus `for sat in &ret_stack { assert!(!sat.has_sig); }` confirming the
convention that *all* unused children in this branch are signature-free).

So: **Impossible first, then sig-free (must be chosen to avoid malleation), then minimal
(sat_size − dissat_size)**; the `(k+1)`-sigless-branch check is exactly the spec's *"if more than
one non-HASSIG solution exists → DONTUSE"* rule.

**Malleable `thresh_mall` (`mod.rs:1044-1074`)**: sort *only* by `(sat_size − dissat_size)`
(`(&Witness::Unavailable,_)|(&Witness::Impossible,_) => i64::MAX` still keeps dead branches last;
atomicity not needed since we're allowed to be malleable), take k, concat — *"no non-malleability
checks needed"*.

### 3.17 Selection across `or_*`/`andor`: `minimum` vs `minimum_mall` (`mod.rs:1076-1149`)

Non-malleable choice — the comment block *is* the selection logic:

```rust
fn minimum(sat1: Self, sat2: Self) -> Self {
    // If there is only one available satisfaction, we must choose that
    // regardless of has_sig marker.   // (Impossible side falls away first)
    match (&sat1.stack, &sat2.stack) {
        (&Witness::Impossible, _) => return sat2,
        (_, &Witness::Impossible) => return sat1,
        _ => {} }
    match (sat1.has_sig, sat2.has_sig) {
        // If neither option has a signature, this is a malleability
        // vector, so choose neither one.
        (false, false) => Self { stack: Witness::Unavailable, ... },  // DONTUSE
        // If only one has a signature, take the one that doesn't; a
        // third party could malleate by removing the signature, but
        // can't malleate if he'd have to add it
        (false, true)  => sat1-without-sig ...,
        (true, false)  => sat2 ...,
        // If both have a signature associated with them, choose the
        // cheaper one (where "cheaper" is defined such that available
        // things are cheaper than unavailable ones)
        (true, true) if sat1.stack < sat2.stack => sat1,
        (true, true) => sat2,
    }
}
```

Malleable choice:

```rust
fn minimum_mall(sat1: Self, sat2: Self) -> Self {
    match (&sat1.stack, &sat2.stack) {
        // dead/unavailable branches always lose:
        (&Witness::Impossible, _) | (&Witness::Unavailable, _) => return sat2,
        (_, &Witness::Impossible) | (_, &Witness::Unavailable) => return sat1,
        _ => {} }
    // otherwise strictly cheaper witness-size:
    let (stack, ..) = if sat1.stack < sat2.stack { sat1... } else { sat2... };
    Self { stack,
           // The fragment is has_sig only if both of the fragments are has_sig
           has_sig: sat1.has_sig && sat2.has_sig, ... }
}
```
(`mod.rs:1128-1149`)

Note the asymmetry: `minimum` prefers a sig-less *available* branch outright (malleability beats
size), while `minimum_mall` minimises raw bytes and conjunctively ANDs `has_sig`.

---

## 4. Preconditions, error paths, and timelock/sig marshalling details

### 4.1 How "preconditions fail" — tri-state instead of `Err`

Old rust-miniscript returned per-fragment `Result<Satisfaction, Error>` variants
(precondition-style failures); this tree has **no `InvalidTimelock` error at all** (verified by
grep over `src/`). The equivalent outcomes are encoded in `Witness`:

| Old / spec concept | This tree |
|---|---|
| "no satisfaction exists / unsatisfiable" | `Witness::Impossible` — *no third party* can produce one |
| "not available to us right now" | `Witness::Unavailable` |
| `Error::InvalidTimelock` (bad `older` value) | absorbed at parse into `RelLockTime` invariants — `TryFrom<Sequence>` rejects `0` and non-BIP68 sequences (`src/primitives/relative_locktime.rs:85-94`), and `rel`/`abs` lock merging returns `None` ⇒ `IMPOSSIBLE` on mixed units (§4.2) |
| top-level failure | `Error::CouldNotSatisfy` — `_satisfy` maps `Unavailable \| Impossible` to it (`src/miniscript/mod.rs:663-673`); also `plan.rs:286-291` |

"Empty" witness/push cases: `Witness::empty()` (`mod.rs:850`), `push_0()`/`push_1()`
(`mod.rs:853-856`) and the constants `TRIVIAL`/`IMPOSSIBLE` (`sat.rs:24-29`, `mod.rs:886-889`).

### 4.2 Timelock satisfiers, units, and 1 << 22

- `relative::LockTime` granularity: in rust-bitcoin 0.32, `Sequence::LOCK_TYPE_MASK = 0x0040_0000`
  (= **1 << 22**); `Sequence::from_512_second_intervals(intervals) = Sequence(intervals | LOCK_TYPE_MASK)`
  (rust-bitcoin `transaction.rs:354-356,441-442`). `to_relative_lock_time()` is `None` unless the
  disable flag `0x8000_0000` is clear.
- rust-miniscript impls: `Sequence`'s `check_older` fails closed (`false`) if the sequence isn't a
  valid relative locktime (`mod.rs:116-124`); `relative::LockTime`'s `check_older` is the rust-bitcoin
  **`n.is_implied_by(*self)`** (`mod.rs:132-134`), which requires **same unit kind** and
  self >= n (rust-bitcoin `locktime/relative.rs:226-233` — `(Blocks,Time)` ⇒ `false`), so a
  512-second-unit satisfier can never satisfy a blocks-based `older` (and vice versa).
  `absolute::LockTime` mirrors this (`mod.rs:136-138`).
- Requirement aggregator: `concatenate_rev` merges two paths' timelocks
  (`mod.rs:918-944`):

```rust
let relative_timelock = match (self.relative_timelock, other.relative_timelock) {
    (None, x) | (x, None) => x,
    (Some(a), Some(b)) => match RelLockTime::max(a, b) {
        Some(t) => Some(t),
        None => return Self::IMPOSSIBLE,
    }, };
```

`RelLockTime::max` (`src/primitives/relative_locktime.rs:74-82`) and `AbsLockTime::max`
(`src/primitives/absolute_locktime.rs:78`) compare via `relative::LockTime::partial_cmp`, which is
`None` for mixed height/time ⇒ **same-unit paths keep the *max* (later) lock; mixed-unit paths
become `Witness::Impossible`** — exactly the trait-doc contract quoted in §1, and exercised in
`regression_895` (`mod.rs:1382-1406`) where mixed `after(144)`+`after(1_000_000_000)` paths kill
the malleable plan while the non-malleable one survives because the dsat of the expensive-threshold
branch never merges the two kinds.
- Because every *used* timelock is carried in the `Satisfaction`, a `Plan` surfaces
  `absolute_timelock`/`relative_timelock` directly (`src/plan.rs:216-219`), and the #895 fix
  ensures a timelock inside an `and_v`-style *dissatisfaction* is likewise recorded
  (`concatenate_rev` applies to dissats too, e.g. `sat.rs:378,387,397-398,431`).

### 4.3 The PSBT satisfier's timelock checks (`src/psbt/mod.rs`)

```rust
fn check_after(&self, n: absolute::LockTime) -> bool {
    if !self.psbt.unsigned_tx.input[self.index].enables_lock_time() { return false; }
    let lock_time = self.psbt.unsigned_tx.lock_time;
    <dyn Satisfier<Pk>>::check_after(&lock_time, n)
}

fn check_older(&self, n: relative::LockTime) -> bool {
    let seq = self.psbt.unsigned_tx.input[self.index].sequence;
    if self.psbt.unsigned_tx.version < transaction::Version::TWO || !seq.is_relative_lock_time() {
        return false; }
    <dyn Satisfier<Pk>>::check_older(&seq, n)
}
```
(`psbt/mod.rs:326-344`) — i.e. tx must be v≥2 (BIP68), sequence non-final lockable, `nLockTime`
enabled by a non-final sequence: the full "seq/locktime combination requirements" the witness-side
spec assumes.

### 4.4 Taproot sig marshalling (64 B vs 65 B) and signature sizing

- **Template = actual size**: schnorr sig sizes recorded in `Placeholder::SchnorrSigPk(.., size)`
  come straight from `s.serialize().len()` (`plan.rs:150-160, 177-183`). For
  `bitcoin::taproot::Signature`, `to_vec()`/`serialize()` is **64 B when `sighash_type == SIGHASH_DEFAULT
  (0x00)` and 65 B otherwise** (the sighash byte is appended only for non-default); the template then
  `debug_assert!`s the completed sig has the recorded length (`mod.rs:672-692`).
- `SchnorrSigType` distinguishes the two query channels so completion knows which lookup to redo:
  `KeySpend { merkle_root: Option<TapNodeHash> }` vs `ScriptSpend { leaf_hash: TapLeafHash }`
  (`mod.rs:558-571`; selection at `mod.rs:672-685`).
- **Worst-case accounting = 66 B per schnorr sig element** (65 + 1-byte push/element-length
  opcode): `extra_props.rs:206` (`(SigType::Schnorr) => (33, 66)` for `pk_k`), `:242` (pk_h),
  `:328` (`multi_a`: `(n - k) + 66 * k`), and the documented convention *"Assumes all Schnorr
  signatures are 66 bytes, including push opcode and sighash suffix"* (`src/descriptor/tr/mod.rs:145-146`).
  ECDSA worst-case is **73 B**: doc *"All ECDSA signatures are assumed to be 73 bytes… and its
  sighash byte"* (`extra_props.rs:89-91`); runtime template costing uses 73 for
  `EcdsaSigPk{,Hash}` (`src/util.rs:25`).
- Per-item template size table (`src/util.rs:20-41`, `ItemSize for Placeholder`): pubkey/pkh use
  the stored size (incl. push), schnorr sigs `size + 1` (`// +1 for the OP_PUSH`), hash
  (dis)satisfactions 33, `PushOne = 2`, `PushZero = 1`, tap script/control block get their varint
  prefix accounted. `witness_size(wit) = Σ item sizes + varint(item count)` (`util.rs:48-50`) is
  the metric everything compares with — including `Ord for Witness` (§2.2) and the `thresh`
  counters (§3.16) — so it *is* the "cost function" of this codebase.

---

## 5. Size estimation vs. the old `multiple_satisfactions`/`max_satisfaction_cost`

`multiple_satisfactions()` (which used to enumerate how many satisfactions a fragment admits, for
min/max size bounds) is **not present** anywhere in this tree (grep). The question's two APIs map
to current ones as follows:

| Old name | Current replacement | Ref |
|---|---|---|
| `max_satisfaction_cost` (satisfier-informed weight) | Per-descriptor `max_weight_to_satisfy()`, or satisfier-informed `Plan::satisfaction_weight()` | below / `plan.rs:235` |
| `multiple_satisfactions`-based static bounds | `ext.sat_data`/`dissat_data` statically computed per fragment (`extra_props.rs:143-160`), exposed via `Miniscript::max_satisfaction_size()` (`miniscript/mod.rs:605-607`: `Ctx::max_satisfaction_size` → `sat_data.map(|d| d.max_witness_stack_size)` for segwit contexts; `max_script_sig_size` for Bare) and `max_satisfaction_witness_elements()` (`miniscript/mod.rs:586-591`: `max_witness_stack_count + 1`) | `extra_props.rs`, `context.rs:469-471,604-606,728-730` |

The static table is fragment-wise worst-case (selected highlights): `pk_k` sig = 73/66 (`extra_props.rs:202-230`),
`multi`: `1 + 73*k` sat / `1 + k` dsat (`:288-302`), `multi_a`: `(n-k) + 66*k` sat / `n` dsat
(`:323-343`), hashlocks 33 (`:355ff.`), or-combinations via
`SatData::fieldwise_max_opt(l.sat_data, sat_concat(l.dissat_data, r.sat_data))` etc. (`:698-748`).

`max_weight_to_satisfy` math:

- **WPKH** (`src/descriptor/segwitv0.rs:253-259`):
  `(varint_len(2) − varint_len(0)) + (73 + pk_len(=34))` — i.e. `1 + 107 = 108` bytes ⇒ the doc's
  example `wsh` yields 288 WU etc. It is framed as *"an upper bound on the difference between a
  non-satisfied TxIn's segwit_weight and a satisfied TxIn's"* (`segwitv0.rs:248-249`).
- **WSH/Bare** sum the miniscript-level sizes; `sh.rs:168-197` splits scriptSig/witness halves and
  adds the redeem-script weight.
- **TR** (`src/descriptor/tr/mod.rs:152-194`): key-spend = `varint_len(1) + (1 + 65)`; script-path
  scans all leaves taking the **`.max()`** of
  `stack_varint_diff(varint(max_sat_elems + 1) − varint(0)) + max_sat_size + varint(script_size) +
  script_size + varint(control_block_size) + control_block_size`, i.e. worst-cost leaf wins
  (upper bound), `Error::ImpossibleSatisfaction` if no leaf is satisfiable at all.
- **Satisfier-informed cost**: `Plan { template, absolute_timelock, relative_timelock, .. }`
  (`plan.rs:213-222`) with `witness_size()` (incl. witness-script varint adjustments for WSH,
  `plan.rs:258-277`), `scriptsig_size()` (`plan.rs:239-252`), `satisfaction_weight()`
  (`plan.rs:235`) = `witness_size + scriptsig_size * 4`. `Plan::satisfy` materialises the witness
  from placeholders (`plan.rs:280-291`) — the modern deserialization of what
  `multiple_satisfactions`-style reasoning used to feed.
- **Taproot tree choice**: `best_tap_spend` (`src/descriptor/tr/mod.rs:444-510`) tries key-spend
  first (`provider_lookup_tap_key_spend_sig`), else every leaf and keeps the **minimum
  `witness_size`** template, appending `Placeholder::TapScript` + `Placeholder::TapControlBlock`
  to the leaf's stack (`tr/mod.rs:496-505`).

Regression context for the semantics in §4.2: `mod.rs:1272-1408` (`regression_895`) documents why
dissatisfactions record timelocks, and `mod.rs:1219-1270` (`regression_1037`) documents the
`root_has_sig`-driven DONTUSE/`Unavailable` distinction and its known over-approximation for
type-malleable roots:
*"FIXME: The root's erased signature property makes the unmet timelock Unavailable rather than
Impossible. … Track signatures that a third party cannot remove in the satisfaction algorithm
instead of relying on root_has_sig."* (`mod.rs:1252-1256`).

---

## 6. Quick cross-reference index

| Topic | Location |
|---|---|
| `Satisfier` trait (14 methods) | `src/miniscript/satisfy/mod.rs:31-111` |
| Map/tuple/ref impls | `mod.rs:114-556` |
| `Witness` enum + `Ord` | `mod.rs:702-735` |
| `Placeholder` enum + `satisfy_self` | `mod.rs:573-700` |
| `Satisfaction` struct, `concatenate_rev`, `thresh`/`minimum`_* | `mod.rs:871-1149` |
| Per-fragment tables | `src/miniscript/satisfy/sat_dissat.rs:303-494` (helpers :34-295) |
| Lockmerge (height↔time ⇒ Impossible) | `mod.rs:923-936`; `src/primitives/relative_locktime.rs:74-82`; `src/primitives/absolute_locktime.rs:78` |
| 1<<22 time-unit flag | rust-bitcoin `transaction.rs` `Sequence::LOCK_TYPE_MASK` |
| Sig sizes: actual (64/65) | `src/plan.rs:150-160`; worst-case 66/73 | `src/miniscript/types/extra_props.rs:89-91,206,328` |
| Item/witness costing | `src/util.rs:20-50` |
| Descriptor upper bounds | `src/descriptor/{bare.rs:65, sh.rs:168, segwitv0.rs:66&253, tr/mod.rs:152}` |
| Plan / satisfier-informed weight | `src/plan.rs:213-306` |
| PSBT satisfier (incl. timelock gates) | `src/psbt/mod.rs:261-372` |

*Analysis is strictly read-only; no files in `rust-miniscript/` were modified.*
