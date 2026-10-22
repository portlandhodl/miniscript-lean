# `ExtData` — rust-miniscript extra type properties (analysis)

Target file: `rust-miniscript/src/miniscript/types/extra_props.rs` (1052 lines).
READ-ONLY analysis. All `file:line` refs are relative to `/home/qrsnap/git/miniscript-lean/rust-miniscript/`.

`ExtData` is the "miscellaneous type properties" record (not correctness/malleability —
those live in `types/correctness.rs` / `types/malleability.rs`). It is computed bottom-up
by `ExtData::type_check` for every node and stored in `Miniscript.ext`
(`src/miniscript/mod.rs:316-319`).

---

## 1. The structs

### 1.1 `ExtData` — `src/miniscript/types/extra_props.rs:142-160`

```rust
pub struct ExtData {
    pub pk_cost: usize,               // bytes needed to encode its scriptpubkey
    pub has_free_verify: bool,        // can be verify-wrapped for free
    pub static_ops: usize,            // static (executed + unexecuted) opcodes; irrelevant in Taproot
    pub sat_data: Option<SatData>,    // worst-case values for satisfaction
    pub dissat_data: Option<SatData>, // worst-case values for dissatisfaction
    pub timelock_info: TimelockInfo,  // heightlocks/timelocks info
    pub tree_height: usize,           // miniscript tree depth (stack-overflow protection)
}
```

| Field | Meaning | Notes |
|---|---|---|
| `pk_cost` | Byte size of the fragment's *script* encoding | Compared against script-size limits (`520`/`3600`/`10000`/block weight) in the context checks. |
| `has_free_verify` | Last opcode can be merged with `OP_VERIFY` (i.e. `CHECKSIG→CHECKSIGVERIFY`, `EQUAL→EQUALVERIFY`, `CHECKMULTISIG→CHECKMULTISIGVERIFY`, `NUMEQUAL→NUMEQUALVERIFY`) | Consumed by `cast_verify` to charge `0` or `1` bytes/ops. |
| `static_ops` | Number of opcode bytes in the script text, executed **or not** | Legacy/Segwitv0 only ("Irrelevant in Taproot context", `:148-149`). |
| `sat_data` | `Some(SatData)` iff the fragment is satisfiable | `None` ⇒ `ImpossibleSatisfaction` downstream (`src/miniscript/context.rs:440`). |
| `dissat_data` | `Some(SatData)` iff the fragment is dissatisfiable | — |
| `timelock_info` | Which kinds of timelocks appear & whether a conflicting mix exists | see §2.x |
| `tree_height` | Height of this node's AST subtree (leaves = 0) | Checked against `MAX_RECURSION_DEPTH = 402` (`src/lib.rs:499`) in `from_ast` (`src/miniscript/mod.rs:327`) and against `ValidationParams::max_recursive_depth` in `validate_non_top_level` (`src/miniscript/mod.rs:391`). |

### 1.2 `SatData` — `extra_props.rs:92-112`

Documented assumption (`:87-91`): *"All ECDSA signatures are assumed to be 73 bytes
in size (including the length prefix if it's a witness element, or push opcode if it's
a script push) and its sighash byte."*

| Field | Meaning |
|---|---|
| `max_witness_stack_size` (`:98`) | Max **bytes** of witness stack, incl. per-element length prefixes but **not** the stack-wide varint. |
| `max_witness_stack_count` (`:100`) | Max number of witness **elements**. |
| `max_script_sig_size` (`:104`) | Max bytes of `scriptSig`, **excluding** its length prefix. |
| `max_exec_stack_count` (`:109`) | Max stack+altstack elements *pushed during execution* — **excludes the initial witness elements** (`:105-108`). Combined with `max_witness_stack_count` for the 1000-stack-element check. |
| `max_exec_op_count` (`:111`) | Max **executed** non-push opcodes beyond static counting; only `multi` ever sets it non-zero (see §4). |

Helpers: `fieldwise_max` (`:115-129` — per-field `cmp::max`) and
`fieldwise_max_opt` (`:131-138` — `Option`-propagating version, `None ∨ x = x`).

### 1.3 `TimelockInfo` — `extra_props.rs:15-27`

```rust
pub struct TimelockInfo {
    pub csv_with_height: bool,   // relative lock (older) expressed in blocks
    pub csv_with_time: bool,     // relative lock (older) expressed in time
    pub cltv_with_height: bool,  // absolute lock (after) as block height
    pub cltv_with_time: bool,    // absolute lock (after) as block time
    pub contains_combination: bool, // some branch needs incompatible locks simultaneously
}
```
`contains_unspendable_path()` (`:42`) is just `contains_combination`; surfaced as
`Miniscript::has_mixed_timelocks()` (`src/miniscript/analyzable.rs:45`) and rejected when
`!allow_mixed_time_locks` (`src/miniscript/mod.rs:399-401`).

Merging (`:44-84`):
- `combine_and(a,b) = combine_threshold(2, {a,b})`, `combine_or(a,b) = combine_threshold(1, {a,b})`.
- `combine_threshold(k, ts)` folds: it always ORs the four flag fields and OR-propagates
  children `contains_combination` (`:77-81`). **Only when `k > 1`** (real conjunction) it
  sets `contains_combination` on a cross conflict (`:69-76`):

```rust
let height_and_time = (acc.csv_with_height && t.csv_with_time)
    || (acc.csv_with_time && t.csv_with_height)
    || (acc.cltv_with_time && t.cltv_with_height)
    || (acc.cltv_with_height && t.cltv_with_time);
```

Note the exact conflict pairs: **csv-height ↔ csv-time** and **cltv-height ↔ cltv-time**.
CSV vs CLTV mixes are *not* flagged — a height-locked `nSequence` and a time-locked
`nLockTime` (or vice versa) coexist in one tx, so only same-field unit conflicts are
unspendable. With `k == 1` (disjunction) only propagation happens: one branch at a time
is executed, so alternatives never conflict. Unit test: `:1032-1051`
(thresh-1 of {time,time,height} is fine; thresh-2 is unspendable).

---

## 2. Per-`Terminal`-variant `ext_data` computation

Dispatcher: `ExtData::type_check` (`:949-1018`) matches every `Terminal` variant
(enum defined at `src/miniscript/decode.rs:90-162`) and calls the constructors below.
Referenced size helper: `script_num_size` (`src/lib.rs:636-645`): 1 byte ≤ 0x10 (OP_n),
then PUSH1/2/3/4/5.

### 2.1 Leaves

**`False` (`0`) / `True` (`1`)** — consts `FALSE`/`TRUE` (`:163-196`).
`pk_cost = 1`, `static_ops = 0`, `tree_height = 0`. `FALSE`: `sat_data: None`,
dissat = all-zero but `max_exec_stack_count: 1` (the pushed `0`). `TRUE` is the mirror.

**`PkK` (pk_k)** — `:202-230`. Size depends on context sig type + key form (`:203-207`):
```rust
let (key_bytes, max_sig_bytes) = match Ctx::sig_type() {
    crate::SigType::Ecdsa if pk.is_uncompressed() => (65, 73),
    crate::SigType::Ecdsa => (34, 73),
    crate::SigType::Schnorr => (33, 66),
};
```
`pk_cost = key_bytes` (key + push opcode). sat: 1 element of `max_sig_bytes`;
dissat: 1 element of 1 byte (push of `0`, or empty-with-prefix). `max_exec_stack_count: 1`,
`max_exec_op_count: 0`, `has_free_verify: false` (no last opcode; `v:pk_k` costs a real
`OP_VERIFY` — free-ness comes from `c:`/`c:pk_k` ending in `CHECKSIG`).

**`PkH` (pk_h) / `RawPkH`** — `:236-266`; `RawPkH` passes `None` for the key
(`type_check` `:958-959`) so worst-case key size is assumed for the context
(FIXME at `:237-238`). `pk_cost: 24` (`DUP HASH160 <20+1> EQUALVERIFY`),
`static_ops: 3`, sat = sig + pubkey (2 items; `key_bytes + max_sig_bytes` bytes — must push
the pubkey preimage), dissat = pubkey + one 0-byte (`key_bytes + 1`),
`max_exec_stack_count: 2 // dup and hash push`. `has_free_verify: false` (EQUALVERIFY's own
VERIFY is already merged; a further `v:` costs 1).

**`Multi` / `SortedMulti`** — `:269-313` (sorted variant just delegates, `:309-313`).
`num_cost` = 2/3/3/4 bytes for the `k`/`n` pushes (`:273-278`);
`pk_cost = num_cost + Σ key sizes + 1` (CHECKMULTISIG). `has_free_verify: true`,
`static_ops: 1`. sat: `1 + 73*k` bytes / `k+1` items (the CHECKMULTISIG dummy element);
dissat: `1 + k` bytes / `k+1` items (dummy + `k` zeroes).
**Unique:** `max_exec_op_count: n` with the comment
*"Multi is the only fragment which has additional executed opcodes to count"* (`:293-294`)
— legacy `CHECKMULTISIG` bumps the Core opcounter by the number of keys.

**`MultiA` / `SortedMultiA`** — `:316-347`. `pk_cost = num_cost + 33*n + (n-1) + 1`
(x-only keys, one CHECKSIG + n−1 CHECKSIGADD + NUMEQUAL). `has_free_verify: true`,
`static_ops: 0 // irrelevant; no ops limit in Taproot` (`:326`). sat witness:
`(n-k) + 66*k` bytes over `n` items (schnorr sig 66 or a 1-byte empty),
`max_script_sig_size: 0`, `max_exec_stack_count: 2`
(*"the two nums before num equal verify"*, `:331`). dissat: `n` empty items.

**`After(n)` (CLTV)** — `:454-476`. `pk_cost = script_num_size(n)+1`, `static_ops: 1`,
sat = empty (0/0) with `max_exec_stack_count: 1 // <t>`, **`dissat_data: None`** (absolute
locks can't be bypassed). Sets `cltv_with_height = t.is_block_height()`,
`cltv_with_time = t.is_block_time()` (`:467-473`).

**`Older(n)` (CSV)** — `:479-501`. Same shape, `dissat_data: None`, sets
`csv_with_height = t.is_height_locked()`, `csv_with_time = t.is_time_locked()` (`:492-497`).

**`Sha256`/`Hash256`** — `:350-399`: `pk_cost: 33 + 6`
(`SIZE <32> EQUALVERIFY {SHA256|HASH256} <hash> EQUAL`), `static_ops: 4`,
`has_free_verify: true` (terminal `EQUAL→EQUALVERIFY`).
**`Ripemd160`/`Hash160`** — `:402-451`: same but `pk_cost: 21 + 6` (20-byte hash).
All four: sat/dissat both `33` bytes / 1 element (a hash dissatisfaction is a single
32-byte element, `:363`); `max_exec_stack_count: 2 // either size <32> or <sha256> <32 byte>`.

### 2.2 Wrappers (all `tree_height + 1`; static timelocks pass through)

| Wrapper | fn | `pk_cost` | `static_ops` | `has_free_verify` | sat/dissat effect |
|---|---|---|---|---|---|
| `a:` (Alt) | `cast_alt` `:504-514` | +2 (TO/FROMALTSTACK) | +2 | `false` | unchanged |
| `s:` (Swap) | `cast_swap` `:517-527` | +1 (SWAP) | +1 | **propagated** (`:520`) | unchanged |
| `c:` (Check) | `cast_check` `:530-540` | +1 (CHECKSIG-family) | +1 | **`true`** (`:533`) | unchanged |
| `d:` (DupIf) | `cast_dupif` `:543-569` | +3 (DUP IF ENDIF) | +3 | `false` | sat: +2 witness bytes (`0x01` + len prefix), +1 witness item, +1 scriptsig byte (OP_1); dissat = constant 1-byte/1-item |
| `v:` (Verify) | `cast_verify` `:572-583` | `+ usize::from(!has_free_verify)` | `+ verify_cost` | resets to `false` | **`dissat_data: None`** |
| `j:` (NonZero) | `cast_nonzero` `:586-602` | +4 (SIZE 0NOTEQUAL IF ENDIF) | +4 | `false` | sat unchanged; dissat = constant 1-byte |
| `n:` (ZeroNotEqual) | `cast_zeronotequal` `:605-618` | +1 (0NOTEQUAL) | +1 | `false` | unchanged (see §4 note on exec stack) |

`cast_verify` is the only consumer of `has_free_verify` (`:573-577`):
```rust
let verify_cost = usize::from(!self.has_free_verify);
Self { pk_cost: self.pk_cost + usize::from(!self.has_free_verify),
       has_free_verify: false, static_ops: verify_cost + self.static_ops, ... }
```
If the child ends in a verify-mergeable opcode, `v:` is **free**: `CHECKSIGVERIFY`,
`EQUALVERIFY`, `CHECKMULTISIGVERIFY`, `NUMEQUALVERIFY` are still single opcodes — hence
both the byte cost and the static-op cost are 0.

Virtual casts: `cast_true` → `and_v(self, TRUE)`, `cast_unlikely` → `or_i(self, FALSE)`,
`cast_likely` → `or_i(FALSE, self)` (`:620-629`).

### 2.3 Conjunctions (SUM children)

**`AndB` (`[E] [W] BOOLAND`)** — `:632-658`: `pk_cost l+r+1`, `static_ops` sum +1,
`has_free_verify: false`, **sat witness/scriptSig sizes and op counts are SUMMED**;
dissat = dissat(l) + dissat(r) (both needed for `BOOLAND`→0). exec stack:
`max(l.exec, 1 + r.exec)` — *"Left element leaves a stack result on the stack top…
Therefore + 1 is added to execution size of second element"* (`:641-643`).
Timelocks: `combine_and` (`:655`). Tree height `1 + max`.

**`AndV` (`[V] [T]…`)** — `:661-678`: plain concatenation, `pk_cost l+r`,
`has_free_verify: r.has_free_verify` (`:664` — script's last opcode is the right child's;
this plus `multi`/hash/`thresh`/`c:` is how "free verify" propagates upward),
witnesses SUMMED, **`dissat_data: None`**, exec stack `max(l, r)` (no residual:
V-type children leave nothing, `:670`), `combine_and`.

### 2.4 Disjunctions (build both alternatives → fieldwise MAX)

**`OrB` (`[E] [W] BOOLOR`)** — `:681-706`: `pk_cost l+r+1`. sat =
`fieldwise_max_opt(sat(l)+dissat(r), dissat(l)+sat(r))` (`:698-701`) — both sides always
execute, so both components contribute (SUM within each alternative, MAX across).
Since both children are always evaluated even in a satisfaction,
malleator-supplied dissat data is accounted worst-case. dissat = dissat(l)+dissat(r).
exec stack uses the and_b rule `max(l, 1+r)` inside the concat (`:689`). `combine_or`.

**`OrD` (`[E] IFDUP NOTIF [T]/[E] ENDIF`)** — `:709-729`: `pk_cost l+r+3`,
`static_ops +3`. sat = `max(l.sat, l.dissat + r.sat)` (`:724`) — first alternative has no
guard; the second pays `l`'s dissatisfaction. Within `sat_concat`, exec stack is plain
`cmp::max(l, r)` (`:715`) — **subtlety:** unlike `or_b` there is *no* `+1`, because
`IFDUP NOTIF` consumes `l`'s 0 result before `r` runs (regression test `test_or_d_exec_stack_count_fix`,
`src/miniscript/mod.rs:2068-2082`: `or_d(pk(A),pk(B))` dissat exec count must be 1, not 2).
dissat = l.dissat + r.dissat (also plain-max exec).

**`OrC` (`[E] NOTIF [V] ENDIF`)** — `:732-752`: `pk_cost l+r+2`. sat =
`max(l.sat, l.dissat + r.sat)`; **`dissat_data: None`**; exec plain-max. `combine_or`.

**`OrI` (`IF [l] ELSE [r] ENDIF`)** — `:755-783`: `pk_cost l+r+3`.
Selector accounting via `with_0`/`with_1` closures (`:756-769`): +1 element to both
witness/scriptsig paths; the witness byte cost is `+1` for pushing `0` (empty vector,
prefix only) and `+2` for pushing `1` (prefix + byte) while a scriptSig push is `+1`
in both cases (OP_0/OP_1). `max_exec_stack_count` is *not* bumped (selector is consumed
by `IF` before the child runs — same "max(1, ·) collapses" argument as `cast_zeronotequal`,
comment `:610-613`). sat = `max(l.sat∘with_1, r.sat∘with_0)`; dissat likewise (`:775-779`).
Short-circuiting, so only one child's data contributes — only MAX, no SUM of sats.

**`AndOr(a,b,c)` (`[a] NOTIF [c] ELSE [b] ENDIF`)** — `:786-812`: `pk_cost a+b+c+3`.
sat = `max(sat(a)+sat(b), dissat(a)+sat(c))` (`:801-804`) — again per-field
`fieldwise_max` over the two paths (see §4: may combine fields from *different* paths).
dissat = dissat(a)+dissat(c). exec plain-max in `sat_concat` (`:792` — `NOTIF` pops `a`'s
result before either arm). Timelocks: `combine_or(combine_and(a,b), c)` (`:806-809`) —
`a`'s locks conflict-check only against `b` (the `c` path never satisfies `a`; a fragment
like `after` can't be dissatisfied at all, so no `a`-vs-`c` conflict is possible).

### 2.5 `Thresh(k, subs…)` — `:814-945`

```rust
pub fn threshold<S>(k: usize, n: usize, mut sub_ck: S) -> Self
where S: FnMut(usize) -> Self,
```
- **pk_cost**: `1 + script_num_size(k) + Σ pk_cost + (n-1)` — threshold `k`, terminal
  `EQUAL`, and `(n-1)*ADD` (`:819`, `:937` note `//all pk cost + (n-1)*ADD`).
- **static_ops**: `Σ static_ops + 1 + (n-1)` (`:939`, "adds and equal").
- **`has_free_verify: true`** (`:938`) — ends in `EQUAL` ⇒ `EQUALVERIFY` merge.
- **dissat**: iff *every* child is dissatisfiable — running `zip` fold over all `n`
  children (`:826-848`): counts/sizes/op-counts SUMMED, exec stack per-field MAX
  with the accumulator caveat below.
- **sat (the tricky part)** — worst-case over all C(n,k) choices of which children are
  satisfied, computed independently per `SatData` field (`:855-910`):
  1. children are **sorted ascending by `proj(sat) − proj(dissat)`** (`:894-897`)
     for the field under consideration;
  2. the fold over the reversed (`descending`) vector **satisfies the first `k` children
     with the largest (sat − dissat) "deficit"** and dissatisfies the rest (`:898-909`):

```rust
.try_fold(0, |acc, (i, &(sat, dissat))| {
    if i < k { sat.map(|x| cmp(acc, proj(x))) }
    else { dissat.map(|y| cmp(acc, proj(y))) }
});
```
  The combine closure `cmp` is `+` (sum) for witness stack count/size, scriptSig size and
  op count, but for `max_exec_stack_count` it is
  `max(acc, x + usize::from(acc > 0))` (`:885`) — the *"acc > 0" hack* detects "not the
  first child": every child after the first executes while the running 0/1 accumulator
  already sits on the stack (`:879-885`). Because any needed `sat`/`dissat` being `None`
  poisons the fold, `sat_data` becomes `None` unless a valid k-of-n assignment exists
  (`:912-934`).
- **timelocks**: `combine_threshold(k, timelocks)` (`:942`) — children conflict-checked
  pairwise only when `k > 1` (see §1.3).
- **tree_height**: `max_child_height + 1` (`:943`).

Regression tests for both subtleties: `test_threshold_exec_stack_count_max_not_sum`
(`mod.rs:2084-2113`) and `test_thresh_sat_data_exact_k_satisfactions` (`mod.rs:2115-2130`:
`thresh(1,pk(A),s:pk(B))` ⇒ 74 bytes / 2 items; `thresh(2,pk(A),s:pk(B),a:pk(C))` ⇒ 147/3).

---

## 3. Limits checked against `ExtData`

There is **no** `check_limits` method on `ExtData` itself — checks live in the
per-context `ScriptContext` impls (`src/miniscript/context.rs`) and in
`Miniscript::validate*` (`src/miniscript/mod.rs`), all reading `ms.ext.*`.

### 3.1 Constants (`src/miniscript/limits.rs`)

| Constant | Value | Line |
|---|---|---|
| `MAX_OPS_PER_SCRIPT` | 201 | :9 |
| `MAX_STANDARD_P2WSH_STACK_ITEMS` | 100 | :12 |
| `MAX_SCRIPT_SIZE` | 10 000 | :15 |
| `MAX_STANDARD_P2WSH_SCRIPT_SIZE` | 3 600 | :18 |
| `MAX_SCRIPT_ELEMENT_SIZE` | 520 | :22 |
| `MAX_SCRIPTSIG_SIZE` | 1 650 | :25 |
| `MAX_STACK_SIZE` | 1 000 | :29 |
| `MAX_BLOCK_WEIGHT` | 4 000 000 | :31 |
| `MAX_PUBKEYS_PER_MULTISIG` | 20 | :35 (bound on `Multi`'s `Threshold`) |
| `MAX_PUBKEYS_IN_CHECKSIGADD` | 999 | :38 (bound on `MultiA`'s `Threshold`) |
| `MAX_RECURSION_DEPTH` | 402 | `src/lib.rs:499` |

### 3.2 Per-context checks (each consumes an `ExtData` field)

| Context | Global consensus | Global policy | Local consensus | Local policy |
|---|---|---|---|---|
| **Legacy** (`context.rs:371-484`) | `pk_cost > 520` ⇒ `MaxRedeemScriptSizeExceeded` (:423) | — | `sat_op_count() > 201` ⇒ `MaxOpCountExceeded`/`ImpossibleSatisfaction` (:439-446) | `max_script_sig_size > 1650` (:457-470) |
| **Segwitv0** (:490-613) | `pk_cost > 10 000` (:545) | `pk_cost > 3 600` (:576-581) | `sat_op_count() > 201` (:561-568) | witness items `max_witness_stack_count + 1 > 100` (:591-599) |
| **Tap** (:619-737) | `pk_cost > Weight::MAX_BLOCK` (:679-683, note: uses rust-bitcoin's constant, *not* `limits.rs::MAX_BLOCK_WEIGHT`) | none | `max_witness_stack_count + max_exec_stack_count > 1000` ⇒ `StackSizeLimitExceeded` (:704-711); 201-ops replaced by the sigops-budget argument (:695-703) | none |
| **BareCtx** (:746-860) | `pk_cost > 10 000` (:801) | — | `sat_op_count() > 201` (:817) | — |
| **NoChecks** (:862+) | — | — | — | — |

`sat_op_count()` (`extra_props.rs:1020-1025`) = `static_ops + sat_data.max_exec_op_count`.

### 3.3 `ValidationParams`-driven checks (`src/miniscript/mod.rs:387-509`, params in `src/validation.rs:16-70`)

`validate_non_top_level` reads `ext` for:
1. `ext.tree_height > params.max_recursive_depth` ⇒ `MaxRecursiveDepthExceeded` (:391;
   hard cap 402 also enforced unconditionally in `from_ast`, :327).
2. `has_mixed_timelocks()` (i.e. `ext.timelock_info.contains_combination`) when
   `!allow_mixed_time_locks` ⇒ `MixedTimeLocks` (:399-401).
3. `script_size() > params.max_script_size` (:463) — recomputed from the tree
   (`mod.rs:537-577`), not from `pk_cost`.
4. `max_satisfaction_witness_elements()` = `sat_data.max_witness_stack_count + 1`
   (:586-591; the +1 is the witness script itself) vs `params.max_witness_items` (:475).
5. `ext.sat_op_count()` vs `params.max_opcode_count` (:484-493).
6. `sat_data.max_witness_stack_count + sat_data.max_exec_stack_count` vs
   `params.max_exec_stack_size` (:499-506) — **quirk:** the error's `actual:` field is
   `max_witness_stack_size + max_exec_stack_count` (:503), i.e. bytes+count, while the
   condition uses count+count (Tap's own check at `context.rs:705-707` is consistent).
7. `validate` (:349-380) additionally: `ext.sat_data.is_none()` ⇒ `Unsatisfiable` (:374).

Default params: `ValidationParams::MAX` (`validation.rs:74-95`, depth 402 from
<sipa/miniscript#5>), `SANE` (:103-126 — no dup keys, no malleability, no mixed
timelocks, `allow_raw_pkh=false`, `allow_inconsistent_multipath_keys=false`, all numeric
limits `usize::MAX`), `CONSENSUS` (:133-155). They intersect per-field
(`intersect`, :188-233); each context defines `CONSENSUS`/`SANE` using these limits
(e.g. `Segwitv0::SANE` at `context.rs:502-506`).

Also: the compiler rejects >201-op thresholds using `ext.sat_op_count()`
(`src/policy/compiler.rs:1560`, test 67-of-68 at :1550-1582).

---

## 4. Subtle / surprising behaviors

1. **`thresh` satisfaction is field-wise, not path-wise.** For each of the 5 `SatData`
   fields the children are re-sorted by that field's `sat − dissat` difference and the
   worst k-of-n assignment is computed *separately* (`:855-910`). The resulting `SatData`
   may be the per-field worst case of *different* spending paths — a conservative
   over-estimate, never under-estimate. Same pattern in `andor`'s
   `fieldwise_max(a.sat+b.sat, a.dissat+c.sat)` (`:801-804`) and in all `or_*`
   alternatives: the maximum is per-field across paths.
2. **`thresh` exec-stack "acc > 0" hack.** `max(acc, child + (acc > 0))` (:885) encodes
   "one partial 0/1 result sits on the stack during every child except the first" —
   correct as long as children's exec counts are ≥ 1 (all real ones are). Fixed by
   regression test (`mod.rs:2084-2113`): `max` not `sum`, first child exempt.
3. **`multi_a` over-counts `pk_cost` by 1 when `n > 16`.** `num_cost` (:317-322) charges
   for pushing *both* `k` and `n` (`(false,true) => 3`), but the `multi_a` script pushes
   only `k` — compare `Miniscript::script_size()` for `MultiA`
   (`mod.rs:568-573`: `script_num_size(k) + 1 + Σ keys + n`). Conservative (only inflates
   the static size marginally; safe for limit checks) but inconsistent with `multi`,
   whose `num_cost` matches `script_size()` exactly.
4. **`max_exec_stack_count` excludes the initial witness stack and counts only
   *execution-time* pushes** (`:105-108`); the interpreter's 1000-element check compares
   witness **count** + exec count (`context.rs:705`, `mod.rs:499`), never witness *bytes*.
   The `n:`/`or_i` wrappers skip a theoretical `max(1,·+1)` bump, justified by comment as
   always collapsing (`:610-613`, `:760-768`).
5. **"VERIFY-free" accounting.** `static_ops` counts *every* opcode byte in the script,
   including branches never executed; combined with `max_exec_op_count` (only `multi`'s
   `n` from CHECKMULTISIG, `:293-294`) into `sat_op_count()` vs 201. So the legacy/segwit
   op check is a *static-text* upper bound, not an executed-ops measurement. In Taproot
   the whole mechanism is switched off (`multi_a` hardcodes `static_ops: 0`, `:326`).
6. **Sig-size assumptions (malleability-aware worst case).** ECDSA sigs are fixed at
   73 bytes everywhere (`:89-91`), Schnorr at 66; these cap what a *malleator* could push
   (standardness forces high-S valid DER, ≤ 73 B). pk dissatisfactions assume the minimal
   1 byte; `pk_h` dissat still charges `key_bytes + 1` because the pubKey preimage must be
   pushed. `or_b` always costs `sat(l)+dissat(r)` or `dissat(l)+sat(r)` — i.e. assumes a
   malleator supplies the missing branch's fullest dissatisfaction, because `BOOLOR`
   evaluates both branches unconditionally (`:698-701`).
7. **`dissat`-assuming alternatives flow through dissat data.** Every disjunction's sat
   for a branch other than the preferred one charges the `dissat` of skipped branches;
   since `after`/`older`/`v:`/`and_v`/`or_c` have `dissat_data: None`
   (`:466, 491, 579, 674, 748`), any alternative path requiring them silently disappears
   via `Option` propagation (`fieldwise_max_opt`, `zip`), shrinking `sat_data` — and if
   nothing survives, the node becomes unsatisfiable.
8. **`tree_height` = envelope depth, not script depth.** Leaves are 0; every wrapper and
   combinator adds exactly 1 (`:512, …, :810, :943`). Used purely as a
   recursion/stack-overflow guard (`from_ast` :327; DoS tests `mod.rs:2050-2066`), with a
   TODO that 402 is inherited from segwitv0 reasoning (`mod.rs:323-326`).
9. **`has_free_verify` propagation is one-directional conjunction:** only `multi*`,
   hash-locks, `thresh`, `c:` create it; `and_v` forwards it *from the right child only*
   (`:664`), `s:` preserves it (`:520`), everything else clears it; `v:` consumes and
   resets it (`:573-577`). This exactly tracks whether the script's final opcode can
   absorb a `VERIFY`.
10. **Tap global size check bypasses `limits.rs`.** `Tap::check_global_consensus_validity`
    compares `pk_cost` to rust-bitcoin's `Weight::MAX_BLOCK` (`context.rs:679`), while
    `MAX_BLOCK_WEIGHT` in `limits.rs:31` is defined but unused there.
