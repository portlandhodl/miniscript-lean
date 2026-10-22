# Bitcoin Core Miniscript: String Parsing, Script Decoding, and Validity Checks

Scope: `/home/qrsnap/git/miniscript-lean/bitcoin-core/src/script/miniscript.h` (2707 lines),
`/home/qrsnap/git/miniscript-lean/bitcoin-core/src/script/miniscript.cpp` (432 lines),
and the invocation sites in `/home/qrsnap/git/miniscript-lean/bitcoin-core/src/script/descriptor.cpp` (3146 lines).
All line references are to these files unless noted otherwise.

---

## 1. `FromString` / `Parse` — textual parsing

### Entry points

```cpp
// miniscript.h:2684-2688
template <typename Ctx>
inline std::optional<Node<typename Ctx::Key>> FromString(const std::string& str, const Ctx& ctx)
{
    return internal::Parse<typename Ctx::Key>(str, ctx);
}
```

`internal::Parse...` (miniscript.h:1853-2211) is documented as:

```cpp
// miniscript.h:1848-1854
/**
 * Parse a miniscript from its textual descriptor form.
 * This does not check whether the script is valid, let alone sane. The caller is expected to use
 * the `IsValidTopLevel()` and `IsSaneTopLevel()` to check for these properties on the node.
 */
template <typename Key, typename Ctx>
inline std::optional<Node<Key>> Parse(std::span<const char> in, const Ctx& ctx)
```

### Structure: **iterative** machine, not recursive descent

The parser is an explicit-stack state machine — no recursive calls. State is a stack of
`std::tuple<ParseContext, int64_t, int64_t>` over enum `ParseContext` (miniscript.h:1758-1810:
`WRAPPED_EXPR, EXPR, SWAP, ALT, CHECK, DUP_IF, VERIFY, NON_ZERO, ZERO_NOTEQUAL, WRAP_U, WRAP_T,
AND_N, AND_V, AND_B, ANDOR, OR_B, OR_C, OR_D, OR_I, THRESH, COMMA, CLOSE_BRACKET`), plus a
`constructed` stack of finished `Node`s:

```cpp
// miniscript.h:1872-1875
    // The two integers are used to hold state for thresh()
    std::vector<std::tuple<ParseContext, int64_t, int64_t>> to_parse;
    std::vector<Node<Key>> constructed;

    to_parse.emplace_back(ParseContext::WRAPPED_EXPR, -1, -1);
```

The main loop pops one context per iteration (`while (!to_parse.empty())`, miniscript.h:1914) and
each case pushes follow-up contexts (a poor-man's CFG). E.g. `andor(` pushes, in reverse execution
order (miniscript.h:2051-2059):

```cpp
            } else if (Const("andor(", in)) {
                to_parse.emplace_back(ParseContext::ANDOR, -1, -1);
                to_parse.emplace_back(ParseContext::CLOSE_BRACKET, -1, -1);
                to_parse.emplace_back(ParseContext::WRAPPED_EXPR, -1, -1);
                to_parse.emplace_back(ParseContext::COMMA, -1, -1);
                to_parse.emplace_back(ParseContext::WRAPPED_EXPR, -1, -1);
                to_parse.emplace_back(ParseContext::COMMA, -1, -1);
                to_parse.emplace_back(ParseContext::WRAPPED_EXPR, -1, -1);
                script_size += 5;
```

**`MAX_RECURSION_DEPTH` does not exist in this snapshot.** A repo-wide grep finds no occurrence;
parsing is fully iterative (tree evaluation elsewhere is also iterative — `TreeEvalMaybe`,
miniscript.h:651-713 — and even the `Node` destructor flattens the tree iteratively,
miniscript.h:552-569). In lieu of a recursion cap, the parser enforces a *script-size budget*:

```cpp
// miniscript.h:1868-1869
    size_t script_size{1};
    size_t max_size{internal::MaxScriptSize(ctx.MsContext())};
```

checked at the top of every loop iteration and inside the wrapper loop:

```cpp
// miniscript.h:1915
        if (script_size > max_size) return {};
// miniscript.h:1934 (inside wrapper-prefix loop)
                if (script_size > max_size) return {};
```

`script_size` is incremented per fragment as parsing proceeds (`+=2` for `a:`, `+=1` for `s:`/`c:`/
`n:`, `+=3` for `d:`, `+=4` for `j:`/`u:`/`l:`, `+=1` `t:`, plus per-fragment constants in `EXPR`),
and the invariant is asserted at the end:

```cpp
// miniscript.h:2203-2206
    // Sanity checks on the produced miniscript
    assert(constructed.size() >= 1);
    CHECK_NONFATAL(constructed.size() == 1);
    assert(constructed[0].ScriptSize() == script_size);
```

One explicit structural guard against degenerate wrappers:

```cpp
// miniscript.h:1953-1957
                } else if (in[j] == 'v') {
                    // do not permit "...vv...:"; it's not valid, and also doesn't trigger early
                    // failure as script_size isn't incremented.
                    if (last_was_v) return {};
```

(`v:` adds 0 bytes when it folds into a `-VERIFY` opcode, so without this check `vvvv...:` would
iterate without growing `script_size`.)

### Tokenization primitives (not a separate lexer)

There is no tokenizer phase; the parser consumes the span in place using helpers from
`src/script/parsing.cpp`:

```cpp
// parsing.cpp:13-20 — Const(): match a literal prefix, optionally consume
bool Const(const std::string& str, std::span<const char>& sp, bool skip)
// parsing.cpp:22-29 — Func(): require "str(" ... ")" and strip both
bool Func(const std::string& str, std::span<const char>& sp)
// parsing.cpp:31-48 — Expr(): extract span up to first top-level ','/')'/'}' (paren/brace balanced)
std::span<const char> Expr(std::span<const char>& sp)
```

`FindNextChar` (miniscript.cpp:421-429) is used by `multi(`/`thresh(` to find the next `,`
*within the current parentheses depth* (breaks on `')'`):

```cpp
// miniscript.cpp:421-429
int FindNextChar(std::span<const char> sp, const char m)
{
    for (int i = 0; i < (int)sp.size(); ++i) {
        if (sp[i] == m) return i;
        // We only search within the current parentheses
        if (sp[i] == ')') break;
    }
    return -1;
}
```

`Split()` (util/string.h:120) is **not** used by the miniscript parser itself — only at the
descriptor layer for keys: BIP32 path components `Split(sp, '/')` (descriptor.cpp:1987), origin
info `Split(sp, ']')` (descriptor.cpp:2210), multipath `Split(..., ";")` (descriptor.cpp:1921),
`musig()` args `Split(sp, ')', /*include_sep=*/true)` (descriptor.cpp:2079), checksum
`Split(sp, '#')` (descriptor.cpp:2980).

### Wrapper prefix parsing (the `asct...:` prefix)

`WRAPPED_EXPR` scans for a `:` preceded only by `[a-z]` and enqueues one context per wrapper
character (miniscript.h:1922-1976):

```cpp
// miniscript.h:1922-1930
        case ParseContext::WRAPPED_EXPR: {
            std::optional<size_t> colon_index{};
            for (size_t i = 1; i < in.size(); ++i) {
                if (in[i] == ':') {
                    colon_index = i;
                    break;
                }
                if (in[i] < 'a' || in[i] > 'z') break;
            }
```

Letters recognized (miniscript.h:1935-1971): `a` (+2 bytes), `s` (+1), `c` (+1), `d` (+3),
`j` (+4), `n` (+1), `v` (+0, no `vv`), `u` (+4), `t` (+1), `l` (+4); anything else → `return {}`.

### Fragment recognition in `EXPR` (miniscript.h:1978-2090) and sugar

- `0` / `1` → `JUST_0` / `JUST_1` (miniscript.h:1979-1982).
- **`pk(K)` sugar** → `WRAP_C(PK_K(K))`; **`pkh(K)` sugar** → `WRAP_C(PK_H(K))`:

```cpp
// miniscript.h:1983-1992
            } else if (Const("pk(", in, /*skip=*/false)) {
                std::optional<Key> key = ParseKey<Key, Ctx>("pk", in, ctx);
                if (!key) return {};
                constructed.emplace_back(internal::NoDupCheck{}, ctx.MsContext(), Fragment::WRAP_C, Vector(Node<Key>(internal::NoDupCheck{}, ctx.MsContext(), Fragment::PK_K, Vector(std::move(*key)))));
                script_size += IsTapscript(ctx.MsContext()) ? 33 : 34;
            } else if (Const("pkh(", in, /*skip=*/false)) { ... Fragment::WRAP_C over PK_H ... script_size += 24; }
```

  `pk_k`/`pk_h` are the raw unsugared forms (miniscript.h:1993-2002).

- **`and_n(X,Y)` sugar** → pushed as `AND_N` and later built as `ANDOR(X,Y,JUST_0)`:

```cpp
// miniscript.h:2061-2063
                if (Const("and_n(", in)) {
                    to_parse.emplace_back(ParseContext::AND_N, -1, -1);
                    script_size += 5;
// miniscript.h:2133-2137
        case ParseContext::AND_N: {
            auto mid = std::move(constructed.back());
            constructed.pop_back();
            constructed.back() = Node{internal::NoDupCheck{}, ctx.MsContext(), Fragment::ANDOR, Vector(std::move(constructed.back()), std::move(mid), Node<Key>{internal::NoDupCheck{}, ctx.MsContext(), Fragment::JUST_0})};
```

- **`t:` wrapper sugar** → `AND_V(X, JUST_1)`; **`u:`** → `OR_I(X, JUST_0)`; **`l:`** → `OR_I(JUST_0, X)`:

```cpp
// miniscript.h:2121-2127
        case ParseContext::WRAP_U: {
            constructed.back() = Node{..., Fragment::OR_I, Vector(std::move(constructed.back()), Node<Key>{..., Fragment::JUST_0})};
        case ParseContext::WRAP_T: {
            constructed.back() = Node{..., Fragment::AND_V, Vector(std::move(constructed.back()), Node<Key>{..., Fragment::JUST_1})};
// miniscript.h:1964-1968 (l: pushes JUST_0 first, then OR_I combines in-order)
                } else if (in[j] == 'l') {
                    // The l: wrapper is equivalent to or_i(0,X)
                    script_size += 4;
                    constructed.emplace_back(internal::NoDupCheck{}, ctx.MsContext(), Fragment::JUST_0);
                    to_parse.emplace_back(ParseContext::OR_I, -1, -1);
```

(These internal encodings are documented at miniscript.h:241-244.)

### Number parsing rules: `after(n)` / `older(n)` / `thresh`/`multi` thresholds

All numbers go through `ToIntegral<int64_t>` (strict `-?[0-9]+`, whole-string match, range-checked,
`std::nullopt` on any failure — util/strencodings.h:170-189). For timelocks:

```cpp
// miniscript.h:2023-2036 (after / older are identical)
            } else if (Const("after(", in, /*skip=*/false)) {
                auto expr = Expr(in);
                if (!Func("after", expr)) return {};
                const auto num{ToIntegral<int64_t>(std::string_view(expr.begin(), expr.end()))};
                if (!num.has_value() || *num < 1 || *num >= 0x80000000L) return {};
                constructed.emplace_back(internal::NoDupCheck{}, ctx.MsContext(), Fragment::AFTER, *num);
                script_size += 1 + (*num > 16) + (*num > 0x7f) + (*num > 0x7fff) + (*num > 0x7fffff);
```

So both `after(n)` and `older(n)` require **1 ≤ n < 2³¹** (0x80000000). There is *no* separation
of time/height ranges at parse time (n ≥ 500M is a valid `older` value textually; the type system
flags it via `g`/`h` from `SEQUENCE_LOCKTIME_TYPE_FLAG` — miniscript.cpp:91-98 — and
`after` splits `i`/`j` on `LOCKTIME_THRESHOLD = 500'000'000`, script/script.h:48).

`thresh(k,...)`: `k ≥ 1` at scan time; `k ≤ n` at close time:

```cpp
// miniscript.h:2041-2050
            } else if (Const("thresh(", in)) {
                int next_comma = FindNextChar(in, ',');
                if (next_comma < 1) return {};
                const auto k{ToIntegral<int64_t>(std::string_view(in.data(), next_comma))};
                if (!k.has_value() || *k < 1) return {};
// miniscript.h:2174-2184
            } else if (in[0] == ')') {
                if (k > n) return {};
                ...
                constructed.emplace_back(internal::NoDupCheck{}, ctx.MsContext(), Fragment::THRESH, std::move(subs), k);
```

### Hash fragments: exact byte-size enforcement

```cpp
// miniscript.h:1824-1833
inline std::optional<std::vector<unsigned char>> ParseHexStr(const std::string& func, std::span<const char>& in, const size_t expected_size)
{
    std::span<const char> expr = script::Expr(in);
    if (!script::Func(func, expr)) return {};
    std::string val = std::string(expr.begin(), expr.end());
    if (!IsHex(val)) return {};
    auto hash = ParseHex(val);
    if (hash.size() != expected_size) return {};
    return hash;
}
```

Callers: `sha256(`/`hash256(` → 32 bytes (miniscript.h:2004, 2014); `ripemd160(`/`hash160(` →
20 bytes (miniscript.h:2009, 2019). Re-checked at node construction: `CHECK_NONFATAL(data_size ==
32/20)`, miniscript.cpp:42-48.

### `multi(k, key1, key2, ..., keyn)` argument order and limits

`parse_multi_exp` (miniscript.h:1878-1912) reads **k first**, then keys in listed order — the
script convention `[k] [key_n]* [n] OP_CHECKMULTISIG` is inverted in the textual form:

```cpp
// miniscript.h:1878-1902
    const auto parse_multi_exp = [&](std::span<const char>& in, const bool is_multi_a) -> bool {
        const auto max_keys{is_multi_a ? MAX_PUBKEYS_PER_MULTI_A : MAX_PUBKEYS_PER_MULTISIG};
        const auto required_ctx{is_multi_a ? MiniscriptContext::TAPSCRIPT : MiniscriptContext::P2WSH};
        if (ctx.MsContext() != required_ctx) return false;
        // Get threshold
        int next_comma = FindNextChar(in, ',');
        if (next_comma < 1) return false;
        ...
        // Get keys. It is compatible for both compressed and x-only keys.
        std::vector<Key> keys;
        while (next_comma != -1) { ... keys.push_back(...) }
        if (keys.size() < 1 || keys.size() > max_keys) return false;
        if (k < 1 || k > (int64_t)keys.size()) return false;
```

Limits: `MAX_PUBKEYS_PER_MULTISIG = 20` (script/script.h:35), `MAX_PUBKEYS_PER_MULTI_A = 999`
(script/script.h:38). **Context gating happens here**: `multi(` only in P2WSH, `multi_a(` only in
TAPSCRIPT (miniscript.h:1880-1881). Node construction re-verifies: miniscript.cpp:75-80
(`n_keys ≥ 1 && n_keys <= MAX_PUBKEYS_PER_MULTISIG`, `!IsTapscript(ms_ctx)` for MULTI, etc.).

### Termination and key duplication

```cpp
// miniscript.h:2207-2210
    if (in.size() > 0) return {};
    Node<Key> tl_node{std::move(constructed.front())};
    tl_node.DuplicateKeyCheck(ctx);
    return tl_node;
```

Trailing garbage is rejected (`in.size() > 0`). Note that contrary to the doc comment, the parser
**does** compute duplicate-key info (`DuplicateKeyCheck`); sanity (`IsSane` etc.) is still left to
the caller — see §6 for how descriptor.cpp does it.

---

## 2. Decoding miniscript from raw script bytes

### Pipeline: `FromScript` → `DecomposeScript` → `DecodeScript`

```cpp
// miniscript.h:2690-2703
template <typename Ctx>
inline std::optional<Node<typename Ctx::Key>> FromScript(const CScript& script, const Ctx& ctx)
{
    using namespace internal;
    // A too large Script is necessarily invalid, don't bother parsing it.
    if (script.size() > MaxScriptSize(ctx.MsContext())) return {};
    auto decomposed = DecomposeScript(script);
    if (!decomposed) return {};
    auto it = decomposed->begin();
    auto ret = DecodeScript<typename Ctx::Key>(it, decomposed->end(), ctx);
    if (!ret) return {};
    if (it != decomposed->end()) return {};
    return ret;
}
```

### `DecomposeScript` (miniscript.cpp:368-406): canonicalization *rejection*, not acceptance

Produces a vector of `(opcodetype, pushdata)` pairs **in reverse order** so the decoder can walk
from the script tail. The combined `-VERIFY` opcodes are split:

```cpp
// miniscript.cpp:380-395
        } else if (opcode == OP_CHECKSIGVERIFY) {
            // Decompose OP_CHECKSIGVERIFY into OP_CHECKSIG OP_VERIFY
            out.emplace_back(OP_CHECKSIG, std::vector<unsigned char>());
            opcode = OP_VERIFY;
        } else if (opcode == OP_CHECKMULTISIGVERIFY) { ... OP_CHECKMULTISIG + OP_VERIFY ... }
        } else if (opcode == OP_EQUALVERIFY) { ... OP_EQUAL + OP_VERIFY ... }
        } else if (opcode == OP_NUMEQUALVERIFY) { ... OP_NUMEQUAL + OP_VERIFY ... }
```

`OP_1`–`OP_16` become pushes of the decoded number (miniscript.cpp:377-379). Non-canonical forms
are **rejected**:

```cpp
// miniscript.cpp:396-401
        } else if (IsPushdataOp(opcode)) {
            if (!CheckMinimalPush(push_data, opcode)) return {};
        } else if (it != itend && (opcode == OP_CHECKSIG || opcode == OP_CHECKMULTISIG || opcode == OP_EQUAL || opcode == OP_NUMEQUAL) && (*it == OP_VERIFY)) {
            // Rule out non minimal VERIFY sequences
            return {};
        }
```

(`CheckMinimalPush`, script/script.cpp:373-396, requires the shortest push encoding — `OP_0` for
empty, `OP_1..16` for 1-16, direct push ≤75 bytes, PUSHDATA1/2 beyond; a 1-byte `0x81` push is
rejected: "Should have used OP_1NEGATE".)

So `OP_EQUAL OP_VERIFY` spelled out in the raw script is *not* accepted — only the fused
`OP_EQUALVERIFY` (and analogues). Since `ToScript` never emits the unfused sequence (see
`BuildScript(..., verify ? OP_EQUALVERIFY : OP_EQUAL)`, miniscript.h:821-824, 827, 853, 861, 868),
this is exact canonical matching.

### `ParseScriptNumber` (miniscript.cpp:408-419) — numeric pushes, negative-int handling

```cpp
std::optional<int64_t> ParseScriptNumber(const Opcode& in) {
    if (in.first == OP_0) {
        return 0;
    }
    if (!in.second.empty()) {
        if (IsPushdataOp(in.first) && !CheckMinimalPush(in.second, in.first)) return {};
        try {
            return CScriptNum(in.second, true).GetInt64();
        } catch(const scriptnum_error&) {}
    }
    return {};
}
```

- Only `OP_0` (→0) or a *minimal* data push ≤ 4 bytes (`CScriptNum::nDefaultMaxSize = 4`,
  script/script.h:244) is accepted.
- **OP_1NEGATE is unreachable**: `GetOp` returns it with empty `push_data`, so the
  `!in.second.empty()` branch is skipped and `nullopt` results. Combined with `CheckMinimalPush`
  rejecting every non-minimal negative encoding, *no negative integer can survive*; any that would
  (e.g. minimal `<0x90>` = −16) is parsed as a negative `int64_t` and then rejected by every
  consumer's range check (`older`/`after` require ≥1, miniscript.h:2348/2354; `thresh` ≥1,
  miniscript.h:2454; multi n∈[1,20], k∈[1,n], miniscript.h:2384, 2392; multi_a k∈[1,999],
  miniscript.h:2404).

### `DecodeScript` (miniscript.h:2295-2680): another iterative machine

`DecodeContext` (miniscript.h:2226-2292): `SINGLE_BKV_EXPR, BKV_EXPR, W_EXPR, SWAP, ALT, CHECK,
DUP_IF, VERIFY, NON_ZERO, ZERO_NOTEQUAL, MAYBE_AND_V, AND_V, AND_B, ANDOR, OR_B, OR_C, OR_D,
THRESH_W, THRESH_E, ENDIF, ENDIF_NOTIF, ENDIF_ELSE`.

Top level is `BKV_EXPR` — comment at miniscript.h:2302-2304: "This is the top level, so we assume
the type is B (in particular, disallowing top level W expressions)".

Early-abort validity/sanity per node (miniscript.h:2307-2308):

```cpp
        // Exit early if the Miniscript is not going to be valid.
        if (!constructed.empty() && !constructed.back().IsValid()) return {};
```

and a final type check (miniscript.h:2676-2679):

```cpp
    // Note that due to how ComputeType works (only assign the type to the node if the
    // subs' types are valid) this would fail if any node of tree is badly typed.
    if (!tl_node.IsValidTopLevel()) return {};
```

Key matching rules per fragment (opcode exactness — reverse order, so first element is last opcode):

- **Leaf constants**: `OP_1`→`JUST_1`, `OP_0`→`JUST_0` (miniscript.h:2319-2328).
- **pk_k**: any bare 33- or 32-byte push followed (in script order) by `OP_CHECKSIG` is first
  read as the key push — `if (in[0].second.size() == 33 || in[0].second.size() == 32)` →
  `ctx.FromPKBytes(...)` → `PK_K` (miniscript.h:2330-2336); the following `OP_CHECKSIG` is later
  consumed by the `CHECK` context (see c: below) making it `c:pk_k` = `pk()`. The KeyParser then
  enforces context-correct size (§5).
- **pk_h**: exact 5-opcode pattern (reversed: `OP_VERIFY OP_EQUAL <20B> OP_HASH160 OP_DUP`)
  (miniscript.h:2337-2343).
- **older/after**: `OP_CHECKSEQUENCEVERIFY <n>` / `OP_CHECKLOCKTIMEVERIFY <n>` with
  `1 ≤ n ≤ 0x7FFFFFFF`:

```cpp
// miniscript.h:2346-2351
            if (last - in >= 2 && in[0].first == OP_CHECKSEQUENCEVERIFY && (num = ParseScriptNumber(in[1]))) {
                in += 2;
                if (*num < 1 || *num > 0x7FFFFFFFL) return {};
                constructed.emplace_back(internal::NoDupCheck{}, ctx.MsContext(), Fragment::OLDER, *num);
```

- **hashes**: exact 7-element pattern (reversed) — `OP_EQUAL <hash> OP_HASHOP OP_VERIFY 32-as-number OP_SIZE`… actually the reversed layout checked is
  `in[0]==OP_EQUAL, in[3]==OP_VERIFY, in[4]==OP_EQUAL, num(in[5])==32, in[6]==OP_SIZE`, with
  `in[2]` ∈ {SHA256, RIPEMD160, HASH256, HASH160} and `in[1].second.size()` 32/20/32/20 to
  distinguish (miniscript.h:2359-2377). So `OP_SIZE <32> OP_EQUALVERIFY OP_SHA256 <32B> OP_EQUAL`.
- **multi (P2WSH only)**: reversed `OP_CHECKMULTISIG n key_n...key_1 k`; `n∈[1,20]`, all keys
  exactly 33 bytes, `k∈[1,n]`, then keys re-reversed to script order (miniscript.h:2379-2396:

```cpp
            if (last - in >= 3 && in[0].first == OP_CHECKMULTISIG) {
                if (IsTapscript(ctx.MsContext())) return {};
                ...
                if (*n < 1 || *n > 20) return {};
                for (int i = 0; i < *n; ++i) {
                    if (in[2 + i].second.size() != 33) return {};
                ...
                std::reverse(keys.begin(), keys.end());
```

  — note the *decode* accepts only 33-byte keys for MULTI even though the type itself is
  context-gated; x-only MULTI scripts never exist on-chain v0).
- **multi_a (Tapscript only)**: reversed `OP_NUMEQUAL k (OP_CHECKSIGADD <key>)* OP_CHECKSIG <key>`;
  walks `(CHECKSIGADD|CHECKSIG, 32-byte key)` pairs, terminates on `OP_CHECKSIG`, rejects early if
  count > 999 (miniscript.h:2399-2427):

```cpp
            if (last - in >= 4 && in[0].first == OP_NUMEQUAL) {
                if (!IsTapscript(ctx.MsContext())) return {};
                const auto k = ParseScriptNumber(in[1]);
                if (!k) return {};
                if (*k < 1 || *k > MAX_PUBKEYS_PER_MULTI_A) return {};
                ...
                for (int pos = 2;; pos += 2) {
                    if (last - in < pos + 2) return {};
                    // Make sure it's indeed an x-only pubkey and a CHECKSIG[ADD], then parse the key.
                    if (in[pos].first != OP_CHECKSIGADD && in[pos].first != OP_CHECKSIG) return {};
                    if (in[pos + 1].second.size() != 32) return {};
                    ...
                    // Make sure early we don't parse an arbitrary large expression.
                    if (keys.size() > MAX_PUBKEYS_PER_MULTI_A) return {};
```

- **c:** any `OP_CHECKSIG` tail → `CHECK` + recurse `SINGLE_BKV_EXPR` (miniscript.h:2431-2437).
- **v:** any `OP_VERIFY` tail → `VERIFY` + recurse (miniscript.h:2438-2443).
- **n:** any `OP_0NOTEQUAL` tail → `ZERO_NOTEQUAL` + recurse (miniscript.h:2445-2451).
- **thresh:** `OP_EQUAL <k≥1>` tail → `THRESH_W` chains matching `OP_ADD` between W-type children
  (miniscript.h:2452-2458, 2589-2612).
- **and_b / or_b**: `OP_BOOLAND` / `OP_BOOLOR` (miniscript.h:2471-2486); the comment at
  miniscript.h:2466-2470 documents why only `SINGLE_BKV_EXPR` (not `BKV_EXPR`) is used for the
  right side: to keep `and_v` "outside" (`or_b(and_v(X,Y),Z)` scripts decode as
  `and_v(X,or_b(Y,Z))` — the only valid form).
- **ENDIF chains** disambiguate the IF-family: `OP_ELSE` → or_i vs andor (`ENDIF_ELSE`,
  miniscript.h:2656-2669); `OP_IF` + `OP_DUP` → **d:** (`OP_DUP OP_IF`, miniscript.h:2623-2626);
  `OP_IF` + `OP_0NOTEQUAL` + `OP_SIZE` → **j:** (miniscript.h:2627-2630) — i.e. j: requires the
  exact triple `OP_SIZE OP_0NOTEQUAL OP_IF`, any other opcode combination fails;
  `OP_NOTIF` → or_c vs or_d via `OP_IFDUP` probe (`ENDIF_NOTIF`, miniscript.h:2635-2654).
- **a:/s:** in `W_EXPR` the decoder first looks for `OP_FROMALTSTACK`; if found it pushes `ALT`
  (which then *requires* `OP_TOALTSTACK`, miniscript.h:2523-2528), otherwise `SWAP` which requires
  `OP_SWAP` (miniscript.h:2495-2521). So `a:X` matches exactly the `OP_TOALTSTACK X OP_FROMALTSTACK`
  pattern — `OP_TOALTSTACK` never appears anywhere else in the grammar, and `MAYBE_AND_V` explicitly
  refuses to glue an `and_v` before `OP_TOALTSTACK`/`OP_SWAP`/`OP_IF`/`OP_ELSE`/`OP_NOTIF`:

```cpp
// miniscript.h:2507-2515
        case DecodeContext::MAYBE_AND_V: {
            // If we reach a potential AND_V top-level, check if the next part of the script could be another AND_V child
            // These op-codes cannot end any well-formed miniscript so cannot be used in an and_v node.
            if (in < last && in[0].first != OP_IF && in[0].first != OP_ELSE && in[0].first != OP_NOTIF && in[0].first != OP_TOALTSTACK && in[0].first != OP_SWAP) {
```

Wrappers (`SWAP`, `ALT`, `CHECK`, `DUP_IF`, `VERIFY`, `NON_ZERO`, `ZERO_NOTEQUAL`) just wrap
`constructed.back()` (miniscript.h:2517-2553); `BuildBack(..., /*reverse=*/true)` reassembles
binary nodes in correct order (miniscript.h:2554-2577).

**Sugar recognition during decode:** there is *none* — `t:`, `u:`, `l:`, `and_n`, `pk`, `pkh` are
not matched as such. `[X] <1>` decodes as `AND_V(X, JUST_1)`, `OP_IF 0 X OP_ENDIF`-shapes as
`OR_I(JUST_0/…, …)`, `<pk> OP_CHECKSIG` as `WRAP_C(PK_K)`, etc. Sugar is only re-emitted by
`ToString` (miniscript.h:930-935: `t:`, `l:`, `u:`; :966: `and_n`; :912-923: `pk`/`pkh`; and the
wrapper chain logic at :887-895, with ":" separator logic). Round-trip
script→miniscript→string therefore produces the canonical sugared form.

---

## 3. Node sanity: `IsSane()`, `IsNotSatisfiable()`, `IsSaneSubexpression()`, `NeedsSignature()`

Exact definitions (miniscript.h:1674-1702):

```cpp
    //! Check whether this node is valid at all.
    bool IsValid() const {
        if (GetType() == ""_mst) return false;
        return ScriptSize() <= internal::MaxScriptSize(m_script_ctx);
    }

    //! Check whether this node is valid as a script on its own.
    bool IsValidTopLevel() const { return IsValid() && GetType() << "B"_mst; }

    //! Check whether this script can always be satisfied in a non-malleable way.
    bool IsNonMalleable() const { return GetType() << "m"_mst; }

    //! Check whether this script always needs a signature.
    bool NeedsSignature() const { return GetType() << "s"_mst; }

    //! Check whether there is no satisfaction path that contains both timelocks and heightlocks
    bool CheckTimeLocksMix() const { return GetType() << "k"_mst; }

    //! Check whether there is no duplicate key across this fragment and all its sub-fragments.
    bool CheckDuplicateKey() const { return has_duplicate_keys && !*has_duplicate_keys; }

    //! Whether successful non-malleable satisfactions are guaranteed to be valid.
    bool ValidSatisfactions() const { return IsValid() && CheckOpsLimit() && CheckStackSize(); }

    //! Whether the apparent policy of this node matches its script semantics. Doesn't guarantee it is a safe script on its own.
    bool IsSaneSubexpression() const { return ValidSatisfactions() && IsNonMalleable() && CheckTimeLocksMix() && CheckDuplicateKey(); }

    //! Check whether this node is safe as a script on its own.
    bool IsSane() const { return IsValidTopLevel() && IsSaneSubexpression() && NeedsSignature(); }
```

And (miniscript.h:1606-1607):

```cpp
    //! Whether no satisfaction exists for this node.
    bool IsNotSatisfiable() const { return !GetStackSize(); }
```

So a node accepted as a descriptor-level miniscript must (descriptor.cpp:2745
`if (!node->IsSane() || node->IsNotSatisfiable())`):

1. **Be type-valid** — `GetType() != ""_mst`. `ComputeType`+`SanitizeType` (miniscript.cpp:19-262)
   enforce the full type system: e.g. THRESH children must be `Bdu, Wdu, Wdu…`
   (miniscript.cpp:237: `if (!(t << (i ? "Wdu"_mst : "Bdu"_mst))) return ""_mst;`); per-fragment
   argument sanity (k/n/data sizes, miniscript.cpp:41-83); and legality axioms like "z conflicts
   with o", "K implies u", "V implies f", "z implies m" (miniscript.cpp:22-35).
2. **Fit the context script-size limit** (`MaxScriptSize`, §4).
3. **Be top-level type B** (`IsValidTopLevel`).
4. **Pass `CheckOpsLimit` / `CheckStackSize`** (`ValidSatisfactions`, §4).
5. **Be non-malleable** under guaranteed availability (type property `m`).
6. **Never mix height and time locks on one satisfaction path** (`k` property; computed e.g. for
   AND_V at miniscript.cpp:152-156 with the `g*h + h*g + i*j + j*i` exlusion logic).
7. **Contain no duplicate keys** (`DuplicateKeyCheck`, miniscript.h:1494-1556, using the
   descriptor-aware comparator `KeyParser::KeyCompare`, descriptor.cpp:2304-2318, which compares
   derived pubkeys when possible and falls back to comparing public expression strings so
   *different* xpub expressions never count as duplicates).
8. **Require a signature for every satisfaction** (`s` property → `NeedsSignature()`; this is the
   difference between `IsSane()` and `IsSaneSubexpression()` — the former adds
   `IsValidTopLevel` + `NeedsSignature`).
9. **Be satisfiable at all** (`IsNotSatisfiable()` false ⇔ a max-non-malleable-satisfaction stack
   size exists, i.e. `ss.Sat().Valid()`).

descriptor.cpp:2746-2767 maps each failure to a human-readable message, using
`FindInsaneSub()` (miniscript.h:1623-1629) to localize the offending subnode, e.g.
`": witnesses without signature exist"` for `NeedsSignature()` failure,
`": contains duplicate public keys"` for `CheckDuplicateKey()`, etc.

---

## 4. Limits: script size, ops, stack — where enforced

Maximum script size is context-dependent (miniscript.h:284-296):

```cpp
constexpr uint32_t MaxScriptSize(MiniscriptContext ms_ctx)
{
    if (IsTapscript(ms_ctx)) {
        // Leaf scripts under Tapscript are not explicitly limited in size. ...
        constexpr auto max_size{MAX_STANDARD_TX_WEIGHT - TX_BODY_LEEWAY_WEIGHT - MAX_TAPSCRIPT_SAT_SIZE};
        return max_size - GetSizeOfCompactSize(max_size);
    }
    return MAX_STANDARD_P2WSH_SCRIPT_SIZE;
}
```

Constants: `MAX_STANDARD_P2WSH_SCRIPT_SIZE = 3600` (policy/policy.h:60),
`MAX_STANDARD_P2WSH_STACK_ITEMS = 100` (policy/policy.h:54), `MAX_OPS_PER_SCRIPT = 201`
(script/script.h:32), `MAX_STACK_SIZE = 1000` (script/script.h:44), `MAX_STANDARD_TX_WEIGHT =
400'000` (policy/policy.h:38), `MAX_TAPMINISCRIPT_STACK_ELEM_SIZE = 65` (miniscript.h:271).

Enforcement points:

| Limit | Enforced at | Mechanism |
|---|---|---|
| Script size ≤ 3600 (wsh) / ~388k (tr) | **During string parse**: `if (script_size > max_size) return {};` (miniscript.h:1915, 1934) | Running `script_size` accounting |
| Same | **Node-level, both paths**: `Node::IsValid()` (miniscript.h:1675-1678) recomputes `ScriptSize()` | Called by decoder loop (miniscript.h:2308) and by `IsSane*` |
| Same | **Script decode entry**: `FromScript` bails before decomposing (miniscript.h:2695) | `script.size() > MaxScriptSize(...)` |
| Ops ≤ 201 | `Node::CheckOpsLimit()` (miniscript.h:1571-1575) | `GetOps() <= MAX_OPS_PER_SCRIPT`, **skipped for Tapscript** (`if (IsTapscript(m_script_ctx)) return true;`) since Tapscript has no per-script op limit (sigops budget instead) |
| Stack: ≤100 *initial* witness items (wsh) / ≤1000 *during execution* (tr) | `Node::CheckStackSize()` (miniscript.h:1594-1604) | wsh: `GetStackSize() <= MAX_STANDARD_P2WSH_STACK_ITEMS`; tr: `GetExecStackSize() <= MAX_STACK_SIZE` (`exec+1`, per SatInfo semiring, miniscript.h:400-505) |
| multi ≤20 keys / multi_a ≤999 keys | String parser `parse_multi_exp` (miniscript.h:1879, 1901); decoder (miniscript.h:2384, 2404, 2418); node type check (miniscript.cpp:75-80) | All three layers |
| `k≤n` thresh / multi | parser (miniscript.h:1902, 2175), decoder (miniscript.h:2392, 2422 vs keys.size(), 2603), `ComputeType` (miniscript.cpp:52-55) | |
| Tree depth in `tr(...)` | descriptor.cpp:2603-2606: `branches.size() > TAPROOT_CONTROL_MAX_NODE_COUNT` → error | descriptor layer only; 128 levels |

`CheckOpsLimit`/`CheckStackSize` reach the descriptor layer through `IsSane()` →
`IsSaneSubexpression()` → `ValidSatisfactions()` at descriptor.cpp:2745 (string) and
descriptor.cpp:2950 (`node->IsSane()`, script-inference path). The InferScript path additionally
does not need an explicit `IsNotSatisfiable` check — impossible-on-its-face scripts can't decode to
a well-typed tree — but sanity is still required (`node && node->IsSane()`).

---

## 5. Key handling per context

### Descriptor-layer key parsing (`ParsePubkeyInner`, descriptor.cpp:1983-2059)

- `permit_uncompressed = ctx == ParseScriptContext::TOP || ctx == ParseScriptContext::P2SH`
  (line 1986) — so inside **wsh()/tr() miniscript, only compressed keys**:
  - 65-byte uncompressed → `"Uncompressed keys are not allowed"` (lines 2006-2013).
  - 33-byte compressed → `ConstPubkeyProvider(idx, pubkey, false)`.
  - **32-byte hex is accepted only in `P2TR`** as an x-only key (even-Y is assumed by setting
    prefix 0x02), producing an x-only-typed provider:

```cpp
// descriptor.cpp:2014-2022
            } else if (data.size() == 32 && ctx == ParseScriptContext::P2TR) {
                unsigned char fullkey[33] = {0x02};
                std::copy(data.begin(), data.end(), fullkey + 1);
                pubkey.Set(std::begin(fullkey), std::end(fullkey));
                if (pubkey.IsFullyValid()) {
                    ret.emplace_back(std::make_unique<ConstPubkeyProvider>(key_exp_index, pubkey, true));
```

  - WIF private keys: uncompressed rejected outside TOP/P2SH (lines 2027-2038).
  - BIP32 xpub/xprv with optional origin info `[fpr/path...]` and derivation path
    (`/0/1/...`, ranged `*` / hardened `*'` or `*h`, multipath `<0;1>`): lines 2041-2058,
    origin handled in `ParsePubkey` (2210-2249) — allowed (and common) inside miniscript key
    positions, including in `tr()`. Nested `musig(...)` allowed only in P2TR context
    (lines 2071-2075: `"musig() is only allowed in tr() and rawtr()"`).

### Glue into the miniscript parser: `KeyParser` (descriptor.cpp:2284-2388)

- String direction: `KeyParser::FromString` → `ParsePubkey(m_expr_index, in, ParseContext(), ...)`
  where `ParseContext()` maps `MiniscriptContext::P2WSH → ParseScriptContext::P2WSH` and
  `TAPSCRIPT → P2TR` (lines 2320-2326). So key syntax differences (32B x-only) follow purely from
  the miniscript context.
- Script direction: `FromPKBytes` accepts 32-byte keys **only under Tapscript** and any valid
  `CPubKey` size only under **P2WSH**:

```cpp
// descriptor.cpp:2343-2364
    template<typename I> std::optional<Key> FromPKBytes(I begin, I end) const
    {
        assert(m_in);
        Key key = m_keys.size();
        if (miniscript::IsTapscript(m_script_ctx) && end - begin == 32) {
            XOnlyPubKey pubkey;
            std::copy(begin, end, pubkey.begin());
            if (auto pubkey_provider = InferXOnlyPubkey(pubkey, ParseContext(), *m_in)) { ... }
        } else if (!miniscript::IsTapscript(m_script_ctx)) {
            CPubKey pubkey(begin, end);
            if (auto pubkey_provider = InferPubkey(pubkey, ParseContext(), *m_in)) { ... }
        }
        return {};
    }
```

  `InferPubkey` additionally rejects non-compressed keys outside TOP/P2SH
  (descriptor.cpp:2258-2260) and always rejects hybrid keys (:2255). so a 65-byte key embedded in a
  wsh witness script will not deserialize to a descriptor.

### Script serialization: `ScriptMaker` (descriptor.cpp:1643-1675)

- `ToPKBytes`: P2WSH → full 33-byte compressed pubkey; Tapscript → **always 32-byte x-only**
  even if the descriptor used a full key (lines 1662-1669).
- `ToPKHBytes` (`pk_h`/`pkh`): `Hash160` of the x-only key under Tapscript, plain `GetID()` under
  P2WSH (lines 1652-1657) — i.e. `hash160(xonly)` vs `hash160(compressed)`.

The miniscript engine itself is key-type/size agnostic in the text parser ("It is compatible for
both compressed and x-only keys", miniscript.h:1889); length checks for keys appear only at the
*script*-decode layer (33B for MULTI, 32B for MULTI_A — §2) and in the context (`FromPKBytes`).

---

## 6. `MiniscriptContext` impact; how `wsh()` and `tr()` differ in descriptor.cpp

`enum class MiniscriptContext { P2WSH, TAPSCRIPT }` (miniscript.h:253-256). Effects inside the
engine:

1. **Grammar gating**: `multi(` vs `multi_a(` (string parse, miniscript.h:1880-1881); MULTI rejected
   when decoding in Tapscript, MULTI_A rejected when not (miniscript.h:2380, 2400);
   `CHECK_NONFATAL(!is_tapscript)` / `CHECK_NONFATAL(is_tapscript)` in `ToScript`/`ToString`
   (miniscript.h:848, 856, 969, 979).
2. **Size/ops/stack limits**: §4 (`MaxScriptSize`, `CheckOpsLimit`, `CheckStackSize`).
3. **Type system**: `WRAP_D` gets `u` under Tapscript only — comment at miniscript.cpp:125-127:
   `'d:' is 'u' under Tapscript but not P2WSH as MINIMALIF is only a policy rule there.`
4. **Script-size accounting in the string parser**: pk/pk_k cost 34/33 bytes in wsh, 33/32 in tr
   (miniscript.h:1987, 1997).
5. **Witness-size estimates**: sig 1+72 vs 1+65, pubkey 1+33 vs 1+32
   (miniscript.h:1194-1195), feeding `MaxSatSize()` (descriptor.cpp:1785-1789).

### The two descriptor call sites

**String → descriptor** (descriptor.cpp:2731-2744), the tail `catch-all` of `ParseScript`:

```cpp
    // Process miniscript expressions.
    {
        const auto script_ctx{ctx == ParseScriptContext::P2WSH ? miniscript::MiniscriptContext::P2WSH : miniscript::MiniscriptContext::TAPSCRIPT};
        KeyParser parser(/*out = */&out, /* in = */nullptr, /* ctx = */script_ctx, key_exp_index);
        auto node = miniscript::FromString(std::string(expr.begin(), expr.end()), parser);
        ...
        if (node) {
            if (ctx != ParseScriptContext::P2WSH && ctx != ParseScriptContext::P2TR) {
                error = "Miniscript expressions can only be used in wsh or tr.";
                return {};
            }
            if (!node->IsSane() || node->IsNotSatisfiable()) { ... }
```

Note the asymmetry: for a *P2SH* context the miniscript parse is attempted with the **Tapscript**
context (any non-P2WSH ctx maps to TAPSCRIPT, line 2733) and rejected afterwards (line 2741) — so
no `multi()`-style P2WSH rules leak into sh()-wrapped positions.

- **`wsh(...)`**: descriptor.cpp:2555-2556 —
  `if ((ctx == ParseScriptContext::TOP || ctx == ParseScriptContext::P2SH) && Func("wsh", expr)) { auto descs = ParseScript(key_exp_index, expr, ParseScriptContext::P2WSH, out, error);` —
  allowed at top level or inside `sh()`; the recursive call with `P2WSH` ctx reaches the
  miniscript block with `MiniscriptContext::P2WSH`.
- **`tr(...)`**: descriptor.cpp:2578-2671 —
  `if (ctx == ParseScriptContext::TOP && Func("tr", expr))` (top-level only; line 2674-2676 error
  otherwise). Parses the internal key with `ParseScriptContext::P2TR` (line 2580), then iteratively
  walks `{...}`-nested tree branches (nesting capped by `TAPROOT_CONTROL_MAX_NODE_COUNT` = 128,
  lines 2603-2606) and parses each leaf with `ParseScript(..., ParseScriptContext::P2TR, ...)`
  (line 2610), which reaches the miniscript block with `MiniscriptContext::TAPSCRIPT`. Depths are
  validated (`TaprootBuilder::ValidDepths`, line 2637) and wrapped in `TRDescriptor`
  (line 2669). Multipath lengths are equalized across leaves (lines 2641-2659).

The built `MiniscriptDescriptor` (one per multipath expansion, lines 2792-2801, via
`node->Clone()`) lives as the single sub-descriptor of `WSHDescriptor` or one leaf-desc of
`TRDescriptor`; `MiniscriptDescriptor::MakeScripts` (descriptor.cpp:1731-1743) re-derives the
context with `m_node.GetMsCtx()` so script generation is consistent with the parse-time context.
The constructor additionally walks the tree to warn on `older()` values exceeding the consensus
`SEQUENCE_LOCKTIME_MASK` granularity (descriptor.cpp:1749-1763 — time-vs-height warnings).

**Script → descriptor** (`InferScript`, descriptor.cpp:2945-2958), used by
`InferDescriptor()`/`AddressDescriptor` recovery and `wsh`/`sh(wsh)`/`tr` script inference:

```cpp
    if (ctx == ParseScriptContext::P2WSH || ctx == ParseScriptContext::P2TR) {
        const auto script_ctx{ctx == ParseScriptContext::P2WSH ? miniscript::MiniscriptContext::P2WSH : miniscript::MiniscriptContext::TAPSCRIPT};
        uint32_t key_exp_index = 0;
        KeyParser parser(/* out = */nullptr, /* in = */&provider, /* ctx = */script_ctx, key_exp_index);
        auto node = miniscript::FromScript(script, parser);
        if (node && node->IsSane()) { ... return std::make_unique<MiniscriptDescriptor>(...) }
    }
```

Here the context comes from the *enclosing output type*: a P2WSH `scriptPubKey`'s witnessScript
(→ `InferScript(subscript, ParseScriptContext::P2WSH, provider)`, line 2899), or a Taproot leaf
script (→ `InferScript(CScript(...), ParseScriptContext::P2TR, provider)`, line 2920, via
`InferTaprootTree`).

### One nuance on `pk`/`pkh` name collision

At the *descriptor* level, `pk(KEY)`/`pkh(KEY)` are bound earlier in `ParseScript`
(descriptor.cpp:2398-2419) to legacy `PKDescriptor`/`PKHDescriptor` — `pkh` only in
TOP/P2SH/P2WSH, `pk` anywhere (tr: `PKDescriptor` with x-only flag). The miniscript sugar
`pk()`/`pkh()` (miniscript.h:1983-1992) only sees keys *inside* a miniscript expression that was
not already consumed by those earlier descriptor branches (e.g. `wsh(pk(K))` at TOP gives a legacy
PK-in-wsh; but `wsh(miniscript...)`, any `...and_v(pk(K),...)`, or any position after wrappers,
goes through the miniscript parser). Under `tr()` context, descriptor `pkh` is not offered at all,
so `tr(_,pkh(K))` falls into the miniscript block where *miniscript* `pkh(K)` = `c:pk_h(K)` under
TAPSCRIPT — a real behavioral fork between the two layers worth noting.

---

## Appendix — quick map of cited locations

| Item | File:lines |
|---|---|
| `Parse` string parser | miniscript.h:1853-2211 |
| Wrapper prefix scan + `vv` guard | miniscript.h:1922-1976 |
| Leaf fragments + sugar (pk/pkh/0/1) | miniscript.h:1978-2002 |
| Hash size checks | miniscript.h:1824-1833, 2003-2022 |
| after/older 1≤n<2³¹ | miniscript.h:2023-2036 |
| multi/multi_a args: k first, then keys | miniscript.h:1878-1912 |
| thresh k/n checks | miniscript.h:2041-2050, 2167-2189 |
| `script_size` budget | miniscript.h:1858-1869, 1915, 1934 |
| `FromString` | miniscript.h:2684-2688 |
| `FromScript` + size pre-check | miniscript.h:2690-2703 |
| `DecomposeScript` (VERIFY fusion/minimality) | miniscript.cpp:368-406 |
| `ParseScriptNumber` (minimality, ≤4 bytes) | miniscript.cpp:408-419 |
| `DecodeScript` | miniscript.h:2295-2680 |
| IsValid/IsSane/… | miniscript.h:1674-1702, 1606-1607 |
| CheckOpsLimit/CheckStackSize | miniscript.h:1571-1575, 1594-1604 |
| MaxScriptSize | miniscript.h:284-296 |
| ComputeType/SanitizeType | miniscript.cpp:39-262 / 19-37 |
| KeyParser (context key glue) | descriptor.cpp:2284-2388 |
| ParsePubkeyInner compressed/x-only rules | descriptor.cpp:1983-2059 |
| ParsePubkey + origin/BIP32 | descriptor.cpp:2063-2249 |
| InferPubkey/InferXOnlyPubkey | descriptor.cpp:2252-2278 |
| Miniscript catch-all in ParseScript | descriptor.cpp:2731-2812 |
| wsh() path | descriptor.cpp:2555-2565 |
| tr() path + tree depth cap | descriptor.cpp:2578-2677 |
| InferScript miniscript path | descriptor.cpp:2945-2958 |
| ScriptMaker serialization ctx switch | descriptor.cpp:1643-1675 |
| Limits constants | script.h:30-48, policy.h:38/54/60 |
