# Bitcoin Core Miniscript — Static Type System Reference

Target for Lean formalization. Source analyzed (READ-ONLY):

- `/home/qrsnap/git/miniscript-lean/bitcoin-core/src/script/miniscript.h` (2707 lines)
- `/home/qrsnap/git/miniscript-lean/bitcoin-core/src/script/miniscript.cpp` (432 lines)
- Repo revision: `f86c614` (Merge bitcoin/bitcoin#35919), checked out 2026-10-21.

Below, `h:NNN` = miniscript.h line, `cpp:NNN` = miniscript.cpp line.

**Notation used throughout:** for a child type `X ∈ {x, y, z, tᵢ}`, `X.p` means "`X` has property `p`", i.e. `X << "p"_mst` in C++ (see §1.3 for the direction of `<<`). Conjunction `∧`, disjunction `∨`, negation `¬`. `tap` abbreviates `IsTapscript(ms_ctx)`. The empty type (flags = 0) is written `⊥`; a `Type` value is *valid* iff it survives `SanitizeType` non-empty (§3).

---

## 1. The `Type` class (h:130–158)

### 1.1 Definition

```cpp
class Type {
    //! Internal bitmap of properties (see ""_mst operator for details).
    uint32_t m_flags;

    //! Internal constructor used by the ""_mst operator.
    explicit constexpr Type(uint32_t flags) : m_flags(flags) {}

public:
    //! The only way to publicly construct a Type is using this literal operator.
    friend consteval Type operator""_mst(const char* c, size_t l);
    ...
};
```
(h:130–139)

A `Type` is just a `uint32_t` bitmask. Public construction is *only* via the compile-time literal `_mst` (§1.4). `Type{0}` (all bits clear) is the **empty/invalid type**, spelled `""_mst`.

### 1.2 Bit layout (from `_mst`, h:161–191)

| char | bit | value (1<<bit) | C++ comment (h:) | meaning |
|------|-----|----------------|------------------|---------|
| `B`  | 0   | 1       | 167 | Base type |
| `V`  | 1   | 2       | 168 | Verify type |
| `K`  | 2   | 4       | 169 | Key type |
| `W`  | 3   | 8       | 170 | Wrapped type |
| `z`  | 4   | 16      | 171 | Zero-arg property |
| `o`  | 5   | 32      | 172 | One-arg property |
| `n`  | 6   | 64      | 173 | Nonzero arg property |
| `d`  | 7   | 128     | 174 | Dissatisfiable property |
| `u`  | 8   | 256     | 175 | Unit property |
| `e`  | 9   | 512     | 176 | Expression property |
| `f`  | 10  | 1024    | 177 | Forced property |
| `s`  | 11  | 2048    | 178 | Safe property |
| `m`  | 12  | 4096    | 179 | Nonmalleable property |
| `x`  | 13  | 8192    | 180 | Expensive verify |
| `g`  | 14  | 16384   | 181 | older: relative **time** timelock (csv_time) |
| `h`  | 15  | 32768   | 182 | older: relative **height** timelock (csv_height) |
| `i`  | 16  | 65536   | 183 | after: **time** timelock (cltv_time) |
| `j`  | 17  | 131072  | 184 | after: **height** timelock (cltv_height) |
| `k`  | 18  | 262144  | 185 | does not contain a combination of height and time locks |

Bits 19–31 are unused. Property semantics are documented in the class comment h:39–129 ("B/V/K/W" basic types h:44–71, correctness props `zondue` h:72–90, nonmalleability props `efsm` h:91–107, `x` h:108–113, timelock props `ghijk` h:114–129, including the *subset rule*: "an expression with properties X, Y, and Z, is also valid in places where an X, a Y, a Z, an XY, ... is expected" h:127–128).

### 1.3 Operators (exact code)

```cpp
    //! Compute the type with the union of properties.
    constexpr Type operator|(Type x) const { return Type(m_flags | x.m_flags); }

    //! Compute the type with the intersection of properties.
    constexpr Type operator&(Type x) const { return Type(m_flags & x.m_flags); }

    //! Check whether the left hand's properties are superset of the right's (= left is a subtype of right).
    constexpr bool operator<<(Type x) const { return (x.m_flags & ~m_flags) == 0; }

    //! Comparison operator to enable use in sets/maps (total ordering incompatible with <<).
    constexpr bool operator<(Type x) const { return m_flags < x.m_flags; }

    //! Equality operator.
    constexpr bool operator==(Type x) const { return m_flags == x.m_flags; }

    //! The empty type if x is false, itself otherwise.
    constexpr Type If(bool x) const { return Type(x ? m_flags : 0); }
```
(h:141–157)

Formal reading (let `A = a.m_flags`, `B = b.m_flags` as subsets of {0..18}):

| operator | C++ | set-theoretic meaning |
|---|---|---|
| `a \| b` | `Type(A \| B)` | union A ∪ B |
| `a & b` | `Type(A & B)` | intersection A ∩ B |
| `a << b` | `(B & ~A) == 0` | **A ⊇ B** — "a's properties are a superset of b's", i.e. *a is a subtype of b*. `X << "abc"_mst` ⟺ `X.a ∧ X.b ∧ X.c`. Note the receiver is the *left* argument: `this` ⊇ `x`. |
| `a < b` | `A < B` (integer compare) | total order for sets/maps; explicitly **incompatible with `<<`** (h:150) |
| `a == b` | `A == B` | flag equality |
| `a.If(c)` | `Type(c ? A : 0)` | `A` if `c`, else `⊥` |

Usage note baked into `ComputeType` (cpp:86–87):
```cpp
    // It heavily relies on Type's << operator (where "X << a_mst" means
    // "X has all properties listed in a").
```

Consequences for formalization:
- `x << y` is only meaningful when `y` is a *literal-like* mask; it is not a symmetric relation and it is not bitwise implication "a ⊆ b" — it is "a ⊇ b".
- `a | ⊥ = a`, `a & ⊥ = ⊥`, `⊥ << q = false` for any nonempty `q`, `a << ""_mst = true` for all `a` (any type is a "subtype" of the empty property list — used e.g. in `(x | y) << "z"_mst` where it means union-has-z).
- `⊥.If(c) = ⊥` always.
- `(a & mask)` is the standard "pass through only these property bits" idiom.

### 1.4 `operator""_mst` (h:160–191) — exact char→bit mapping

```cpp
//! Literal operator to construct Type objects.
inline consteval Type operator""_mst(const char* c, size_t l)
{
    Type typ{0};

    for (const char *p = c; p < c + l; p++) {
        typ = typ | Type(
            *p == 'B' ? 1 << 0 : // Base type
            *p == 'V' ? 1 << 1 : // Verify type
            *p == 'K' ? 1 << 2 : // Key type
            *p == 'W' ? 1 << 3 : // Wrapped type
            *p == 'z' ? 1 << 4 : // Zero-arg property
            *p == 'o' ? 1 << 5 : // One-arg property
            *p == 'n' ? 1 << 6 : // Nonzero arg property
            *p == 'd' ? 1 << 7 : // Dissatisfiable property
            *p == 'u' ? 1 << 8 : // Unit property
            *p == 'e' ? 1 << 9 : // Expression property
            *p == 'f' ? 1 << 10 : // Forced property
            *p == 's' ? 1 << 11 : // Safe property
            *p == 'm' ? 1 << 12 : // Nonmalleable property
            *p == 'x' ? 1 << 13 : // Expensive verify
            *p == 'g' ? 1 << 14 : // older: contains relative time timelock   (csv_time)
            *p == 'h' ? 1 << 15 : // older: contains relative height timelock (csv_height)
            *p == 'i' ? 1 << 16 : // after: contains time timelock   (cltv_time)
            *p == 'j' ? 1 << 17 : // after: contains height timelock   (cltv_height)
            *p == 'k' ? 1 << 18 : // does not contain a combination of height and time locks
            (throw std::logic_error("Unknown character in _mst literal"), 0)
        );
    }

    return typ;
}
```
(h:161–191)

- Chars are OR-accumulated; order irrelevant; duplicates idempotent.
- Any char ∉ the 19-letter alphabet throws `std::logic_error`; since the operator is `consteval`, this is a **compile-time** error for literals.
- Mapping table = §1.2.

### 1.5 Failure model: graceful `⊥` vs `CHECK_NONFATAL`

Two failure channels exist and must be distinguished in any formalization:

1. **Graceful invalidity:** a `Type` with none of B/V/K/W is converted to `⊥` by `SanitizeType` (§3), and `ComputeType` itself returns `""_mst` early for `THRESH` with bad children (cpp:237).
2. **Invariant violations:** all `CHECK_NONFATAL(cond)` checks (util/check.h:115–116) are the identity when `cond` holds, and otherwise **throw `NonFatalCheckError`** (release) / abort (debug builds) — via `inline_check_non_fatal` (util/check.h:75–82). They are documented as *"this should only be used where the condition is assumed to be true, not for error handling"* (util/check.h:103–113). For the Lean model, treat every `CHECK_NONFATAL` in `ComputeType`/`SanitizeType` as a **precondition** of the function, not part of the returned value.

---

## 2. `ComputeType` (cpp:39–262)

Signature:
```cpp
Type ComputeType(Fragment fragment, Type x, Type y, Type z, const std::vector<Type>& sub_types, uint32_t k,
                 size_t data_size, size_t n_subs, size_t n_keys, MiniscriptContext ms_ctx)
```
(cpp:39–40; declared h:299)

`x, y, z` are the types of children 0, 1, 2 (empty `""_mst` when absent); `sub_types` is filled only for `THRESH` (h:783–791). The result is passed through `SanitizeType` by `Node::CalcType` (§5.1).

### 2.0 Global pre-flight checks (all `CHECK_NONFATAL`, i.e. preconditions; cpp:41–83)

```cpp
    // Sanity check on data
    if (fragment == Fragment::SHA256 || fragment == Fragment::HASH256) {
        CHECK_NONFATAL(data_size == 32);
    } else if (fragment == Fragment::RIPEMD160 || fragment == Fragment::HASH160) {
        CHECK_NONFATAL(data_size == 20);
    } else {
        CHECK_NONFATAL(data_size == 0);
    }
    // Sanity check on k
    if (fragment == Fragment::OLDER || fragment == Fragment::AFTER) {
        CHECK_NONFATAL(k >= 1 && k < 0x80000000UL);
    } else if (fragment == Fragment::MULTI || fragment == Fragment::MULTI_A) {
        CHECK_NONFATAL(k >= 1 && k <= n_keys);
    } else if (fragment == Fragment::THRESH) {
        CHECK_NONFATAL(k >= 1 && k <= n_subs);
    } else {
        CHECK_NONFATAL(k == 0);
    }
    // Sanity check on subs
    if (fragment == Fragment::AND_V || fragment == Fragment::AND_B || fragment == Fragment::OR_B ||
        fragment == Fragment::OR_C || fragment == Fragment::OR_I || fragment == Fragment::OR_D) {
        CHECK_NONFATAL(n_subs == 2);
    } else if (fragment == Fragment::ANDOR) {
        CHECK_NONFATAL(n_subs == 3);
    } else if (fragment == Fragment::WRAP_A || fragment == Fragment::WRAP_S || fragment == Fragment::WRAP_C ||
               fragment == Fragment::WRAP_D || fragment == Fragment::WRAP_V || fragment == Fragment::WRAP_J ||
               fragment == Fragment::WRAP_N) {
        CHECK_NONFATAL(n_subs == 1);
    } else if (fragment != Fragment::THRESH) {
        CHECK_NONFATAL(n_subs == 0);
    }
    // Sanity check on keys
    if (fragment == Fragment::PK_K || fragment == Fragment::PK_H) {
        CHECK_NONFATAL(n_keys == 1);
    } else if (fragment == Fragment::MULTI) {
        CHECK_NONFATAL(n_keys >= 1 && n_keys <= MAX_PUBKEYS_PER_MULTISIG);
        CHECK_NONFATAL(!IsTapscript(ms_ctx));
    } else if (fragment == Fragment::MULTI_A) {
        CHECK_NONFATAL(n_keys >= 1 && n_keys <= MAX_PUBKEYS_PER_MULTI_A);
        CHECK_NONFATAL(IsTapscript(ms_ctx));
    } else {
        CHECK_NONFATAL(n_keys == 0);
    }
```
(cpp:41–83)

External constants: `MAX_PUBKEYS_PER_MULTISIG = 20` (script/script.h:35), `MAX_PUBKEYS_PER_MULTI_A = 999` (script/script.h:38). Note the two **context guards**: `MULTI` requires `¬tap` (cpp:77), `MULTI_A` requires `tap` (cpp:80) — see §4.

### 2.1 Fragment reference

Each entry gives: script template (from the `Fragment` enum doc, h:213–245), exact C++, then **Requires** (minimal conditions on child types so the raw result has ≥1 basic-type bit, i.e. is non-`⊥` after `SanitizeType`) and **Computes** (formula per output property; "—" = never set). Unless stated otherwise, requirements failures are *implicit* (empty result), not exceptions.

---

#### `JUST_0` — `OP_0`

```cpp
        case Fragment::JUST_0: return "Bzudemsxk"_mst;
```
(cpp:104)

- Requires: nothing (leaf). Pre-flight: k=0, no data/subs/keys.
- Computes (constant): **B z u d e m s x k** = {B, z, o̸, n̸, d, u, e, f̸, s, m, x, k}. Mask `0x43B91`.

#### `JUST_1` — `OP_1`

```cpp
        case Fragment::JUST_1: return "Bzufmxk"_mst;
```
(cpp:103)

- Requires: nothing.
- Computes (constant): **B z u f m x k** = {B, z, u, f, m, x, k}. Mask `0x43511`.

#### `PK_K` — `[key]`

```cpp
        case Fragment::PK_K: return "Konudemsxk"_mst;
```
(cpp:89)

- Requires: nothing (pre-flight n_keys=1, cpp:73–74).
- Computes (constant): **K o n u d e m s x k** = {K, o, n, u, d, e, m, s, x, k}. Mask `0x43BE4`.

#### `PK_H` — `OP_DUP OP_HASH160 [keyhash] OP_EQUALVERIFY`

```cpp
        case Fragment::PK_H: return "Knudemsxk"_mst;
```
(cpp:90)

- Requires: nothing (pre-flight n_keys=1).
- Computes (constant): **K n u d e m s x k** (no `o`) = {K, n, u, d, e, m, s, x, k}. Mask `0x43BC4`.

#### `OLDER` — `[n] OP_CHECKSEQUENCEVERIFY`

```cpp
        case Fragment::OLDER: return
            "g"_mst.If(k & CTxIn::SEQUENCE_LOCKTIME_TYPE_FLAG) |
            "h"_mst.If(!(k & CTxIn::SEQUENCE_LOCKTIME_TYPE_FLAG)) |
            "Bzfmxk"_mst;
```
(cpp:91–94)

- Requires: nothing (pre-flight `1 ≤ k < 0x80000000`, cpp:50–51).
- Computes:
  - `g` ⟺ `k & 0x400000 ≠ 0` (SEQUENCE_LOCKTIME_TYPE_FLAG = `1 << 22`, primitives/transaction.h:100 — time-based relative lock)
  - `h` ⟺ `k & 0x400000 = 0` (height-based relative lock)
  - always: **B z f m x k**.

#### `AFTER` — `[n] OP_CHECKLOCKTIMEVERIFY`

```cpp
        case Fragment::AFTER: return
            "i"_mst.If(k >= LOCKTIME_THRESHOLD) |
            "j"_mst.If(k < LOCKTIME_THRESHOLD) |
            "Bzfmxk"_mst;
```
(cpp:95–98)

- Requires: nothing (pre-flight `1 ≤ k < 0x80000000`).
- Computes:
  - `i` ⟺ `k ≥ 500000000` (`LOCKTIME_THRESHOLD`, script/script.h:48 — absolute time lock)
  - `j` ⟺ `k < 500000000` (absolute height lock)
  - always: **B z f m x k**.

#### `SHA256`, `HASH256`, `RIPEMD160`, `HASH160` — `OP_SIZE 32 OP_EQUALVERIFY OP_<HASH> [hash] OP_EQUAL`

```cpp
        case Fragment::SHA256: return "Bonudmk"_mst;
        case Fragment::RIPEMD160: return "Bonudmk"_mst;
        case Fragment::HASH256: return "Bonudmk"_mst;
        case Fragment::HASH160: return "Bonudmk"_mst;
```
(cpp:99–102)

- Requires: nothing (pre-flight data_size 32 for SHA256/HASH256, 20 for RIPEMD160/HASH160, cpp:42–45).
- Computes (constant): **B o n u d m k** = {B, o, n, u, d, m, k}. Mask `0x411E1`. (No `x`: last opcode is `OP_EQUAL`, cheaply verify-ifiable; no `e`/`f`/`s`/`z`.)

#### `WRAP_A` (`a:`) — `OP_TOALTSTACK [X] OP_FROMALTSTACK`

```cpp
        case Fragment::WRAP_A: return
            "W"_mst.If(x << "B"_mst) | // W=B_x
            (x & "ghijk"_mst) | // g=g_x, h=h_x, i=i_x, j=j_x, k=k_x
            (x & "udfems"_mst) | // u=u_x, d=d_x, f=f_x, e=e_x, m=m_x, s=s_x
            "x"_mst; // x
```
(cpp:105–109)

| | |
|---|---|
| **Requires** | `x.B` |
| **Computes** | `W ⟺ x.B`; `g,h,i,j,k,u,d,f,e,m,s ⟵ x` (pass-through); `x := 1` always; `z,o,n` never |

#### `WRAP_S` (`s:`) — `OP_SWAP [X]`

```cpp
        case Fragment::WRAP_S: return
            "W"_mst.If(x << "Bo"_mst) | // W=B_x*o_x
            (x & "ghijk"_mst) | // g=g_x, h=h_x, i=i_x, j=j_x, k=k_x
            (x & "udfemsx"_mst); // u=u_x, d=d_x, f=f_x, e=e_x, m=m_x, s=s_x, x=x_x
```
(cpp:110–113)

| | |
|---|---|
| **Requires** | `x.B ∧ x.o` |
| **Computes** | `W ⟺ x.B ∧ x.o`; `g,h,i,j,k,u,d,f,e,m,s,x ⟵ x`; `z,o,n` never set by the wrapper |

#### `WRAP_C` (`c:`) — `[X] OP_CHECKSIG`

```cpp
        case Fragment::WRAP_C: return
            "B"_mst.If(x << "K"_mst) | // B=K_x
            (x & "ghijk"_mst) | // g=g_x, h=h_x, i=i_x, j=j_x, k=k_x
            (x & "ondfem"_mst) | // o=o_x, n=n_x, d=d_x, f=f_x, e=e_x, m=m_x
            "us"_mst; // u, s
```
(cpp:114–118)

| | |
|---|---|
| **Requires** | `x.K` |
| **Computes** | `B ⟺ x.K`; `g,h,i,j,k,o,n,d,f,e,m ⟵ x`; `u := 1`, `s := 1` always; `z,x` never |

#### `WRAP_D` (`d:`) — `OP_DUP OP_IF [X] OP_ENDIF`

```cpp
        case Fragment::WRAP_D: return
            "B"_mst.If(x << "Vz"_mst) | // B=V_x*z_x
            "o"_mst.If(x << "z"_mst) | // o=z_x
            "e"_mst.If(x << "f"_mst) | // e=f_x
            (x & "ghijk"_mst) | // g=g_x, h=h_x, i=i_x, j=j_x, k=k_x
            (x & "ms"_mst) | // m=m_x, s=s_x
            // NOTE: 'd:' is 'u' under Tapscript but not P2WSH as MINIMALIF is only a policy rule there.
            "u"_mst.If(IsTapscript(ms_ctx)) |
            "ndx"_mst; // n, d, x
```
(cpp:119–127)

| | |
|---|---|
| **Requires** | `x.V ∧ x.z` |
| **Computes** | `B ⟺ x.V ∧ x.z`; `o ⟺ x.z` (so o=1 whenever valid); `e ⟺ x.f`; `g,h,i,j,k,m,s ⟵ x`; **`u ⟺ tap`** (context-dependent!); `n,d,x := 1` always; `z,f` never |

Context note: under P2WSH, MINIMALIF is only a *standardness* rule, so the `d:` wrapper's duplicated stack element is not guaranteed canonical 1; under Tapscript MINIMALIF is consensus, hence `u` (cpp:125–126).

#### `WRAP_V` (`v:`) — `[X] OP_VERIFY` (or VERIFY-form of last opcode)

```cpp
        case Fragment::WRAP_V: return
            "V"_mst.If(x << "B"_mst) | // V=B_x
            (x & "ghijk"_mst) | // g=g_x, h=h_x, i=i_x, j=j_x, k=k_x
            (x & "zonms"_mst) | // z=z_x, o=o_x, n=n_x, m=m_x, s=s_x
            "fx"_mst; // f, x
```
(cpp:128–132)

| | |
|---|---|
| **Requires** | `x.B` |
| **Computes** | `V ⟺ x.B`; `g,h,i,j,k,z,o,n,m,s ⟵ x`; `f := 1`, `x := 1` always; `d,u,e` never (V-fragment) |

#### `WRAP_J` (`j:`) — `OP_SIZE OP_0NOTEQUAL OP_IF [X] OP_ENDIF`

```cpp
        case Fragment::WRAP_J: return
            "B"_mst.If(x << "Bn"_mst) | // B=B_x*n_x
            "e"_mst.If(x << "f"_mst) | // e=f_x
            (x & "ghijk"_mst) | // g=g_x, h=h_x, i=i_x, j=j_x, k=k_x
            (x & "oums"_mst) | // o=o_x, u=u_x, m=m_x, s=s_x
            "ndx"_mst; // n, d, x
```
(cpp:133–138)

| | |
|---|---|
| **Requires** | `x.B ∧ x.n` |
| **Computes** | `B ⟺ x.B ∧ x.n`; `e ⟺ x.f`; `g,h,i,j,k,o,u,m,s ⟵ x`; `n,d,x := 1` always; `z,f` never |

#### `WRAP_N` (`n:`) — `[X] OP_0NOTEQUAL`

```cpp
        case Fragment::WRAP_N: return
            (x & "ghijk"_mst) | // g=g_x, h=h_x, i=i_x, j=j_x, k=k_x
            (x & "Bzondfems"_mst) | // B=B_x, z=z_x, o=o_x, n=n_x, d=d_x, f=f_x, e=e_x, m=m_x, s=s_x
            "ux"_mst; // u, x
```
(cpp:139–142)

| | |
|---|---|
| **Requires** | `x.B` |
| **Computes** | `B ⟵ x`; `g,h,i,j,k,z,o,n,d,f,e,m,s ⟵ x`; `u := 1`, `x := 1` always |

#### `AND_V` (`and_v(X,Y)`) — `[X] [Y]`

```cpp
        case Fragment::AND_V: return
            (y & "KVB"_mst).If(x << "V"_mst) | // B=V_x*B_y, V=V_x*V_y, K=V_x*K_y
            (x & "n"_mst) | (y & "n"_mst).If(x << "z"_mst) | // n=n_x+z_x*n_y
            ((x | y) & "o"_mst).If((x | y) << "z"_mst) | // o=o_x*z_y+z_x*o_y
            (x & y & "mz"_mst) | // m=m_x*m_y, z=z_x*z_y
            ((x | y) & "s"_mst) | // s=s_x+s_y
            "f"_mst.If((y << "f"_mst) || (x << "s"_mst)) | // f=f_y+s_x
            (y & "ux"_mst) | // u=u_y, x=x_y
            ((x | y) & "ghij"_mst) | // g=g_x+g_y, h=h_x+h_y, i=i_x+i_y, j=j_x+j_y
            "k"_mst.If(((x & y) << "k"_mst) &&
                !(((x << "g"_mst) && (y << "h"_mst)) ||
                ((x << "h"_mst) && (y << "g"_mst)) ||
                ((x << "i"_mst) && (y << "j"_mst)) ||
                ((x << "j"_mst) && (y << "i"_mst)))); // k=k_x*k_y*!(g_x*h_y + h_x*g_y + i_x*j_y + j_x*i_y)
```
(cpp:143–156)

| | |
|---|---|
| **Requires** | `x.V ∧ (y.K ∨ y.V ∨ y.B)` |
| **Computes** | `B ⟺ x.V∧y.B`, `V ⟺ x.V∧y.V`, `K ⟺ x.V∧y.K`; `n ⟺ x.n ∨ (x.z ∧ y.n)`; `o ⟺ (x.o ∨ y.o) ∧ (x.z ∨ y.z)`; `z ⟺ x.z ∧ y.z`; `m ⟺ x.m ∧ y.m`; `s ⟺ x.s ∨ y.s`; `f ⟺ y.f ∨ x.s`; `u ⟺ y.u`; `x ⟺ y.x`; `g ⟺ x.g ∨ y.g` (same for h,i,j); `k ⟺ x.k ∧ y.k ∧ ¬((x.g∧y.h) ∨ (x.h∧y.g) ∨ (x.i∧y.j) ∨ (x.j∧y.i))`; `d,e` never |

#### `AND_B` (`and_b(X,Y)`) — `[X] [Y] OP_BOOLAND`

```cpp
        case Fragment::AND_B: return
            (x & "B"_mst).If(y << "W"_mst) | // B=B_x*W_y
            ((x | y) & "o"_mst).If((x | y) << "z"_mst) | // o=o_x*z_y+z_x*o_y
            (x & "n"_mst) | (y & "n"_mst).If(x << "z"_mst) | // n=n_x+z_x*n_y
            (x & y & "e"_mst).If((x & y) << "s"_mst) | // e=e_x*e_y*s_x*s_y
            (x & y & "dzm"_mst) | // d=d_x*d_y, z=z_x*z_y, m=m_x*m_y
            "f"_mst.If(((x & y) << "f"_mst) || (x << "sf"_mst) || (y << "sf"_mst)) | // f=f_x*f_y + f_x*s_x + f_y*s_y
            ((x | y) & "s"_mst) | // s=s_x+s_y
            "ux"_mst | // u, x
            ((x | y) & "ghij"_mst) | // g=g_x+g_y, h=h_x+h_y, i=i_x+i_y, j=j_x+j_y
            "k"_mst.If(((x & y) << "k"_mst) &&
                !(((x << "g"_mst) && (y << "h"_mst)) ||
                ((x << "h"_mst) && (y << "g"_mst)) ||
                ((x << "i"_mst) && (y << "j"_mst)) ||
                ((x << "j"_mst) && (y << "i"_mst)))); // k=k_x*k_y*!(g_x*h_y + h_x*g_y + i_x*j_y + j_x*i_y)
```
(cpp:157–171)

| | |
|---|---|
| **Requires** | `x.B ∧ y.W` |
| **Computes** | `B ⟺ x.B ∧ y.W`; `o ⟺ (x.o ∨ y.o) ∧ (x.z ∨ y.z)`; `n ⟺ x.n ∨ (x.z ∧ y.n)`; `e ⟺ x.e ∧ y.e ∧ x.s ∧ y.s`; `d ⟺ x.d ∧ y.d`; `z ⟺ x.z ∧ y.z`; `m ⟺ x.m ∧ y.m`; `f ⟺ (x.f ∧ y.f) ∨ (x.s ∧ x.f) ∨ (y.s ∧ y.f)`; `s ⟺ x.s ∨ y.s`; `u := 1`, `x := 1` always; `g,h,i,j ⟺` childwise ∨; `k ⟺ x.k ∧ y.k ∧ ¬((x.g∧y.h) ∨ (x.h∧y.g) ∨ (x.i∧y.j) ∨ (x.j∧y.i))`; `V,K` never |

#### `OR_B` (`or_b(X,Y)`) — `[X] [Y] OP_BOOLOR`

```cpp
        case Fragment::OR_B: return
            "B"_mst.If(x << "Bd"_mst && y << "Wd"_mst) | // B=B_x*d_x*W_x*d_y
            ((x | y) & "o"_mst).If((x | y) << "z"_mst) | // o=o_x*z_y+z_x*o_y
            (x & y & "m"_mst).If((x | y) << "s"_mst && (x & y) << "e"_mst) | // m=m_x*m_y*e_x*e_y*(s_x+s_y)
            (x & y & "zse"_mst) | // z=z_x*z_y, s=s_x*s_y, e=e_x*e_y
            "dux"_mst | // d, u, x
            ((x | y) & "ghij"_mst) | // g=g_x+g_y, h=h_x+h_y, i=i_x+i_y, j=j_x+j_y
            (x & y & "k"_mst); // k=k_x*k_y
```
(cpp:172–179) — (the `W_x` in the code comment is a typo for `W_y`; the code gates on `y << "Wd"_mst`)

| | |
|---|---|
| **Requires** | `x.B ∧ x.d ∧ y.W ∧ y.d` |
| **Computes** | `B ⟺ x.B∧x.d∧y.W∧y.d`; `o ⟺ (x.o ∨ y.o) ∧ (x.z ∨ y.z)`; `m ⟺ x.m ∧ y.m ∧ (x.s ∨ y.s) ∧ x.e ∧ y.e`; `z ⟺ x.z∧y.z`; `s ⟺ x.s∧y.s`; `e ⟺ x.e∧y.e`; `d,u,x := 1` always; `g,h,i,j ⟺` childwise ∨; `k ⟺ x.k ∧ y.k`; `n,f` never |

#### `OR_D` (`or_d(X,Y)`) — `[X] OP_IFDUP OP_NOTIF [Y] OP_ENDIF`

```cpp
        case Fragment::OR_D: return
            (y & "B"_mst).If(x << "Bdu"_mst) | // B=B_y*B_x*d_x*u_x
            (x & "o"_mst).If(y << "z"_mst) | // o=o_x*z_y
            (x & y & "m"_mst).If(x << "e"_mst && (x | y) << "s"_mst) | // m=m_x*m_y*e_x*(s_x+s_y)
            (x & y & "zs"_mst) | // z=z_x*z_y, s=s_x*s_y
            (y & "ufde"_mst) | // u=u_y, f=f_y, d=d_y, e=e_y
            "x"_mst | // x
            ((x | y) & "ghij"_mst) | // g=g_x+g_y, h=h_x+h_y, i=i_x+i_y, j=j_x+j_y
            (x & y & "k"_mst); // k=k_x*k_y
```
(cpp:180–188)

| | |
|---|---|
| **Requires** | `x.B ∧ x.d ∧ x.u ∧ y.B` |
| **Computes** | `B ⟺ x.B∧x.d∧x.u∧y.B`; `o ⟺ x.o ∧ y.z`; `m ⟺ x.m ∧ y.m ∧ x.e ∧ (x.s ∨ y.s)`; `z ⟺ x.z∧y.z`; `s ⟺ x.s∧y.s`; `u,f,d,e ⟵ y`; `x := 1` always; `g,h,i,j ⟺` childwise ∨; `k ⟺ x.k ∧ y.k` |

#### `OR_C` (`or_c(X,Y)`) — `[X] OP_NOTIF [Y] OP_ENDIF`

```cpp
        case Fragment::OR_C: return
            (y & "V"_mst).If(x << "Bdu"_mst) | // V=V_y*B_x*u_x*d_x
            (x & "o"_mst).If(y << "z"_mst) | // o=o_x*z_y
            (x & y & "m"_mst).If(x << "e"_mst && (x | y) << "s"_mst) | // m=m_x*m_y*e_x*(s_x+s_y)
            (x & y & "zs"_mst) | // z=z_x*z_y, s=s_x*s_y
            "fx"_mst | // f, x
            ((x | y) & "ghij"_mst) | // g=g_x+g_y, h=h_x+h_y, i=i_x+i_y, j=j_x+j_y
            (x & y & "k"_mst); // k=k_x*k_y
```
(cpp:189–196)

| | |
|---|---|
| **Requires** | `x.B ∧ x.d ∧ x.u ∧ y.V` |
| **Computes** | `V ⟺ x.B∧x.d∧x.u∧y.V`; `o ⟺ x.o ∧ y.z`; `m ⟺ x.m ∧ y.m ∧ x.e ∧ (x.s ∨ y.s)`; `z ⟺ x.z∧y.z`; `s ⟺ x.s∧y.s`; `f := 1`, `x := 1` always; `g,h,i,j ⟺` childwise ∨; `k ⟺ x.k ∧ y.k`; `d,u,e` never |

#### `OR_I` (`or_i(X,Y)`) — `OP_IF [X] OP_ELSE [Y] OP_ENDIF`

```cpp
        case Fragment::OR_I: return
            (x & y & "VBKufs"_mst) | // V=V_x*V_y, B=B_x*B_y, K=K_x*K_y, u=u_x*u_y, f=f_x*f_y, s=s_x*s_y
            "o"_mst.If((x & y) << "z"_mst) | // o=z_x*z_y
            ((x | y) & "e"_mst).If((x | y) << "f"_mst) | // e=e_x*f_y+f_x*e_y
            (x & y & "m"_mst).If((x | y) << "s"_mst) | // m=m_x*m_y*(s_x+s_y)
            ((x | y) & "d"_mst) | // d=d_x+d_y
            "x"_mst | // x
            ((x | y) & "ghij"_mst) | // g=g_x+g_y, h=h_x+h_y, i=i_x+i_y, j=j_x+j_y
            (x & y & "k"_mst); // k=k_x*k_y
```
(cpp:197–205)

| | |
|---|---|
| **Requires** | `(x.B∧y.B) ∨ (x.V∧y.V) ∨ (x.K∧y.K)` (children agree on a basic type) |
| **Computes** | `B ⟺ x.B∧y.B`, `V ⟺ x.V∧y.V`, `K ⟺ x.K∧y.K`; `u ⟺ x.u∧y.u`; `f ⟺ x.f∧y.f`; `s ⟺ x.s∧y.s`; `o ⟺ x.z ∧ y.z`; `e ⟺ (x.e ∨ y.e) ∧ (x.f ∨ y.f)`; `m ⟺ x.m ∧ y.m ∧ (x.s ∨ y.s)`; `d ⟺ x.d ∨ y.d`; `x := 1` always; `g,h,i,j ⟺` childwise ∨; `k ⟺ x.k ∧ y.k`; `z,n` never |

#### `ANDOR` (`andor(X,Y,Z)`) — `[X] OP_NOTIF [Z] OP_ELSE [Y] OP_ENDIF`

```cpp
        case Fragment::ANDOR: return
            (y & z & "BKV"_mst).If(x << "Bdu"_mst) | // B=B_x*d_x*u_x*B_y*B_z, K=B_x*d_x*u_x*K_y*K_z, V=B_x*d_x*u_x*V_y*V_z
            (x & y & z & "z"_mst) | // z=z_x*z_y*z_z
            ((x | (y & z)) & "o"_mst).If((x | (y & z)) << "z"_mst) | // o=o_x*z_y*z_z+z_x*o_y*o_z
            (y & z & "u"_mst) | // u=u_y*u_z
            (z & "f"_mst).If((x << "s"_mst) || (y << "f"_mst)) | // f=(s_x+f_y)*f_z
            (z & "d"_mst) | // d=d_z
            (z & "e"_mst).If(x << "s"_mst || y << "f"_mst) | // e=e_z*(s_x+f_y)
            (x & y & z & "m"_mst).If(x << "e"_mst && (x | y | z) << "s"_mst) | // m=m_x*m_y*m_z*e_x*(s_x+s_y+s_z)
            (z & (x | y) & "s"_mst) | // s=s_z*(s_x+s_y)
            "x"_mst | // x
            ((x | y | z) & "ghij"_mst) | // g=g_x+g_y+g_z, h=h_x+h_y+h_z, i=i_x+i_y+i_z, j=j_x+j_y_j_z
            "k"_mst.If(((x & y & z) << "k"_mst) &&
                !(((x << "g"_mst) && (y << "h"_mst)) ||
                ((x << "h"_mst) && (y << "g"_mst)) ||
                ((x << "i"_mst) && (y << "j"_mst)) ||
                ((x << "j"_mst) && (y << "i"_mst)))); // k=k_x*k_y*k_z* !(g_x*h_y + h_x*g_y + i_x*j_y + j_x*i_y)
```
(cpp:206–222)

| | |
|---|---|
| **Requires** | `x.B ∧ x.d ∧ x.u ∧ ((y.B∧z.B) ∨ (y.K∧z.K) ∨ (y.V∧z.V))` |
| **Computes** | `B ⟺ x.B∧x.d∧x.u∧y.B∧z.B`, `K ⟺ x.B∧x.d∧x.u∧y.K∧z.K`, `V ⟺ x.B∧x.d∧x.u∧y.V∧z.V`; `z ⟺ x.z∧y.z∧z.z`; `o ⟺ (x.o ∨ (y.o∧z.o)) ∧ (x.z ∨ (y.z∧z.z))`; `u ⟺ y.u ∧ z.u`; `f ⟺ z.f ∧ (x.s ∨ y.f)`; `d ⟺ z.d`; `e ⟺ z.e ∧ (x.s ∨ y.f)`; `m ⟺ x.m∧y.m∧z.m ∧ x.e ∧ (x.s ∨ y.s ∨ z.s)`; `s ⟺ z.s ∧ (x.s ∨ y.s)`; `x := 1` always; `g,h,i,j ⟺` 3-way ∨; `k ⟺ x.k ∧ y.k ∧ z.k ∧ ¬((x.g∧y.h) ∨ (x.h∧y.g) ∨ (x.i∧y.j) ∨ (x.j∧y.i))` — **note the cross-timelock exclusion tests only x vs y, never z**; `n` never |

#### `MULTI` (`multi(k,key₁..keyₙ)`) — `[k] [key_n]* [n] OP_CHECKMULTISIG`

```cpp
        case Fragment::MULTI: {
            return "Bnudemsk"_mst;
        }
```
(cpp:223–225)

- Context/arity preconditions (exceptions on failure): `¬tap` (cpp:77), `1 ≤ n_keys ≤ 20` (cpp:76), `1 ≤ k ≤ n_keys` (cpp:52–53).
- Requires: nothing (beyond preconditions).
- Computes (constant): **B n u d e m s k** = {B, n, u, d, e, m, s, k}. Mask `0x41BC1`. (No `x` — CHECKMULTISIG has a VERIFY form; no `f`,`z`,`o`.)

#### `MULTI_A` (`multi_a(k,key₁..keyₙ)`) — `[key_0] OP_CHECKSIG ([key_n] OP_CHECKSIGADD)* [k] OP_NUMEQUAL`

```cpp
        case Fragment::MULTI_A: {
            return "Budemsk"_mst;
        }
```
(cpp:226–228)

- Context/arity preconditions: `tap` (cpp:80), `1 ≤ n_keys ≤ 999` (cpp:79), `1 ≤ k ≤ n_keys` (cpp:52–53).
- Requires: nothing (beyond preconditions).
- Computes (constant): **B u d e m s k** = {B, u, d, e, m, s, k}. Mask `0x41B81`. (No `n` — satisfactions need a zero stack element for each non-signing key; no `x` — NUMEQUAL has a VERIFY form.)

#### `THRESH` (`thresh(k,X₁..Xₙ)`) — `[X1] ([Xn] OP_ADD)* [k] OP_EQUAL`

```cpp
        case Fragment::THRESH: {
            bool all_e = true;
            bool all_m = true;
            uint32_t args = 0;
            uint32_t num_s = 0;
            Type acc_tl = "k"_mst;
            for (size_t i = 0; i < sub_types.size(); ++i) {
                Type t = sub_types[i];
                if (!(t << (i ? "Wdu"_mst : "Bdu"_mst))) return ""_mst; // Require Bdu, Wdu, Wdu, ...
                if (!(t << "e"_mst)) all_e = false;
                if (!(t << "m"_mst)) all_m = false;
                if (t << "s"_mst) num_s += 1;
                args += (t << "z"_mst) ? 0 : (t << "o"_mst) ? 1 : 2;
                acc_tl = ((acc_tl | t) & "ghij"_mst) |
                    // Thresh contains a combination of timelocks if it has threshold > 1 and
                    // it contains two different children that have different types of timelocks
                    // Note how if any of the children don't have "k", the parent also does not have "k"
                    "k"_mst.If(((acc_tl & t) << "k"_mst) && ((k <= 1) ||
                        ((k > 1) && !(((acc_tl << "g"_mst) && (t << "h"_mst)) ||
                        ((acc_tl << "h"_mst) && (t << "g"_mst)) ||
                        ((acc_tl << "i"_mst) && (t << "j"_mst)) ||
                        ((acc_tl << "j"_mst) && (t << "i"_mst))))));
            }
            return "Bdu"_mst |
                   "z"_mst.If(args == 0) | // z=all z
                   "o"_mst.If(args == 1) | // o=all z except one o
                   "e"_mst.If(all_e && num_s == n_subs) | // e=all e and all s
                   "m"_mst.If(all_e && all_m && num_s >= n_subs - k) | // m=all e, >=(n-k) s
                   "s"_mst.If(num_s >= n_subs - k + 1) |  // s= >=(n-k+1) s
                   acc_tl; // timelock info
            }
```
(cpp:229–259)

- Arity precondition: `1 ≤ k ≤ n_subs` (cpp:54–55). (Hence n = n_subs ≥ 1.)
- **Requires** (explicit, graceful `⊥` return — the only fragment that does this):
  - `t₀.B ∧ t₀.d ∧ t₀.u` (first child must be `Bdu`),
  - `tᵢ.W ∧ tᵢ.d ∧ tᵢ.u` for all `i ≥ 1` (subsequent children must be `Wdu`).
- **Computes** (given all children pass, with `n = n_subs`, `k` = threshold):
  - `B, d, u := 1` always.
  - `z ⟺ ∀i. tᵢ.z` (i.e. `args == 0`).
  - `o ⟺` (exactly one child has `o`, all others have `z`) — enforced weighting: `args += 0` if `tᵢ.z`, `1` if `tᵢ.o`, else `2`; `o ⟺ args == 1`.
  - `e ⟺ (∀i. tᵢ.e) ∧ (num_s == n)`, where `num_s = #{i | tᵢ.s}`.
  - `m ⟺ (∀i. tᵢ.e) ∧ (∀i. tᵢ.m) ∧ (num_s ≥ n − k)`.
  - `s ⟺ num_s ≥ n − k + 1`.
  - `g ⟺ ∃i. tᵢ.g`, likewise `h, i, j` (folded into `acc_tl` as a running union).
  - `k_prop` (folded): inductively, `acc₀ = {k}`; per child `tᵢ`:
    `acc_{i+1}.k ⟺ acc_i.k ∧ tᵢ.k ∧ (k ≤ 1 ∨ ¬((acc_i.g ∧ tᵢ.h) ∨ (acc_i.h ∧ tᵢ.g) ∨ (acc_i.i ∧ tᵢ.j) ∨ (acc_i.j ∧ tᵢ.i)))`, where `acc_i.{g,h,i,j}` is the union over `t₀..t_{i−1}`. Final `k = acc_n.k`. Equivalently: all children have `k` ∧ (`k ≤ 1` ∨ no pair of children with conflicting time-vs-height locks of the same relative/absolute class).
    (**Name shadowing pitfall:** inside the loop, `k` is the *threshold parameter*, `"k"_mst` is the *property* — distinct things to keep apart in Lean.)
  - `n, f, x` never set.

---

## 3. `SanitizeType` (cpp:19–37) — exact rules

```cpp
Type SanitizeType(Type e) {
    int num_types = (e << "K"_mst) + (e << "V"_mst) + (e << "B"_mst) + (e << "W"_mst);
    if (num_types == 0) return ""_mst; // No valid type, don't care about the rest
    CHECK_NONFATAL(num_types == 1); // K, V, B, W all conflict with each other
    CHECK_NONFATAL(!(e << "z"_mst) || !(e << "o"_mst)); // z conflicts with o
    CHECK_NONFATAL(!(e << "n"_mst) || !(e << "z"_mst)); // n conflicts with z
    CHECK_NONFATAL(!(e << "n"_mst) || !(e << "W"_mst)); // n conflicts with W
    CHECK_NONFATAL(!(e << "V"_mst) || !(e << "d"_mst)); // V conflicts with d
    CHECK_NONFATAL(!(e << "K"_mst) ||  (e << "u"_mst)); // K implies u
    CHECK_NONFATAL(!(e << "V"_mst) || !(e << "u"_mst)); // V conflicts with u
    CHECK_NONFATAL(!(e << "e"_mst) || !(e << "f"_mst)); // e conflicts with f
    CHECK_NONFATAL(!(e << "e"_mst) ||  (e << "d"_mst)); // e implies d
    CHECK_NONFATAL(!(e << "V"_mst) || !(e << "e"_mst)); // V conflicts with e
    CHECK_NONFATAL(!(e << "d"_mst) || !(e << "f"_mst)); // d conflicts with f
    CHECK_NONFATAL(!(e << "V"_mst) ||  (e << "f"_mst)); // V implies f
    CHECK_NONFATAL(!(e << "K"_mst) ||  (e << "s"_mst)); // K implies s
    CHECK_NONFATAL(!(e << "z"_mst) ||  (e << "m"_mst)); // z implies m
    return e;
}
```
(cpp:19–37; declared h:305)

Formalized, for a candidate type `e`:

1. Let `nt = 𝟙[e.K] + 𝟙[e.V] + 𝟙[e.B] + 𝟙[e.W]` (each `<<` returns bool → 0/1).
2. If `nt = 0` → **return `⊥`** (this is the *only* graceful rewriting; the type is discarded wholesale).
3. Preconditions (exception on failure):

| # | rule (implication form) | C++ comment |
|---|---|---|
| R1 | `nt = 1` | K, V, B, W all conflict with each other |
| R2 | `e.z → ¬e.o` | z conflicts with o |
| R3 | `e.n → ¬e.z` | n conflicts with z |
| R4 | `e.n → ¬e.W` | n conflicts with W |
| R5 | `e.V → ¬e.d` | V conflicts with d |
| R6 | `e.K → e.u` | K implies u |
| R7 | `e.V → ¬e.u` | V conflicts with u |
| R8 | `e.e → ¬e.f` | e conflicts with f |
| R9 | `e.e → e.d` | e implies d |
| R10 | `e.V → ¬e.e` | V conflicts with e |
| R11 | `e.d → ¬e.f` | d conflicts with f |
| R12 | `e.V → e.f` | V implies f |
| R13 | `e.K → e.s` | K implies s |
| R14 | `e.z → e.m` | z implies m |

4. Otherwise return `e` unchanged. (`SanitizeType` never adds or clears individual bits; it only maps everything to `⊥` when no basic type is present.)

These rules double as **lemmas available via (`e` was sanitized)** when simplifying fragment formulas — e.g. when computing `o` in AND_V/AND_B/OR_B, `(x.o ∨ y.o) ∧ (x.z ∨ y.z)` ≡ `(x.o ∧ y.z) ∨ (y.o ∧ x.z)` by R2 per child; the `e`-formula in OR_I, `(x.e ∨ y.e) ∧ (x.f ∨ y.f)` ≡ `(x.e ∧ y.f) ∨ (y.e ∧ x.f)` by R8 per child; the ANDOR `o` similarly — matching the in-code comments `o=o_x*z_y+z_x*o_y`, `e=e_x*f_y+f_x*e_y`, `o=o_x*z_y*z_z+z_x*o_y*o_z`.

---

## 4. Context dependence (P2WSH vs TAPSCRIPT) summary

`MiniscriptContext` (h:253–256) with `IsTapscript` (h:259–266). Only **three** places in the type system branch on context:

| site | condition | effect |
|---|---|---|
| `MULTI` precondition, cpp:77 | `!IsTapscript(ms_ctx)` | `multi()` is P2WSH-only (**exception** if used in tapscript) |
| `MULTI_A` precondition, cpp:80 | `IsTapscript(ms_ctx)` | `multi_a()` is Tapscript-only (**exception** if used in P2WSH) |
| `WRAP_D` `u` property, cpp:125–126 | `IsTapscript(ms_ctx)` | `d:` gets `u` only in Tapscript (MINIMALIF is consensus there, policy-only under P2WSH) |

Everything else in `ComputeType` is context-independent. Downstream, context also affects *limits* rather than types:

- `MaxScriptSize` (h:284–296): P2WSH → `MAX_STANDARD_P2WSH_SCRIPT_SIZE` = 3600 (policy/policy.h:60); Tapscript → `(400000 − 378 − 70135) − 5 = 329482` (constants: `MAX_STANDARD_TX_WEIGHT` 400000 policy.h:38, `TX_BODY_LEEWAY_WEIGHT` 378 h:274–280, `MAX_TAPSCRIPT_SAT_SIZE` 70135 h:271–282 with `TAPROOT_CONTROL_MAX_SIZE=4129` interpreter.h:244–247; the trailing −5 is the CompactSize length, h:292–293).
- `Node::CheckOpsLimit` (h:1570–1575): tapscript → no limit; P2WSH → max ops ≤ `MAX_OPS_PER_SCRIPT` = 201 (script.h:32).
- `Node::CheckStackSize` (h:1594–1604): tapscript → exec-stack ≤ `MAX_STACK_SIZE` = 1000 (script.h:44); P2WSH → initial-stack ≤ `MAX_STANDARD_P2WSH_STACK_ITEMS` = 100 (policy.h:54).

---

## 5. Node-level wiring and validity predicates

### 5.1 `Node::CalcType` (h:779–794)

```cpp
    //! Compute the type for this miniscript.
    Type CalcType() const {
        using namespace internal;

        // THRESH has a variable number of subexpressions
        std::vector<Type> sub_types;
        if (fragment == Fragment::THRESH) {
            for (const auto& sub : subs) sub_types.push_back(sub.GetType());
        }
        // All other nodes than THRESH can be computed just from the types of the 0-3 subexpressions.
        Type x = subs.size() > 0 ? subs[0].GetType() : ""_mst;
        Type y = subs.size() > 1 ? subs[1].GetType() : ""_mst;
        Type z = subs.size() > 2 ? subs[2].GetType() : ""_mst;

        return SanitizeType(ComputeType(fragment, x, y, z, sub_types, k, data.size(), subs.size(), keys.size(), m_script_ctx));
    }
```
(h:779–794)

- Children types are themselves sanitized (`typ(CalcType())` in every constructor, e.g. h:1721), so an invalid child already has type `⊥`; since `⊥ << q` fails for any nonempty `q`, **invalidity propagates upward** through every Requires formula. Cf. the decoding comment (h:2676–2677): *"due to how ComputeType works (only assign the type to the node if the subs' types are valid) this would fail if any node of tree is badly typed."*
- The computed (sanitized) type is cached in the member `typ` and returned by `GetType()` (h:1616–1617).

### 5.2 Typing-related predicates on `Node`

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
(h:1674–1702)

As formulas over the node's type `T` and context `ctx`:

| predicate | formula |
|---|---|
| `IsValid()` | `T ≠ ⊥ ∧ ScriptSize ≤ MaxScriptSize(ctx)` |
| `IsValidTopLevel()` | `IsValid() ∧ T.B` |
| `IsNonMalleable()` | `T.m` |
| `NeedsSignature()` | `T.s` |
| `CheckTimeLocksMix()` | `T.k` |
| `CheckDuplicateKey()` | `has_duplicate_keys` computed `= false` (see `DuplicateKeyCheck`, h:1500–1556) |
| `CheckOpsLimit()` | `tap ∨ (ops_sat defined → count + sat ≤ 201)` (h:1570–1575) |
| `CheckStackSize()` | `tap → ExecStackSize ≤ 1000`; `¬tap → StackSize ≤ 100` (h:1594–1604; `IsBKW`, h:1577–1580, adds 1 when `T ∩ {B,K,W} ≠ ∅`) |
| `ValidSatisfactions()` | `IsValid() ∧ CheckOpsLimit() ∧ CheckStackSize()` |
| `IsSaneSubexpression()` | `ValidSatisfactions() ∧ T.m ∧ T.k ∧ ¬dup` |
| `IsSane()` | `IsValidTopLevel() ∧ IsSaneSubexpression() ∧ T.s` |

Related: `IsNotSatisfiable()` (`¬GetStackSize()`, h:1607) and the runtime *consistency checks* between the type system and the satisfaction algorithm in `ProduceInput`'s `tester` (h:1448–1489) — these assert, e.g., that a `z`-node's (dis)satisfactions have 0 stack elements, `o` → 1 element, `n` → nonempty top element, `d` → sig-free dissatisfaction exists, `f`/`s` → signatures present, `m`/`me` → non-malleable (dis)satisfactions, all as `CHECK_NONFATAL` (not part of typing, but a useful cross-specification for verifying the Lean model).

---

## 6. Pitfalls for the Lean formalization

1. **Direction of `<<`:** `a << b` ⟺ `a ⊇ b` (left is subtype of right). `X << "Bd"_mst` reads "X has B and d". It is defined as `(x.m_flags & ~m_flags) == 0` with `x` the *argument* (h:147–148).
2. **`(x | y) << "z"`** means *union-has-z* (`z_x ∨ z_y`), not "both have z"; **`(x & y) << "z"`** means `z_x ∧ z_y`. Both idioms appear throughout (e.g. AND_V lines 145–147).
3. **Graceful `⊥` vs exception:** only `THRESH` explicitly `return ""_mst`s on requirement failure (cpp:237). Other fragments encode requirements as masks/`.If`s on the *basic-type bits*; failure shows up only after `SanitizeType`'s `num_types == 0` rule (cpp:21). All `CHECK_NONFATAL`s (arity, k-range, key counts, MULTI/MULTI_A context, all of `SanitizeType`'s R1–R14) are exceptions — model them as preconditions.
4. **Shadowing:** in `THRESH`, the bound variable `k` is the threshold; the property `'k'` (`"k"_mst`) is different. Likewise `t << "i"_mst` for loop-index-independent property `i`.
5. **`args` accounting in THRESH (cpp:241):** `z→0, o→1, else→2`; hence `args==0 ⟺ all z`, `args==1 ⟺ exactly one o and rest z`.
6. **THRESH `k` fold uses the *old* accumulator** for the cross-timelock test (RHS evaluated before assignment, cpp:242–250): conflicts are pairwise over all *unordered* child pairs {i<j} (union of earlier vs current).
7. **AND/OR/B-combinator formulas rely on SanitizeType invariants** to match their comments (`o=o_x*z_y+z_x*o_y` needs R2; `e=e_x*f_y+f_x*e_y` needs R8). The raw bitwise definitions in §2.1 are the ground truth; the multiplicative forms are derived lemmas.
8. **ANDOR's timelock-conflict check excludes z** (only x–y cross products, cpp:218–222); OR_B/OR_C/OR_D/OR_I have no cross-check at all (`k = k_x ∧ k_y`), unlike AND_V/AND_B (cpp:152–156, 167–171).
9. **`u` in `d:` is Tapscript-only** (cpp:125–126); `MULTI` ⇔ ¬tap, `MULTI_A` ⇔ tap (cpp:75–80). These are the entire context-dependence of the type system.
10. **`WRAP_S` passes `x` through from its child; `WRAP_A` always sets `x`** (cpp:109 vs 113) — an asymmetry easy to miss.
11. `MULTI`/`MULTI_A` have constant types but *no* `f` bit and no `x` bit; `MULTI_A` lacks `n`.
12. `Type` has **19** used bits (0–18); comparisons `<` (h:151) and `==` (h:154) are over raw flags.
