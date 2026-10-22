# Bitcoin Core opcode semantics cheat sheet (for a Miniscript formalization)

Source tree: `bitcoin-core` @ `f86c614` (master, post-#35919), read 2026-10-21.
Primary sources (line refs use these abbreviations):

| tag | file |
|---|---|
| `icpp` | `src/script/interpreter.cpp` |
| `ih` | `src/script/interpreter.h` |
| `sh` | `src/script/script.h` |
| `scpp` | `src/script/script.cpp` |
| `ph` | `src/policy/policy.h` |
| `pcpp` | `src/policy/policy.cpp` |
| `ch` | `src/consensus/consensus.h` |
| `txh` | `src/primitives/transaction.h` |
| `val` | `src/validation.cpp` |
| `seh` | `src/script/script_error.h` |

All stack notation is `(bottom ... top)`, i.e. top-most element is rightmost; `stacktop(-1)` is the top.

---

## 0. Execution contexts (`SigVersion`, ih:201-207)

| SigVersion | Meaning | Miniscript context |
|---|---|---|
| `BASE` | bare "legacy" scripts **and** P2SH redeem scripts | `sh()` inner script runs as BASE |
| `WITNESS_V0` | BIP141 witness v0 (P2WPKH, P2WSH) | `wsh()` |
| `TAPSCRIPT` | BIP342, P2TR script path, leaf version `0xc0` | tapscript Miniscript |
| `TAPROOT` | BIP341 key path only; **no script execution** (`EvalScript` asserts against it, icpp:428) | — |

**Flags actually applied.** Block validation uses `GetBlockScriptFlags` (val:2249-2288): always `P2SH|WITNESS|TAPROOT`
(except two historical exception blocks), plus `DERSIG` (BIP66), `CHECKLOCKTIMEVERIFY` (BIP65),
`CHECKSEQUENCEVERIFY` (BIP112), `NULLDUMMY` (BIP147, active with segwit). Everything else —
`CLEANSTACK`, `MINIMALIF`, `NULLFAIL`, `LOW_S`, `MINIMALDATA`, `STRICTENC`, `WITNESS_PUBKEYTYPE`,
`CONST_SCRIPTCODE`, all `DISCOURAGE_*` — is **policy-only**: `MANDATORY_SCRIPT_VERIFY_FLAGS` (ph:98-104),
`STANDARD_SCRIPT_VERIFY_FLAGS` (ph:112-125). Flag enum with per-flag comments: ih:50-152.

---

## 1. Global limits (constants defined)

### Consensus
| constant | value | ref |
|---|---|---|
| `MAX_SCRIPT_ELEMENT_SIZE` | 520 bytes | sh:29 |
| `MAX_OPS_PER_SCRIPT` | 201 (non-push) | sh:32 |
| `MAX_PUBKEYS_PER_MULTISIG` | 20 | sh:35 |
| `MAX_SCRIPT_SIZE` | 10,000 bytes | sh:41 |
| `MAX_STACK_SIZE` | 1000 elements (main+alt) | sh:44 |
| `LOCKTIME_THRESHOLD` | 500,000,000 | sh:48 |
| `ANNEX_TAG` | 0x50 | sh:59 |
| `VALIDATION_WEIGHT_PER_SIGOP_PASSED` | 50 | sh:62 |
| `VALIDATION_WEIGHT_OFFSET` | 50 | sh:65 |
| `MAX_BLOCK_WEIGHT` | 4,000,000 WU | ch:15 |
| `MAX_BLOCK_SIGOPS_COST` | 80,000 | ch:17 |
| `WITNESS_SCALE_FACTOR` | 4 | ch:21 |
| `MAX_PUBKEYS_PER_MULTI_A` | 999 (limit for `multi_a`, from BIP342 stack limit) | sh:38 |

### Policy (standardness)
| constant | value | ref | enforced at |
|---|---|---|---|
| `MAX_STANDARD_TX_WEIGHT` | 400,000 WU | ph:38 | `IsStandardTx` pcpp:111-115 |
| `MAX_STANDARD_SCRIPTSIG_SIZE` | 1650 bytes | ph:62 | pcpp:127-130 (also `IsPushOnly`, 131-134) |
| `MAX_P2SH_SIGOPS` | 15 | ph:42 | `AreInputsStandard` pcpp:254-258 |
| `MAX_STANDARD_TX_SIGOPS_COST` | 16,000 (=80,000/5) | ph:44 | mempool check val:938 |
| `MAX_TX_LEGACY_SIGOPS` | 2,500 (BIP54) | ph:46 | pcpp:170-194 |
| `MAX_STANDARD_P2WSH_STACK_ITEMS` | 100 (excl. witnessScript) | ph:54 | `IsWitnessStandard` pcpp:312-314 |
| `MAX_STANDARD_P2WSH_STACK_ITEM_SIZE` | 80 bytes | ph:56 | pcpp:315-318 |
| `MAX_STANDARD_P2WSH_SCRIPT_SIZE` | 3600 bytes | ph:60 | pcpp:310-311 |
| `MAX_STANDARD_TAPSCRIPT_STACK_ITEM_SIZE` | 80 bytes (leaf 0xc0 only) | ph:58 | pcpp:336-341 |

---

## 2. Interpreter-wide rules (the `EvalScript` skeleton, icpp:417-1255)

These apply to **every** opcode and are needed for a correct formalization:

1. **Parse**: `GetScriptOp` (scpp:313-363). Direct push = opcode byte 0x01-0x4b (1-75 bytes); `OP_PUSHDATA1` + 1-byte len; `OP_PUSHDATA2` + 2-byte LE len; `OP_PUSHDATA4` + 4-byte LE len. Truncated script → `SCRIPT_ERR_BAD_OPCODE` (icpp:455-456). Fails even in unexecuted branches (parse precedes branch logic).
2. **520-byte push limit**: any pushed value (`vchPushValue`) > 520 bytes → `SCRIPT_ERR_PUSH_SIZE` (icpp:457-458). Applies to **all** sigversions incl. tapscript, and regardless of branch execution.
3. **201-op limit** (`MAX_OPS_PER_SCRIPT`): counted only for opcodes > `OP_16`; **only for BASE and WITNESS_V0** (icpp:460-465). No op-count limit in tapscript. `OP_RESERVED` is exempt from counting (comment icpp:461). `OP_CHECKMULTISIG(VERIFY)` adds *n* (the key count) to the counter (icpp:1129-1131).
4. **Script size** ≤ 10,000 bytes for BASE and WITNESS_V0 only; **no script-size limit in tapscript** (icpp:438-440). For P2WSH this bounds the witnessScript; for BASE it bounds scriptSig/redeemScript/scriptPubKey.
5. **Disabled opcodes** (`OP_CAT`, `OP_SUBSTR`, `OP_LEFT`, `OP_RIGHT`, `OP_INVERT`, `OP_AND`, `OP_OR`, `OP_XOR`, `OP_2MUL`, `OP_2DIV`, `OP_MUL`, `OP_DIV`, `OP_MOD`, `OP_LSHIFT`, `OP_RSHIFT`) → always `SCRIPT_ERR_DISABLED_OPCODE`, even in unexecuted branches (icpp:467-482). Not used by Miniscript.
6. **Execution gating**: a push or ordinary opcode runs only if all enclosing IFs are "true" (`fExec = vfExec.all_true()`, icpp:450, 488, 493). IF/ELSE/ENDIF themselves are always dispatched (:493). Data pushes/ops in non-executed branches are skipped entirely (no stack access).
7. **MINIMALDATA** (policy): executed, non-minimally-encoded pushes fail (`SCRIPT_ERR_MINIMALDATA`, icpp:488-491; rules in `CheckMinimalPush` scpp:373-396: empty must be `OP_0`; single byte 1-16 must be `OP_1..16`; byte 0x81 must be `OP_1NEGATE`; ≤75 must be a direct push; ≤255 must be `OP_PUSHDATA1`; ≤65535 `OP_PUSHDATA2`).
8. **Stack depth**: after every executed instruction, `len(stack)+len(altstack) ≤ 1000`, else `SCRIPT_ERR_STACK_SIZE` (icpp:1232-1233).
9. **Unbalanced conditionals**: `OP_ELSE`/`OP_ENDIF` with no open IF → `SCRIPT_ERR_UNBALANCED_CONDITIONAL` (icpp:649-650, 657-658); dangling IF at script end → same error (icpp:1245-1246).
10. **Unknown opcode** (executed) → `SCRIPT_ERR_BAD_OPCODE` (icpp:1227-1228) — except tapscript's OP_SUCCESSx (§4.3).
11. **`CScriptNum`** (sh:227-394): little-endian sign-magnitude; empty vector = 0. Reading an operand: max **4 bytes** by default (`nDefaultMaxNumSize`, sh:244); longer → `scriptnum_error` → `SCRIPT_ERR_SCRIPTNUM` (seh:17; thrown in sh:249-251, caught at icpp:1236-1239). Minimal encoding required only when `MINIMALDATA` flag set (sh:252-269; non-minimal incl. negative-zero `0x80` rejected). Arithmetic may produce >4-byte results which stay valid until next numeric read ("overflow is legal mid-script", comment sh:229-236). Results are always re-serialized minimally (`getvch`, sh:337-373).
12. **`CastToBool`** (icpp:46-59): false iff (a) empty/all-zero, or (b) negative zero — all bytes zero except top byte 0x80. Any other nonzero byte → true.
13. **Condition stack** is a virtual bool stack; `OP_ELSE` toggles the top (icpp:283-328, 647-653).

---

## 3. Opcode-by-opcode (the Miniscript set)

Flags column: consensus = [C]-ish flags from `GetBlockScriptFlags`; everything else policy-only.

### 3.1 `OP_0` (0x00), `OP_1..OP_16` (0x51..0x60), raw pushes (icpp:488-492, 499-523)
- **Push**: nothing popped. `OP_0` pushes the empty vector `[]`. `OP_1..OP_16` push the minimal `CScriptNum` encoding of 1..16 (`[01], [02], …, [10]`, icpp:517-519; value = `opcode - (OP_1 - 1)`).
- **Failures**: none beyond the universal rules (520-byte push limit; MINIMALDATA minimal-encoding policy for data pushes). `OP_0..OP_16` pushes are never counted toward the 201-op limit.
- Note: `OP_1NEGATE` (0x4f, pushes `[81]` = −1) exists in the same case-arm but is not used by Miniscript.

### 3.2 `OP_IF` / `OP_NOTIF` / `OP_ELSE` / `OP_ENDIF` (0x63/0x64/0x67/0x68) — icpp:613-661
- **IF/NOTIF** (only interact with the data stack when executed): pop 1 element.
  - fail: empty stack → `SCRIPT_ERR_INVALID_STACK_OPERATION` (icpp:620-621).
  - pushes: `CastToBool(arg)` (inverted for NOTIF) onto the condition stack; data stack loses the arg (icpp:638-643).
- **MINIMALIF differences** (icpp:623-637):
  - **BASE**: no restriction — any byte string accepted, `CastToBool` decides.
  - **WITNESS_V0**: only when policy flag `SCRIPT_VERIFY_MINIMALIF` set → arg must be `[]` or exactly `[01]`, else `SCRIPT_ERR_MINIMALIF` (seh:54).
  - **TAPSCRIPT**: *consensus rule, flag-independent* — arg must be exactly `[]` or `[01]`, else `SCRIPT_ERR_TAPSCRIPT_MINIMALIF` (seh:80; ih:117-121 comment). Equivalently: `size>1` fails, and `size==1 && byte!=0x01` fails.
- **ELSE**: toggle top condition; fail `SCRIPT_ERR_UNBALANCED_CONDITIONAL` if no open IF.
- **ENDIF**: pop condition; same failure.
- **Flags**: `MINIMALIF` (policy, v0 only); tapscript rule is hard consensus.

### 3.3 `OP_VERIFY` (0x69) — icpp:663-675
- pops 1. Top must be truthy (`CastToBool`): true → popped, execution continues; false → `SCRIPT_ERR_VERIFY`. Empty stack → `SCRIPT_ERR_INVALID_STACK_OPERATION`. No flags alter behavior.

### 3.4 `OP_DUP` (0x76) — icpp:804-812
- `(x → x x)`. ≥1 element; else `SCRIPT_ERR_INVALID_STACK_OPERATION`. Duplicates the top byte string verbatim. No flags.

### 3.5 `OP_SWAP` (0x7c) — icpp:863-870
- `(x1 x2 → x2 x1)`. ≥2 elements. No flags.

### 3.6 `OP_TOALTSTACK` (0x6b) / `OP_FROMALTSTACK` (0x6c) — icpp:687-703
- TOALTSTACK: `(x → )`, moves top of main to alt; fails on empty main stack (`SCRIPT_ERR_INVALID_STACK_OPERATION`).
- FROMALTSTACK: `( → x)`, fails on empty alt stack (`SCRIPT_ERR_INVALID_ALTSTACK_OPERATION`, seh:38).
- Alt stack counts toward the 1000-element combined limit (icpp:1232). Alt stack is *not* carried between scriptSig/scriptPubKey/redeemScript/witness evaluations (fresh per `EvalScript`, icpp:436, 1844). No flags.

### 3.7 `OP_SIZE` (0x82) — icpp:883-891
- `(x → x n)`: pushes `CScriptNum(len(top))` without popping. ≥1 element. No flags.

### 3.8 `OP_EQUAL` (0x87) / `OP_EQUALVERIFY` (0x88) — icpp:897-923
- `(x1 x2 → b)` — **bytewise** equality (no normalization!). Pops 2, pushes `[01]`/`[]`.
- EQUALVERIFY additionally: equal → pop the result (net: both args consumed, nothing pushed); unequal → `SCRIPT_ERR_EQUALVERIFY`.
- ≥2 elements required. No flags. (Miniscript relies on raw byte equality for hash preimages, pubkeys.) 

### 3.9 `OP_BOOLAND` (0x9a) / `OP_BOOLOR` (0x9b) — icpp:955-1010 (cases at 985-986)
- `(x1 x2 → b)`: both read as `CScriptNum` (≤4 bytes each; longer → `SCRIPT_ERR_SCRIPTNUM`; minimal encoding under MINIMALDATA policy). Push `[01]`/`[]`:
  - BOOLAND = `(b1 ≠ 0 && b2 ≠ 0)`; BOOLOR = `(b1 ≠ 0 || b2 ≠ 0)`.
- **Formalization pitfall**: operands are *script numbers*, not `CastToBool` — a >4-byte truthy blob (e.g. 33 bytes) fails with overflow instead of evaluating true. Negative values count as "nonzero".

### 3.10 `OP_ADD` (0x93) — icpp:955-1000 (case 977-979)
- `(x1 x2 → x1+x2)` as `CScriptNum`, operands ≤4 bytes (signed 31-bit magnitude), int64 result, minimally re-encoded. Operand >4 bytes → `SCRIPT_ERR_SCRIPTNUM`. MINIMALDATA requires minimal operands. No overflow trap in practice (int64 headroom).

### 3.11 `OP_0NOTEQUAL` (0x92) — icpp:929-953 (case 947)
- `(x → b)`: `bn = (bn ≠ 0)`. Reads 4-byte `CScriptNum`; pushes `[01]` if nonzero else `[]` (`getvch` of 0 is empty). Same numeric failure modes as above.

### 3.12 `OP_SHA256` (0xa8) / `OP_RIPEMD160` (0xa6) / `OP_HASH256` (0xaa) / `OP_HASH160` (0xa9) — icpp:1032-1056
- `(x → h)`. ≥1 element. RIPEMD160 → 20 bytes; SHA256 → 32 bytes (single SHA-256); HASH256 → 32 bytes (double SHA-256); HASH160 → 20 bytes (RIPEMD160∘SHA256). Hash of the raw stack bytes, no length prefixing. No flags.

### 3.13 `OP_CHECKSIG` (0xac) / `OP_CHECKSIGVERIFY` (0xad) — icpp:1069-1092
- `(sig pubkey → bool)`. ≥2 elements; `sig = stacktop(-2)`, `pubkey = stacktop(-1)`. Pops both, pushes result; VERIFY then pops the result and fails with `SCRIPT_ERR_CHECKSIGVERIFY` when false (icpp:1084-1090).
- Dispatch (icpp:397-415): BASE/WITNESS_V0 → ECDSA path (`EvalChecksigPreTapscript`, icpp:331-355); TAPSCRIPT → Schnorr path (`EvalChecksigTapscript`, icpp:357-395).

#### ECDSA / pre-tapscript semantics (icpp:331-355 + 1701-1724)
1. **scriptCode** = script from the most recent `OP_CODESEPARATOR` to the end. In **BASE only**, `FindAndDelete` removes the signature bytes from scriptCode; with policy flag `CONST_SCRIPTCODE`, if anything was removed → `SCRIPT_ERR_SIG_FINDANDDELETE` (icpp:339-343). Witness v0 never deletes.
2. **Signature encoding** (`CheckSignatureEncoding`, icpp:211-226): the **empty signature always passes encoding** (and later verifies false → result `[]`; NULLFAIL doesn't trigger on empty). Non-empty:
   - `DERSIG` (consensus, BIP66): strict DER `IsValidSignatureEncoding` (icpp:118-181: 9-73 bytes total incl. sighash byte, `0x30` SEQ, lengths consistent, R/S nonzero-length, non-negative, no padding) else `SCRIPT_ERR_SIG_DER`.
   - `LOW_S` (policy): S ≤ n/2 else `SCRIPT_ERR_SIG_HIGH_S` (icpp:183-198).
   - `STRICTENC` (policy): DER + sighash type defined — base type ∈ {1,2,3} after masking off `SIGHASH_ANYONECANPAY` (icpp:200-209), else `SCRIPT_ERR_SIG_HASHTYPE`.
   The sig's last byte is the sighash type, stripped before verifying (icpp:1708-1713).
3. **Pubkey encoding** (`CheckPubKeyEncoding`, icpp:228-237): `STRICTENC` → 33-byte compressed (0x02/0x03) or 65-byte uncompressed (0x04); `WITNESS_PUBKEYTYPE` (policy) + WITNESS_V0 → compressed only, else `SCRIPT_ERR_WITNESS_PUBKEYTYPE`.
4. **Verify** (`CheckECDSASignature`, icpp:1701-1724): a structurally *invalid pubkey* (bad curve point) returns `false` (script continues!) if it survived encoding checks. Legacy BASE sighash = `CTransactionSignatureSerializer` (icpp:1263-1354) with the SIGHASH_SINGLE out-of-range → `uint256::ONE` bug (icpp:1614-1621); WITNESS_V0 = BIP143 sighash including the prevout **amount** (icpp:1633-1670).
5. **NULLFAIL** (policy): if verification returned false and the signature is non-empty → `SCRIPT_ERR_SIG_NULLFAIL` (icpp:351-352).

#### Schnorr / tapscript semantics (`EvalChecksigTapscript`, icpp:357-395; `CheckSchnorrSignature`, icpp:1726-1752)
Order matters (consensus-critical comment icpp:361-366):
1. `success = (sig ≠ empty)`. If sig **non-empty**: decrement the validation-weight budget by 50 (`VALIDATION_WEIGHT_PER_SIGOP_PASSED`); if it goes below 0 → `SCRIPT_ERR_TAPSCRIPT_VALIDATION_WEIGHT` (icpp:367-376).
2. **Empty pubkey** → immediate `SCRIPT_ERR_TAPSCRIPT_EMPTY_PUBKEY`, even with empty sig (icpp:377-378).
3. **32-byte pubkey** → Schnorr check iff sig non-empty (icpp:379-382). Invalid Schnorr → script fails hard (`SCRIPT_ERR_SCHNORR_SIG*` below) — NULLFAIL is *baked into consensus* in tapscript; there is no "false result with non-empty sig".
4. **Pubkey size ∉ {0, 32}** ("unknown pubkey type") → auto-success (success stays as computed); counted against the budget if sig non-empty. Policy `DISCOURAGE_UPGRADABLE_PUBKEYTYPE` → fail (icpp:383-392).

Schnorr signature format rules (`CheckSchnorrSignature`, icpp:1726-1752):
- size must be exactly **64 or 65 bytes**, else `SCRIPT_ERR_SCHNORR_SIG_SIZE` (icpp:1736). (64 = BIP340 sig; 65 = sig + 1-byte sighash.)
- 64-byte → sighash type `SIGHASH_DEFAULT` (0x00), which behaves as `SIGHASH_ALL` (ih:37; icpp:1740). 65-byte → last byte is the hash type and must **not** be 0x00 (`SIGHASH_DEFAULT`), else `SCRIPT_ERR_SCHNORR_SIG_HASHTYPE` (icpp:1741-1744).
- Allowed explicit hash types: 0x01, 0x02, 0x03, 0x81, 0x82, 0x83 (`SignatureHashSchnorr`, icpp:1526); anything else → `SCRIPT_ERR_SCHNORR_SIG_HASHTYPE` (icpp:1747-1749). Failed BIP340 verification → `SCRIPT_ERR_SCHNORR_SIG` (icpp:1750).
- Sighash: BIP341 `TapSighash` tagged hash, `ext_flag=1` + `key_version=0` for tapscript (includes tapleaf hash and last codeseparator position, icpp:1492-1580). Key-path (`SigVersion::TAPROOT`, icpp:1970-1975) uses `ext_flag=0` and the 65/64-byte rules too (no empty-sig carve-out — key path sig goes straight to `CheckSchnorrSignature`).
- No DER/LOW_S/STRICTENC/WITNESS_PUBKEYTYPE involvement: encoding flags above are ECDSA-only. `DISCOURAGE_UPGRADABLE_PUBKEYTYPE` is the only flag changing tapscript CHECKSIG behavior.

### 3.14 `OP_CHECKMULTISIG` (0xae) / `OP_CHECKMULTISIGVERIFY` (0xaf) — icpp:1115-1225
- **TAPSCRIPT**: unconditional `SCRIPT_ERR_TAPSCRIPT_CHECKMULTISIG` when executed (icpp:1118). ECDSA multisig exists only in BASE/WITNESS_V0 (hence Miniscript `multi()` is segwit-v0-only; tapscript uses `multi_a` = CHECKSIGADD chains).
- **Stack layout** (bottom→top): `dummy sig_1 … sig_m m pk_1 … pk_n n`.
- **Pop/read order** (reads are by depth; actual pops at cleanup):
  1. top = `n` (`CScriptNum` ≤4B); require `0 ≤ n ≤ 20` else `SCRIPT_ERR_PUBKEY_COUNT` (icpp:1126-1128). `nOpCount += n`; total must stay ≤201 (icpp:1129-1131).
  2. below the n keys: `m` at depth n+2; require `0 ≤ m ≤ n` else `SCRIPT_ERR_SIG_COUNT` (icpp:1140-1142).
  3. then m signatures; then the dummy. Depth/stack-size checks: icpp:1122-1146.
- **BASE**: every signature is `FindAndDelete`'d from scriptCode; `CONST_SCRIPTCODE` fails if found (icpp:1151-1160).
- **Matching loop** (icpp:1162-1191): processes the topmost not-yet-consumed signature against the topmost not-yet-consumed key; on match advance both, else advance only the key; abort early when remaining sigs > remaining keys. Consequently **signatures must be pushed in the same order as their public keys** (extra sigs lead to immediate false). Per pair: sig encoding + pubkey encoding re-checked (icpp:1171-1174) then ECDSA verify (icpp:1177).
- **NULLFAIL** (policy): overall result false ⇒ all pushed signature items must be empty; non-empty → `SCRIPT_ERR_SIG_NULLFAIL`, enforced while clearing the sig region of the stack (icpp:1193-1201).
- **NULLDUMMY** (consensus, BIP147): exactly one extra element is consumed (the "dummy" from the historical off-by-one); it must be the empty vector, else `SCRIPT_ERR_SIG_NULLDUMMY` (icpp:1203-1213).
- Result pushed `[01]`/`[]`; VERIFY variant pops and fails `SCRIPT_ERR_CHECKMULTISIGVERIFY` on false (icpp:1215-1223). n-of-m with 0 keys (`n=0`, `m=0`) is legal and yields `[01]` after consuming the dummy.

### 3.15 `OP_CHECKSIGADD` (0xba) — icpp:1094-1113
- **BASE/WITNESS_V0**: executed → `SCRIPT_ERR_BAD_OPCODE` (icpp:1097). Tapscript only.
- Stack: ≥3; `sig = stacktop(-3)`, `num = stacktop(-2)`, `pubkey = stacktop(-1)`.
- **`num` is parsed as `CScriptNum` with the default 4-byte limit** (sh:244); >4 bytes → `SCRIPT_ERR_SCRIPTNUM`. Minimal encoding is required only under `MINIMALDATA` (policy/standardness), *not* at consensus — BIP342 requires just "valid 4-byte script number" (icpp:1103).
- Sig/pubkey handling = `EvalChecksigTapscript` (§3.13 Schnorr path): empty pubkey always fails; 32-byte pubkey + non-empty sig → Schnorr (hard fail on bad sig); unknown pubkey size passes; non-empty sig decrements the tapscript weight budget by 50.
- Pops 3, pushes `num + (success ? 1 : 0)` re-encoded minimally (icpp:1108-1111). Note: with an empty sig the pushed value is `num` *re-serialized* (non-minimal input becomes minimal output).

### 3.16 `OP_CHECKLOCKTIMEVERIFY` (0xb1, BIP65) — icpp:532-569
- If `SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY` not set → treated as NOP2 (no stack touch; and never subject to `DISCOURAGE_UPGRADABLE_NOPS`, ih:86-87). CLTV is consensus-mandatory since BIP65 activation (val:2272-2275).
- Peeks (does **not** pop) the top: empty stack → `SCRIPT_ERR_INVALID_STACK_OPERATION` (icpp:539-540); read as CScriptNum with **5-byte** limit (icpp:556); negative → `SCRIPT_ERR_NEGATIVE_LOCKTIME` (icpp:561-562).
- `CheckLockTime` (icpp:1754-1789) — the BIP65 conditions, all must hold else `SCRIPT_ERR_UNSATISFIED_LOCKTIME` (icpp:565-566):
  1. (covered above) stack non-empty, and operand ≥ 0;
  2. type match: operand and `tx.nLockTime` on the same side of `LOCKTIME_THRESHOLD` (500,000,000; height vs. UNIX time) (icpp:1764-1768);
  3. `operand ≤ tx.nLockTime` (icpp:1770-1773);
  4. the input's `nSequence ≠ SEQUENCE_FINAL` (0xFFFFFFFF, txh:77) (icpp:1785-1786).

### 3.17 `OP_CHECKSEQUENCEVERIFY` (0xb2, BIP112) — icpp:571-603
- If flag not set → NOP3. Consensus-mandatory since BIP112 activation (val:2277-2280).
- Peeks top; ≥1 element; CScriptNum **5-byte** (icpp:584); negative → `SCRIPT_ERR_NEGATIVE_LOCKTIME` (icpp:589-590).
- **Escape hatch**: if the operand has bit 31 set (`SEQUENCE_LOCKTIME_DISABLE_FLAG = 1<<31`, txh:94), the opcode is a **NOP** (icpp:592-596). Miniscript `older()` never sets this bit for meaningful constraints.
- `CheckSequence` (icpp:1791-1836), fail → `SCRIPT_ERR_UNSATISFIED_LOCKTIME` (icpp:599-600):
  1. `tx.version ≥ 2` (icpp:1800);
  2. the input's `nSequence` must **not** have the disable flag set (icpp:1803-1808);
  3. mask both sides with `SEQUENCE_LOCKTIME_TYPE_FLAG | SEQUENCE_LOCKTIME_MASK` = `0x0040ffff` (txh:100, 105) (icpp:1810-1814);
  4. type match on bit `1<<22` (height vs. 512-second time units; granularity `SEQUENCE_LOCKTIME_GRANULARITY = 9`, txh:115) (icpp:1816-1828);
  5. `masked_operand ≤ masked_input_nSequence` (icpp:1830-1833).
- Argument is not popped.

---

## 4. Where the script sits: VerifyScript & witness programs

### 4.1 `VerifyScript` pipeline (icpp:2012-2131)
1. `SIGPUSHONLY` (policy) → scriptSig must be push-only (icpp:2022-2024).
2. Eval scriptSig (BASE), then scriptPubKey (BASE) on the same stack; after scriptPubKey: stack non-empty and top truthy, else `SCRIPT_ERR_EVAL_FALSE` (icpp:2029-2040).
3. **Bare witness program** (scriptPubKey is `OP_n <2..40B>`, `IsWitnessProgram` scpp:248-264): scriptSig must be *exactly empty* else `SCRIPT_ERR_WITNESS_MALLEATED` (icpp:2045-2058).
4. **P2SH** (flag `P2SH`, scriptPubKey = `OP_HASH160 <20B> OP_EQUAL`): scriptSig push-only (icpp:2064-2066); redeemScript = last pushed scriptSig element, re-evaluated as **BASE** (icpp:2076-2086), must leave truthy top.
5. **P2SH-wrapped witness**: redeemScript is a witness program; then scriptSig must be *exactly one push* of the redeemScript else `SCRIPT_ERR_WITNESS_MALLEATED_P2SH` (icpp:2089-2103).
6. Policy `CLEANSTACK` → exactly one element left (icpp:2110-2118). Policy `WITNESS` + non-null witness for a non-witness spend → `SCRIPT_ERR_WITNESS_UNEXPECTED` (icpp:2120-2127).

### 4.2 P2WSH / witness v0 (`VerifyWitnessProgram`, icpp:1927-1956; `ExecuteWitnessScript`, icpp:1842-1880)
- 20-byte v0 program → P2WPKH (exactly 2 witness items; implied `<DUP HASH160 <pkh> EQUALVERIFY CHECKSIG>` script). 32-byte v0 program → P2WSH: witness stack non-empty, last item = witnessScript, `SHA256(witnessScript)` must equal the program (`SCRIPT_ERR_WITNESS_PROGRAM_MISMATCH` otherwise).
- **Initial witness stack items ≤ 520 bytes** (consensus, all witness versions — unconditional loop icpp:1868-1871), i.e. witness-provided data elements obey the legacy element limit even though the witnessScript itself is only bound by `MAX_SCRIPT_SIZE`/policy.
- Post-execution: **implicit CLEANSTACK**: exactly one stack element and truthy, else `SCRIPT_ERR_CLEANSTACK` / `SCRIPT_ERR_EVAL_FALSE` (icpp:1876-1878) — this is consensus inside any witness evaluation.
- Witness v0 keeps: 10,000-byte script limit, 201-op limit, legacy 1000-element stack limit (icpp:438, 460-465, 1232).

### 4.3 Taproot / tapscript (icpp:1957-1999)
- v1 + 32-byte program, non-P2SH (P2SH-wrapped v1 → future-witness success / discouraged). Requires `WITNESS|TAPROOT` (if `TAPROOT` flag off → anyone-can-spend success, icpp:1959).
- **Annex**: ≥2 witness items and last item starts with 0x50 → popped off and hashed into sighash (icpp:1961-1969); annex presence is **non-standard** (pcpp:327-330).
- **Key path** (1 item after annex removal): single Schnorr sig vs. the tweaked output key, `SIGHASH_DEFAULT` rules as above (icpp:1970-1975).
- **Script path** (≥2 items): pop control block (`33 + 32k` bytes, k ≤ 128, else `SCRIPT_ERR_TAPROOT_WRONG_CONTROL_SIZE`, icpp:1980-1982; constants ih:244-247), pop the leaf script, compute tapleaf hash from `control[0] & 0xfe`, verify the tweaked-key commitment (`SCRIPT_ERR_WITNESS_PROGRAM_MISMATCH`, icpp:1983-1986).
- Leaf version `0xc0` (`TAPROOT_LEAF_TAPSCRIPT`, ih:243) → tapscript evaluation with **sigops budget**: `validation_weight_left = GetSerializeSize(entire witness stack incl. script+control+annex) + 50` (icpp:1991; `VALIDATION_WEIGHT_OFFSET` sh:65). Each *executed, non-empty-signature* CHECKSIG/CHECKSIGVERIFY/CHECKSIGADD spends 50 (`VALIDATION_WEIGHT_PER_SIGOP_PASSED` sh:62); dropping below 0 → `SCRIPT_ERR_TAPSCRIPT_VALIDATION_WEIGHT` (icpp:372-375). Empty signatures are free.
- Tapscript pre-scan (`ExecuteWitnessScript`, icpp:1846-1866): any **OP_SUCCESSx** opcode (`IsOpSuccess` scpp:365-371: 0x50, 0x62, 0x7e-0x81, 0x83-0x86, 0x89-0x8a, 0x8d-0x8e, 0x95-0x99, 0xbb-0xfe) found *anywhere* in the leaf script (even in non-executed branches) → immediate success; policy `DISCOURAGE_OP_SUCCESS` → `SCRIPT_ERR_DISCOURAGE_OP_SUCCESS`. Also enforces initial witness stack count ≤ 1000 (icpp:1865) in addition to the 520-byte-item rule.
- Unknown leaf versions: success, discouraged by policy `DISCOURAGE_UPGRADABLE_TAPROOT_VERSION` (icpp:1995-1998; also pcpp tapscript item-size rule applies only to leaf 0xc0, pcpp:336-341).

### 4.4 Rules matrix per SigVersion (quick reference)
| rule | BASE | WITNESS_V0 | TAPSCRIPT |
|---|---|---|---|
| script ≤ 10,000 B (icpp:438) | ✓ | ✓ (witnessScript) | ✗ |
| 201 non-push ops (icpp:460-465) | ✓ | ✓ (+n per CHECKMULTISIG) | ✗ |
| ≤520 B per pushed value (icpp:457) | ✓ | ✓ | ✓ |
| ≤520 B per initial witness item (icpp:1868-1871) | — | ✓ | ✓ |
| ≤1000 stack items (icpp:1232, 1865) | ✓ | ✓ | ✓ |
| MINIMALIF on IF/NOTIF arg | ✗ (any bool) | policy-only | ✓ consensus `[]`/`[01]` |
| non-empty failing sig | false result; NULLFAIL policy | false result; NULLFAIL policy | hard fail (consensus) |
| empty sig & VERIFY-variant | false → CHECKSIGVERIFY fails | same | same |
| CHECKMULTISIG | ECDSA ≤20 keys | ECDSA ≤20 keys | disabled (`multi_a` instead) |
| CHECKSIGADD | BAD_OPCODE | BAD_OPCODE | ✓ Schnorr accumulator |
| OP_SUCCESSx | BAD_OPCODE | BAD_OPCODE | auto-success |
| sighash | legacy (+SINGLE bug icpp:1614-1621) | BIP143 w/ amount | BIP341 TapSighash |
| implicit CLEANSTACK | ✗ (top-true only) | ✓ | ✓ |

---

## 5. Policy details that bind Miniscript analysis

- **P2WSH standardness** (pcpp:309-319): witnessScript ≤ 3600 B (`MAX_STANDARD_P2WSH_SCRIPT_SIZE`); ≤ 100 witness stack items excluding the witnessScript; each non-script item ≤ 80 B (consensus caps them at 520 B but standardness only relays ≤ 80 B — this is why Miniscript keys are 33 B, hashes 20/32 B, sigs ≤ 73 B).
- **Tapscript standardness** (pcpp:321-349): no annex; for leaf 0xc0 every witness item other than script+control ≤ 80 B (`MAX_STANDARD_TAPSCRIPT_STACK_ITEM_SIZE`; holds Schnorr sigs ≤ 65 and x-only keys 32). No standardness limit on tapscript *script* size beyond `MAX_STANDARD_TX_WEIGHT`.
- **Tx-level**: weight ≤ 400,000 WU (pcpp:111-115) — the bound in `miniscript.h` (max satisfaction size); scriptSig push-only & ≤ 1650 B for legacy/P2SH inputs (pcpp:127-134); P2SH redeem script ≤ 15 sigops (pcpp:254-258) — hence classic P2SH Miniscript multisig caps at 15 keys; mempool sigop-cost ceiling 16,000 (val:938).
- **MINIMALDATA/LOW_S/STRICTENC/MINIMALIF/NULLDUMMY/NULLFAIL/WITNESS_PUBKEYTYPE/CLEANSTACK** are all in the standard set (ph:112-125) and therefore assumed by Miniscript's malleability analysis, but only `P2SH, DERSIG, NULLDUMMY, CLTV, CSV, WITNESS, TAPROOT` are mandatory/consensus-level (ph:98-104, val:2249-2288).
