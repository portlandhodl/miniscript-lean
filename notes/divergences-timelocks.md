# Timelock semantics: bitcoin-core vs rust-miniscript

Audience: Lean formalization of `older(n)` / `after(n)` (CSV/CLTV) in miniscript.

Trees compared (READ-ONLY review, no modifications):
- **Core**: `bitcoin-core/src/script/miniscript.h`, `miniscript.cpp`, `script.h`, `interpreter.cpp`, `sign.cpp`, `descriptor.cpp`, `src/test/miniscript_tests.cpp`
- **Rust**: `rust-miniscript/src/primitives/{absolute,relative}_locktime.rs`, `src/miniscript/types/extra_props.rs`, `src/miniscript/satisfy/{mod.rs,sat_dissat.rs}`, `src/interpreter/{mod.rs,stack.rs}`, `src/miniscript/{decode.rs,lex.rs,mod.rs,analyzable.rs}`, `src/expression/mod.rs`, `src/validation.rs`, `src/psbt/mod.rs`, plus vendored `bitcoin-0.32.x` (`absolute.rs`, `relative.rs`, `transaction.rs`).

Short answer: the **static timelock-domain checks and the height/time mixing predicate are logically equivalent** (Core's property `k` ⇔ ¬ rust's `contains_combination`). The **dynamic "is the lock met" semantics diverge in exactly two consensus conditions** (CSV version≥2 and CLTV input-finality), which Core's interpreter enforces and rust's interpreter omits (rust re-adds them only in the PSBT satisfier). The Core *test model* abstracts locks as exact-value atoms and is deliberately weaker than both.

---

## 1. Domain: accepted `n` for `older`/`after`

### Core

Accepted domain: **`1 ≤ n < 2^31`** for both fragments, at three layers:

| Layer | Check | Location |
|---|---|---|
| Text parse (descriptor policy) | `ToIntegral<int64_t>` then `*num < 1 \|\| *num >= 0x80000000L` | `miniscript.h:2026-2027` (`after`), `miniscript.h:2033-2034` (`older`) |
| Node construction (invariant) | `CHECK_NONFATAL(k >= 1 && k < 0x80000000UL)` | `miniscript.cpp:50-51` |
| Script decode | `ParseScriptNumber` → `CScriptNum(vch, fRequireMinimal=true, nMaxNumSize=4 default)` then `*num < 1 \|\| *num > 0x7FFFFFFFL` | `miniscript.h:2344-2357`; `miniscript.cpp:408-418`; `script.h:244-271` |

Minimal-encoding checks (script side):
- `DecomposeScript` rejects non-minimal *push opcodes* for any pushdata: `miniscript.cpp:396-397` (`IsPushdataOp && !CheckMinimalPush`).
- `ParseScriptNumber` additionally rejects non-minimal *scriptnum* encoding via `CScriptNum(vch, true)` (`script.h:252-268`: MSB-zero padding check), and caps the push at **4 bytes** (`nDefaultMaxNumSize=4`, `script.h:244`).
- Small ints: `OP_1`..`OP_16` are canonicalized to a 1-byte push by `DecomposeScript` (`miniscript.cpp:377-379`) and then parsed as scriptnums; `OP_0` maps to 0 (`miniscript.cpp:409-410`) and is later rejected by the ≥1 bound.
- Emission is always minimal: `BuildScript(node.k, OP_CHECKSEQUENCEVERIFY)` / `BuildScript(node.k, OP_CHECKLOCKTIMEVERIFY)` (`miniscript.h:819-820`) via `push_int64` (OP_N for 1..16, shortest scriptnum otherwise).

**5-byte policy**: the *consensus* interpreter reads CLTV/CSV operands as 5-byte scriptnums — `CScriptNum(stacktop(-1), fRequireMinimal, 5)` at `interpreter.cpp:556` (CLTV) and `interpreter.cpp:584` (CSV) — because 32-bit locktimes do not fit 31 bits. This window is **unreachable from well-formed miniscript**: the miniscript domain (≤ 0x7FFFFFFF) always fits minimal 4-byte encoding, and both the miniscript parser and the typed rust constructors reject anything larger. If the Lean model reasons about raw Script execution, it must include the 5-byte rule; if it only reasons about the miniscript AST, it can assume `1 ≤ k < 2^31`.

### Rust

Accepted domain: **`1 ≤ n ≤ 0x7FFF_FFFF`** — numerically identical.

- `AbsLockTime::from_consensus(n)`: `n >= 1 && n <= 0x7FFF_FFFF` — `absolute_locktime.rs:51-56` (constants `MAX_ABSOLUTE_LOCKTIME = 0x7FFF_FFFF` L10, `MIN_ABSOLUTE_LOCKTIME = 1` L17).
- `RelLockTime::from_consensus(n)` → `TryFrom<Sequence>`: `seq.is_relative_lock_time() && seq != Sequence::ZERO` — `relative_locktime.rs:85-94`, `relative_locktime.rs:42-44`. `is_relative_lock_time()` is `n & 0x8000_0000 == 0` (`bitcoin/blockdata/transaction.rs:393-395`), so the accepted set is `{1 ..= 0x7FFFFFFF}` = Core's `[1, 2^31)`.
- Text parse: `verify_after`/`verify_older` (`expression/mod.rs:347-357, 364-374`) calling `parse_num` (`expression/mod.rs:696-702`): first char must be `'1'..='9'` (or the literal `"0"`), i.e. **rejects `-`, `+`, and leading zeros** — stricter than Core's `std::from_chars`-based `ToIntegral` in that Core accepts `"after(01)"` (parses to 1) while rust rejects it. Both reject `after(-1)` and `after(+1)` (Core test: `miniscript_tests.cpp:723-724`).
- Script decode: `decode.rs:447-450` on `Tk::Num(n)`, where the lexer (`lex.rs:207-224`) uses `instructions_minimal()` + `read_scriptint()` — minimal push, minimal scriptnum, ≤4 bytes, non-negative (`lex.rs:219-223`), with OP_N/OP_0 canonicalized to `Num(n)` (`lex.rs:227-276`).
- Emission: `push_int` (`astelem.rs:55, 58`), same minimal-encoding result as Core; size formula `script_num_size` (`lib.rs:636-645`) = Core's `1 + (num>16) + (num>0x7f) + (num>0x7fff) + (num>0x7fffff)` (`miniscript.h:2029, 2036`).

### Leaf-level "forbidden combinations" and garbage bits

- **Disable flag (bit 31, `1<<31`)**: impossible at miniscript leaf level in both (domain caps at 2^31). Core's consensus CSV has a NOP-on-disable-operand rule (`interpreter.cpp:592-596`); unreachable from valid miniscript.
- **Type flag (bit 22, `SEQUENCE_LOCKTIME_TYPE_FLAG = 0x00400000`, `transaction.h:100`)**: is exactly the `older` unit bit in both (see §2). Core: `k & CTxIn::SEQUENCE_LOCKTIME_TYPE_FLAG` (`miniscript.cpp:92-93`); rust: `Sequence::LOCK_TYPE_MASK = 0x00400000` (`transaction.rs:356`) via `is_time_locked()`/`is_height_locked()` (`transaction.rs:397-407`, reached through `older()`, `extra_props.rs:493-494`).
- **Bits 23..30 (unused by consensus)**: accepted by both (e.g. `older(0x0080000A)`), classified by bit 22 only, and masked away with the same mask at check time (Core: `nSequence & (TYPE_FLAG | SEQUENCE_LOCKTIME_MASK)` = `& 0x0040FFFF`, `interpreter.cpp:1812-1814`; rust: `to_relative_lock_time` keeps `low_u16()` + type bit, `transaction.rs:481-495`). No divergence.
- **Absolute `after`**: no flag bits at all; unit decided solely by comparison with `LOCKTIME_THRESHOLD = 500_000_000` (Core `script.h:46-48`; rust `bitcoin-units/locktime/absolute.rs:24, 243-246`). Identical boundary: `n < 500_000_000` ⇒ height (`j`), else time (`i`).
- **Core-only descriptor lint**: `MiniscriptDescriptor` *warns* (does not reject) when an `older` has value bits beyond the 16-bit mask: `value_part = raw & ~TYPE_FLAG; if (value_part > SEQUENCE_LOCKTIME_MASK)` → "unsafe" warning (`descriptor.cpp:1749-1763`). rust-miniscript has no equivalent. No acceptance effect. **(operational divergence)**

---

## 2. Unit classification at the leaf (g/h/i/j ↔ csv/cltv_with_{time,height})

Core leaf types (`miniscript.cpp:91-98`, bit indices `miniscript.h:181-185`, doc `miniscript.h:114-126`):

```cpp
case Fragment::OLDER: return
    "g"_mst.If(k & CTxIn::SEQUENCE_LOCKTIME_TYPE_FLAG) |   // g = csv_time
    "h"_mst.If(!(k & CTxIn::SEQUENCE_LOCKTIME_TYPE_FLAG)) | // h = csv_height
    "Bzfmxk"_mst;
case Fragment::AFTER: return
    "i"_mst.If(k >= LOCKTIME_THRESHOLD) |   // i = cltv_time
    "j"_mst.If(k < LOCKTIME_THRESHOLD) |    // j = cltv_height
    "Bzfmxk"_mst;
```

Rust leaf typing (`extra_props.rs:454-476, 479-501` via `bitcoin`’s `absolute::LockTime::from_consensus` / `Sequence` flags):

```rust
// after(t):  cltv_with_height: t.is_block_height(),  cltv_with_time: t.is_block_time()   // n < 500M ?
// older(t):  csv_with_height:  t.is_height_locked(), csv_with_time:  t.is_time_locked()  // bit22 ?
```

Correctness/malleability part matches Core’s `"Bzfm"` + `x`: rust `Type::time()` = `Base::B`, `Input::Zero`, `dissatisfiable: false` (`types/mod.rs:256`, `correctness.rs:176-178`), `Malleability::NonMalleable{dissat: None}` (`malleability.rs:155`), `has_free_verify: false` (`extra_props.rs:457, 482`).

Mapping: **g ≙ csv_with_time, h ≙ csv_height, i ≙ cltv_with_time, j ≙ cltv_height.** On the common domain each leaf sets exactly one of each pair in both implementations (disable bit impossible ⇒ rust `is_height_locked ¬¬ is_time_locked`; the threshold test is a dichotomy). ⇒ **Leaf classification functions are identical.**

---

## 3. Mixing rule: Core `k` vs rust `contains_combination`

### Core: per-fragment rules in `ComputeType`

- `AND_V` (`miniscript.cpp:151-156`), `AND_B` (`miniscript.cpp:166-171`), `ANDOR` (`miniscript.cpp:217-222`):

```cpp
((x | y) & "ghij"_mst) | /* ... */ "k"_mst.If(((x & y) << "k"_mst) &&
    !(((x << "g"_mst) && (y << "h"_mst)) ||
      ((x << "h"_mst) && (y << "g"_mst)) ||
      ((x << "i"_mst) && (y << "j"_mst)) ||
      ((x << "j"_mst) && (y << "i"_mst))));  // k=k_x*k_y*!(g_x*h_y + h_x*g_y + i_x*j_y + j_x*i_y)
```

  (`ANDOR` uses `(x & y & z) << "k"` and checks **only x×y**, the two branches that co-execute on the sat path.)
- `OR_B / OR_D / OR_C / OR_I` (`miniscript.cpp:178-179, 187-188, 195-196, 204-205`): no cross check; `k = k_x ∧ k_y`.
- `THRESH` (`miniscript.cpp:234-250`): fold over child types with running union accumulator:

```cpp
Type acc_tl = "k"_mst;
for (Type t : sub_types) {
    ...
    acc_tl = ((acc_tl | t) & "ghij"_mst) |
        "k"_mst.If(((acc_tl & t) << "k"_mst) && ((k <= 1) ||
            ((k > 1) && !(((acc_tl << "g"_mst) && (t << "h"_mst)) ||
                          ((acc_tl << "h"_mst) && (t << "g"_mst)) ||
                          ((acc_tl << "i"_mst) && (t << "j"_mst)) ||
                          ((acc_tl << "j"_mst) && (t << "i"_mst))))));
}
```

- Wrappers propagate `ghijk` pointwise (`(x & "ghijk"_mst)` in every `WRAP_*`, e.g. `miniscript.cpp:107, 112, 116, 123, 130, 136, 140`).
- **`SanitizeType` (`miniscript.cpp:19-37) contains no ghijk rule at all** — it only enforces base-type/property coherence. The k-rule is enforced semantically: `CheckTimeLocksMix()` (`miniscript.h:1690`), part of `IsSaneSubexpression` (`miniscript.h:1699`) and `IsSane` (`miniscript.h:1702`), and is what descriptor parsing rejects on (`descriptor.cpp:2745-2768`, error text "contains mixes of timelocks expressed in blocks and seconds", L2758-2759). The bare `miniscript::FromString`/AST layer deliberately *does not* reject mixes (tests below prove this).

### Rust: `TimelockInfo`

```rust
pub struct TimelockInfo {                 // extra_props.rs:15-27
    pub csv_with_height: bool,   // ≙ h
    pub csv_with_time: bool,     // ≙ g
    pub cltv_with_height: bool,  // ≙ j
    pub cltv_with_time: bool,    // ≙ i
    pub contains_combination: bool,        // ≙ ¬k
}
pub fn contains_unspendable_path(self) -> bool { self.contains_combination }  // extra_props.rs:42
```

- Core fold (`extra_props.rs:55-84`):

```rust
pub(crate) fn combine_threshold<I>(k: usize, timelocks: I) -> Self {
    timelocks.into_iter().fold(Self::default(), |mut acc, t| {
        if k > 1 {
            let height_and_time = (acc.csv_with_height && t.csv_with_time)
                || (acc.csv_with_time && t.csv_with_height)
                || (acc.cltv_with_time && t.cltv_with_height)
                || (acc.cltv_with_height && t.cltv_with_time);
            acc.contains_combination |= height_and_time;
        }
        acc.csv_with_height |= t.csv_with_height;
        acc.csv_with_time  |= t.csv_with_time;
        acc.cltv_with_height |= t.cltv_with_height;
        acc.cltv_with_time |= t.cltv_with_time;
        acc.contains_combination |= t.contains_combination;
        acc
    })
}
```

- Call sites: `combine_and` = threshold 2 (`extra_props.rs:45-47`), `combine_or` = threshold 1 (L50-52); used by `and_b` (L655), `and_v` (L675), `or_b` (L703), `or_d` (L726), `or_c` (L749), `or_i` (L780), `andor` as `combine_or(combine_and(a, b), c)` (L786-809 — i.e. cross checks **only x×y**, same as Core), `threshold` (L942). Wrappers pass `timelock_info` through unchanged (`cast_alt` L504-514, etc.).
- Enforcement: `Miniscript::from_str` validates with `Ctx::SANE` (`mod.rs:1196-1200`) → `validate_non_top_level` rejects `has_mixed_timelocks()` unless `allow_mixed_time_locks` (`mod.rs:399-401`; `has_mixed_timelocks` = `timelock_info.contains_unspendable_path()`, `analyzable.rs:45`; `SANE.allow_mixed_time_locks = false`, `validation.rs:108`). `from_str_insane` uses `Ctx::CONSENSUS` (`mod.rs:972-978`) where mixes are allowed (`validation.rs:138`); such trees later fail `lift()` with `HeightTimelockCombination` and `validate(SANE)` (`mod.rs:1928-1946`).

### Equivalence verdict

**The predicates are logically equivalent up to negation**: for every node, Core's type has property `k` ⟺ rust's `timelock_info.contains_combination` is false; and the four union bits match the four leaf flags pointwise. Induction over the tree:

| Fragment class | Core rule | Rust rule | Equal? |
|---|---|---|---|
| leaf older/after | `(g\|h), k` / `(i\|j), k` | exactly one flag set, `comb=false` | ✔ |
| wrappers (a,s,c,d,v,j,n) | `x & "ghijk"` | pass-through | ✔ |
| `and_v`, `and_b` | `k_x∧k_y ∧ ¬cross(u_x,v_y)` etc. | `comb_a ∨ comb_b ∨ cross(a,b)` (threshold 2) | ✔ (De Morgan + symmetry of cross) |
| `or_b/c/d/i` | `k_x ∧ k_y`, no cross | propagate comb, no cross (threshold 1 fold) | ✔ |
| `andor(x,y,z)` | children all k ∧ ¬cross(x,y) only | `comb(and(x,y)) ∨ comb(z)`, i.e. cross(x,y) only | ✔ |
| `thresh(k, subs)` | all-children k ∧ (k≤1 ∨ no pairwise cross), via union-fold | same fold: `k>1` gate, `acc×t` cross, propagate child comb | ✔ (both skip checks at k=1; pairwise coverage via cumulative union; cross symmetric so one orientation suffices) |
| `multi/multi_a/pk/pkh/hash/0/1` | k set, ghij clear | `TimelockInfo::new()` | ✔ |

`multi`/`multi_a` contain no timelocks (`miniscript.cpp:223-228` = `"...k"`; `extra_props.rs:303, 341` = `TimelockInfo::new()`), consistent.

Corner cases (identical outcomes verified against in-tree tests):
- **abs×rel mixes are allowed** by both (cross terms only mix *within* csv-height/time or *within* cltv-height/time): Core test `miniscript_tests.cpp:567` (`andor(...,v:older(4194305 [time]),...)` … acceptable), `miniscript_tests.cpp:580`; rust has no special rule either. Rationale (both): one tx has *both* nSequence and nLockTime fields.
- `older(time) ∧ older(height)`: rejected by both — Core test `miniscript_tests.cpp:585` (`TESTMODE_TIMELOCKMIX`), rust test `mod.rs:1915-1919`.
- `after(h) ∨ after(t)`: allowed by both — Core `miniscript_tests.cpp:556`, rust `mod.rs:1922-1926`.
- `thresh(2, …, after(t), after(h))`: rejected by both — Core `miniscript_tests.cpp:592`, rust `extra_props.rs:1033-1050`.
- `thresh(1, …mixed…)`: allowed by both — Core `miniscript_tests.cpp:591`, rust same test.
- Union over-approximation granularity is identical: a node may carry *both* `g` and `h` (e.g. `or_i(older(time), older(height))`), so a later `and` against an `h`-only branch flags a mix even if dynamically avoidable. Both accept this same conservatism.
- "after with both flags" is impossible in both (threshold dichotomy).

Test assertion pinning the Core semantics: `miniscript_tests.cpp:466`:

```cpp
BOOST_CHECK_MESSAGE((node->GetType() << "k"_mst) == !(mode & TESTMODE_TIMELOCKMIX), ...);
```

---

## 4. Satisfaction semantics ("is this lock met?")

### Core — three distinct layers

1. **Abstract satisfier callback** (miniscript library): a leaf is satisfiable iff `ctx.CheckOlder(node.k)` / `ctx.CheckAfter(node.k)` returns true (`miniscript.h:1353-1358`); satisfaction witness is `EMPTY`, else `INVALID`. The library is agnostic: any predicate works.

2. **Production semantics** (real signing): `sign.cpp:463-465`
   ```cpp
   bool CheckAfter(uint32_t value) const { return m_creator.Checker().CheckLockTime(CScriptNum(value)); }
   bool CheckOlder(uint32_t value) const { return m_creator.Checker().CheckSequence(CScriptNum(value)); }
   ```
   resolved by `GenericTransactionSignatureChecker`:
   - CLTV (`interpreter.cpp:1755-1789`): unit agreement both ways vs `LOCKTIME_THRESHOLD`; `operand ≤ tx.nLockTime`; **fail if spending input's nSequence == SEQUENCE_FINAL (0xffffffff)** (L1785-1786).
   - CSV (`interpreter.cpp:1791-1836`): **fail if `tx.version < 2`** (L1800-1801); fail if tx nSequence has disable bit (L1807-1808); mask both sides with `TYPE_FLAG | MASK = 0x0040FFFF` (L1812-1814); unit agreement on masked type bit (L1823-1828); masked operand ≤ masked tx sequence (L1832).
   (The operand-level script-opcode overhead — 5-byte scriptnum, negative-operand rejection, CSV disable-NOP — is `interpreter.cpp:532-603`; unreachable miniscript-side per §1.)
   For witness-size estimation, `DummySignatureChecker` returns `true` unconditionally (`sign.cpp:953-954`).

3. **Test model** (`miniscript_tests.cpp`):
   ```cpp
   bool CheckAfter(uint32_t value) const { return supported.contains(Challenge(ChallengeType::AFTER, value)); }  // L208-210
   bool CheckOlder(uint32_t value) const { return supported.contains(Challenge(ChallengeType::OLDER, value)); }  // L213-215
   ```
   Exact-value membership — each distinct locktime value is an independent atom: **no unit logic, no ≤ monotonicity, no version/finality.** `TestSignatureChecker` forwards these verbatim into `VerifyScript` (`miniscript_tests.cpp:282-290`), so witness *verification* in tests uses the same abstract model. Consequences the harness acknowledges: a k-violating node like `and_b(after(100),a:after(1000000000))` *is satisfiable in the model* once both atoms are added (both leaves yield `EMPTY`); the suite therefore (a) asserts only the type-bit equality at L466 for such nodes and (b) skips the IsSane-gated soundness assertions (`miniscript_tests.cpp:409-431`). `FindChallenges` collects `(OLDER, n)`/`(AFTER, n)` atoms per leaf value (`miniscript_tests.cpp:309-311`).
   MTP is not modeled anywhere (Core: block-validation layer, out of scope; rust: absent).

### Rust — layers

1. **`Satisfier` trait** (abstract; defaults return false): `satisfy/mod.rs:96-110`.
2. **Built-in satisfiers** (`satisfy/mod.rs:116-138`): `Sequence::check_older(n)` = `to_relative_lock_time()` (None if disable bit ⇒ false) then `n.is_implied_by(lock)`; `RelLockTime` delegates; `absolute::LockTime::check_after(n)` = `n.is_implied_by(lock)`. Here `n.is_implied_by(avail)` = **same unit ∧ avail_value ≥ required_value** (vendored bitcoin-0.32 `absolute.rs`/`relative.rs` `is_implied_by`). This is *monotone* and *unit-aware*: `older(5)` is met when height-10 is available — unlike Core's exact-match test atoms.
3. **Leaf satisfaction**: `sat_dissat.rs:208-251` — records the actual lock used in `Satisfaction.{absolute,relative}_timelock` (`Some(t)` on success); on failure returns `Witness::Impossible` when `root_has_sig` (sig contests the locktime), else `Unavailable` (Core simply returns `INVALID`/`NO` — no MAYBE-grade for timelocks; minor representational difference in failure provenance).
4. **Dynamic combination guard**: `Satisfaction::concatenate_rev` (`satisfy/mod.rs:918-944`) joins the timelock fields with `AbsLockTime::max` / `RelLockTime::max`; **unit mismatch ⇒ `Witness::Impossible`** (primitives `absolute_locktime.rs:78-85` / `relative_locktime.rs:75-82` return `None` on unit mismatch). This is a *runtime* analog of the k/`contains_combination` rule localized to the chosen path — Core has no such mechanism (k-rule is purely static). Documented at `satisfy/mod.rs:906-917`.
5. **Interpreter** (`interpreter/stack.rs`):
   - `evaluate_after` (L205-224): enum-typed comparison — `(Blocks,Blocks)|(Seconds,Seconds) ⇒ n ≤ lock_time`; unit mismatch ⇒ `Error::AbsoluteLockTimeComparisonInvalid` (a distinct error; Core just fails CLTV with `SCRIPT_ERR_UNSATISFIED_LOCKTIME`). **No SEQUENCE_FINAL / enables-lock-time check.**
   - `evaluate_older` (L232-248): `sequence.to_relative_lock_time()` (None/disable ⇒ `RelativeLockTimeDisabled`), then `n.is_implied_by(tx_lock)`. **No `version ≥ 2` check** — the interpreter context carries only `(sequence, lock_time)` (`interpreter/mod.rs:38-39, 144-153`).
6. **PSBT-level satisfier** re-adds exactly the two missing consensus conditions (`psbt/mod.rs:326-346`): `check_after` gates on `input.enables_lock_time()` (i.e. `sequence != SEQUENCE_FINAL` — bitcoin `transaction.rs:247`), `check_older` gates on `unsigned_tx.version < 2 || !seq.is_relative_lock_time() ⇒ false`.

Thus: **rust's bare-`Satisfier`/interpreter CSV+CLTV model = Core's consensus minus {version≥2, input-not-final}, and this gap is closed only at the PSBT layer.**

Unit-agreement comparison note: rust's enum-based unit check (and error) is logically the same predicate as Core's raw-u32 threshold test: `absolute::LockTime::from_consensus` splits at the same 500,000,000 boundary, and `to_relative_lock_time` splits at the same bit 22.

---

## 5. Divergence ledger

Class legend — **SEMANTIC**: changes which (script, tx-context) pairs a consumer reports as satisfied; **MODELING**: only test/abstraction-layer meaning; **OPERATIONAL**: warning/DX only, acceptance identical; **REPRESENTATIONAL**: where/how a check is done, same net acceptance.

| # | Divergence | Core side | Rust side | Class |
|---|---|---|---|---|
| D1 | Text parse of locktime numerals: Core `ToIntegral`/`std::from_chars` accepts leading zeros (`after(01)` → 1); rust `parse_num_nonzero` requires first digit `'1'..='9'` | `miniscript.h:2026-2027, 2033-2034`; `util/strencodings.h:180-189` | `expression/mod.rs:683-702` | OPERATIONAL (console text only) |
| D2 | "Unsafe" descriptor **warning** when `older(n)` exceeds 16-bit value range (`n & ~TYPE_FLAG > 0xFFFF`); rust silent | `descriptor.cpp:1749-1763` | — | OPERATIONAL |
| D3 | CSV requires `tx.version ≥ 2`; CLTV requires spending input not final (`nSequence ≠ 0xFFFFFFFF`) | `interpreter.cpp:1800-1801`, `interpreter.cpp:1785-1786` | omitted in `interpreter/stack.rs:232-248` and `205-224` (context has only `sequence, lock_time`, `interpreter/mod.rs:38-39`); re-added only in PSBT satisfier `psbt/mod.rs:326-346` | **SEMANTIC** in the interpreter crate; REPRESENTATIONAL overall if PSBT path is the reference |
| D4 | Runtime merge of chosen-path timelocks with unit-mismatch ⇒ impossible | — (none; static k-rule only) | `satisfy/mod.rs:918-944` (`concatenate_rev` + `max`) | REPRESENTATIONAL (extra soundness guard; same ultimate property on sane scripts) |
| D5 | Test satisfier model: Core uses exact-value atoms (no monotonicity/units), rust's in-crate satisfier impls are monotone `≤` with units | `miniscript_tests.cpp:204-215, 282-290` | `satisfy/mod.rs:116-138` | MODELING — for Lean, axiomatize `check_older`/`check_after` as abstract predicates (Core view); monotonicity is a possible instantiation, not a property the harness relies on |
| D6 | Enforcement point of the mixing rule: Core's `miniscript::FromString` parses mixed scripts fine (tests: `miniscript_tests.cpp:557` etc.), rejection only at descriptor parse via `IsSane()`; rust's `Miniscript::from_str` rejects at parse (SANE), with `from_str_insane` as escape hatch | `descriptor.cpp:2745-2768`; `miniscript.h:1690,1699,1702` | `miniscript/mod.rs:1196-1200, 399-401`; `analyzable.rs:45`; `validation.rs:108`; escape: `mod.rs:972-978` | REPRESENTATIONAL |
| D7 | Failure provenance for unmet timelock leaf: Core `INVALID` (Availability::NO); rust distinguishes `Witness::Impossible` (when `root_has_sig`) vs `Unavailable` | `miniscript.h:1353-1358` | `sat_dissat.rs:208-251` | REPRESENTATIONAL |
| D8 | Error taxonomy on unit mismatch: Core `SCRIPT_ERR_UNSATISFIED_LOCKTIME`; rust distinct `AbsoluteLockTimeComparisonInvalid` | `interpreter.cpp:1764-1773` | `interpreter/stack.rs:212-216` | REPRESENTATIONAL |

Verified **non-divergences** (worth stating in the formalization as lemmas):
- Accepted domain identical: `1 ≤ n ≤ 0x7FFFFFFF` at text, AST, and script-decode levels, both impls.
- Minimal-encoding acceptance identical (minimal push + minimal scriptnum + ≤4 bytes; OP_N canonical; emission identical byte-for-byte: §1).
- Threshold and flag constants identical: 500,000,000 (`script.h:48` / bitcoin-units `LOCK_TIME_THRESHOLD`, absolute.rs note L6); bit 22 type flag (`transaction.h:100` / `transaction.rs:356`); 16-bit value mask (`transaction.h:105` / `low_u16`); bit 31 disable flag (`transaction.h:94` / `transaction.rs:354`) — unreachable at leaf level in both.
- Disable-flag, unit-mismatch, and masked-value comparisons on the tx side agree wherever both model them (post-D3 caveat).

## 6. Notes for the Lean model

1. **Types**: model `Type` as a bitset with bits `{B,V,K,W,z,o,n,d,u,e,f,s,m,x,g,h,i,j,k}` exactly per `miniscript.h:161-191`; prove `ComputeType` ≡ `ExtData.type_check` modulo the ghijk/contains_combination correspondence (§3 equivalence, incl. the `andor` x×y-only asymmetry both sides share).
2. **Mixing theorem**: state `k(node) = true ⇔ ¬comb(node)` by induction; the only non-structurally-obvious cases are `thresh` (cumulative-union fold, pairwise via symmetry of the cross term) and `andor` (x×y only).
3. **Satisfaction**: treat `checkOlder`/`checkAfter` as opaque predicates `Fin 2^31 → Bool` at leaf level (`miniscript.h:1354/1357`); soundness/completeness theorems of the satisfier should be parameterized over them (Core's library architecture literally takes a context object).
4. **Instantiation matters**: when instantiating to "consensus-accurate" predicates, rust's interpreter model is *weaker* than Core's consensus checker (D3). If the goal is a theorem parallel to Core's `IsSane ⇒ all sane satisfactions verify under consensus`, the CSV version-fence and CLTV finality conditions must be stated as hypotheses on the transaction context.
5. **5-byte window**: include `interpreter.cpp:556/584` (5-byte scriptnum) only in a raw-Script-level model; at miniscript-AST level assume the `[1, 2^31)` invariant from §1.
