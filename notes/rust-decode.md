# rust-miniscript — parsing / (de)serialization analysis

Scope: `rust-miniscript/` (crate `miniscript` v13.0.0, `bitcoin = 0.32.6`).
All paths below are relative to `rust-miniscript/`. Read-only analysis; nothing modified.

Files on the "parsing side":

| File | Role |
|---|---|
| `src/miniscript/astelem.rs` | `Terminal::encode()` — AST → Bitcoin Script |
| `src/miniscript/lex.rs` | Script → token stream (`lex`, `TokenIter`) |
| `src/miniscript/decode.rs` | token stream → AST (`decode`), plus the `Terminal` enum itself |
| `src/miniscript/iter.rs` + `src/iter/mod.rs`,`tree.rs` | AST traversal used by validation/equality/display |
| `src/expression/mod.rs` | string-form tokenizer/grammar (`Tree`), `parse_num`, `verify_*` helpers |
| `src/miniscript/mod.rs` | `FromTree for Miniscript` (string → AST), `from_str*`, `decode*` entry points |
| `src/miniscript/display.rs` | the sugar (`t:`/`u:`/`l:`/`and_n`/`pk`) — display only |

---

## 1. Encoding: `Terminal::encode` — exact script per variant

`Miniscript::encode()` is a thin wrapper (`src/miniscript/mod.rs:523-528`):

```rust
pub fn encode(&self) -> script::ScriptBuf { self.node.encode(script::Builder::new()).into_script() }
```

`Terminal::encode` (`src/miniscript/astelem.rs:38-195`) recurses via a
`push_astelem` helper on `script::Builder` (astelem.rs:19-32). Every variant, exactly:

| Terminal | Script (opcode order as emitted) | code |
|---|---|---|
| `PkK(pk)` | `<pk′>` — context-dependent push, see below | astelem.rs:43 |
| `PkH(pk)` | `DUP HASH160 <hash160(pk′)> EQUALVERIFY` | astelem.rs:44-48 |
| `RawPkH(h)` | `DUP HASH160 <h (20B)> EQUALVERIFY` (identical template, hash pushed directly) | astelem.rs:49-53 |
| `After(t)` | `<n> CLTV` (`push_int` ⇒ minimal push / `OP_PUSHNUM_n` for 0..=16) | astelem.rs:54-56 |
| `Older(t)` | `<n> CSV` | astelem.rs:57-59 |
| `Sha256(h)` | `SIZE <32> EQUALVERIFY SHA256 <h> EQUAL` | astelem.rs:60-66 |
| `Hash256(h)` | `SIZE <32> EQUALVERIFY HASH256 <h> EQUAL` | astelem.rs:67-73 |
| `Ripemd160(h)` | `SIZE <32> EQUALVERIFY RIPEMD160 <h> EQUAL` | astelem.rs:74-80 |
| `Hash160(h)` | `SIZE <32> EQUALVERIFY HASH160 <h> EQUAL` | astelem.rs:81-87 |
| `True` | `OP_TRUE` (= `OP_PUSHNUM_1`, 0x51) | astelem.rs:88 |
| `False` | `OP_FALSE` (= `OP_0`, 0x00) | astelem.rs:89 |
| `Alt(x)` | `TOALTSTACK [x] FROMALTSTACK` | astelem.rs:90-93 |
| `Swap(x)` | `SWAP [x]` | astelem.rs:94 |
| `Check(x)` | `[x] CHECKSIG` | astelem.rs:95-97 |
| `DupIf(x)` | `DUP IF [x] ENDIF` | astelem.rs:98-102 |
| `Verify(x)` | `[x]` then **merged** `VERIFY` (see §1.1) | astelem.rs:103 |
| `NonZero(x)` | `SIZE 0NOTEQUAL IF [x] ENDIF` | astelem.rs:104-109 |
| `ZeroNotEqual(x)` | `[x] 0NOTEQUAL` | astelem.rs:110-112 |
| `AndV(l,r)` | `[l] [r]` (concatenation; no opcode) | astelem.rs:113 |
| `AndB(l,r)` | `[l] [r] BOOLAND` | astelem.rs:114-117 |
| `AndOr(a,b,c)` | `[a] NOTIF [c] ELSE [b] ENDIF` (note c/b swap!) | astelem.rs:118-124 |
| `OrB(l,r)` | `[l] [r] BOOLOR` | astelem.rs:125-128 |
| `OrD(l,r)` | `[l] IFDUP NOTIF [r] ENDIF` | astelem.rs:129-134 |
| `OrC(l,r)` | `[l] NOTIF [r] ENDIF` | astelem.rs:135-139 |
| `OrI(l,r)` | `IF [l] ELSE [r] ENDIF` | astelem.rs:140-145 |
| `Thresh(t)` | `[e0] [e1] ADD … [en−1] ADD <k> EQUAL` (n−1 `ADD`s) | astelem.rs:146-154 |
| `Multi(t)` | `<k> <pk1>…<pkn> <n> CHECKMULTISIG` | astelem.rs:155-171 |
| `SortedMulti(t)` | same but keys BIP67-sorted at encode time (`into_sorted_bip67`, astelem.rs:158-160) | astelem.rs:155-171 |
| `MultiA(t)` | `<pk1> CHECKSIG <pk2> CHECKSIGADD … <pkn> CHECKSIGADD <k> NUMEQUAL` | astelem.rs:172-193 |
| `SortedMultiA(t)` | same but keys sorted (`into_sorted_bip67_xonly`, astelem.rs:175-177) | astelem.rs:172-193 |

### 1.1 `Verify` — last-opcode VERIFY merging

astelem.rs:103:

```rust
Self::Verify(ref sub) => builder.push_astelem(sub).push_verify(),
```

`push_verify` is rust-bitcoin 0.32.6 `Builder::push_verify`
(`bitcoin-0.32.6/src/blockdata/script/builder.rs:97-106`): it replaces the
**last opcode just emitted** using `opcode_to_verify`
(`bitcoin-0.32.6/src/blockdata/script/mod.rs:262-269`):

```text
EQUAL          → EQUALVERIFY
NUMEQUAL       → NUMEQUALVERIFY
CHECKSIG       → CHECKSIGVERIFY
CHECKMULTISIG  → CHECKMULTISIGVERIFY
_              → append OP_VERIFY
```

Consequences (all confirmed by tests in `src/miniscript/mod.rs`):

- `v:pk(k)` → `<pk> CHECKSIGVERIFY` (1 opcode less than naive).
- `v:multi(...)` → `... CHECKMULTISIGVERIFY` (see test at mod.rs:1571-1579).
- `v:sha256(h)` → `SIZE <32> EQUALVERIFY SHA256 <h> EQUALVERIFY` (the *second* EQUAL merges).
- `v:thresh(...)` → `... <k> NUMEQUALVERIFY` … wait, no — `Thresh` ends in `EQUAL`, so `v:thresh` ends in `EQUALVERIFY`; `v:multi_a` ends in `NUMEQUALVERIFY`.
- No `VERIFY` merge exists for `CSV`/`CLTV`, so `v:older(n)` → `<n> CSV OP_VERIFY` (e.g. mod.rs:1645-1650 shows `... OP_CSV OP_VERIFY ...`).

Because of the merge, `Verify` can be *free* in size: `script_size()` counts
`usize::from(!sub.ext.has_free_verify)` bytes for `Verify` (mod.rs:555); the
`has_free_verify` bit is computed in `src/miniscript/types/extra_props.rs`
(e.g. `multi`/`multi_a`/`sha256` set it `true`, extra_props.rs:286,325,353,…).

The lexer is the exact dual: `OP_CHECKSIGVERIFY` lexes to `[CheckSig, Verify]`,
`OP_EQUALVERIFY` → `[Equal, Verify]`, etc. (`lex.rs:110-113, 117-120, 124-127, 135-138`).

### 1.2 `c:pk_k` vs `pk` — there is no difference in the AST

`pk(KEY)` is an *alias* for `c:pk_k(KEY)` — literally the same node
(`src/miniscript/mod.rs:156-165`):

```rust
/// The `pk` combinator, which is an alias for `c:pk_k`.
pub fn pk(pk: Pk) -> Self { … node: Terminal::Check(inner /* PkK */) … }
```

So `pk`, `c:pk_k` encode *(byte-for-byte)* as `<key> CHECKSIG`; likewise
`pkh` ≡ `c:pk_h` (mod.rs:167-176). Display canonicalizes `Check(PkK)` → `pk`
and `Check(PkH)` → `pkh` (`display.rs:257-258`), with the `TreeLike` collapse at
`display.rs:73-80`.

Key push is context-dependent (`src/util.rs:86-95`):

```rust
match Ctx::sig_type() {
    context::SigType::Ecdsa => self.push_key(&key.to_public_key()),      // 33/65B + PUSHBYTES
    context::SigType::Schnorr => self.push_slice(key.to_x_only_pubkey().serialize()), // 32B
}
```

and `push_ms_key_hash` (util.rs:97-108) pushes `hash160` of the full pubkey in
ECDSA contexts, `hash160` of the 32-byte x-only key in Schnorr contexts.

### 1.3 `t:`/`u:`/`l:`/`and_n` — display sugar only; `encode` is sugar-free

`encode` has **no special cases** for these; the sugar exists only in
`display.rs` and in the string parser:

`display.rs:265-274` (name selection) and `display.rs:89-123` (tree-shape collapse):

```rust
Terminal::AndV(ref left, ref right) if matches!(right.as_inner(), Terminal::True) =>
    Tree::Unary(DisplayNode::Node(left.ty, left.as_inner()))        // prints as "t:X"
Terminal::OrI(ref left, _)   if matches!(left.as_inner(), Terminal::False) =>  … "l:X"
Terminal::OrI(_, ref right)  if matches!(right.as_inner(), Terminal::False) => … "u:X"
Terminal::AndOr(a, b, c) if matches!(c.as_inner(), Terminal::False) => Tree::Binary(a, b)  // "and_n(X,Y)"
```

`fragment_name()` maps those same shapes to `"t"`, `"u"`, `"l"`, `"and_n"`
(display.rs:265-275). I.e.:

| AST node | displays as | encodes as |
|---|---|---|
| `AndV(X, True)` | `t:X` | `[X] OP_1` |
| `OrI(False, X)` | `l:X` | `IF OP_0 ELSE [X] ENDIF` |
| `OrI(X, False)` | `u:X` | `IF [X] ELSE OP_0 ENDIF` |
| `AndOr(X, Y, False)` | `and_n(X,Y)` | `[X] NOTIF OP_0 ELSE [Y] ENDIF` |
| `Check(PkK(k))` | `pk(k)` | `<k> CHECKSIG` |
| `Check(PkH(k))` | `pkh(k)` | `DUP HASH160 <h160> EQUALVERIFY CHECKSIG` |
| `Check(RawPkH(h))` | `expr_raw_pkh(h)` | same minus `CHECKSIG` is *inside*: `DUP HASH160 <h> EQUALVERIFY CHECKSIG` for the Check; see display.rs:259 |

Quirk: a bare `RawPkH` (not under `Check`) displays as `"expr_raw_pk_h"`
(display.rs:248) while `Check(RawPkH)` displays as `"expr_raw_pkh"`
(display.rs:259). Only `"expr_raw_pkh"` is parseable from string
(mod.rs:1055) — `"expr_raw_pk_h"` hits the `UnknownName` error path.

---

## 2. Lexer rules

There are **two separate lexers**:

### 2a. String form → `expression::Tree` (`src/expression/mod.rs`)

This is the tokenizer for the textual miniscript. Entry: `Tree::from_str`
(expression/mod.rs:611-679).

1. **Pre-check / charset** (`parse_pre_check`, expression/mod.rs:511-601)
   first calls `verify_checksum` (`src/descriptor/checksum.rs:94-126`):
   - every char must be ASCII 32..127 (`InvalidCharacter` otherwise — so a
     literal space passes this layer);
   - an optional `#xxxxxxxx` checksum suffix is verified and stripped (any `#`
     starts it; last `#` wins).
   - Note: `INPUT_CHARSET` (expression/mod.rs:41) is defined but **not
     referenced anywhere in the crate** — the effective grammar is "anything
     except `(){}[],`".
2. **Name/ident chars**: a "name" is any maximal run of bytes that are not
   `(`, `)`, `{`, `}`, `,` (scan loop, expression/mod.rs:634-668). Colons and position metadata are kept in the name.
   There is **no whitespace trimming** — spaces land inside names and will make
   the later fragment/key lookup fail (e.g. `" pk"` is not `pk`).
   Non-ASCII input is rejected earlier (see test `non_ascii`, mod.rs:1695-1701).
3. **Structure**: balanced parens enforced in `parse_pre_check`
   (`MismatchedParens`, `UnmatchedOpenParen`, `UnmatchedCloseParen`,
   `TrailingCharacter`, `ExpectedParenOrComma`), recursion depth capped at
   `MAX_RECURSION_DEPTH` (expression/mod.rs:591-598). `X{...}` curly-brace
   trees are tokenized but miniscript rejects them via
   `root.verify_no_curly_braces()` (mod.rs:1012-1014).
4. **Int parsing** (`parse_num`/`parse_num_nonzero`, expression/mod.rs:683-702):
   - leading digit must be `1..=9` unless the whole string is `"0"`
     (rejects `"00"`, `"06"`, `"+6"`, `"-6"`; tests at expression/mod.rs:782-790);
   - parsed as `u32` (so `> 4294967295` fails).
   - `after(n)`: `verify_after` → `AbsLockTime::from_consensus(n)`
     (expression/mod.rs:347-357); `older(n)`: `verify_older` →
     `RelLockTime::from_consensus(n)` (expression/mod.rs:364-374). Both reject
     values that violate the respective locktime rules.
5. **Hash literals**: parsed by `TreeIterItem::verify_terminal_parent`
   (expression/mod.rs:398-412) → `T::from_str(child_name)` where
   `T = Pk::Sha256 / Hash256 / Ripemd160 / Hash160` (bounds in
   `src/blanket_traits.rs:28-78`). For the built-in key types these are the
   `bitcoin::hashes` newtypes, i.e. plain hex (`sha256`, 64 chars / `ripemd160`,
   `hash160`, 40 chars). `Pk::Hash256` is the miniscript crate's
   forward-displaying `hash256` newtype (mod.rs:1205-1213).
6. **Keys**: same `verify_terminal("public_key")` path → `Pk::from_str`. The
   accepted form is driven by the *key type*, not the context:
   - `bitcoin::PublicKey`: 33-byte compressed (`02/03…`) or 65-byte
     uncompressed (`04…`) hex; rejects 32-byte x-only.
   - `bitcoin::secp256k1::XOnlyPublicKey`: 64-char x-only hex.
   - `String` (tests): any string.
   The **context** only kicks in afterwards via `Ctx::check_global_validity`,
   applied per node during `from_ast` and again over the whole tree
   (mod.rs:1187-1189): `Legacy::check_pk` (context.rs:391-398) and
   `BareCtx::check_pk` (context.rs:773-780) reject x-only keys;
   `Segwitv0::check_pk` rejects x-only *and* uncompressed
   (context.rs:512-521); `Tap::check_pk` rejects uncompressed (context.rs:646-651);
   `Miniscript<bitcoin::PublicKey, Tap>` with compressed keys is explicitly
   allowed (test mod.rs:1715-1719). Script-side key decoding is separate — see §4.
7. **`:` wrapper grouping**: `TreeIterItem::name_separated(':')`
   (expression/mod.rs:267-281) splits `name` at the *first* colon into
   `(Option<prefix>, rest)`; a second colon is an error
   (`ParseTreeError::MultipleSeparators`). The prefix is consumed byte-wise,
   **right to left** (mod.rs:1160-1174):

   ```rust
   for ch in frag_wrap.bytes().rev() {
       let term = match ch {
           b'a' => Terminal::Alt(new),
           b's' => Terminal::Swap(new),
           b'c' => Terminal::Check(new),
           b'd' => Terminal::DupIf(new),
           b'v' => Terminal::Verify(new),
           b'j' => Terminal::NonZero(new),
           b'n' => Terminal::ZeroNotEqual(new),
           b't' => Terminal::AndV(new, Arc::new(Self::TRUE)),
           b'u' => Terminal::OrI(new, Arc::new(Self::FALSE)),
           b'l' => Terminal::OrI(Arc::new(Self::FALSE), new),
           x => return Err(Error::UnknownWrapper(x.into())),
       };
       new = Arc::new(Self::from_ast(term)?);
   }
   ```

   Each wrapper is immediately type-checked (`from_ast`). An empty wrapper
   (`":pk(...)"`) is rejected (mod.rs:1153-1157). Fragment names are
   case-sensitive lowercase; anything else falls to
   `ParseTreeError::UnknownName` (mod.rs:1144-1148).

### 2b. Script → tokens (`src/miniscript/lex.rs`)

`lex(script)` (lex.rs:96-282) iterates `script.instructions_minimal()` and maps
to the `Token` enum (lex.rs:18-51):

- All ~35 relevant opcodes map 1:1, **except** the fused verify opcodes which
  expand to two tokens (`EQUALVERIFY → [Equal, Verify]`,
  `NUMEQUALVERIFY → [NumEqual, Verify]`, `CHECKSIGVERIFY → [CheckSig, Verify]`,
  `CHECKMULTISIGVERIFY → [CheckMultiSig, Verify]`; lex.rs:110-113 to 135-138).
- Any other opcode → `Err(Error::InvalidOpcode(op))` (lex.rs:278) — e.g.
  `OP_1NEGATE`, `OP_RESERVED`, `OP_NOT`, `OP_OR` are rejected outright. (Test
  "OR not BOOLOR": mod.rs:1684.)
- Pushes (lex.rs:207-226): length decides the token — 20B → `Hash20`,
  32B → `Bytes32`, 33B → `Bytes33`, 65B → `Bytes65`; any other length is parsed
  with `script::read_scriptint`:
  - `v >= 0` → `Token::Num(v as u32)` (scriptints are ≤ 4 bytes, so no truncation);
  - `v < 0` → `Err(Error::NegativeInt)` (lex.rs:222);
  - parse failure → `Err(Error::InvalidInt)` (lex.rs:223).
- `OP_0` (`OP_PUSHBYTES_0`) → `Num(0)`; `OP_PUSHNUM_1..16` → `Num(1..16)`
  (lex.rs:227-276). So in token space there is no distinction between a
  "number" and a bare `0`/`1` value — `0` vs `OP_0` is the *same* thing
  (OP_0 **is** the canonical 0).
- **Non-minimal push rejection** is inherited from
  `bitcoin::script::Script::instructions_minimal` — errors become
  `Error::Script` at lex.rs:100. Covered by tests mod.rs:1681-1683
  (`03990300b2` non-minimal number push, `4c0169b2` non-minimal PUSHDATA1).
- **Non-minimal VERIFY rejection** (lex.rs:184-193): if the lexer sees a bare
  `OP_VERIFY` and the *previous token* is `Equal`, `CheckSig` or
  `CheckMultiSig`, it errors with `Error::NonMinimalVerify` ("should be one
  opcode, `XVERIFY`"). Quirk: `NumEqual` is **not** in this deny-list — a
  script with `NUMEQUAL VERIFY` (two opcodes) lexes to the same token stream as
  `NUMEQUALVERIFY`, while `EQUAL VERIFY`, `CHECKSIG VERIFY`,
  `CHECKMULTISIG VERIFY` are rejected.

`TokenIter` (lex.rs:66-93) wraps the token `Vec` and **pops from the back** —
i.e. the grammar in `decode` is written against a *reversed* script stream
(last opcode first). `un_next` pushes a token back (lex.rs:80).

---

## 3. Building the AST from the string form

`FromStr` → `Miniscript::from_str_with_validation_params` (mod.rs:1194-1200,
980-989): `expression::Tree::from_str`, then `FromTree::from_tree`, then
`ms.validate(params)`.

`from_tree` (mod.rs:998-1191) walks `root.pre_order_iter().enumerate().rev()`
— i.e. **right-to-left post-order** — so children are pushed onto a stack
before their parents are reduced:

- **Terminal literal children are skipped in the main loop**
  (mod.rs:1029-1046): inner values of unary fragments (keys/hashes/locktimes),
  all children of `multi*`/`sortedmulti*`, and the first (`k`) child of
  `thresh`. They are consumed by the parent's verifier instead:
  `verify_terminal_parent` for `pk*`, `pkh`, `sha256`, `hash256`, `ripemd160`,
  `hash160`, `expr_raw_pkh`; `verify_after`/`verify_older` for locktimes;
  `verify_threshold` (expression/mod.rs:439-463) for `thresh`/`multi*` —
  which requires `kchild` to be a leaf (`KNotTerminal`), parses `k` with
  `parse_num`, and builds `Threshold::new(k, n_children-1)`, enforcing
  `k ≥ 1`, `k ≤ n`, `n ≤ MAX` (`src/primitives/threshold.rs:46-53,67-70`;
  `MAX_PUBKEYS_PER_MULTISIG = 20`, `MAX_PUBKEYS_IN_CHECKSIGADD = 999`,
  `src/miniscript/limits.rs:35-38`).
- **Fragment dispatch** on the name part (mod.rs:1054-1148). Notable:
  - `"and_n"` builds `Terminal::AndOr(x, y, Arc::new(Self::FALSE))`
    (mod.rs:1107-1109) — the *same* node as `andor(x,y,0)`. Both spellings
    accepted; display canonicalizes to `and_n`.
  - `"pk"`/`"pkh"` aliases (mod.rs:1059-1066); `"andor"` needs exactly 3
    children (mod.rs:1110-1119); `"1"`/`"0"` need 0 children — `"1()"` fails
    (test mod.rs:1464-1465: note `1()` parses the tree as `1` with one empty
    child, and `verify_n_children(_, 0..=0)` rejects it).
  - `"expr_raw_pkh"` is recognized but then rejected by validation unless
    `allow_raw_pkh` (tests mod.rs:1849-1868: only
    `from_str_with_validation_params(.., &ValidationParams::MAX)` accepts).
- After the fragment node is built, wrapper chars (`t`,`u`,`l`,`a`,`s`,`c`,`d`,
  `v`,`j`,`n`) are applied on top (see §2a.7), each via
  `Miniscript::from_ast` (mod.rs:315-332), i.e. **type check + ExtData +
  recursion-depth + per-node `Ctx::check_global_validity` at every step**, so
  badly-typed wrapper combinations (e.g. `t:pk_k(…)`, `j:multi_a(…)` in Tap
  — test mod.rs:1878-1886) fail immediately during parsing, not afterwards.

### `and_v(X,1)` vs `t:X` — equivalence/canonicalization

Both parse to the identical AST `Terminal::AndV(X, True)`:

- `t:` wrapper: mod.rs:1169 `b't' => Terminal::AndV(new, Arc::new(Self::TRUE))`.
- `and_v(X,1)`: `binary(.., Terminal::AndV)` (mod.rs:1105) with right child
  `"1"` → `Self::TRUE` (mod.rs:1093-1098).

So they are the same object; `PartialEq` (which for `Terminal` compares
discriminants + leaves along a pre-order walk, decode.rs:222-248) reports them
equal, and display prints both as `t:X`. The same holds for `or_i(0,X)` ≡
`l:X`, `or_i(X,0)` ≡ `u:X`, `andor(X,Y,0)` ≡ `and_n(X,Y)`. Type checking is
identical, e.g. both `t:X` and `and_v(X,1)` require `X` of type `V`
(AndV's left), so `and_v(pk_k(A),1)` fails exactly like `t:pk_k(A)`.

**Does the parser reject strings that could encode differently?** There is
nothing to reject: encoding is a pure function of the AST node (each
`Terminal` has exactly one script template, §1), so any string accepted by
`from_tree`+`from_ast` re-encodes to the same bytes. The string→string
canonicalization is enforced by round-trip tests (`string_rtt`,
mod.rs:1259-1276) which `assert_eq!(roundtrip, script)` on the parsed display
output.

**Duplicate-key policy** (string path): `from_str` uses `Ctx::SANE`;
`ValidationParams::SANE` has `allow_duplicate_keys: false`
(`src/validation.rs:103-112`), enforced in `validate_non_top_level`
(mod.rs:396-398) via `has_repeated_keys()`
(`src/miniscript/analyzable.rs:48-56`, which counts vs dedupes
`iter_pk()` from `src/miniscript/iter.rs:26`). `from_str_insane`
(mod.rs:974-977) uses `Ctx::CONSENSUS` with `allow_raw_pkh: false` overlaid —
`CONSENSUS` has `allow_duplicate_keys: true` (validation.rs:133-142), so
dupes parse fine there. Test: mod.rs:1897-1910. The same params gate strings
for `allow_dup_if` (Legacy rejects `d:`), `allow_or_i`, `allow_multi(_a)`,
`mixed_timelocks` (mod.rs:399-401; tests 1912-1947), etc.

---

## 4. Decoding from script bytes

### Entry points (`src/miniscript/mod.rs:717-783`)

```rust
pub fn decode_with_validation_params(script, params) -> Result<Self, Error> {
    let tokens = lex(script)?;                    // §2b
    let mut iter = TokenIter::new(tokens);
    let top = decode::decode(&mut iter)?;
    Ctx::check_global_validity(&top)?;
    types::Type::type_check(&top.node)?;
    if let Some(leading) = iter.next() {          // leftover ⇒ Error::Trailing
        Err(Error::Trailing(leading.to_string()))
    } else {
        top.validate(params).map_err(Error::Validation)?;
        Ok(top)
    }
}
```

`decode` uses `Ctx::SANE`, `decode_consensus` uses `Ctx::CONSENSUS`.
Composed nodes created during `decode` go through `Miniscript::from_ast`
(via `TerminalStack::reduce*`, decode.rs:304-334), which runs
`Type::type_check`, `ExtData::type_check` and `Ctx::check_global_validity` on
each node so constructed (mod.rs:315-332). Leaf nodes are instead created
through the direct constructors (`Miniscript::pk_k`, `older`, `sha256`, …),
which skip `from_ast` — their key *form* is still enforced at the point of
`Ctx::Key::from_slice`, and their context validity is covered because every
leaf is either a child of some `from_ast`-reduced parent or is the top node,
which `decode_with_validation_params` checks explicitly (mod.rs:737-738).
The genuinely new checks at this layer are the **trailing-token check**
(mod.rs:739-741) and the **top-level validation params** (top must be `B`,
no dup keys, etc., per `params`).

### The grammar machine (`src/miniscript/decode.rs`)

Because the token stream is consumed **backwards** (last opcode first),
`decode` (decode.rs:336-696) is an explicit-state parser over a `NonTerm`
grammar (decode.rs:55-81) plus a `TerminalStack`. It starts with
`[MaybeAndV, Expression]` (decode.rs:344-346) — "top level cannot be swap,
must be B".

`Expression` dispatch order (`match_token!`, decode.rs:278-291, patterns are
tried in source order; a mismatch on the first token is an error — multi-token
arms like `CheckSequenceVerify, Num(n)` *commit* after the first token):

1. `Bytes33` / `Bytes65` → `PkK` (full key; decode.rs:353-362). Errors from
   `Ctx::Key::from_slice` are wrapped as `Error::PubKeyCtxError(e, Ctx::name_str())`.
2. `Bytes32` → `PkK` with an x-only key (decode.rs:363-378), with the famous
   disambiguation comment (decode.rs:363-374): a naked 32-byte push is parsed
   as an x-only key; it cannot collide with 32-byte hashlocks because in
   miniscript a hashlock's `<hash> EQUAL` is only ever preceded (in reversed
   stream) by `Equal` (branch 6 below), never by a bare `Expression`; and the
   MultiA case is disambiguated by `NumEqual` (branch 12).
3. `CheckSig` → recurse one `Expression`, then `reduce1(Check)`
   (decode.rs:380-383, 590).
4. `Verify` → (decode.rs:385-441): if followed by `Equal`, look at the third
   token:
   - `Hash20` then `Hash160,Dup` → **`RawPkH`** (`expr_raw_pkh`,
     decode.rs:389-397) — script decoding never produces `PkH`, since the key
     preimage is unavailable (the API docs on decode.rs:100-104 say this
     variant exists only for script inference; the string form cannot produce
     it under SANE);
   - `Hash20` then `Hash160/Ripemd160, Verify, Equal, Num(32), Size` →
     hashlock fragment, then wrap in `Verify` (decode.rs:398-410);
   - `Bytes32` then `Sha256/Hash256, Verify, Equal, Num(32), Size` →
     `sha256`/`hash256` + `Verify` (decode.rs:413-427);
   - `Num(k)` → `ThreshW { k, n: 0 }` under a pending `Verify` → `v:thresh`
     (decode.rs:428-434);
   - anything else → generic `v:` wrapper: `un_next`, parse an `Expression`,
     reduce `Verify` (decode.rs:436-441).
5. `ZeroNotEqual` → `n:` wrapper (decode.rs:442-445, 594).
6. `CheckSequenceVerify, Num(n)` → `Older(RelLockTime::from_consensus(n)?)`;
   `CheckLockTimeVerify, Num(n)` → `After(AbsLockTime::from_consensus(n)?)`
   (decode.rs:447-450; invalid locktime encodings rejected here).
7. `Equal` → (decode.rs:452-498) hashlocks or `thresh`:
   - `Bytes32` + full reversed `… Sha256/Hash256 Verify Equal Num(32) Size` →
     `sha256`/`hash256`;
   - `Hash20` + `… Ripemd160/Hash160 …` → `ripemd160`/`hash160`;
   - `Num(k)` → `ThreshW { k, n: 0 }` (no wrapper).
   The hashlock tail (`Size 32 EqualVerify …`) must match **exactly**; a
   "relaxed" hashlock (missing `SIZE 32 EQUALVERIFY` prefix) is not accepted
   and will simply error with `Unexpected`.
   `ThreshW` then either sees `Add` (another W-child) or falls back to
   `Expression` (last child), collecting `n` children into `ThreshE`
   (decode.rs:615-635) → `Terminal::Thresh(Threshold::new(k, subs)?)` — so
   `k == 0` / `k > n` / `n > MAX` fail through `Threshold::new`.
8. `Num(0)` → `Terminal::False`, `Num(1)` → `Terminal::True`
   (decode.rs:500-501). No other bare number is legal in `Expression` position
   (falls to `Unexpected`).
9. `EndIf` → the `EndIf*`/`Tern` state machine (decode.rs:502-506, 636-677):
   - `EndIf … Else … If` → `OrI` (reduce2, decode.rs:666-671);
   - `EndIf … Else … NotIf …` → `Tern` = `AndOr`; pops three and **reorders**:
     `Terminal::AndOr(Arc::new(a), Arc::new(c), Arc::new(b))`
     (decode.rs:607-614) because the middle and third children swap position
     between the script layout (`[a] NOTIF [c] ELSE [b] ENDIF`) and the AST
     order. `andor` decodes with `c` real, unlike `and_n` which is not
     distinguished from scripts (its distinguishing feature, the `0` literal,
     is exactly `NotIf OP_0 …` ⇒ decodes as `AndOr(a,b,False)` which *is*
     `and_n(a,b)` up to display).
   - `EndIf … If Dup` → `DupIf` (`d:`); `EndIf … If ZeroNotEqual Size` →
     `NonZero` (`j:`) (decode.rs:644-649);
   - `EndIf … NotIf IfDup` → `OrD`; `EndIf … NotIf <else>` → `OrC`
     (decode.rs:655-665).
10. `BoolAnd`/`BoolOr` → `AndB`/`OrB`, right operand parsed as a
    `WExpression` (decode.rs:508-517; `WExpression` must begin with
    `FromAltStack` → `a:` or (default) `Swap` → `s:`, decode.rs:678-685).
11. `CheckMultiSig, Num(n)` → read `n` keys (`Bytes33`/`Bytes65` only),
    then `Num(k)`, reverse keys, `Terminal::Multi(thresh)` (decode.rs:519-539).
    `validate_k_n(1, n)` pre-check ensures `1 ≤ n ≤ 20`. **Always `Multi`, never
    `SortedMulti`** — sorting is an encode-time projection only.
12. `NumEqual, Num(k)` → MultiA (decode.rs:544-564): consume
    `CheckSigAdd, Bytes32` pairs greedily (`while tokens.peek() == Some(&Tk::CheckSigAdd)`),
    then require a final `CheckSig, Bytes32`, reverse, `Terminal::MultiA`.
    Comment decode.rs:540-543: "We never decode into a sortedmulti_a. This may
    be done in the future…". Because the lexer expands `NUMEQUALVERIFY` →
    `[NumEqual, Verify]`, `v:multi_a` enters through branch 4's generic
    `Verify` path and still ends up here. Keys must be `Bytes32` (x-only);
    compressed keys in MultiA script fail `from_slice` for XOnlyPublicKey
    (see the `Tap` vs `Segwitv0` decode tests, mod.rs:1727-1747).

`is_and_v` (decode.rs:698-707) is how implicit `and_v` chaining is found:
after any completed expression, if the next (reversed) token is anything other
than `If | NotIf | Else | ToAltStack | Swap | <end>`, an `AndV` is inserted
(decode.rs:567-573, 595-602). Note `FromAltStack` is *not* in that list — an
`a:`-wrapped fragment can never directly start an `and_v` right-hand side,
which matches the type system (right side of `and_v` must be `V/T/F/K` and an
unwrapped `a:` node is `W`).

`AndOr`/`AndB`/… all then route through `TerminalStack::reduce1/2`
(decode.rs:304-334) → `Miniscript::from_ast`, i.e. full `Type::type_check` +
`ExtData::type_check` + `Ctx::check_global_validity` per node, during decode.
So even `decode_consensus` produces only well-typed, per-context-valid trees;
"consensus" relaxes only what `ValidationParams` covers (dup keys, raw pkh,
malleability, top-level-B, resource limits).

Failure modes worth listing: `Error::Unexpected(tok)` / `UnexpectedStart`
(malformed fragment, e.g. bare `VERIFY` at end — test mod.rs:1678),
`Error::Trailing` (junk after a complete parse), lexer errors of §2b
(`InvalidOpcode`, `NegativeInt`, `InvalidInt`, `NonMinimalVerify`, plus
non-minimal-push `Error::Script`), key errors (`PubKeyCtxError`), locktime
errors, threshold errors, and recursion depth
(`from_ast` → `MaxRecursiveDepthExceeded`, mod.rs:327-329).

### `Terminal::decode` "dispatch order"

There is no method literally named `Terminal::decode`; the dispatch is the
`Expression` arm order above (decode.rs:349-565). The order mostly doesn't
matter for correctness because the first token almost fully determines the
fragment; the two intentional overlaps are:

- `Verify`+`Equal`+… tried *before* the bare-`Equal` branch — because in the
  reversed stream `v:hashlock` starts `Verify Equal …`.
- `Num(0)`/`Num(1)` land in the plain-`Expression` arm; an `Equal, Num(0),…`
  prefix still goes down the `ThreshW` path and later fails via
  `Threshold::new(0, …)`, so `0 EQUAL` cannot be misparsed as anything else.

The final `assert_eq!(term.0.len(), 1)` (decode.rs:694) plus the caller's
trailing-token check guarantee a single complete tree.

---

## 5. Role of `src/miniscript/iter.rs` (and `src/iter/*`) on the parsing side

`src/miniscript/iter.rs` itself does no parsing; it provides traversals the
parse/validate pipeline depends on:

- `Miniscript::branches()` / `get_nth_child()` (iter.rs:30-95): child
  enumeration in AST order — for `AndOr` that's `[a, b, c]` (which is *not*
  script order, see §4.9); used by the `Iter` pre-order walker
  (iter.rs:129-170).
- `iter_pk()` / `PkIter` / `get_nth_pk()` (iter.rs:101-208): used by
  `has_repeated_keys()` (`analyzable.rs:48-56`) → the duplicate-key policy that
  `from_str`/`decode` enforce via `ValidationParams`.
- `src/iter/mod.rs:79-170` implements the generic `TreeLike` for
  `&Miniscript`, `&Arc<Miniscript>` and `&Terminal`; that backs
  `pre_order_iter`, which `decode.rs` itself uses for `PartialEq`/`Hash` of
  `Terminal` (decode.rs:222-276 — structural equality; this is why
  `and_v(X,1)` and `t:X`, or Multi vs SortedMulti with same keys, compare
  exactly as their node discriminants dictate) and which `display.rs` reuses
  through its `DisplayNode` wrapper to re-derive the sugar on printing.
- `stack.pop2/pop3/pop_thresh` helpers (`src/iter/mod.rs:60-76`) are used by
  the bulk re-builders (`Clone`, `translate_pk`, `substitute_raw_pkh`,
  mod.rs:90-136, 860-965) which run post-order reconstruction with shared
  `from_ast`-style typing guarantees.

---

## 6. Round-trip identities (verified by tests in `src/miniscript/mod.rs:1259-1693`)

- `display(parse(s)) == canonical(s)` — `string_rtt` (mod.rs:1259-1276).
- `decode(encode(ms)) == ms` under `decode_consensus` — `script_rtt`
  (mod.rs:1312-1323), including the `EQUALVERIFY`/`VERIFY` merging cases
  (`verify_parse`, mod.rs:1468-1485; `tv:thresh` test mod.rs:1665-1669).
- Known non-round-trips:
  - a script containing `DUP HASH160 <h> EQUALVERIFY …` decodes to `RawPkH`
    nodes, whose display is `expr_raw_pkh(...)`, which is *unparseable* from
    string unless `ValidationParams::MAX` (mod.rs:1849-1868; `decode` with
    SANE params also rejects, mod.rs:1866-1867).
  - `sortedmulti*`/`sortedmulti_a` decode as `multi`/`multi_a` (key order
    cannot be recovered; comment decode.rs:540-543).
  - pathological `NUMEQUAL VERIFY` (two opcodes) decodes fine but re-encodes
    fused to `NUMEQUALVERIFY` (§2b).
