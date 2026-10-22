# Resource-limit accounting: bitcoin-core vs rust-miniscript

Audience: Lean formalization of ops / stack / witness / script-size / depth limits in miniscript,
for the **P2WSH** and **Tapscript** contexts.

Trees compared (READ-ONLY review, no modifications):

- **Core** (f86c614, v32-dev): `src/script/miniscript.h` (2707 lines), `src/script/miniscript.cpp`
  (432 lines), plus `src/script/descriptor.cpp`, `src/script/interpreter.cpp`, `src/policy/policy.{h,cpp}`,
  `src/script/script.h`.
- **Rust** (96a1c91, v13.0.0): `src/miniscript/types/extra_props.rs`, `src/miniscript/limits.rs`,
  `src/miniscript/context.rs`, plus `src/miniscript/mod.rs`, `src/validation.rs`, `src/lib.rs`,
  `src/descriptor/{mod.rs,segwitv0.rs,tr/mod.rs}`, `src/expression/mod.rs`, `src/miniscript/analyzable.rs`.

Classification legend for divergences:

- **[harmless]** — no impact on which miniscripts are accepted, or differences cancel/not reachable.
- **[accept-set-differs]** — some miniscripts are accepted by one implementation and rejected by the
  other (under their respective intended entry paths).
- **[real-bug-risk]** — divergence that could mask or produce funds-freezing / policy-invalid spends.

Short answer: **the accounting *formulas* are a near-perfect 1:1 match** (ops counts, witness byte
sizes, witness item counts, script sizes, the free-verify bit). All material divergence is in
**(a) what satisfaction semantics the bounds quantify over**, **(b) over/under-approximation of the
exec-stack model**, and **(c) *where* the limits get enforced** — rust's `wsh()` descriptor parse path
never runs the local-limit checks at all, while Core's descriptor parse always requires `IsSane()`.

---

## 1. Ops counting

### 1.1 Models

| | Core | rust |
|---|---|---|
| Struct | `internal::Ops { count, sat, dsat }` (`miniscript.h:389-398`) | `ExtData::static_ops` + `SatData::max_exec_op_count` (`extra_props.rs:150, 111`) |
| Total | `GetOps() = ops.count + ops.sat` (`miniscript.h:1562-1565`) | `sat_op_count() = static_ops + sat_data.max_exec_op_count` (`extra_props.rs:1022-1025`) |
| `count` / `static_ops` meaning | non-push opcodes **in the serialized script** (both executed and non-executed branches) | same |
| `sat` / `max_exec_op_count` meaning | max number of pubkeys consumed by *executed* `OP_CHECKMULTISIG(VERIFY)` on a worst-case satisfaction path (interpreter adds `nKeysCount` per executed CMS, `interpreter.cpp:1127-1130`) | same, per-`SatData` path |
| Limit enforcement | `CheckOpsLimit()`: P2WSH only, `GetOps() ≤ 201` (`miniscript.h:1570-1575`); tapscript skips (early `return true`) | `ValidationParams::max_opcode_count`, checked in `validate_non_top_level` (`mod.rs:484-493`) and `Segwitv0::check_local_consensus_validity` (`context.rs:558-571`); Tap never sets it (`usize::MAX`) |

Grounding: the 201 consensus rule counts **statically** — `if (sigversion == BASE || WITNESS_V0) { if (opcode > OP_16 && ++nOpCount > 201) fail }` (`interpreter.cpp:460-465`) is **not** gated on `fExec`
(opcodes in non-executed branches DO count). Both implementations replicate this exactly by counting
all non-push script opcodes statically and adding the dynamic CMS key-count on the worst satisfaction
path. Tapscript never increments `nOpCount` (line 460's sigversion guard).

### 1.2 Per-fragment op counts — all identical

| fragment | Core `CalcOps` (`miniscript.h:1004-1076`) | rust ``*` / `static_ops`,`exec_ops` (`extra_props.rs`) | match |
|---|---|---|---|
| `0`/`1` | `{0,…}` (1006-1007) | 0/0 (`FALSE`/`TRUE`, 164-195) | ✓ |
| `pk_k` | `{0,0,0}` (1008) | 0 / 0 (212, 218) | ✓ |
| `pk_h` | `{3,0,0}` (1009) | 3 / 0 (248) DUP,HASH160,EQUALVERIFY | ✓ |
| `older`,`after` | `{1,0,{}}` (1010-1011) | 1 / 0 (458) | ✓ |
| hash4 | `{4,0,{}}` (1012-1015) | 4 / 0 (354 etc.) | ✓ |
| `and_v` | x+y (1016) | l+r (665) | ✓ |
| `and_b` | 1+x+y (1018) | 1+l+r (636) | ✓ |
| `or_b` | 1+x+y (1024) | 1+l+r (697) | ✓ (per task instruction, double-checked) |
| `or_c` | 2+x+y (1036) | 2+l+r (746) | ✓ |
| `or_d` | 3+x+y (1030) | 3+l+r (723) | ✓ |
| `or_i` | 3+x+y (1041) | 3+l+r (774) | ✓ |
| `andor` | 3+x+y+z (1047) | 3+a+b+c (800) | ✓ |
| `thresh` | Σ(sub.count + 1) = Σ + n (n−1 ADDs + 1 EQUAL) (1061-1073) | Σ + 1 + (n−1) (939) | ✓ equal totals |
| `multi` | `{1, n, n}` — static 1 + **n keys** exec factor, regardless of k (1052) | static 1, exec **n** (287, 294) — matches interpreter `nOpCount += nKeysCount` | ✓ |
| `multi_a` | `{n+1, 0, 0}` (1053) — n CHECKSIG[ADD] + NUMEQUAL recorded | static 0, exec 0 ("irrelevant; no ops limit in Taproot", 326, 331) | ✓ different recorded value, **both unused** (Tap exempt) → [harmless] |
| `a:` | 2+x (1057) | 2+x (508) | ✓ |
| `s:`/`c:`/`n:` | 1+x (1054-1056) | 1+x (521, 534, 609) | ✓ |
| `d:` | 3+x (1058) | 3+x (547) | ✓ |
| `j:` | 4+x (1059) | 4+x (590) | ✓ |
| `v:` | x + (sub has `x` bit) (1060) | x + `!has_free_verify` (573-577) | ✓ (§5) |

Composition rules for the dynamic part also match: `or_b sat = (x.sat+y.dsat)|(x.dsat+y.sat)`
(`miniscript.h:1025` ↔ `extra_props.rs:698-701` via `sat_concat`+`fieldwise_max_opt`), etc.
THRESH uses the same exact-solution algorithm on both sides and gets equal results: Core's knapsack DP
(`miniscript.h:1061-1073`) vs rust's sort-by-(sat−dissat)-take-top-k greedy (`extra_props.rs:894-909`;
optimal for additive fields, so equal for ops).

### 1.3 Divergences

- **D-OPS-1 [accept-set-differs][real-bug-risk on wsh descriptor path]**: *enforcement coverage*.
  Core rejects >201-op P2WSH miniscripts at descriptor parse time unconditionally
  (`descriptor.cpp:2745` requires `node->IsSane()` → `CheckOpsLimit()`).
  Rust enforces the 201 check only inside `Miniscript::validate(params)` (`mod.rs:484-493`), reached by
  `Miniscript::from_str` (SANE params, `mod.rs:1196-1199`) — **but the descriptor-string path
  (`Descriptor::from_str` → `Wsh::from_tree`, `segwitv0.rs:184-194`) only runs `top_level_checks`
  (multipath-length only) plus per-node `check_global_validity` (script size + key type);
  it never calls `validate()`**. Verified empirically (Appendix A, test B): a 203-op P2WSH miniscript
  is rejected by `Miniscript<_,Segwitv0>::from_str` with `MaxOpCountExceeded { actual: 203, limit: 201 }`
  (count matches Core's model: 101×`v:older`×2 + 1 `CHECKSIG` = 203) but **accepted** as
  `Descriptor::from_str("wsh(...)")`. Such a script is unspendable at consensus → funds frozen.
  (The same gap covers the 100-item, 1000-exec-stack, non-malleability, no-sigless-branch, and
  duplicate-key checks; see §6.)

- **D-OPS-2 [harmless]**: tapscript 201-limit ⇔ sigops budget. Both treat Tap identically in effect:
  Core's `CheckOpsLimit` short-circuits to `true` (`miniscript.h:1571-1572`); rust's Tap params leave
  `max_opcode_count = usize::MAX` (`context.rs:622-635`), justified by the BIP342 sigops-budget
  argument documented at `context.rs:695-703` (every executed CHECKSIG[ADD] spends 50 budget from a
  `witness_size+50` budget, and miniscript typing forces unique sigs per CHECKSIG). Core has no such
  comment but shares the semantics. The `multi_a` static-op record differs (n+1 vs 0) but is dead
  code on both sides.

- `or_b`/`multi`/thresh ops counting confirmed bit-identical (table above); no [real-bug-risk] found
  in the ops formulas themselves.

---

## 2. Stack & witness accounting

### 2.1 Models

**Core** tracks *three* bottom-up quantities per node (`miniscript.h:594-599` cache):
- `ops` (§1),
- `ss: StackSize { sat, dsat : SatInfo }` — an exact semiring over execution traces:
  `SatInfo { netdiff, exec }` where sat/dsat are tracked as *scripts' stack effects*
  (`miniscript.h:400-505`; `|`, `+` at 463-481). Only **canonical non-malleable** traces contribute:
  e.g. hash dissatisfactions are INVALID here (see D-STACK-2).
  `GetStackSize() = ss.sat.netdiff + isBKVW(top)` (1583-1586) = worst-case *initial witness items*;
  `GetExecStackSize() = ss.sat.exec + isBKVW` (1589-1592) = exact worst-case *max combined stack+alt
  height during execution, including the initial witness* (altstack moves are count-neutral).
- `ws: WitnessSize { sat, dsat : MaxInt<uint32_t> }` — witness **bytes** only (519-526, 1193-1244).
  Used for fee/weight estimation (`GetWitnessSize`, 1611-1614; descriptor `MaxSatSize`,
  `descriptor.cpp:1785-1789`). Note per comment: excludes the witness-script push.

**rust** tracks per sat/dissat one `SatData` (`extra_props.rs:93-112`):
`max_witness_stack_size` (bytes), `max_witness_stack_count` (items, *excludes* script push),
`max_script_sig_size` (legacy-only dimension, no Core analog), `max_exec_stack_count`
(*excludes* initial witness items), `max_exec_op_count` (§1).

Structural consequence: Core's `exec` is an **exact** value over traces; rust composes
`max_witness_stack_count + max_exec_stack_count` **(max+max, possibly attained on different
branches/points)** — a sound over-approximation.

### 2.2 Leaf and combinator formulas

Witness **byte** sizes: sig = 73 P2WSH / 66 Tap both sides (Core `1+72`/`1+65`,
`miniscript.h:1194-1195`; rust 73/66, `extra_props.rs:204-206`); pubkey 34/33 both (1195; 205-207).
Per-fragment equality verified:

| fragment | Core `CalcWitnessSize` (`miniscript.h`) | rust `SatData` (`extra_props.rs`) | match |
|---|---|---|---|
| `pk_k` | sat 73/66, dsat 1 (1201) | same (213-226) | ✓ |
| `pk_h` | sat sig+pub, dsat 1+pub (1202) | same (249-262) | ✓ |
| hash4 | sat 33, **dsat INVALID** (1203-1206) | sat 33, **dsat Some(33)** (362-368 etc.) | ✗ D-STACK-2 |
| `older`/`after`/`1` | sat 0, dsat inv (1198-1200) | sat 0, `dissat: None` (after 466; older 490-491) | ✓ |
| `0` | sat inv, dsat 0 | same | ✓ |
| `multi` | sat `k·73+1`, dsat `k+1` (1222) | `1+73k` / `1+k` (289-299) | ✓ |
| `multi_a` | sat `66k + (n−k)`, dsat `n` (1223) | same (328-335) | ✓ |
| `or_i` | true-branch push +2 bytes, false +1 (1221) | `with_1` +2/+1, `with_0`+1/+1 (756-769) | ✓ |
| `d:` | sat +2, dsat 1 (1228) | sat +2 size/+1 count, dissat 1/1 (548-565) | ✓ |
| `j:` | sat pass, dsat 1 (1230) | same (591-598) | ✓ |
| `or_b`,`or_c`,`or_d`,`and_b`,`and_v`,`andor`, `a:`/`s:`/`c:`/`n:`/`v:` passthrough | (1207-1229) | (637-812) | ✓ formulas 1:1 |
| `thresh` | DP over `(dsat_i, sat_i)` (1231-1241) | sort-top-k greedy per field, equal optimum (815-945) | ✓ equal result |

Witness **item** counts: compared indirectly through Core's `netdiff` traces; per-fragment equality
holds for every fragment (`pk_h` attributes the sig item at the leaf in rust vs at `c:`-time in Core,
`extra_props.rs:251` vs `miniscript.h:1151-1154`+`1086`; totals agree at top level). `multi`: both
`k+1`; `multi_a`: both `n`; `d:` +1 both; `or_i` selector +1 both (1221 for bytes; ss 1134-1138).

Exec-stack fragments of note:
- `multi`: Core `SatInfo(k, k+n+2)` (1139-1143, exact: k+1 witness + k/n number pushes + n key pushes,
  max k+n+3 above final 1). rust `max_exec_stack_count = n` ("n pks", 292) → rust's bound
  `count+exec = k+n+1` **under-counts the true max stack by 2** (the two number pushes).
  → **D-STACK-3**, but only feeds rust's Segwitv0 1000-exec check which is unreachable in P2WSH
  (≤100 items + ≤201 single-push ops ⇒ ≲ 300): **[harmless]** under-estimate, unreachable; Core never
  uses an exec value for `multi` (P2WSH checks initial size only) so no acceptance difference.
- `multi_a`: Core `SatInfo(n−1, n)` (1144-1147, exact; true max = n+1 incl. final). rust
  `exec = 2` ("the two nums before num equal verify", 331) + `count = n` ⇒ rust bound n+2 vs Core's
  exact n+1: rust **over-counts by 1**. See D-STACK-1 for the boundary consequence.
- `or_i`: Core exact (`SatInfo::If()` union, 1134-1138); rust takes `fieldwise_max` of the branches
  (760,767,775) while adding +1 witness count ⇒ rust ≥ Core, sometimes strictly.
- `thresh` exec: Core DP with exact `SatInfo` composition (1164-1188); rust heuristic accumulator
  `max(acc, x + (acc>0))` approximating "accumulator sits on stack for children 2..n"
  (`extra_props.rs:879-887`) — not provably the exact trace maximum; over-approximate in mixed cases.
- `and_b` exec: rust `max(l.exec, 1+r.exec)` (643, 652) matches Core's binary-op concatenation
  model (1108-1112) modulo the exclude/include-initial-witness bookkeeping.

**Witness byte size limits at miniscript level: none in either** for P2WSH or Tapscript
(Core checks only ops + stack counts; rust checks only ops + item counts + exec sum). Both use the
byte sizes only for fee/weight estimation APIs. ScriptSig/max 1650 etc.: rust Legacy-only,
not applicable here; Core's lean tree supports only P2WSH/Tapscript (`miniscript.h:253-256`).

### 2.3 Accept-relevant checks, P2WSH

| limit | Core | rust | relation |
|---|---|---|---|
| initial witness items ≤ 100 (standardness) | `CheckStackSize()`: `GetStackSize() ≤ 100`, **script push NOT counted** (`miniscript.h:1594-1604`) | `Segwitv0::check_local_policy_validity` + `validate`: `max_satisfaction_witness_elements() = count + 1` **includes script push** (`mod.rs:586-591`; `context.rs:585-602`) | **D-STACK-4 [accept-set-differs]**, rust *stricter by one* |
| exec-time stack ≤ 1000 (consensus) | not checked for P2WSH in miniscript (unreachable: ≤100 items, ≤201 ops) | `validate`: `count + exec ≤ 1000` (from `Segwitv0::CONSENSUS.max_exec_stack_size`, `context.rs:499`; `mod.rs:495-506`) | rust-only belt, unreachable → [harmless] |

**D-STACK-4 analysis**: the actual standardness rule, `policy.cpp:308-318`, computes
`sizeWitnessStack = txin.scriptWitness.stack.size() - 1` (the −1 *excludes* the witness script push)
and compares `> 100`. A miniscript whose satisfaction needs exactly **100 input items** is therefore
standard (101-item stack − 1 script = 100 ≤ 100). Core's check (`≤100` without +1) implements policy
exactly. rust counts the script (`+1` is *correct* for its other consumer, `varint_len` sizing in
weight estimation — `segwitv0.rs:72-77`) and so rejects the legitimate exactly-100 case:
`and_v(v:pk, ×99 …, pk)` (100 sigs, script 3,500 bytes ≤ 3600, ops 100 ≤ 201) — verified: rust SANE
rejects with `MaxWitnessItemsExceeded { actual: 101, limit: 100 }`, Core accepts (100 ≤ 100),
mempool accepts (101−1 = 100). **[accept-set-differs]** (rust over-conservative, never dangerous).

Note the dual-use odor: rust's `max_satisfaction_witness_elements()` exists for the *size of the
element-count varint in a serialized tx* (where +1 is right) and is also reused for the *standardness
limit* (where +1 is wrong by one).

### 2.4 Accept-relevant checks, Tapscript

| limit | Core | rust | relation |
|---|---|---|---|
| stack+altstack ≤ 1000 during exec (consensus, `interpreter.cpp:1232`; initial ≤ 1000, `1864-1865`) | `CheckStackSize()`: tapscript branch uses exact `GetExecStackSize() ≤ 1000` (`miniscript.h:1594-1604`) | `validate`/Tap::SANE: `max_witness_stack_count + max_exec_stack_count > 1000` (`context.rs:704-711`; `mod.rs:495-506`) | **D-STACK-1 [accept-set-differs]**, rust stricter (over-approx) |

**D-STACK-1 boundary case**: `multi_a(k, 999 keys)`. Core: `GetExecStackSize = 999 + 1 = 1000 ≤ 1000`
→ accept; true consensus trace peaks at exactly 1000 (999 witness items + 1 key push) → valid.
rust: `999 + 2 = 1001 > 1000` → **reject**. Verified: rust rejects `multi_a(999, 999 keys)`,
accepts 998 keys. Over-estimation sources: `multi_a` exec slack 2-vs-1 (`extra_props.rs:331`) and the
general max(witness)+max(exec) decomposition (`mod.rs:499`). Same divergence shape arises for deep
`or_i`/`thresh` combinations near the 1000 boundary.

Observation (shared blind spot, **not** a divergence): both models fold altstack into the accounting
transparently and correctly for the combined stack+alt consensus rule (`a:` passthrough in Core ss
1150 and in rust 509-510) — TOALTSTACK only *moves* an element, so the combined bound is unchanged.
✓ both sound.

### 2.5 Reporting-only quantities

- Core descriptor `WSHDescriptor::MaxSatisfactionElems/MaxSatSize` adds the witness script
  (`descriptor.cpp:1525-1541`), giving the same API-level totals as rust
  `Wsh::max_weight_to_satisfy` (`segwitv0.rs:66-80`).
- **D-STACK-5 [harmless]**: `TRDescriptor::MaxSatisfactionWeight/MaxSatisfactionElems`
  **assume key-path** (`descriptor.cpp:1616-1624`, marked `FIXME: can lead to very large
  underestimations`), while rust `Tr::max_weight_to_satisfy` computes the max over leaves incl.
  control block (`descriptor/tr/mod.rs:152-194`). Estimation-only; known-FIXME upstream.
- **D-STACK-2 [harmless]**: hash dsat INVALID vs Some(33). Core's `ss`/`ws` model only
  *canonical non-malleable* traces; a hash dissatisfaction (32-byte zero preimage) is malleable
  by construction, so Core excludes it (`miniscript.h:1090-1093`, `1203-1206`). rust includes it
  (`extra_props.rs:362-369`). Consequence: for trees where the max-size satisfaction path
  dissatisfies a hash — all necessarily non-`e`/non-`m`, i.e. **insane and rejected by both** at the
  sane tiers — reported maxima differ. Verified: `or_b(sha256(H),a:pk(K))`: Core `GetWitnessSize()=34`
  (only the sat-hash+dsat-pk path), rust `max_satisfaction_size()=106` (includes the malleable
  dsat-hash + sig path). No accept-set effect because both reject such miniscripts anyway;
  matters only when comparing `decode_consensus`-tier estimates. For the Lean model: Core's `ws/ss.dsat`
  is "worst-case *non-malleable* (dis)satisfaction", rust's is "worst-case over both".

---

## 3. Script size limits

| limit | Core | rust |
|---|---|---|
| P2WSH ≤ 3600 (standardness) | `IsValid()` ⇔ `ScriptSize() ≤ MaxScriptSize(ctx)` (`miniscript.h:1675-1678`, `284-296`: returns `MAX_STANDARD_P2WSH_SCRIPT_SIZE`); enforced per-node during string parse via incremental accounting `script_size > max_size` bail (`miniscript.h:1868-1873, 1915`) and pre-parse bail in `FromScript` (`2695`) | per-node during parse: `check_global_policy_validity`: `pk_cost > 3600` (`context.rs:573-583`); and at `validate()`: `script_size() > params.max_script_size` (`mod.rs:463-468`, SANE=3600 `context.rs:502-505`) |
| witness-script ≤ 10000 (consensus, `script.h:26-31` via interpreter `EvalScript` guard `interpreter.cpp:438-440`) | **not separately enforced in miniscript.h** (3600 check subsumes it; no consensus-tier entry point) | yes: `check_global_consensus_validity`: `pk_cost > MAX_SCRIPT_SIZE` (`context.rs:525-556`) — a distinct weaker tier used by `decode_consensus` |
| Tapscript | `MaxScriptSize(TAPSCRIPT) =` **329,482 bytes** (`miniscript.h:271-296`): `400000 (MAX_STANDARD_TX_WEIGHT, policy.h:38) − 378 (TX_BODY_LEEWAY_WEIGHT = (8+1+41+1+43)·4+2) − 70135 (MAX_TAPSCRIPT_SAT_SIZE = compactsize(1000) + 66·1000 + compactsize(4129) + 4129, where 4129 = TAPROOT_CONTROL_MAX_SIZE = 33+32·128, interpreter.h:247) − compactsize(329487)=5` | **4,000,000 weight-equivalent bytes**: `check_global_consensus_validity`: `pk_cost as u64 > Weight::MAX_BLOCK.to_wu()` (`context.rs:671-687`); SANE leaves `max_script_size=usize::MAX` — i.e. **no policy limit** |

**D-SIZE-1 [accept-set-differs]** (Tapscript): Core enforces ≤ 329,482 bytes for descriptor acceptance;
rust allows up to 4,000,000. Any rust-building descriptor of size 329,483..4,000,000 is Core-invalid.
(Core's bound is a *standardness* sufficiency bound for spendability under 400k-weight txs; rust
defers to the block limit deliberately — comments `context.rs:673-678`. Different design choices,
both "safe" w.r.t. consensus; the practical accept sets differ hugely at the extreme end.)

**D-SIZE-2 [harmless]**: `multi_a` size accounting: rust `pk_cost = num_cost + 33n + (n−1) + 1`
(`extra_props.rs:317-324`), Core `= 34n + BuildScript(k).size() + 1` (`miniscript.cpp:278`).
For `k ≤ 16 < n` rust counts +1 too many (num_cost 3 vs needed 2); for `16 < k ≤ 127` also +1
(4 vs 3); equal elsewhere. Since rust's only size gate for Tap multi_a is the 4M check, the
over-count is absorbed → harmless today; would matter if a tighter Tap limit were added.
(P2WSH `multi` sizes are byte-identical, `miniscript.cpp:277` ↔ `extra_props.rs:273-285`.)

Script-size *formulas*: `ScriptSize()` (`ComputeScriptLen`, `miniscript.cpp:264-296` — the authoritative
values; the odd-looking Parse-time deltas in `miniscript.h:1860-2060` are an internal "borrow 1"
accounting scheme, `assert`-reconciled against `ScriptSize()` at `miniscript.h:2206`) vs rust
`pk_cost` (extra_props) and `script_size()` (`mod.rs:537-577`). Per-fragment table — all equal
(except D-SIZE-2):

| fragment | bytes | both |
|---|---|---|
| `0`,`1` | 1 | ✓ |
| `pk_k` | 34 P2WSH / 33 Tap | ✓ (`miniscript.cpp:269` ↔ `extra_props.rs:203-207`) |
| `pk_h` | 24 | ✓ (`270` ↔ `246`) |
| `older`/`after` | `1 + sizeof(k)` minimal-scriptnum | ✓ (`271-272` ↔ `456,481`) |
| `sha256`,`hash256` | 39 (`4+2+33`) | ✓ (`273-274` ↔ `352`) |
| `ripemd160`,`hash160` | 27 (`4+2+21`) | ✓ (`275-276` ↔ `404,431`) |
| `and_v`,`v:`(free) | +0 | ✓ (`279` ↔ `555,664`) |
| `a:` +2, `s:`/`c:`/`n:`/`and_b`/`or_b` +1, `or_c` +2, `d:`/`or_d`/`or_i`/`andor` +3, `j:` +4 | ✓ (`281-292` ↔ `506-590, 688-792`) |
| `thresh` | `Σ subs + n + sizeof(k)` | ✓ (`293` ↔ `819,937`) |
| 520-byte rule | n/a: Core-lean has no Legacy miniscript ctx (`miniscript.h:253-256`) | rust Legacy: `pk_cost ≤ 520` (`context.rs:403-434`) — out of the two requested contexts |

---

## 4. Tree height / recursion limits

| | Core | rust |
|---|---|---|
| limit | **none** | **402** (`MAX_RECURSION_DEPTH`, `lib.rs:499`; history note sipa/miniscript#5) |
| enforcement | n/a (fully iterative: `TreeEval` `miniscript.h:651-757;` iterative destructor `550-569`; parser uses explicit stacks) | (a) syntactic paren-depth cap in `expression::Tree::from_str` (`expression/mod.rs:593-596`); (b) per-node at construction `from_ast` (`mod.rs:326-329`); (c) `validate_non_top_level` (`mod.rs:391-395`) |
| metric | n/a | `tree_height`: leaves 0, wrappers +1, combinators 1+max(child) (`extra_props.rs:157-159, 512-943`) |

**D-TREE-1 [accept-set-differs]**. Deep trees: rust rejects >402, Core accepts unboundedly.
Reachable within all other limits: `and_v` adds **0 bytes** (`miniscript.cpp:279`; rust `mod.rs:543`);
e.g. 500-deep `and_v(t:…,…)` chains or wrapper chains (`a:`=2B/level; 403 levels ≈ 806 bytes ≪ 3600)
parse fine in Core and fail in rust at the 402 cap. Classified [accept-set-differs] but **deliberate
protective difference**: rust still has recursive drop/traversal structures and caps depth for stack
safety; Core eliminated recursion so it needs no cap. Not a "bug" on either side; a porting caveat
(Tapscript leaf scripts can legitimately exceed 402 depth within Core's limits).

Direction note: rust's tree_height also counts `t:`/`l:`/`u:` sugar as real nodes (they ARE real nodes
in both ASTs — Core models them as `AND_V(·,JUST_1)` / `OR_I`) ✓ consistent meaning of "height".

---

## 5. `pk_cost` and the free-verify bit (`x` ↔ `has_free_verify`)

**Exact inverse mapping verified fragment-by-fragment** — Core's type property `x` ("last opcode is
not EQUAL/CHECKSIG/CHECKMULTISIG/NUMEQUAL", `miniscript.h:108-113, 180`) ⇔ **¬** rust's
`has_free_verify` (`extra_props.rs:146-147`):

| fragment | Core has `x`? | rust `has_free_verify`? |
|---|---|---|
| `pk_h`,`older`,`after`,`0`,`1` (`Konudemsxk`/`Knudemsxk`/`Bzfmxk`, `miniscript.cpp:89-104`) | yes | false (211,247,457,482,166,183) |
| hashes (`Bonudmk`, `99-102`) | **no** | **true** (353 etc.) |
| `multi` (`Bnudemsk`, `224`), `multi_a` (`Budemsk`, `227`), `thresh` (`Bdu…`, `252`) | no | true (286, 325, 938) |
| `c:` (`114-118`: no x added) | no | true (533) |
| `a:` (adds `x`, `105-109`), `d:` (`ndx`,`127`), `j:` (`ndx`,`138`), `n:` (`ux`,`142`), `v:` (`fx`,`132`) | yes | false (507,546,576,589,608) |
| `s:` (inherits x, `110-113`) | = child | = child (520) |
| `and_v` (`(y & "ux")`,`150`) | = right child | `r.has_free_verify` (664) |
| `and_b`,`or_*`,`andor` (`ux`/`dux`/`x`,`165-216`) | yes | false (635,696,722,745,773,799) |

Consequences verified equal:
- **byte cost of `v:`**: Core `ComputeScriptLen` WRAP_V `subsize + x_bit` (`miniscript.cpp:280`),
  parser-delta identical (`miniscript.h:2117`); rust `cast_verify`: `+ !has_free_verify`
  (`extra_props.rs:573-577`) and `script_size()` (`mod.rs:555`).
- **op cost of `v:`**: Core `ops.count + x_bit` (`miniscript.h:1060`); rust `verify_cost + static_ops`
  (`extra_props.rs:577`).
- **script emission**: both merge into `CHECKSIGVERIFY`/`CHECKMULTISIGVERIFY`/`EQUALVERIFY`/
  `NUMEQUALVERIFY` when free (Core `ToScript` upfn `miniscript.h:816-834` with the
  propagate-through-`and_v`-right/WRAP_S downfn at `803-811`; rust `Terminal::Verify` encode keyed
  on `sub.ext.has_free_verify`). The `v:` (as well as `t:`/`l:`/`u:`) accounting equivalence means no
  acceptance divergence via the 201-op or 3600-byte rules.

**Consequence on `v:` acceptance: none.** One cosmetic asymmetry: Core's string parser rejects the
literal wrapper string `…vv…:` early (`miniscript.h:1953-1956`), because `v:` adds no byte when free
and would evade its incremental size accounting; rust rejects double-`v` only at type-check
(`Verify` requires B child; a `Verify` node is V-typed) — same accepted set.

Also equivalent by construction: `has_free_verify` of `v:X` = false in rust / V-nodes always have `x`
in Core — nested free-verify chaining is impossible in both.

---

## 6. Adjacent non-formula findings (out of strict limits scope, listed for completeness)

1. **[accept-set-differs][real-bug-risk] rust wsh()/sh() descriptor parse skips all local sanity.**
   As shown in §1.3/D-OPS-1: `Wsh::from_tree` (`segwitv0.rs:184-194`) never calls
   `Miniscript::validate`; only the `tr()` path gets a post-hoc `Tap::SANE` validate per leaf
   (`descriptor/mod.rs:1170-1177`; leaf construction itself used `Tap::CONSENSUS`-tier params at
   `descriptor/tr/mod.rs:378-385`). Verified: `Descriptor::from_str("wsh(older(1))")` **accepted**
   (Core: rejected, "witnesses without signature exist"), `wsh(` 203-op script `)` **accepted**
   (Core: rejected via `CheckOpsLimit`), 100-item witness **accepted** past SANE. Notably, rust's
   *direct* `Miniscript::from_str` (SANE) does reject all three — so rust has two different accept
   sets for P2WSH miniscript depending on the entry path; Core has one (`descriptor.cpp:2745`,
   `2950`).
2. **[accept-set-differs][harmless corner] Top-level satisfiability.** Core:
   `!node->IsSane() || node->IsNotSatisfiable()` → rejected (`descriptor.cpp:2745`)
   (`IsNotSatisfiable` = no satisfaction exists, `miniscript.h:1607`). rust:
   `ValidationParams::SANE` (and CONSENSUS) deliberately set `allow_unsatisfiable: true`
   (FIXME, `validation.rs:116-118, 146-147`) → `wsh(0)`-style unsatisfiable scripts parse.
3. **[harmless, cosmetic rust bug]** In `validate_non_top_level`, the exec-stack error reports
   `actual: sat_data.max_witness_stack_size + sat_data.max_exec_stack_count` (**bytes** + items)
   while the comparison uses `max_witness_stack_count` (`mod.rs:499-504`). Verified:
   `multi_a(999,999)` error claims "65936 items on the stack" (999·66+2). Reporting-only.
4. **[harmless] Core `multi` exec tracking vs rust undercount** — §2.2 D-STACK-3; unreachable.
5. **[reporting-only] `TrDescriptor` key-path-assumption FIXME vs rust per-leaf max** — §2.5 D-STACK-5.
6. Both cap `multi` keys at 20 (P2WSH) and `multi_a` keys at 999 identically
   (`script.h:35,38`; `limits.rs:35,38`; parse checks `miniscript.h:1879-1902`,
   decode `2384`/`2404,2418`; Core construction-time `miniscript.cpp:75-80`), and forbid
   cross-context (`multi` in tap / `multi_a` in v0) in both (`miniscript.h:1879-1881`;
   `context.rs` `allow_multi`/`allow_multi_a`, enforced per-node during parse — this one **is**
   checked on the descriptor path on both sides).

---

## 7. Summary table of divergences

| # | topic | Core location | rust location | kind | direction |
|---|---|---|---|---|---|
| D-OPS-1 | 201-ops / 100-items / 1000-exec / dup-key / sigless / malleability not enforced on `wsh()` descriptor parse | `descriptor.cpp:2745` (always checked) | `segwitv0.rs:184-194` (never checked) | **accept-set-differs / real-bug-risk** | rust lax |
| D-OPS-2 | tapscript: no 201; sigops-budget argument | `miniscript.h:1571-1575` | `context.rs:695-703` | none (aligned) | — |
| D-STACK-1 | Tap 1000-exec: exact semiring vs max+max over-approx; `multi_a` slack | `miniscript.h:1139-1147, 1588-1592` | `extra_props.rs:331`, `mod.rs:495-506` | **accept-set-differs** (e.g. `multi_a(*,999)`) | rust strict |
| D-STACK-2 | hash dsat excluded (non-malleable-only bounds) vs included | `miniscript.h:1090-1093, 1203-1206` | `extra_props.rs:362-368` | harmless (insane trees only) | — |
| D-STACK-3 | `multi` exec: exact vs −2 undercount | `miniscript.h:1143` | `extra_props.rs:292` | harmless (unreachable) | — |
| D-STACK-4 | P2WSH 100 items: script push excluded vs included | `miniscript.h:1594-1604`; policy `policy.cpp:308-318` supports Core | `mod.rs:586-591` (+1) | **accept-set-differs** (exactly 100 items) | rust strict |
| D-STACK-5 | `tr()` descriptor: key-path-only estimate FIXME vs per-leaf max | `descriptor.cpp:1616-1624` | `descriptor/tr/mod.rs:152-194` | harmless (estimation API) | — |
| D-SIZE-1 | tapscript max script size 329,482 vs 4,000,000 | `miniscript.h:271-296` | `context.rs:671-687` | **accept-set-differs** | Core strict |
| D-SIZE-2 | `multi_a` pk_cost +1 for `k≤16<n` or `16<k≤127` | `miniscript.cpp:278` | `extra_props.rs:317-324` | harmless (absorbed by D-SIZE-1) | — |
| D-SIZE-3 | consensus-tier 10000 limit exists only in rust (decode_consensus) | n/a (only 3600 tier) | `context.rs:525-556` | accept-set-differs (decode tier only) | rust lax |
| D-TREE-1 | tree recursion: unlimited vs 402 | iterative impl `miniscript.h:550-757` | `lib.rs:499`, `mod.rs:327`, `391` | **accept-set-differs** | rust strict |
| D-PK-0 | `x` ⇔ ¬`has_free_verify` mapping, `v:` cost | `miniscript.cpp` type table, `miniscript.h:1060` | `extra_props.rs` cast/fragment constants | none (verified identical) | — |

Empirical verification scripts: Appendix A (below) — rust side verified against this checkout
(`cargo 1.95.0`, `miniscript 13.0.0`); Core behavior established by code reading (no build performed)
and cross-checked against `src/test/fuzz/miniscript.cpp:1117-1137` assertions which encode the same
semantics (`stack_nonmal.size() ≤ GetStackSize()+1+is_tapscript`, `wit_size ≤ GetWitnessSize()`).

## Appendix A — empirical checks run against the local rust-miniscript checkout

Harness: scratch crate `/tmp/opencode/ms-check` (path dep on this checkout).

| test | input | `Miniscript::from_str` (SANE) | `Descriptor::from_str` |
|---|---|---|---|
| sigless | `wsh(older(1))` | Err `Validation(SiglessBranch)` | **OK** ← Core rejects |
| 203 ops | `wsh(and_v(v:older… ×101 …, pk(G)))` | Err `MaxOpCountExceeded{203, 201}` | **OK** ← Core rejects |
| 100 sigs | `wsh(and_v(v:pk ×99, pk))` | Err `MaxWitnessItemsExceeded{101, 100}` (D-STACK-4) | **OK**; Core also accepts |
| 99 sigs | same ×99 | OK (boundary) | OK |
| Tap exec edge | `multi_a(999, 999 valid keys)` | **rejected** (`count+exec = 1001 > 1000`; error text shows mislabeled `65936`) — Core accepts (=1000 exactly) | n/a |
| Tap exec ok | `multi_a(998, 998 keys)` | OK — Core accepts | n/a |
| hash-dsat bound | `or_b(sha256(H),a:pk(G))` via `from_str_insane` | `max_satisfaction_size = 106`, elems 3 — Core's `GetWitnessSize() = 34` (excludes malleable path) | n/a |
