# Bitcoin Core `src/test/miniscript_tests.cpp` — in-depth analysis

File analyzed: `bitcoin-core/src/test/miniscript_tests.cpp` (780 lines, repo at commit `f86c614`).
All `file:line` refs below are relative to `bitcoin-core/`; `ms_h:` = `src/script/miniscript.h`,
`ms_t:` = `src/test/miniscript_tests.cpp`, `fuzz:` = `src/test/fuzz/miniscript.cpp`.

## 0. Important scope correction

The current file does **not** contain a `TestNode` class, a `SatType` enum, `TestTimelock`
helpers, or random miniscript *generation*. Those belonged to the 2019–2023 revision of this
test file; in current master they live elsewhere:

- `TestNode` → a free function in the fuzz harness: `fuzz:1030-1193` (driven by `GenNode` at
  `fuzz:854` + type-directed generators `ConsumeNodeStable` `fuzz:387` / `ConsumeNodeSmart`
  `fuzz:771`). See §8.
- The reference satisfaction algorithm (`SatType`-style annotated satisfy/dissatisfy logic) →
  the production implementation `Node::ProduceInput` / `Node::Satisfy`: `ms_h:1246-1492` and
  `ms_h:1708-1714`, with the solution-choice operator in `src/script/miniscript.cpp:325-366`.
  This test file *exercises and cross-checks* that algorithm via abstract mock contexts (§2).

What remains in `miniscript_tests.cpp` proper: (a) the abstract satisfaction model
(`TestData`/`Challenge`/`Satisfier`/`TestSignatureChecker`), (b) the randomized driver
`TestSatisfy` that enumerates challenge subsets, (c) the `Test()` assertion harness, and
(d) ~100 handwritten fixed vectors, incl. the timelock-mix cases.

---

## 1. The abstract satisfaction model inside the test file

### 1.1 `TestData` (ms_t:31-104)
Deterministic shared fixtures, built once in `g_testdata` (ms_t:107, reset at 503/741):

- 255 keypairs derived from `keydata[31] = i` (ms_t:59-62) — the same 32 bytes double as hash
  preimages ("31 zero bytes plus any nonzero byte", ms_t:60).
- All signatures sign one constant `MESSAGE_HASH` (ms_t:54); ECDSA sigs get a `0x01` sighash
  byte appended (ms_t:80), Schnorr sigs are padded to 65 bytes with sighash byte (ms_t:82-84).
- 255 preimages each for SHA256 / HASH256 / RIPEMD160 / HASH160 with reverse maps
  `*_preimages` (ms_t:86-101).

### 1.2 `ChallengeType` / `ChallengeNumber` / `Challenge` (ms_t:109-127)
```cpp
enum class ChallengeType { SHA256, RIPEMD160, HASH256, HASH160, OLDER, AFTER, PK };
```
A "challenge" abstracts *any* satisfiability precondition. Identification:
- pubkey → last 4 bytes (`ReadLE32(pubkey.data() + 29)`, ms_t:123)
- hash → first 4 bytes (ms_t:124)
- timelocks → the lock value `k` itself (used in `FindChallenges`, ms_t:310-311)

`FindChallenges` (ms_t:298-323) collects them via an explicit-stack iterative DFS over the
node tree — no recursion, matching the stack-safety theme of `node_stress_stack`.

### 1.3 `KeyConverter` (ms_t:130-197)
The `Ctx` policy bridge: context-dependent key serialization (33-byte compressed for P2WSH,
32-byte x-only for Tapscript, ms_t:142-148), `pk_h` via precomputed `pkhashes` /
`xonly_pkhashes` (ms_t:151-159), script-side key recovery with even-Y normalization for
x-only keys (`GetEvenCorrespondingCPubKey`, ms_t:176-179).

### 1.4 `Satisfier` (ms_t:200-253) — abstract "signer + chain state"
```cpp
struct Satisfier : KeyConverter {
    std::set<Challenge> supported;              // ms_t:205 — the entire world model
    bool CheckAfter(v) { return supported.contains({AFTER, v}); }   // 208-210
    bool CheckOlder(v) { return supported.contains({OLDER, v}); }   // 213-215
    Availability Sign(key, sig);                // 218-232  YES iff {PK, ChallengeNumber(key)} ∈ supported
    Availability SatHash(hash, preimage, type); // 235-246  YES iff challenge supported ∧ preimage known
    SatSHA256 / SatRIPEMD160 / SatHASH256 / SatHASH160  // 249-252
};
```
Deliberately simplified semantics, stated in comments at ms_t:207/212: **exact-match** CLTV/CSV
— a timelock is "satisfied" iff its *exact value* is in `supported`. No `nLockTime ≥ v` logic,
no 500,000,000 height/time threshold discrimination, no `SEQUENCE_LOCKTIME_DISABLE_FLAG`.
`Sign` returns the *precomputed* signature (ECDSA or Schnorr per context) rather than signing.
So signatures, preimages and timelocks are all modeled as opaque capabilities toggled by
set membership. (`Availability::MAYBE`, used by production code for dummy-size estimation, is
never returned here — only YES/NO.)

### 1.5 `TestSignatureChecker` (ms_t:259-291)
A `BaseSignatureChecker` mocking consensus signature/timelock *verification* against the same
model, so that the real `VerifyScript` interpreter can be run end-to-end:
- `CheckECDSASignature` / `CheckSchnorrSignature`: **byte-equality** with the precomputed sig
  for that key (ms_t:268-272, 274-280) — no real secp256k1 verification.
- `CheckLockTime`/`CheckSequence` delegate to `Satisfier::CheckAfter/CheckOlder` (ms_t:282-290).

### 1.6 Output wrapping (ms_t:326-343)
`ScriptPubKey`: P2WSH → `OP_0 <sha256(script)>` (ms_t:328); Tapscript → single-leaf tree under
the NUMS internal key (ms_t:331-333). `SatisfactionToWitness` appends witness script always,
plus control block for Tapscript (ms_t:337-343).

---

## 2. `MiniScriptTest::TestSatisfy` (ms_t:347-433) — the randomized driver

Given an already-constructed `node` (there is **no** random tree generation in this file), it
randomizes over *satisfaction environments*. Pseudocode:

```
script  := node.ToScript(converter)                      // ms_t:349
challist := FindChallenges(node)                         // ms_t:350-351
repeat 3 times (different seed order):                   // ms_t:352-353
    shuffle(challist, m_rng)
    satisfier := Satisfier(ctx) with supported := ∅
    checker   := TestSignatureChecker(satisfier)
    prev_mal := prev_nonmal := false
    for add = -1 .. challist.size()-1:                   // ms_t:358
        if add >= 0: supported.insert(challist[add])     // ms_t:359 — monotonically growing capability set
        build script_pubkey (P2WSH or Taproot leaf)      // ms_t:362-363

        mal_success, witness_mal   := node.Satisfy(satisfier, …, nonmalleable=false)   // 366-368
        nonmal_success, witness_nonmal := node.Satisfy(satisfier, …, nonmalleable=true) // 371-375
        wit_size := serialized size of witness_nonmal.stack minus CompactSize count     // 374

        [assertion battery, see §3]
        prev_mal, prev_nonmal := mal_success, nonmal_success
    satisfiable := node.IsSatisfiable(λ_node. true)      // ms_t:427 — policy-level "could ever pass"
    assert prev_mal == satisfiable                       // ms_t:429
    if node.IsSane(): assert prev_nonmal == satisfiable  // ms_t:430-431
```

How solutions are *picked between* is not here — that is `InputStack operator|`
(`miniscript.cpp:339-366`); the test asserts its consequences (equality of mal/nonmal stacks,
execution success), i.e. the test is an *oracle*, not the algorithm.

---

## 3. Every `BOOST_CHECK` family and what it asserts

### 3.1 Inside `TestSatisfy`

| Lines | Assertion | Meaning |
|---|---|---|
| 381-382 | `witness_nonmal.stack.size() ≤ *node.GetStackSize() + 1 + IsTapscript` | The statically computed max witness-stack item count (`ms_h:1583`) bounds the real witness (+1 witness script, +1 control block for tapscript). |
| 386 | `wit_size ≤ *node.GetWitnessSize()` (plain `assert`) | Static witness-weight bound (`ms_h:1611`) is never exceeded by the produced solution. |
| 384-385 | `mal_success`; `witness_nonmal.stack == witness_mal.stack` | **Malleability cross-check #1:** whenever a non-malleable solution exists, the permissive (`nonmalleable=false`) algorithm must find it and agree bit-for-bit — the two algorithms must not diverge in output, only in acceptance. |
| 389-392 | `VerifyScript(CScript(), spk, &witness_nonmal, STANDARD_SCRIPT_VERIFY_FLAGS, checker, &serror)`; `if (node.ValidSatisfactions()) BOOST_CHECK(res)` | **Consensus/standardness cross-check:** the witness is executed by the real Script interpreter (with mocked sig/timelock checking). For nodes that are valid + within ops + stack limits (`ValidSatisfactions()`, `ms_h:1696`), execution MUST succeed. |
| 395-397 | `res \|\| (!CheckOpsLimit ∧ serror==OP_COUNT) \|\| (!CheckStackSize ∧ serror==STACK_SIZE)` | Failure attribution: a non-malleable satisfaction may only fail execution for exactly the limits the static analysis predicted (`CheckOpsLimit` ms_h:1571, `CheckStackSize` ms_h:1595). |
| 400-406 | malleable-only witness executes, or fails with OP_COUNT/STACK_SIZE | Malleable solutions are never *guaranteed* valid, but the only acceptable failure modes are resource limits (ms_t:404-405 comment). |
| 409-412 | `if (node.IsSane()) mal_success == nonmal_success` | **Malleability cross-check #2:** for sane nodes (`IsSane` ms_h:1702 = valid-top-level ∧ subexpression-sane ∧ non-malleable ∧ no_timelock_mix ∧ no_dup_keys ∧ needs_sig), both algorithms accept/reject identically — sanity implies a malleable attacker gains nothing. |
| 414-415 | `mal_success ≥ prev_mal_success` | **Monotonicity:** enlarging the available capability set can never remove satisfiability. |
| 419-421 | `nonmal_success ≥ prev_nonmal_success` only if node sane, or added challenge is PK | Non-malleable satisfiability is in general *not* monotone: adding a hash-preimage/timelock capability can make the unique previous witness malleable (ms_t:416-418 comment). Exceptions proven by the type system only for signature additions or globally sane nodes. |
| 427-431 | `prev_mal == IsSatisfiable(…)`; if sane also `prev_nonmal == …` | **Completeness:** once *every* challenge of the script is supported, a satisfaction must have been found iff any is semantically possible; and for sane scripts a non-malleable one must have been found. This closes the loop between the abstract challenge enumeration and `IsSatisfiable`'s independent recursive predicate (`ms_h:1633-1672`) — two different implementations of satisfiability must agree. |

Note: `verify` uses `STANDARD_SCRIPT_VERIFY_FLAGS` (ms_t:390), i.e. including `CLEANSTACK`,
`MINIMALDATA`, `MINIMALIF` — so policies like MINIMALIF and minimal-push compliance are
implicitly part of the execution oracle.

### 3.2 Inside `Test(...)` (ms_t:449-476, mode bits at 435-447)

`TestMode` bits (ms_t:435-447): `INVALID`, `VALID`, `NONMAL`, `NEEDSIG`, `TIMELOCKMIX`,
`P2WSH_INVALID`, `TAPSCRIPT_INVALID`.

| Lines | Check |
|---|---|
| 455-456 | Expectedly-invalid strings fail to parse or `!IsValid()` (context-aware: a vector may be invalid only in P2WSH or only in Tapscript). |
| 458-460 | Parses; `IsValid()` (type-correct ∧ script within context size limit, `ms_h:1675-1678`); `IsValidTopLevel()` (additionally top type = B, `ms_h:1681`). |
| 462 | `node->ScriptSize() == computed_script.size()` — static size estimate is exact, not a bound. |
| 463 | Compiled hex equals fixed expected hex (unless `"?"`) — pins the compiler's byte output. |
| 464 | `IsNonMalleable() == !!(mode & NONMAL)` — expected `m` type property (`ms_h:1684`). |
| 465 | `NeedsSignature() == !!(mode & NEEDSIG)` — expected `s` property (`ms_h:1687`). |
| 466 | `(GetType() << "k"_mst) == !(mode & TIMELOCKMIX)` — expected `k` (no height/time mix on any single spend path, `ms_h:1689-1690`). This is the sole timelock invariant mechanism, see §6. |
| 467-469 | `FromScript(script)` re-infers a miniscript, and recompiling it reproduces the script byte-exactly (round-trip script → miniscript → script). |
| 470-473 | Optional exact pins: `GetOps()` (ms_h:1562), `GetStackSize()` (1583), `GetWitnessSize()` (1611), `GetExecStackSize()` (1589). |
| 474 | Every valid vector is fed through `TestSatisfy` (the full §2 battery). |

Two convenience overloads dispatch each vector through **both** `MiniscriptContext::P2WSH`
and `MiniscriptContext::TAPSCRIPT` (ms_t:478-487), with `"="` meaning "same hex in both".

---

## 4. The reference satisfaction algorithm being verified

Since the task asks for its pseudocode: it lives in `Node<Key>::ProduceInput`
(`ms_h:1246-1492`) + `Node::Satisfy` (`ms_h:1708-1714`), operating bottom-up via
`TreeEval<InputResult>` (ms_h:1491) producing `(nsat, sat)` pairs of `InputStack`
(`ms_h:307-361`: flags `available ∈ {NO,YES,MAYBE}`, `has_sig`, `malleable`, `non_canon`,
serialized `size`; canonical constants `ZERO/ ZERO32/ ONE/ EMPTY/ INVALID` at `ms_h:345-353`).

Per-fragment rules (`ms_h:1252-1443`):

```
PK_K:        nsat = ZERO ; sat = sig, has_sig
PK_H:        nsat = ZERO + key ; sat = sig + key, has_sig            // + = stack concat (ms.cpp:325)
MULTI/MULTI_A: DP over keys: sats[j] = best j-signature stack after i keys
             (MULTI: sats[0]={0} for the extra-pop bug; nsat = k+1 ZEROs; MULTI_A nsat = n ZEROs)
             ms_h:1264-1317
THRESH:      DP over subs in reverse: sats[j] = best stack satisfying j of last i subs;
             sat = sats[k]; nsat = union over i≠k of sats[i]; intermediate over-complete
             stacks marked .SetMalleable().SetNonCanon()              ms_h:1318-1352
OLDER/AFTER: nsat = INVALID; sat = EMPTY if ctx.Check{Older,After}(k) else INVALID   ms_h:1353-1358
HASH*/SHA*:  nsat = ZERO32 (32 zero bytes, marked malleable); sat = preimage         ms_h:1359-1378
AND_V:       nsat = (y.nsat + x.sat).NonCanon ; sat = y.sat + x.sat                  ms_h:1379-1388
AND_B:       nsat = (y.nsat+x.nsat) | (y.sat+x.nsat).Mal.NonCanon | (y.nsat+x.sat).Mal.NonCanon ;
             sat  = y.sat + x.sat                                                  ms_h:1389-1397
OR_B:        nsat = z.nsat + x.nsat ;
             sat  = (z.nsat+x.sat) | (z.sat+x.nsat) | (z.sat+x.sat).Mal.NonCanon   ms_h:1398-1402
OR_C/OR_D:   nsat = INVALID resp. z.nsat+x.nsat ; sat = x.sat | (z.sat+x.nsat)      ms_h:1403-1410
OR_I:        nsat = (x.nsat+ONE) | (z.nsat+ZERO); sat = (x.sat+ONE) | (z.sat+ZERO)  ms_h:1411-1414
ANDOR:       nsat = (y.nsat+x.sat).NonCanon | (z.nsat+x.nsat);
             sat  = (y.sat+x.sat) | (z.sat+x.nsat)                                 ms_h:1415-1418
d:X:         nsat = ZERO ; sat = x.sat + ONE                                       ms_h:1424-1427
j:X:         nsat = ZERO marked malleable iff x has a sig-less dissatisfaction
             (conservative: a nonzero-top alternative dsat might exist)            ms_h:1428-1435
v:X:         nsat = INVALID ; sat = x.sat                                          ms_h:1437-1440
a:/s:/c:/n:X: pass-through                                                         ms_h:1419-1423
0 / 1:       {EMPTY, INVALID} / {INVALID, EMPTY}                                   ms_h:1441-1442
```

Choosing between alternatives — `InputStack operator|` (`miniscript.cpp:339-366`):

1. Drop unavailable candidates (340-342).
2. If exactly one side needs a signature, prefer the sig-less side (otherwise an active
   attacker swaps branches — 343-345).
3. If *neither* needs a sig, the choice itself is malleable → mark both malleable (346-349).
4. If both need sigs, prefer the non-malleable one (351-353).
5. Then: among two YES pick the **smaller** witness; among two MAYBE pick the **larger**
   (conservative for fee/size estimation); YES over MAYBE (355-365).

Top-level filter — `Node::Satisfy(ctx, stack, nonmalleable)` (ms_h:1708-1714): run
`ProduceInput`; if `nonmalleable` is requested, decline whenever the constructed satisfaction
is malleable or contains no signature (ms_h:1711). This explains the test asymmetry: a
non-malleable "successful" result always embeds a sig, which is what pins the witness.

`TreeEval` also runs the `tester` wrapper (ms_h:1448-1489) — the **type-properties-to-stack
consistency assertions**, invoked for every node during every test satisfaction:

- `z` ⇒ produced (dis)satisfaction stacks have size 0 (1454-1456)
- `o` ⇒ size 1 (1458-1460)
- `n` ⇒ size ≥ 1 and satisfaction's top element non-empty (1462-1466)
- `d` ⇒ a dissatisfaction exists, has no signature, and if non-malleable is canonical (1468-1472)
- `f`/`s` ⇒ dissatisfactions / satisfactions carry a signature (1474-1476)
- `me` ⇒ a non-malleable dissatisfaction exists (1478-1480)
- `m` ⇒ every existing satisfaction here is non-malleable (1482-1483)
- any non-malleable satisfaction must be canonical (1485-1486)

---

## 5. Handwritten sanity tests (`fixed_tests`, ms_t:501-742)

1. **Timelock bounds** (ms_t:506-513): `older`/`after` valid for `k ∈ [1, 2³¹−1]` only;
   `0` and `2³¹` are invalid in both contexts.
2. **Fragment type-rule table** (ms_t:514-557): one valid exemplar plus systematic single-rule
   violations per combinator, each commented with the violated premise, e.g.
   `andor(Bdu,B,B)` ok vs `andor(Wdu,…)` "X must be B" (515-516); `andor` X must be `d` (517)
   and `u` (obtainable via `n:` wrapper, 518-519); `and_v` X must be V (525-526), Y ∈ {B,V,K}
   (527); `and_b` X must be B (529-532); `or_b` requires `d` on both and W right side (533-539);
   `or_c/or_d` X `Bdu`, Y V resp. B (540-551); `or_i` any same-type B/V/K pair, W rejected
   (552-555); signed variants marked `NEEDSIG` (520, 524, 554).
3. **Aliases + pinned hex** (ms_t:558-559): `pk()`→`c:pk_k`, `pkh()`→`c:pk_h` with exact
   scripts per context (tapscript scripts differ in pushed key size).
4. **33 pinned "randomly generated" vectors** (ms_t:561-592): cover "the majority of type and
   node type combinations" (comment ms_t:561); each pins exact hex for both contexts and exact
   ops / stack-size / witness-size / exec-stack-size numbers (e.g. ms_t:562: `12, 3, 3, 3, 3`).
   Flag annotations cross-check `NONMAL`/`NEEDSIG`/`TIMELOCKMIX` per §3.2.
5. **Tapscript-only section** (ms_t:594-648):
   - `multi_a` script-inference edge cases must fail: no pubkey at all / no key before a
     CHECKSIGADD / malformed tail (601-606).
   - `multi_a` valid in Tapscript, `P2WSH_INVALID` (608); 21-key `multi_a` allowed — legacy
     `multi` caps at 20 (610-616).
   - `dv:` inside `thresh` (needs `u`): OK in Tapscript, invalid in P2WSH — the MINIMALIF
     rationale, see §7 (617-618, and the dedicated check at 674-683).
   - Oversize-but-legal-in-Tapscript: chains of ~99/110/200 `and_b(pk…,a:…)` exceed legacy
     op/stack/script-size limits yet are valid Tapscript (619-629).
   - Execution stack limit boundary: 998 nested `and_b(older(1),a:…)` passes
     (`GetExecStackSize = 1000`), one more fails and `CheckStackSize()` flips to false
     (630-648) — the static exec-stack model is pinned against the 1000-element consensus cap.
6. **Script-inference rejections** (ms_t:650-660): scripts with a non-minimal push or the
   non-minimal-VERIFY pattern are not inferable as miniscript (`FromScript == nullopt`).
7. **thresh k boundaries** (ms_t:661-668): `k == n` and `k == 1` valid; `k > n` and `k == 0`
   invalid.
8. **multi accounting** (ms_t:669-673): `GetOps()==4` (3 keys + CMS op cost counts keys),
   `GetStackSize()==2` (1 sig + dummy from the CHECKMULTISIG extra pop).
9. **Duplicate keys** (ms_t:684-708): four shapes (same key in `and_v`; same key as `pk` and
   `pkh` across an `or_b`; duplicates on different paths/depths) all `!IsSane()` ∧
   `!CheckDuplicateKey()`; a sane no-dup control passes both (705-708).
10. **`FindInsaneSub`** (ms_t:709-720): reports the *deepest* (closest-to-leaf) insanity first
    — the timelock mix inside `and_b(after(1),a:after(1000000000))` is returned rather than the
    shallower "no `s` property" of the enclosing `or_i`.
11. **Number syntax** (ms_t:722-726): sign prefixes rejected in `after(-1)`, `multi(+1,…)`,
    `thresh(-1,…)`.

There are **no explicit node-count assertions**; node-ish sizing is covered by the exact
`ScriptSize`, ops, stack and exec-stack pins above, and tree-depth robustness by `node_stress_stack`.

---

## 6. Timelock tests

Style note: there is no `TestTimelock` helper; timelock behavior is asserted through
`Test(...)` with `TESTMODE_TIMELOCKMIX`, which encodes "lacks property `k`" (checked at
ms_t:466), `k` = "no single satisfaction mixes a heightlock with a timelock"
(`ms_h:1689-1690`, full semantics documented `ms_h:114-126` with per-branch props g/h/i/j).

Cases (ms_t:728-739, plus duplicates of two at 556-557):

- `after(100)` (pure heightlock) and `after(1000000000)` (pure timelock): both VALID+NONMAL (729-730).
- `or_b(l:after(100), al:after(1000000000))`: mix confined to *alternative* branches — no spend
  path mixes ⇒ no TIMELOCKMIX (731).
- `and_b(after(100), a:after(1000000000))`: both on every spend path ⇒ TIMELOCKMIX flagged, yet
  still VALID+NONMAL: mixing is a semantic/policy smell (the script can't ever be spent
  through that conjunction), not a validity or malleability defect (732).
- `thresh(2, ltv:after(1e9), altv:after(100), a:pk(K))`: TIMELOCKMIX but declared NONMAL —
  "correctly detected as non-malleable but for the wrong reason": the type system believes
  branches 1+2 can combine, but since they can never both be satisfied, the key-carrying
  witness is what pins the result (comment ms_t:733-737).
- `thresh(1, c:pk_k(K), altv:after(1e9), altv:after(100))`: in practice non-malleable, but the
  type system cannot prove it ⇒ expected *not* NONMAL (738-739).

Modeling caveats: inside the satisfaction loop, CLTV/CSV satisfaction is **exact match against
the `supported` set** (ms_t:208-215); the height-vs-time 500M distinction only enters through
the *values chosen in vectors* (< 500,000,000 = height) for the type-system `k` computation,
never through mock execution semantics.

---

## 7. How type properties relate to execution (incl. `u`)

- The `tester` lambda inside `ProduceInput` (ms_h:1448-1489) enforces, *at satisfaction
  construction time and on every test run*, the stack-shape part of the type contract:
  z/o/n/d/f/s/e/m vs. actual stack sizes, top-element non-zeroness, signature presence,
  canonicity (§4). These are `CHECK_NONFATAL` invariants coupling the static type system
  (`ComputeType`) to the dynamic satisfier every time `TestSatisfy` runs.
- `u` ("on satisfaction, exactly `1` is pushed", ms_h:87-89) has **no** direct entry in
  `tester` — the constructed witness would need script execution to observe the pushed value.
  Instead `u` is exercised (a) structurally: premises like `andor` X-needs-`u` are unit-tested
  at parse level (ms_t:517-519, 542-544, 548-550, 617-618), and (b) dynamically: executed
  witnesses pass through the real interpreter with `CLEANSTACK`+`MINIMALIF` standardness flags
  (ms_t:390), which would reject any satisfaction leaving != exactly one true element.
- The P2WSH-vs-Tapscript asymmetry of `d:`+`u` is explicitly reasoned about and enforced:
  `d:` duplicates its input and the dup'd value may be a non-`OP_1` nonzero under P2WSH policy
  (MINIMALIF is policy-only there, consensus under Taproot), so `d:` cannot carry `u` in P2WSH
  and `thresh(…,dv:older(42),…)` is `TESTMODE_P2WSH_INVALID` (comment ms_t:674-681; checks
  681-683 and vector 618).
- Top-level typing is what makes execution meaningful at all: `IsValidTopLevel` requires type
  `B` (ms_h:1681, asserted ms_t:460), guaranteeing empty-input and single-true-output
  behavior, which `VerifyScript` then validates for every produced witness.

---

## 8. `node_stress_stack` (ms_t:744-778)

Confirms `~Node()`, `Node::Clone()` and move assignment are heap-stack–safe (iterative, not
recursive): builds a 200,000-deep chain of `WRAP_N` over `Node<uint32_t>` with `NoDupCheck`
(ms_t:760-769), verifies depth via iterative walker, clones (773-774) and move-assigns
(776-777). Comment at 761-766: this catches stack-unsafe destructors under the 512 KiB
`CI_LIMIT_STACK_SIZE` CI jobs.

---

## 9. Where `TestNode`-style full random testing now lives (for cross-reference)

`src/test/fuzz/miniscript.cpp`:
- `TestNode` (1030-1193) runs on fuzz-generated nodes the same battery as here, plus:
  string round-trip (`ToString`→`FromString`→equality, 1034-1040); exact `ScriptSize` (1044);
  `x` property vs last-opcode consistency (1046-1051); `FromScript` round-trip preserving type
  (1056-1063); optional witness/script padding to stress ops and exec-stack accounting
  (1065-1097); then the identical Satisfy-mal/non-mal/VerifyScript/`IsSatisfiable`
  cross-checks (1105-1192) with fuzz-side availability convention `older/after(k) ⇔ k odd`
  (1176-1177).
- Generation: `GenNode` (854) drives type-directed fuzzed constructors `ConsumeNodeStable`
  (387) / `ConsumeNodeSmart` (771, table-driven sub-type selection for valid trees).
- Fuzz targets `miniscript_stable` / `miniscript_smart` at 1210/1222 run generators under both
  P2WSH and Tapscript contexts.

The Boost unit test file analyzed here is thus the *pinned* layer (deterministic vectors, exact
limits, monotonicity/random-subset relaxation of the satisfier), while unbounded random tree
generation is the fuzz layer.
