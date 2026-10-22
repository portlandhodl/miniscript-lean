# Analysis: `src/miniscript/types/malleability.rs` (rust-miniscript)

Read-only analysis of `/home/qrsnap/git/miniscript-lean/rust-miniscript` (no repository state known;
file contents as of 2026-10-21). Primary file: **`src/miniscript/types/malleability.rs`** (394 lines).
Cross-referenced: `types/mod.rs`, `types/correctness.rs`, `miniscript/mod.rs`, `miniscript/decode.rs`,
`miniscript/context.rs`, `miniscript/analyzable.rs`, `miniscript/ms_tests.rs`, `src/validation.rs`,
`src/lib.rs`, `src/primitives/threshold.rs`, `policy/compiler.rs`, and the spec mirror at
`notes/sipa-spec.md` (verbatim copy of https://bitcoin.sipa.be/miniscript/).

---

## 1. Data model: `Dissat` and `Malleability` and the f/e/s/m letters

### 1.1 `Dissat` — malleability.rs:11–30

```rust
pub enum Dissat {
    None,     // malleability.rs:15  — "no dissatisfactions … will abort given non-satisfying input"
    Unique,   // malleability.rs:22  — "a unique dissatisfaction, which is always available, and will push 0"
    Unknown,  // malleability.rs:29  — "No assumptions may be made about dissatisfying this fragment."
}
```

Only carried for **non-malleable** fragments (see the doc comment on `Malleability`,
malleability.rs:54–61: *"The "s", "f" and "e" properties of a fragment only describe its
satisfactions and dissatisfactions if the fragment meets the non-malleability requirement of
every fragment it is built from."*).

Subtyping (`Dissat::is_subtype`, malleability.rs:45–51): reflexive, and **everything is a subtype
of `Unknown`** (`(_, Self::Unknown) => true`, malleability.rs:48). `None` and `Unique` are
incomparable to each other. So the lattice is `None <: Unknown`, `Unique <: Unknown`.

### 1.2 `Malleability` — malleability.rs:62–78

```rust
pub enum Malleability {
    Malleable,                                  // malleability.rs:67 — "no guaranteed non-malleable
                                                //  satisfaction, so nothing is known"
    NonMalleable {
        dissat: Dissat,                         // malleability.rs:72
        signed: bool,                           // malleability.rs:76 — "true if every satisfaction
                                                //  requires a signature"
    },
}
```

**Letter mapping** (from `impl fmt::Display for Type`, `types/mod.rs:161–198`, specifically
`types/mod.rs:183–195`):

| Letter | Rust | Meaning |
|---|---|---|
| `m` | `Malleability::NonMalleable { .. }` itself | printed iff `self.mall` is the `NonMalleable` variant (`types/mod.rs:185,194`); `Malleable` prints nothing |
| `f` ("forced") | `Dissat::None` | `types/mod.rs:187` |
| `e` ("expressive") | `Dissat::Unique` | `types/mod.rs:188` |
| (no letter) | `Dissat::Unknown` | prints `""` (`types/mod.rs:189`) |
| `s` ("signed") | `signed == true` | `types/mod.rs:191–193` |

So a type string like `B/duesm` = base `B`, correctness `d u`, malleability `e s m` (see the
duplicated test renderer in `ms_tests.rs:15–53` and the working example `or_b(pk(A),a:pk(B))` →
`"B/duesm"` asserted in `miniscript/mod.rs:2253–2260`).

Lattices on `Malleability` (`is_subtype`, malleability.rs:114–125):

```rust
// malleability.rs:116-119
// A malleable fragment promises nothing, so everything is a
// subtype of it, and it is a subtype of nothing else.
(_, Self::Malleable) => true,
(Self::Malleable, Self::NonMalleable { .. }) => false,
// malleability.rs:123
dissat.is_subtype(other_dissat) && *signed >= other_signed,
```

i.e. `Malleable` is the *top* of the subtyping order (weakest promise), and within `NonMalleable`,
`dissat` uses the `Dissat` lattice and `signed` uses `true >= false`.

Useful accessors: `is_non_malleable` (malleability.rs:89), `dissat() -> Option<Dissat>`
(malleability.rs:93–98, `None` if malleable), `signed() -> Option<bool>` (malleability.rs:102–107).

### 1.3 Leaf constants

```rust
pub const TRUE:  Self = Self::NonMalleable { dissat: Dissat::None,   signed: false }; // malleability.rs:82  (`1` → "f")
pub const FALSE: Self = Self::NonMalleable { dissat: Dissat::Unique, signed: true  }; // malleability.rs:85  (`0` → "es")
```

Matches the spec rows `1` → `f` and `0` → `s, e` exactly.

---

## 2. Per-`Terminal`-variant requirements and malleability formulas

The `Terminal` enum is in `miniscript/decode.rs:90–162`. The dispatch that computes each node's
`Type` is `Type::type_check` (`types/mod.rs:462–538`), which combines a **`Correctness`** rule
(the only place `Err`/`ErrorKind` comes from — see §4) with a **`Malleability`** rule that
**never errors**: failed malleability *Requires* degrade the result to `Malleability::Malleable`
(the `_ => return Self::Malleable;` arms), not to an `Err`. This is the single most important
structural fact about this file.

Per-variant Requires below are split into **(C)** correctness errors (return `Err(ErrorKind)`)
and **(M)** malleability requirements (flip the node to `Malleable`). "spec Requires" refers to
the sipa spec table (`notes/sipa-spec.md:288–316`).

### 2.1 Leaves — no Requires of any kind; constant types

| Terminal variant (decode.rs) | fn (malleability.rs) | Value | letters | spec |
|---|---|---|---|---|
| `True` (`1`), decode.rs:92 | `TRUE`, :82 | `NonMalleable{None, false}` | `f m` (plus `z;u` corr) | `f` ✓ |
| `False` (`0`), decode.rs:94 | `FALSE`, :85 | `NonMalleable{Unique, true}` | `e s m` (corr `z;u;d`) | `s, e` ✓ |
| `PkK`, decode.rs:97 | `pk_k`, :130 | `NonMalleable{Unique, true}` | `e s m` | `s, e` ✓ |
| `PkH`, decode.rs:99 | `pk_h`, :133 | `NonMalleable{Unique, true}` | `e s m` | `s, e` ✓ |
| `RawPkH`, decode.rs:105 | `pk_h` (same), :133; dispatch `types/mod.rs:475` | same | same | (parsing-only internal fragment; shares `pk_h`'s type) |
| `Multi`, decode.rs:155 | `multi`, :136 | `NonMalleable{Unique, true}` | `e s m` | `s; e` ✓ |
| `SortedMulti`, decode.rs:157 | `sortedmulti`, :139–141 | same | same | (not in spec table; treated as `multi`) |
| `MultiA`, decode.rs:159 | `multi_a`, :144 | `NonMalleable{Unique, true}` | `e s m` | `s; e` ✓ |
| `SortedMultiA`, decode.rs:161 | `sortedmulti_a`, :147–149 | same | same | (not in spec; treated as `multi_a`) |
| `After`, decode.rs:108 | `time`, :155 | `NonMalleable{None, false}` | `f m` | `f` ✓ |
| `Older`, decode.rs:110 | `time`, :155 | same | same | `f` ✓ |
| `Sha256`/`Hash256`/`Ripemd160`/`Hash160`, decode.rs:113–119 | `hash`, :152 | `NonMalleable{Unknown, false}` | `m` only (no f/e/s) | `*(none)*` ✓ |

Context-level (not type-level) restrictions also exist for these leaves: 1 ≤ k ≤ n ≤ MAX for the
multi-like fragments is enforced by `Threshold::new`/`validate_k_n`
(`src/primitives/threshold.rs:46–52, 67–70`), and `multi` vs `multi_a` context legality by
`Ctx::check_global_consensus_validity` (e.g. Legacy/Segwitv0 reject `MultiA`:
`context.rs:415–417, 537–539`).

Dispatch arms: `types/mod.rs:472–485`.

### 2.2 Wrappers — unary casts

Note that **none of the wrapper casts touch `signed`** except pass-through, and the only two
operations on `dissat` are `with_dissat` (replace, malleability.rs:186–191) and
`cast_dissat_if_forced` (malleability.rs:196–208):

```rust
// malleability.rs:196-208
const fn cast_dissat_if_forced(self) -> Self {
    match self {
        Self::Malleable => Self::Malleable,
        Self::NonMalleable { dissat, signed } => Self::NonMalleable {
            dissat: if dissat.constfn_eq(Dissat::None) {
                Dissat::Unique
            } else {
                Dissat::Unknown
            },
            signed,
        },
    }
}
```

| Wrapper | Rust fn (malleability.rs) | Requires (C), all in correctness.rs | Computed `Malleability` | spec row | match? |
|---|---|---|---|---|---|
| `a:X` (`Alt`) | `cast_alt` :158 — **identity** | child `B` else `Err(ChildBase1)` (:181–186) | `s=s_X; f=f_X; e=e_X` | `s=s_X; f=f_X; e=e_X` | ✓ |
| `s:X` (`Swap`) | `cast_swap` :161 — **identity** | child `B` (`ChildBase1`), and input `o`/`on` else `Err(SwapNonOne)` (:194–207) | identity | `s=s_X; f=f_X; e=e_X` | ✓ |
| `c:X` (`Check`) | `cast_check` :164 — **identity** | child `K` else `ChildBase1` (:210–215) | `s=s_X; f=f_X; e=e_X` | **`s; f=f_X; e=e_X`** (grants `s` outright) | see §3.2 — sound only because of the K⇒s invariant |
| `d:X` (`DupIf`) | `cast_dupif` :167 = `cast_dissat_if_forced` | child `V` else `ChildBase1`; child `z` else `Err(NonZeroDupIf)` (:223–236) | `dissat: None→Unique, else→Unknown`; `s=s_X` | `s=s_X; e` | ✓ via V⇒f invariant, §3.3 |
| `v:X` (`Verify`) | `cast_verify` :170 = `with_dissat(Dissat::None)` | child `B` else `ChildBase1` (:239–249) | `dissat = None`; `s=s_X` | `s=s_X; f` | ✓ |
| `j:X` (`NonZero`) | `cast_nonzero` :173 = `cast_dissat_if_forced` | child input `on`/`n` else `Err(NonZeroZero)` (:252–255); child `B` else `ChildBase1` (:256–260) | `dissat: None→Unique, else→Unknown`; `s=s_X` | `s=s_X; e=f_X` | ✓, §3.3 |
| `n:X` (`ZeroNotEqual`) | `cast_zeronotequal` :176 — **identity** | child `B` else `ChildBase1` (:268–273) | identity | `s=s_X; f=f_X; e=e_X` | ✓ |
| `t:X` | `cast_true` :179 = `with_dissat(Dissat::None)` | child `V` else `ChildBase1` (corr `cast_true`, :281–290) | `dissat = None`; `s=s_X` | expanded `and_v(X,1)` | ✓, and parse-desugared, §3.4 |
| `l:X`, `u:X` | `cast_or_i_false` :182 = `cast_dissat_if_forced` | child `B` else `ChildBase1` (corr `cast_or_i_false`, :294–309) | `dissat: None→Unique, else→Unknown`; `s=s_X` | expanded `or_i(0,X)` / `or_i(X,0)` | ✓ (derivation in §3.4) |

Dispatch arms: `types/mod.rs:486–492`. `Type` glue fns: `types/mod.rs:259–367`.

### 2.3 Conjunctions

**`and_b(X,Y)`** — `Malleability::and_b`, malleability.rs:211–236. Dispatch `types/mod.rs:493–497`.

- (C) Requires: left `B`, right `W` else `Err(ChildBase2)` (correctness.rs:312–317). Spec: "*X* is B; *Y* is W" ✓.
- (M) Requires: *none* beyond both children being non-malleable — spec's Requires column is also empty ✓. Any `Malleable` child short-circuits: `_ => return Self::Malleable` (:217).
- Formulas (malleability.rs:220–235):

```rust
dissat: match (left_dissat, right_dissat) {
    (Dissat::None, Dissat::None) => Dissat::None,                 // f = f_X f_Y
    (Dissat::None, _) if left_signed => Dissat::None,             // f ⊇ s_X f_X
    (_, Dissat::None) if right_signed => Dissat::None,            // f ⊇ s_Y f_Y
    (Dissat::Unique, Dissat::Unique) => {
        if left_signed && right_signed { Dissat::Unique }         // e = e_X e_Y s_X s_Y
        else { Dissat::Unknown }
    }
    _ => Dissat::Unknown,
},
signed: left_signed || right_signed,                              // s = s_X or s_Y
```

Spec: `s=s_X or s_Y; f=f_X f_Y or s_X f_X or s_Y f_Y; e=e_X e_Y s_X s_Y` (sipa-spec.md:302) — the
three arms for `None` are *exactly* the f-formula's three disjuncts (first arm covers
`(None,None)` before the signed-guard arms), and `(Unique,Unique) ∧ ¬(s_X∧s_Y) → Unknown`
implements `e` needing all four. ✓

**`and_v(X,Y)`** — `Malleability::and_v`, malleability.rs:239–256. Dispatch `types/mod.rs:498–502`.

- (C): left `V`, right `B|K|V` else `Err(ChildBase2)` (correctness.rs:335–342).
- (M): none; `Malleable` propagates (:245).
- Formulas (:248–255):

```rust
dissat: match (left_signed, right_dissat) {
    (_, Dissat::None) => Dissat::None, // fy
    (true, _) => Dissat::None,         // sx
    _ => Dissat::Unknown,
},
signed: left_signed || right_signed,
```

Spec: `s=s_X or s_Y; f=s_X or f_Y` (sipa-spec.md:301). `dissat=None` ⟺ `f_Y ∨ s_X` ✓. `e` never
granted (spec grants none) ✓.

### 2.4 Disjunctions — where malleability Requires live

**`or_b(X,Z)`** — `Malleability::or_b`, malleability.rs:259–275. Dispatch `types/mod.rs:503–507`.

- (C) Requires: left `d` else `Err(LeftNotDissatisfiable)` (correctness.rs:360–363); right `d`
  else `Err(RightNotDissatisfiable)` (correctness.rs:364–366); bases `(B, W)` else
  `Err(ChildBase2)` (:368–371). Spec: "*X* is Bd; *Z* is Wd" ✓.
- (M) Requires — **this is where "children must be e" lives, and it is NOT an error**;
  malleability.rs:267–272:

```rust
if !left_dissat.constfn_eq(Dissat::Unique)
    || !right_dissat.constfn_eq(Dissat::Unique)
    || !(left_signed || right_signed)
{
    return Self::Malleable;
}
```

i.e. `e_X ∧ e_Z ∧ (s_X ∨ s_Z)`, exactly the spec Requires `e_X e_Z and (s_X or s_Z)`
(sipa-spec.md:303); failure ⇒ `Malleable`, not `Err`.
- Result (:274): `NonMalleable { dissat: Dissat::Unique, signed: left_signed && right_signed }`
  — spec `s=s_X s_Z; e` ✓.

**`or_d(X,Z)`** — malleability.rs:278–291. Dispatch `types/mod.rs:508–512`.

- (C): left `d` (`LeftNotDissatisfiable` :387–388), left `u` (`Err(LeftNotUnit)` :390–392),
  bases `(B,B)` else `ChildBase2` (:394–397). Spec: "*X* is Bdu; *Z* is B" ✓.
- (M): `e_X ∧ (s_X ∨ s_Z)` else `Malleable` (:286–288) — spec Requires `e_X and (s_X or s_Z)` ✓.
- Result (:290): `dissat: right_dissat` (so `f=f_Z` and `e=e_Z` by pass-through), `signed =
  left_signed && right_signed` (`s=s_X s_Z`). Spec: `s=s_X s_Z; f=f_Z; e=e_Z` ✓.

**`or_c(X,Z)`** — malleability.rs:294–307. Dispatch `types/mod.rs:513–517`.

- (C): left `d` (:410–412), left `u` (:413–415), bases `(B,V)` else `ChildBase2` (:417–420). Spec: "*X* is Bdu; *Z* is V" ✓.
- (M): `e_X ∧ (s_X ∨ s_Z)` else `Malleable` (:302–304) — spec `e_X and (s_X or s_Z)` ✓.
- Result (:306): `dissat: Dissat::None` (grant `f` — spec: `f` ✓), `signed = left_signed &&
  right_signed` (`s=s_X s_Z` ✓). (`V` fragment ⇒ must be `f`; consistent with the invariant at
  `types/mod.rs:219`.)

**`or_i(X,Z)`** — malleability.rs:310–331. Dispatch `types/mod.rs:518–522`.

- (C): bases equal — `(B,B)|(V,V)|(K,K)` else `Err(ChildBase2)` (correctness.rs:431–439).
  **No `d`/`u` requirement here** — unlike `or_b`/`or_c`/`or_d` — because its dissatisfactions
  (`dsat(X) 1; dsat(Z) 0`) don't consume a sub-dsast of any particular child to construct…
  wait, they do need one: correctness grants `dissatisfiable: left.dissatisfiable || right.dissatisfiable`
  (:444) — i.e. `or_i` is `d` iff *either* side is. Spec correctness row: `d=d_X or d_Z` ✓.
- (M) Requires: `s_X ∨ s_Z` else `Malleable` (:318–320) — spec Requires `s_X or s_Z` ✓. Note
  `or_i` does **not** require `e` of its children.
- Formulas (:322–330):

```rust
dissat: match (left_dissat, right_dissat) {
    (Dissat::None, Dissat::None) => Dissat::None,       // f = f_X f_Z
    (Dissat::Unique, Dissat::None) => Dissat::Unique,   // e ⊇ e_X f_Z
    (Dissat::None, Dissat::Unique) => Dissat::Unique,   // e ⊇ e_Z f_X
    _ => Dissat::Unknown,
},
signed: left_signed && right_signed,                    // s = s_X s_Z
```

Spec: `s=s_X s_Z; f=f_X f_Z; e=e_X f_Z or e_Z f_X` (sipa-spec.md:306) ✓ exact.

### 2.5 `andor(X,Y,Z)` — malleability.rs:334–357; dispatch `types/mod.rs:523–528`

- (C): first child `d` else `LeftNotDissatisfiable` (correctness.rs:451–452); first child `u`
  else `LeftNotUnit` (:454–456); bases `(B,B,B)|(B,K,K)|(B,V,V)` else `Err(ChildBase3)`
  (:458–463). Spec: "*X* is Bdu; *Y* and *Z* are both B, K, or V" ✓.
- (M) Requires (:343–345): `e_X ∧ (s_X ∨ s_Y ∨ s_Z)` else `Malleable` — spec
  `e_X and (s_X or s_Y or s_Z)` ✓.
- Formulas (:347–356):

```rust
dissat: match (a_signed, b_dissat, c_dissat) {
    (_, Dissat::None, Dissat::Unique) => Dissat::Unique, //E: ez fy
    (true, _, Dissat::Unique) => Dissat::Unique,         // E: ez sx
    (_, Dissat::None, Dissat::None) => Dissat::None,     // F: fy && fz
    (true, _, Dissat::None) => Dissat::None,             // F: sx && fz
    _ => Dissat::Unknown,
},
signed: (a_signed || b_signed) && c_signed,
```

Spec: `s=s_Z and (s_X or s_Y); f=f_Z and (s_X or f_Y); e=e_Z and (s_X or f_Y)`
(sipa-spec.md:300). Arms 1–2 give `Unique` ⟺ `e_Z ∧ (f_Y ∨ s_X)` — the `e` formula with its two
disjuncts as separate arms; arms 3–4 give `None` ⟺ `f_Z ∧ (f_Y ∨ s_X)` — the `f` formula ✓.
Arm order matters: e.g. `(true, None, Unique)` matches arm 2, and `(_, None, Unique)` where b is
`None` and c `Unique` was already consumed by arm 1 — both are "e" cases, disjoint from the "f"
arms 3–4 which require `c` to be `None`. ✓ exact match (the inline `//E:` / `//F:` comments at
malleability.rs:349–352 label the cases).

### 2.6 `thresh(k, X1…Xn)` — `Malleability::threshold`, malleability.rs:361–393; dispatch `types/mod.rs:529–532`

- (C) Requires (correctness.rs:481–504): first sub `B` else `Err(ThresholdBase(i, base))`,
  others `W` else same error; every sub `u` else `Err(ThresholdNonUnit(i))`; every sub `d` else
  `Err(ThresholdDissat(i))`. Spec: "*X1* is Bdu; others are Wdu" ✓. **The `k` parameter is
  ignored here** (`pub fn threshold<'a, I>(_k: usize, …)` correctness.rs:481) — `1 ≤ k ≤ n` is
  enforced earlier by `Threshold::new`/`validate_k_n` (`src/primitives/threshold.rs:46–52, 67–70`),
  because `Terminal::Thresh` stores a `Threshold<Arc<Miniscript>, 0>` (decode.rs:153).
- (M) Requires, implemented **by counting** (malleability.rs:365–379):

```rust
let n = subs.len();
let mut signed_count = 0;
let mut all_are_dissat_unique = true;
for subtype in subs {
    match subtype {
        Self::Malleable => return Self::Malleable,
        Self::NonMalleable { dissat, signed } => {
            signed_count += usize::from(*signed);
            all_are_dissat_unique &= *dissat == Dissat::Unique;
        }
    }
}
if !all_are_dissat_unique || signed_count < n - k {
    return Self::Malleable;
}
```

Spec Requires: `all are e; at most k are non-s` (sipa-spec.md:307).
`all_are_dissat_unique` = "all are e"; `signed_count < n - k` ⟺ `#non-s > k` = "more than k are
non-s". ✓. Also any malleable child ⇒ whole threshold `Malleable` (:370).
- Properties (:381–392):

```rust
dissat: if signed_count == n { Dissat::Unique } else { Dissat::Unknown },  // e = "all are s"
signed: signed_count > n - k,                                              // s = "at most k-1 are non-s"
```

Spec: `s=at most k-1 are non-s; e=all are s`. `signed_count > n-k` ⟺ `#non-s ≤ k−1` ✓;
`signed_count == n` ⟺ all signed ✓. The doc comment at malleability.rs:382–385 explicitly cites
this as *BIP379's "e=all are s"*.
- Subtlety: `n - k` would underflow if `k > n`, but that is impossible by the `Threshold`
  constructor invariant (`validate_k_n`: `k == 0 || k > n` rejected, threshold.rs:47), so the
  type layer leans on an invariant established *outside* the type checker. Also note thresh's
  dissat is never `None` — spec grants `thresh` no `f`. ✓

---

## 3. Subtle differences vs. the sipa spec table

### 3.1 Requires that "fail" are not errors — `Malleable` is a *value*, not an `Err`

The spec presents a single "Requires" column. This implementation splits it in two:

- **Correctness Requires** (`B/W/V/K`, `d`, `u`, `o`, `z`, `n` conditions) return
  `Err(ErrorKind)` from the `Correctness::*` constructors (correctness.rs) and abort type
  checking (see §4).
- **Malleability Requires** (`e_X`, `s_X or s_Z`, "all are e", "at most k are non-s", …) never
  return `Err`. Violating one yields `Malleability::Malleable`, which then *propagates*: every
  parent constructor has a `_ => return Self::Malleable` arm (malleability.rs:217, 245, 265, 284,
  300, 316, 341, 370). Consequence: `from_str_insane("or_b(sha256(..),a:sha256(..))")` parses
  fine; the node just carries no f/e/s/m properties and renders `"B/du"` — exactly the behavior
  pinned by the test `malleable_has_no_malleability_properties`
  (`miniscript/mod.rs:2237–2274`; cf. doc comment malleability.rs:54–61 and the display guard
  `types/mod.rs:183–185`).

Rejection of malleable scripts happens at a completely different layer (§4.2).

### 3.2 `c:X`: spec grants `s` outright; the implementation relies on a K⇒s global invariant

Spec row: `c:X: s; f=f_X; e=e_X` (sipa-spec.md:312) — CHECKSIG makes every satisfaction signed.
The implementation's `cast_check` is just `self` (malleability.rs:163–164), i.e. `s=s_X`, which
looks weaker. It is sound because of the type-system invariant asserted at
`types/mod.rs:220`:

```rust
debug_assert!(signed || self.corr.base != Base::K);
```

(inside `Type::sanity_checks`, types/mod.rs:216–224). Every `K`-typed fragment is `s` by
construction: `pk_k`/`pk_h` are `s` (malleability.rs:130,133), and the only K-producing parents
(`and_v(V,K)`, `or_i(K,K)`, `andor(B,K,K)`) inherit `s`:
`and_v` gives `s=s_X ∨ s_Y` with s_Y=true; `or_i` gives `s_X ∧ s_Z` with both true; `andor`
gives `(a∨b) ∧ c` with b,c true. So `c:X` gets `s` for free. It works, but the equivalence holds
by an asserted invariant rather than by the constructor itself.

### 3.3 `j:X` and `d:X` share `cast_dissat_if_forced`; `j:X` can never be `f`

Spec rows: `d:X: s=s_X; e` and `j:X: s=s_X; e=f_X` (sipa-spec.md:313,315).

- Both wrappers map through `cast_dissat_if_forced` (malleability.rs:166–173 → 196–208):
  `dissat: None → Unique; anything else → Unknown`, preserving `signed`. For `j:X` this is
  literally `e iff f_X` ✓; **note that `j:X` never gets `f`** (its result `dissat` is only ever
  `Unique` or `Unknown`, never `None`) — matching the spec, which lists no `f` for `j:X` (the
  script `SIZE 0NOTEQUAL IF [X] ENDIF` can always be dissatisfied by pushing `0`).
- For `d:X` the spec grants `e` *unconditionally*; the code grants it iff the child's
  `dissat == None`. This is equivalent only because `d:` requires a `V`-typed child
  (correctness.rs:223–228) and the invariant at `types/mod.rs:219` —
  `debug_assert!(dissat == Dissat::None || self.corr.base != Base::V);` — guarantees every `V`
  fragment is `f`. So in practice the child is always `dissat: None` and `d:X` is always `e`,
  as the spec says; but the code would silently degrade to `Unknown` instead of erroring if that
  invariant were ever broken (softening, not unsoundness).
- The doc comment at malleability.rs:193–195 documents this shared helper: *"The malleability
  of the three wrappers that turn a fragment which cannot be dissatisfied into one with a unique
  dissatisfaction, `d:`, `j:` and the `or_i` the `l:` and `u:` wrappers desugar to."*

### 3.4 `t:`, `l:`, `u:` (and `and_n`, `pk`, `pkh`) are parse-time sugar, yet have their own Type casts

The string parser desugars these before any typing (`miniscript/mod.rs:1107–1109, 1160–1175`):

```rust
// mod.rs:1169-1171
b't' => Terminal::AndV(new, Arc::new(Self::TRUE)),
b'u' => Terminal::OrI(new, Arc::new(Self::FALSE)),
b'l' => Terminal::OrI(Arc::new(Self::FALSE), new),
```

and `and_n` → `Terminal::AndOr(x, y, Arc::new(Self::FALSE))` (mod.rs:1107–1109). So
`Type::type_check` never sees them. Nevertheless the type layer *also* carries dedicated casts —
`Malleability::cast_true` (malleability.rs:179) and `cast_or_i_false` (:182), wrapped by
`Type::cast_true/cast_unlikely/cast_likely` (types/mod.rs:337–367) — which are used by the
policy compiler (`policy/compiler.rs:746–773`), where AST nodes are synthesized directly.

Consistency check of the two views (malleability side):
- `t:X = and_v(X,1)`: `dissat = None` unconditionally (since `1` is `dissat:None`, arm
  `(_, Dissat::None)` of `and_v` fires) and `s = s_X ∨ false = s_X` — exactly
  `with_dissat(Dissat::None)` (:179) ✓.
- `l:X = or_i(0,X)`, `u:X = or_i(X,0)`: `0` is `NonMalleable{Unique, signed:true}`, so `or_i`'s
  Requires (`s_X ∨ s_Z`) is always satisfied; result `dissat`: `(Unique/None, Unique,·)` arms
  give `Unique` iff the real child's dissat is `None`, else `Unknown`; `signed =
  true ∧ s_X = s_X` — exactly `cast_dissat_if_forced` (:182) ✓. Interesting corollary: `l:X`/`u:X`
  get `e` iff *X* is `f` (spec-derived: `e = e_0 f_X or e_X f_0 = f_X`), i.e. a dissatisfiable
  unsigned `X` (e.g. `l:sha256(h)`) yields only `m` with no `e`.

### 3.5 `thresh`: "at most k are non-s" implemented by counting signed children

As detailed in §2.6: the spec's Requires (`all are e; at most k are non-s`) become the guard
`signed_count < n - k` (malleability.rs:377); properties become `dissat = Unique iff
signed_count == n` (:386–390, "e=all are s", flagged with the BIP379 comment at :382–385) and
`signed = signed_count > n - k` (:391, "at most k-1 are non-s"). `k ∈ [1, n]` is *not* checked
in the type module at all — `Correctness::threshold` ignores it (`_k: usize`,
correctness.rs:481) and relies on the `Threshold<T, MAX>` smart constructor
(`src/primitives/threshold.rs:46–52, 67–70`, error at `ThresholdError`, threshold.rs:17–37),
which also enforces the `MAX` caps (`MAX_PUBKEYS_PER_MULTISIG` etc.). This is a division of
labor worth remembering: the type checker can assume `k ≤ n`, so `n - k` never underflows.

### 3.6 `multi` vs `multi_a` (and their `sorted` variants)

Malleability is byte-identical for all four: `NonMalleable { dissat: Dissat::Unique,
signed: true }` = "s, e" (malleability.rs:135–149), matching the spec rows `multi: s; e` and
`multi_a: s; e` (sipa-spec.md:308–309). The only spec-mandated difference (`multi` has the `n`
property, `multi_a` does not — correctness table sipa-spec.md:139–140) lives in `Correctness`:
`multi()` uses `input: Input::AnyNonZero` (correctness.rs:150–153) while `multi_a()` uses
`Input::Any` (correctness.rs:160–163). `sortedmulti*` copy their non-sorted counterparts exactly
(also true in the spec, which doesn't list them separately).

### 3.7 Minor notes

- `pk_h`'s *correctness* carries `dissatisfiable: true, // FIXME check with sipa`
  (correctness.rs:145) — the spec does grant `pk_h` the `d` property (sipa-spec.md:125), so the
  FIXME appears stale.
- `is_subtype` asymmetry (malleability.rs:114–125): everything `<: Malleable`. Within
  `NonMalleable`, subtyping is pointwise (`Dissat` lattice, `signed >=`). The spec has no
  subtyping concept; this is rust-miniscript-internal (used e.g. by the compiler).
- `cast_alt`/`cast_swap`/`cast_check`/`cast_zeronotequal` being identity *functions* (not
  constants) corresponds exactly to the spec's `s=s_X; f=f_X; e=e_X` rows for `a:`, `s:`, `n:`
  (and §3.2 for `c:`).
- Legacy structural malleability: the spec-independent rule "`or_i`/`d:` are malleable
  pre-segwit because `IF` need not be minimal" exists as `ScriptContextError::MalleableOrI` /
  `MalleableDupIf` (`context.rs:24–27, 93–96`) with a Legacy override of
  `check_terminal_non_malleable` (`context.rs:384–392`) that rejects `Terminal::OrI` and
  `Terminal::DupIf` — **but grep shows no call sites for `check_terminal_non_malleable`
  anywhere in this snapshot** (six definitions, no invocations). The effective ban instead comes
  from the validation params: Legacy's `CONSENSUS` sets `allow_dup_if: false` /
  `allow_or_i: false` (`context.rs:373,376`) and `Miniscript::validate_non_top_level` rejects
  them with `ValidationError::IllegalDupIf`/`IllegalOrI` (`mod.rs:420–422, 441–443`).

---

## 4. Where the checks fire, and which errors bubble up

There is **no function literally named `check_malleability_requirements`** in this codebase (a
name from older rust-miniscript); the malleability requirements are evaluated *inside* the
`Malleability::*` constructors as the sentinel transformation described above. The error paths:

### 4.1 Fragment/wrapper construction — correctness `Err`s only

1. `Type::type_check` (types/mod.rs:462–538) is invoked per node from `Miniscript::from_ast`
   (`miniscript/mod.rs:315–332`):

```rust
// miniscript/mod.rs:315-321
pub fn from_ast(t: Terminal<Pk, Ctx>) -> Result<Self, Error> {
    let res = Self {
        ty: Type::type_check(&t)?,
        ext: ExtData::type_check(&t),
        ...
```

   `type_check` wraps every `ErrorKind` with the offending fragment's string via the closure at
   types/mod.rs:467–469:

```rust
let wrap_err = |result: Result<Self, ErrorKind>| {
    result.map_err(|kind| Error { fragment_string: fragment.to_string(), error: kind })
};
```

   producing `types::Error { fragment_string, error }` (types/mod.rs:63–69) with the
   human-readable variants (`"fragment «…» requires its left child be dissatisfiable"` etc.,
   Display impl types/mod.rs:71–144). This converts up to `crate::Error::TypeCheck(String)` via
   `From<miniscript::types::Error> for Error` (`src/lib.rs:595–597`).
2. The string parser builds the tree bottom-up, calling `Self::from_ast(term)?` for every
   fragment and every wrapper char (mod.rs:1114–1143, 1174), so a correctness violation aborts
   parse at the *deepest* offending fragment (the error names that fragment, not the whole
   script). After the tree is built, `Ctx::check_global_validity` is run for **every** node
   (mod.rs:1183–1189); `from_ast` itself also runs it once plus the `MAX_RECURSION_DEPTH = 402`
   check (mod.rs:327–331).
3. The script decoder (`decode.rs:306, 613`) likewise constructs via `Miniscript::from_ast`;
   `decode_with_validation_params` then *re*-runs `Type::type_check(&top.node)?` on the root
   (`mod.rs:736–738`) before validating.
4. `Type::sanity_checks` (types/mod.rs:216–224) runs on every successfully computed type
   (types/mod.rs:534–536) as `debug_assert!`s — these encode cross-layer invariants
   (`d ⇒ ¬f`; `V ⇒ f`; `K ⇒ s`; *"no `z` fragment is malleable"*: `self.mall.is_non_malleable()
   || self.corr.input != Input::Zero`, types/mod.rs:222). They are debug-only, not errors.

So at construction time the observable `Err` kinds are exactly the correctness ones
(`ErrorKind::LeftNotDissatisfiable`, `RightNotDissatisfiable`, `LeftNotUnit`, `ChildBase1/2/3`,
`ThresholdBase/Dissat/NonUnit`, `NonZeroDupIf`, `NonZeroZero`, `SwapNonOne` — definitions at
types/mod.rs:26–60), plus recursion-depth and context (key-type, size, `multi`-vs-context)
errors. **A malleability-requirement failure is never observable as an `Err` here.**

### 4.2 Malleability enforcement — one top-level validation gate

The *only* type-driven malleability rejection is in `Miniscript::validate`
(`miniscript/mod.rs:349–380`):

```rust
// miniscript/mod.rs:356-360
// Malleability is only a top-level check since you can fix malleability
// in some cases by adding wrappers.
if !params.allow_malleability && !self.is_non_malleable() {
    return Err(ValidationError::Malleable);
}
```

- `ValidationError::Malleable` is defined in `src/validation.rs:278–279` ("script has a 3rd-party
  malleability vector", display at :329) and converts to `crate::Error::Validation`
  (`lib.rs:489–490`).
- The gate is flipped by `ValidationParams::allow_malleability` (`validation.rs:24`):
  `ValidationParams::MAX`/`CONSENSUS` set it `true` (validation.rs:78, 137); the default
  `SANE` sets it `false` (validation.rs:107). Hence `str::FromStr` (= `Ctx::SANE`,
  mod.rs:1194–1200) **rejects malleable scripts**, while `from_str_insane`
  (mod.rs:974–977, `CONSENSUS` minus raw-pkh) and `decode_consensus` accept them and merely
  record `Malleability::Malleable` on the type.
- Adjacent top-level gates: `ValidationError::NonBase` (needs base `B`, mod.rs:362–365) and
  `ValidationError::SiglessBranch` (needs `non_malleable_and_requires_sig()`, mod.rs:367–370 —
  note this predicate is *only true* for `Malleability::NonMalleable { signed: true, .. }`,
  `analyzable.rs:31–33`; a malleable script therefore also fails the sigless-branch check).

### 4.3 Consumers of the flag (no new errors, but behavior)

- `Miniscript::is_non_malleable` / `non_malleable_and_requires_sig` (`analyzable.rs:31–37`) feed
  the root_has_sig argument of witness construction (`satisfy`/`satisfy_malleable`/
  `build_template*`, mod.rs:629–705).
- The policy compiler matches on the enum: `types::Malleability::Malleable =>
  Err(CompilerError::ImpossibleNonMalleableCompilation)` (`policy/compiler.rs:1126–1132`; also
  concrete.rs:288, 346, 418, 469, 495 and the `is_non_malleable()` filter at
  compiler.rs:813).
- `display.rs:307` re-runs `Type::type_check` when pretty-printing type annotations.

### 4.4 Summary of error flow

```
Terminal node
  └─ Type::type_check (types/mod.rs:462)          ← per-fragment, bottom-up
        ├─ Correctness::*  → Err(ErrorKind)       ← the ONLY Errs in typing
        │     └─ wrap_err → types::Error{fragment_string}
        │           └─ From → crate::Error::TypeCheck(String)      (lib.rs:595)
        ├─ Malleability::* → Malleable sentinel   ← never an Err; propagates upward
        └─ Type::sanity_checks → debug_assert!    (types/mod.rs:216)
Miniscript::from_ast (mod.rs:315)
  └─ + MAX_RECURSION_DEPTH, Ctx::check_global_validity → ScriptContextError/Error
validate(&params) (mod.rs:349)
  ├─ validate_non_top_level → IllegalDupIf/IllegalOrI/DuplicateKeys/MixedTimeLocks/…
  └─ top level → ValidationError::{Malleable, NonBase, SiglessBranch, Unsatisfiable}
                   └─ crate::Error::Validation
```

---

## Appendix: quick reference of the exact symbols

| Concept | Location |
|---|---|
| `enum Dissat {None, Unique, Unknown}` | `src/miniscript/types/malleability.rs:12–30` |
| `enum Malleability {Malleable, NonMalleable{dissat,signed}}` | malleability.rs:63–78 |
| `Malleability::TRUE/FALSE` | malleability.rs:82, 85 |
| letter rendering f/e/s/m | `src/miniscript/types/mod.rs:183–195` |
| combinator constructors | and_b :211, and_v :239, or_b :259, or_d :278, or_c :294, or_i :310, and_or :334, threshold :361 |
| wrapper casts | cast_alt :158, cast_swap :161, cast_check :164, cast_dupif :167, cast_verify :170, cast_nonzero :173, cast_zeronotequal :176, cast_true :179, cast_or_i_false :182; helpers `with_dissat` :186, `cast_dissat_if_forced` :196 |
| `enum ErrorKind` (Err conditions) | types/mod.rs:26–60 |
| per-variant dispatch | `Type::type_check`, types/mod.rs:462–538 |
| top-level malleability gate | `Miniscript::validate`, `src/miniscript/mod.rs:349–380` (check at :356–360) |
| params: `allow_malleability` | `src/validation.rs:24`; defaults: MAX :78 `true`, SANE :107 `false`, CONSENSUS :137 `true` |
| `k`-validity for thresholds | `src/primitives/threshold.rs:46–52` |
| spec mirror used for comparison | `notes/sipa-spec.md:288–316` (malleability table), `:120–147` (correctness table) |
