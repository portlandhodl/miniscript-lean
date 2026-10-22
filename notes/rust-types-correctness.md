# rust-miniscript: `Correctness` type system analysis

Analyzed tree: `/home/qrsnap/git/miniscript-lean/rust-miniscript` @ `96a1c91`
("Merge rust-bitcoin/rust-miniscript#1065: descriptor: reject keys deeper than BIP32 allows")

Primary sources (line refs are into these files):

- **`c.rs` = `src/miniscript/types/correctness.rs`** (517 lines)
- **`m.rs` = `src/miniscript/types/mod.rs`** (539 lines)

Secondary references (only for context, read-only):

- `src/miniscript/types/malleability.rs` (`Dissat`, `Malleability`)
- `src/miniscript/mod.rs` (`Miniscript::validate` top-level B-check)
- `src/validation.rs` (`ValidationParams::allow_non_b`)
- `src/policy/compiler.rs` (only consumer of `Type::is_subtype`)
- `src/miniscript/decode.rs` (definition of the 30-variant `Terminal` enum, lines 90–160)

> Historical note: the current code no longer performs inline checks such as
> `child_ty.corr.base == Base::B` inside `Type::type_check`. All failure conditions
> and the computed output types have been factored into `const fn` constructors on
> `Correctness` (`c.rs`) that return `Result<Self, ErrorKind>`; `Type::type_check`
> (`m.rs:459–538`) is only a dispatch table that calls them and wraps the error with
> the fragment string. This report documents both layers.

---

## 1. Building blocks: `Base`, `Input`, `Correctness`

### 1.1 `Base` — B / V / K / W (`c.rs:7–27`)

```rust
/// Basic type representing where the fragment can go
#[derive(Copy, Clone, PartialEq, Eq, PartialOrd, Ord, Debug, Hash)]
pub enum Base {
    /// Takes its inputs from the top of the stack. Pushes
    /// nonzero if the condition is satisfied. If not, if it
    /// does not abort, then 0 is pushed.
    B,
    /// Takes its inputs from the top of the stack. Pushes a
    /// public key, regardless of satisfaction, onto the stack.
    /// Must be wrapped in `c:` to turn into any other type.
    K,
    /// Takes its inputs from the top of the stack, which
    /// must satisfy the condition (will abort otherwise).
    /// Does not push anything onto the stack.
    V,
    /// Takes from the stack its inputs + element X at the top.
    /// If the inputs satisfy the condition, [nonzero X] or
    /// [X nonzero] is pushed. If not, if it does not abort,
    /// then [0 X] or [X 0] is pushed.
    W,
}
```

These are the four *basic types* of the Miniscript spec (base/verify/key/wrapped).
Printed by `Display for Type` (`m.rs:163–168`):

```rust
f.write_str(match self.corr.base {
    Base::B => "B",
    Base::K => "K",
    Base::V => "V",
    Base::W => "W",
})?;
```

**Discriminant order is `B=0, K=1, V=2, W=3`** (declaration order in the source is
B, K, V, W — *not* the alphabetical/spec order B, V, K, W). This matters only for
the derived `Ord` and for the cast `self.base as u8` used in `is_subtype` (§3.3).

### 1.2 `Input` — the z / o / (–) / (on) / n properties (`c.rs:29–46`)

```rust
/// Type property representing expectations about how many inputs
/// the fragment accepts, and assumptions about that
#[derive(Copy, Clone, PartialEq, Eq, PartialOrd, Ord, Debug, Hash)]
pub enum Input {
    /// Consumes no stack elements under any circumstances
    Zero,
    /// Consumes exactly one stack element under all circumstances
    One,
    /// Consumes any number of stack elements
    Any,
    /// Consumes exactly one stack element. If the fragment is
    /// satisfied, this element must be nonzero.
    OneNonZero,
    /// Consumes 1 or more stack elements. If the fragment is
    /// satisfied, the top element must be nonzero. (This property
    /// cannot be applied to any type with a `W` base.)
    AnyNonZero,
}
```

Printed by `Display for Type` (`m.rs:169–176`, note the leading `/` separator at `m.rs:169`):

```rust
f.write_str("/")?;
f.write_str(match self.corr.input {
    Input::Zero => "z",
    Input::One => "o",
    Input::OneNonZero => "on",
    Input::Any => "",
    Input::AnyNonZero => "n",
})?;
```

The five variants are really **subsets of the two spec properties `z`/`o` (count)
plus `n` (nonzero-top)**; the display string concatenates the letters that hold:

| Variant       | Display | Spec property set | Semantics |
|---------------|---------|-------------------|-----------|
| `Zero`        | `z`     | {z}               | consumes exactly 0 stack elements |
| `One`         | `o`     | {o}               | consumes exactly 1 stack element |
| `Any`         | *(empty)* | {} ("-" in the spec table) | consumes any number of stack elements |
| `OneNonZero`  | `on`    | {o, n}            | exactly 1 element, which must be nonzero on satisfaction |
| `AnyNonZero`  | `n`     | {n}               | ≥1 elements, top element must be nonzero on satisfaction |

So the requested mapping is `Zero→z, One→o, Any→` *nothing* (`"-"` only as spec
notation), `OneNonZero→on` (both letters), `AnyNonZero→n`. (`OneNonZero` holds the
strongest guarantees: it is a subtype of `One`, of `AnyNonZero`, and of `Any` — see §3.2.)
The doc note that `AnyNonZero` "cannot be applied to any type with a `W` base" is enforced
by `sanity_checks` (§1.4).

`Input` additionally has a private `constfn_eq` (`c.rs:48–59`), a `matches!` re-implementation
of `==` for use in const fns (rustc limitation noted at `c.rs:49`).

### 1.3 `Correctness` struct (`c.rs:75–95`)

```rust
/// Soundness and completeness type properties of a fragment.
///
/// Completeness is the property that a valid witness actually exists for all
/// branches, which an honest user can produce. Soundness is the property
/// that no branch can be satisfied _without_ an honest user.
#[derive(Copy, Clone, PartialEq, Eq, PartialOrd, Ord, Debug, Hash)]
pub struct Correctness {
    /// The base type
    pub base: Base,
    /// Properties of the inputs
    pub input: Input,
    /// Whether it is definitely possible to dissatisfy the expression.
    /// If this is false, it does not necessarily mean that dissatisfaction
    /// is impossible (see `Dissat::None` for this property); it only means
    /// that we cannot depend on having a dissatisfaction when reasoning
    /// about completeness.
    pub dissatisfiable: bool,
    /// Whether the fragment's "nonzero" output on satisfaction is
    /// always the constant 1.
    pub unit: bool,
}
```

Field ↔ spec letter correspondence (the remaining two letters are printed in
`Display for Type`, `m.rs:177–182`):

| Field           | Letter | Meaning |
|-----------------|--------|---------|
| `dissatisfiable`| `d`    | a dissatisfaction is guaranteed to exist |
| `unit`          | `u`    | satisfaction pushes exactly the constant `1` |

Together, `Correctness` = spec properties `{B|V|K|W, z, o, n, d, u}`. The full
`Type` (`m.rs:151–159`) pairs it with `Malleability` (properties `f`/`e`/`s`/`m`,
printed at `m.rs:185–195`) — outside the scope of this report except where the
two interact (§1.4, §3).

```rust
// m.rs:153-159
pub struct Type {
    /// Correctness/soundness properties
    pub corr: Correctness,
    /// Malleability properties
    pub mall: Malleability,
}
```

### 1.4 Structural invariants (`sanity_checks`)

Two `debug_assert!`-based invariant checks (no-ops in release builds):

`Correctness::sanity_checks` (`c.rs:117–133`):

```rust
pub(crate) fn sanity_checks(&self) {
    match self.base {
        Base::B => {}
        Base::K => {
            debug_assert!(self.unit);
        }
        Base::V => {
            debug_assert!(!self.unit);
            debug_assert!(!self.dissatisfiable);
        }
        Base::W => {
            debug_assert!(!self.input.constfn_eq(Input::OneNonZero));
            debug_assert!(!self.input.constfn_eq(Input::AnyNonZero));
        }
    }
}
```

i.e. **K ⇒ u; V ⇒ ¬u ∧ ¬d; W ⇒ input ∉ {on, n}** (a `W` leaves extra stack data
below/to the side, so "the top element must be nonzero" is meaningless for it).

`Type::sanity_checks` (`m.rs:215–224`) adds the cross-layer invariants with
malleability:

```rust
fn sanity_checks(&self) {
    if let Malleability::NonMalleable { dissat, signed } = self.mall {
        debug_assert!(!self.corr.dissatisfiable || dissat != Dissat::None);
        debug_assert!(dissat == Dissat::None || self.corr.base != Base::V);
        debug_assert!(signed || self.corr.base != Base::K);
    }
    debug_assert!(self.mall.is_non_malleable() || self.corr.input != Input::Zero);
    self.corr.sanity_checks();
}
```

Both are run on every *successful* `type_check` result (`m.rs:534–536`):

```rust
if let Ok(ref ret) = ret {
    ret.sanity_checks()
}
```

### 1.5 Error vocabulary (`m.rs:24–60`)

Every typing failure in this layer is one `ErrorKind`, wrapped with the failing
fragment's string into `Error` by the closure at `m.rs:467–469`:

```rust
let wrap_err = |result: Result<Self, ErrorKind>| {
    result.map_err(|kind| Error { fragment_string: fragment.to_string(), error: kind })
};
```

Relevant kinds and which constructors raise them:

| `ErrorKind` (`m.rs`) | Raised by (c.rs line) |
|---|---|
| `NonZeroDupIf` (27) | `cast_dupif` (231) |
| `LeftNotDissatisfiable` (31) | `or_b` (362), `or_d` (388), `or_c` (411), `and_or` (452) |
| `RightNotDissatisfiable` (33) | `or_b` (365) |
| `SwapNonOne` (36) | `cast_swap` (202) |
| `NonZeroZero` (39) | `cast_nonzero` (254) |
| `LeftNotUnit` (42) | `or_d` (391), `or_c` (414), `and_or` (455) |
| `ChildBase1(Base)` (45) | all unary casts (`c.rs:185, 198, 214, 227, 243, 259, 272, 285, 298`) |
| `ChildBase2(Base, Base)` (48) | `and_b` (316), `and_v` (341), `or_b` (370), `or_d` (396), `or_c` (419), `or_i` (438) |
| `ChildBase3(Base, Base, Base)` (51) | `and_or` (462) |
| `ThresholdBase(usize, Base)` (54) | `threshold` (493, 496) |
| `ThresholdDissat(usize)` (57) | `threshold` (502) |
| `ThresholdNonUnit(usize)` (59) | `threshold` (499) |

Human-readable messages are in `impl Display for Error` (`m.rs:71–144`); e.g.
`NonZeroDupIf` → *"fragment «…» represents needs to be `z`, needs to consume zero
elements from the stack"* (`m.rs:74–78`).

---

## 2. Typing rules per `Terminal` variant

The dispatch is `Type::type_check` (`m.rs:459–538`):

```rust
pub fn type_check<Pk, Ctx>(fragment: &Terminal<Pk, Ctx>) -> Result<Self, Error>
where
    Pk: MiniscriptKey,
    Ctx: ScriptContext,
```

### 2.1 Leaves — unconditional `Ok`, fixed constants

Dispatch arms (`m.rs:472–485`):

```rust
Terminal::True => Ok(Self::TRUE),
Terminal::False => Ok(Self::FALSE),
Terminal::PkK(..) => Ok(Self::pk_k()),
Terminal::PkH(..) | Terminal::RawPkH(..) => Ok(Self::pk_h()),
Terminal::Multi(..) => Ok(Self::multi()),
Terminal::SortedMulti(..) => Ok(Self::sortedmulti()),
Terminal::MultiA(..) => Ok(Self::multi_a()),
Terminal::SortedMultiA(..) => Ok(Self::sortedmulti_a()),
Terminal::After(_) => Ok(Self::time()),
Terminal::Older(_) => Ok(Self::time()),
Terminal::Sha256(..) => Ok(Self::hash()),
Terminal::Hash256(..) => Ok(Self::hash()),
Terminal::Ripemd160(..) => Ok(Self::hash()),
Terminal::Hash160(..) => Ok(Self::hash()),
```

No preconditions: leaf fragments typecheck in *every* context (consensus limits on
`multi`/`multi_a` key counts are checked elsewhere, by `ScriptContext`). The
constants (with the paired `Malleability` constructors wired in at `m.rs:226–256`):

**`True` (`1`)** — `Correctness::TRUE`, `c.rs:97–100`:

```rust
pub const TRUE: Self =
    Self { base: Base::B, input: Input::Zero, dissatisfiable: false, unit: true };
```
Type: `B/z u` (no `d`: `1` cannot be dissatisfied).

**`False` (`0`)** — `Correctness::FALSE`, `c.rs:102–104`:

```rust
pub const FALSE: Self =
    Self { base: Base::B, input: Input::Zero, dissatisfiable: true, unit: true };
```
Type: `B/z du`.

**`PkK` (`<key>`)** — `pk_k()`, `c.rs:135–138`:

```rust
pub const fn pk_k() -> Self {
    Self { base: Base::K, input: Input::OneNonZero, dissatisfiable: true, unit: true }
}
```
Type: `K/on du` (dissatisfaction = empty/0 signature).

**`PkH` (`DUP HASH160 <keyhash> EQUALVERIFY`) and `RawPkH`** — `pk_h()`, `c.rs:140–148`:

```rust
pub const fn pk_h() -> Self {
    Self {
        base: Base::K,
        input: Input::AnyNonZero,
        dissatisfiable: true, // FIXME check with sipa
        unit: true,
    }
}
```
Type: `K/n du` — `AnyNonZero` because the witness is `[sig] (key)` *if* the key is
revealed; the key need not be available to a "dissatisfier" (note the `FIXME`).
Marked `RawPkH` legacy-only / inference-internal (`decode.rs:100–105`).

**`Multi` / `SortedMulti`** (`k (<key>)* n CHECKMULTISIG`) — `multi()`/`sortedmulti()`,
`c.rs:150–158` (both identical on the correctness layer):

```rust
pub const fn multi() -> Self {
    Self { base: Base::B, input: Input::AnyNonZero, dissatisfiable: true, unit: true }
}
```
Type: `B/n du` — witness = dummy element (`CHECKMULTISIG` quirk) + `k` sigs;
dissatisfaction = all-zero sigs; the nonzero-top requirement comes from the
`multisat` count mechanics, not from a user property here.

**`MultiA` / `SortedMultiA`** (`<key> CHECKSIG (<key> CHECKSIGADD)*`) — `multi_a()`/
`sortedmulti_a()`, `c.rs:160–168`:

```rust
pub const fn multi_a() -> Self {
    Self { base: Base::B, input: Input::Any, dissatisfiable: true, unit: true }
}
```
Type: `B/ du` — differs from `multi` only in `input: Any` (no dummy element, and a
dissatisfaction is a vector of explicit `0` per-key sig placeholders of any length
≥ … — the type layer only records "any number" and does not force nonzero-top).

**`After` / `Older`** (`<n> CHECKLOCKTIMEVERIFY` / `CHECKSEQUENCEVERIFY`) —
`time()`, `c.rs:175–178`:

```rust
pub const fn time() -> Self {
    Self { base: Base::B, input: Input::Zero, dissatisfiable: false, unit: false }
}
```
Type: `B/z` (not dissatisfiable as a *script-level* dissatisfaction — the timelock
script always exposes only satisfaction paths; not unit: the "output" of CLTV/CSV
is the pushed number consumed by the opcode itself, actually a nonzero-but-not-`1`
value is what remains if anything — the type system simply promises nothing).

**`Sha256` / `Hash256` / `Ripemd160` / `Hash160`**
(`SIZE 32 EQUALVERIFY <HASHOP> <h> EQUAL`) — `hash()`, `c.rs:170–173`:

```rust
pub const fn hash() -> Self {
    Self { base: Base::B, input: Input::OneNonZero, dissatisfiable: true, unit: true }
}
```
Type: `B/on du` — one witness element, must be nonzero on satisfaction
(dissatisfaction is `0`/anything-not-the-preimage at the script level; the `on`
requirement is the spec's "nonzero" because `0` would collide with a
dissatisfaction).

### 2.2 Unary wrappers (`a:` `s:` `c:` `d:` `v:` `j:` `n:`)

Dispatch arms (`m.rs:486–492`):

```rust
Terminal::Alt(ref sub) => wrap_err(Self::cast_alt(sub.ty)),
Terminal::Swap(ref sub) => wrap_err(Self::cast_swap(sub.ty)),
Terminal::Check(ref sub) => wrap_err(Self::cast_check(sub.ty)),
Terminal::DupIf(ref sub) => wrap_err(Self::cast_dupif(sub.ty)),
Terminal::Verify(ref sub) => wrap_err(Self::cast_verify(sub.ty)),
Terminal::NonZero(ref sub) => wrap_err(Self::cast_nonzero(sub.ty)),
Terminal::ZeroNotEqual(ref sub) => wrap_err(Self::cast_zeronotequal(sub.ty)),
```

For each: **Requires** = conditions that must hold of the child *or typing fails*;
**Computes** = output fields as functions of child fields.

#### `Alt` — `a:X` = `TOALTSTACK [X] FROMALTSTACK` (`c.rs:180–191`)

```rust
/// Constructor for the correctness properties of the `a:` fragment.
pub const fn cast_alt(self) -> Result<Self, ErrorKind> {
    Ok(Self {
        base: match self.base {
            Base::B => Base::W,
            x => return Err(ErrorKind::ChildBase1(x)),
        },
        input: Input::Any,
        dissatisfiable: self.dissatisfiable,
        unit: self.unit,
    })
}
```

- **Requires:** `child.base == B`, else `ChildBase1(child.base)`.
- **Computes:** `base = W`; `input = Any`; `dissatisfiable = child.d`; `unit = child.u`.

#### `Swap` — `s:X` = `SWAP [X]` (`c.rs:193–207`)

```rust
/// Constructor for the correctness properties of the `s:` fragment.
pub const fn cast_swap(self) -> Result<Self, ErrorKind> {
    Ok(Self {
        base: match self.base {
            Base::B => Base::W,
            x => return Err(ErrorKind::ChildBase1(x)),
        },
        input: match self.input {
            Input::One | Input::OneNonZero => Input::Any,
            _ => return Err(ErrorKind::SwapNonOne),
        },
        dissatisfiable: self.dissatisfiable,
        unit: self.unit,
    })
}
```

- **Requires:** `child.base == B` else `ChildBase1`; **and** `child.input ∈ {One, OneNonZero}`
  else `SwapNonOne` (you can only `SWAP` something that consumes *exactly one*
  stack word, since that word must be the one swapped).
- **Computes:** `base = W`; `input = Any`; `d,u` preserved.

#### `Check` — `c:X` = `[X] CHECKSIG` (K→B converter) (`c.rs:209–220`)

```rust
/// Constructor for the correctness properties of the `c:` fragment.
pub const fn cast_check(self) -> Result<Self, ErrorKind> {
    Ok(Self {
        base: match self.base {
            Base::K => Base::B,
            x => return Err(ErrorKind::ChildBase1(x)),
        },
        input: self.input,
        dissatisfiable: self.dissatisfiable,
        unit: true,
    })
}
```

- **Requires:** `child.base == K` else `ChildBase1` (only a key-pushing fragment
  can be turned into a signature check).
- **Computes:** `base = B`; `input = child.input`; `d` preserved; `unit = true`
  (`CHECKSIG` pushes exactly `1` on success).

#### `DupIf` — `d:X` = `DUP IF [X] ENDIF` (`c.rs:222–236`)

```rust
/// Constructor for the correctness properties of the `d:` fragment.
pub const fn cast_dupif(self) -> Result<Self, ErrorKind> {
    Ok(Self {
        base: match self.base {
            Base::V => Base::B,
            x => return Err(ErrorKind::ChildBase1(x)),
        },
        input: match self.input {
            Input::Zero => Input::OneNonZero,
            _ => return Err(ErrorKind::NonZeroDupIf),
        },
        dissatisfiable: true,
        unit: false,
    })
}
```

- **Requires:** `child.base == V` else `ChildBase1`; **and** `child.input == Zero`
  else `NonZeroDupIf` (the child must be *`z`*: nothing below it may be consumed,
  because the `DUP`ed element is inserted under it). Note the rustdoc on
  `ErrorKind::NonZeroDupIf` (`m.rs:27`) reads *"Passed a `z` argument to a `d`
  wrapper when `z` was expected"* (a typo in-tree; it means the opposite).
- **Computes:** `base = B`; `input = OneNonZero` (the fragment itself now consumes
  the duplicated element, which must be nonzero when satisfied); `dissatisfiable = true`
  (skip the `IF`, the dup'd element *is* the dissatisfaction); `unit = false`
  (satisfied path leaves the original element, not necessarily `1`).

#### `Verify` — `v:X` = `[X] VERIFY` (`c.rs:238–249`)

```rust
/// Constructor for the correctness properties of the `v:` fragment.
pub const fn cast_verify(self) -> Result<Self, ErrorKind> {
    Ok(Self {
        base: match self.base {
            Base::B => Base::V,
            x => return Err(ErrorKind::ChildBase1(x)),
        },
        input: self.input,
        dissatisfiable: false,
        unit: false,
    })
}
```

- **Requires:** `child.base == B` else `ChildBase1`.
- **Computes:** `base = V`; `input` preserved; `dissatisfiable = false` (`VERIFY`
  aborts instead of pushing `0`); `unit = false` (pushes nothing).

#### `NonZero` — `j:X` = `SIZE 0NOTEQUAL IF [X] ENDIF` (`c.rs:251–265`)

```rust
/// Constructor for the correctness properties of the `j:` fragment.
pub const fn cast_nonzero(self) -> Result<Self, ErrorKind> {
    if !self.input.constfn_eq(Input::OneNonZero) && !self.input.constfn_eq(Input::AnyNonZero) {
        return Err(ErrorKind::NonZeroZero);
    }
    Ok(Self {
        base: match self.base {
            Base::B => Base::B,
            x => return Err(ErrorKind::ChildBase1(x)),
        },
        input: self.input,
        dissatisfiable: true,
        unit: self.unit,
    })
}
```

- **Requires:** `child.input ∈ {OneNonZero, AnyNonZero}` else `NonZeroZero`
  (the `j:` wrapper dissatisfies by pushing `0` and skipping; this is only a
  *valid* dissatisfaction if `0` could not have *satisfied* the child);
  **and** `child.base == B` else `ChildBase1`.
- **Computes:** `base = B`; `input` preserved; `dissatisfiable = true`; `unit` preserved.

#### `ZeroNotEqual` — `n:X` = `[X] 0NOTEQUAL` (`c.rs:267–278`)

```rust
/// Constructor for the correctness properties of the `n:` fragment.
pub const fn cast_zeronotequal(self) -> Result<Self, ErrorKind> {
    Ok(Self {
        base: match self.base {
            Base::B => Base::B,
            x => return Err(ErrorKind::ChildBase1(x)),
        },
        input: self.input,
        dissatisfiable: self.dissatisfiable,
        unit: true,
    })
}
```

- **Requires:** `child.base == B` else `ChildBase1`.
- **Computes:** `base = B`; `input` preserved; `d` preserved; `unit = true`
  (`0NOTEQUAL` returns canonical `1` for any nonzero input).

### 2.3 Sugar wrappers with no `Terminal` variant: `t:`, `l:`, `u:`

These three wrappers are desugared before/around the AST, so `Terminal` (and hence
`type_check`) has **no variant for them**: `t:X ≡ and_v(X,1)`, `l:X ≡ or_i(0,X)`,
`u:X ≡ or_i(X,0)`; scripts decoded from raw bytes also surface as `AndV`/`OrI`.
The standalone constructors still exist in `c.rs` (and are used by the policy
compiler: `src/policy/compiler.rs:746–773`):

`cast_true` — `t:` (`c.rs:280–291`): requires `Base::V` else `ChildBase1`; computes
`base=B, input=child.input, dissatisfiable=false, unit=true`. Equivalent to
`and_v(child, TRUE)` since `TRUE.unit == true`.

`cast_or_i_false` — `l:`/`u:` (`c.rs:293–309`):

```rust
/// Constructor for the correctness properties of the `l:` and `u:` fragments.
pub const fn cast_or_i_false(self) -> Result<Self, ErrorKind> {
    Ok(Self {
        base: match self.base {
            Base::B => Base::B,
            x => return Err(ErrorKind::ChildBase1(x)),
        },
        input: match self.input {
            // could by `Input::OneNonZero` but the type system
            // isn't safe enough to capture that `0` is unsatisfiable
            Input::Zero => Input::One,
            _ => Input::Any,
        },
        dissatisfiable: true,
        unit: self.unit,
    })
}
```

(This matches what `or_i(child-or-0, 0-or-child)` yields: `False` has
`input=Zero, d=true, u=true`, and `OrI`'s formula gives `input: (Zero,Zero)→One else Any`,
`d = l||r`, `u = l&&r`.) Exposed at the `Type` layer as `cast_likely` (`m.rs:358–367`)
and `cast_unlikely` (`m.rs:347–356`), both delegating to `cast_or_i_false`.

### 2.4 Binary/ternary combinators

#### `AndV` — `[X] [Y]` (`m.rs:498–502` → `c.rs:334–357`)

```rust
/// Constructor for the correctness properties of the `and_v` fragment
pub const fn and_v(left: Self, right: Self) -> Result<Self, ErrorKind> {
    Ok(Self {
        base: match (left.base, right.base) {
            (Base::V, Base::B) => Base::B,
            (Base::V, Base::K) => Base::K,
            (Base::V, Base::V) => Base::V,
            (x, y) => return Err(ErrorKind::ChildBase2(x, y)),
        },
        input: match (left.input, right.input) {
            (Input::Zero, Input::Zero) => Input::Zero,
            (Input::Zero, Input::One) | (Input::One, Input::Zero) => Input::One,
            (Input::Zero, Input::OneNonZero) | (Input::OneNonZero, Input::Zero) => {
                Input::OneNonZero
            }
            (Input::OneNonZero, _)
            | (Input::AnyNonZero, _)
            | (Input::Zero, Input::AnyNonZero) => Input::AnyNonZero,
            _ => Input::Any,
        },
        dissatisfiable: false,
        unit: right.unit,
    })
}
```

- **Requires:** `(left.base, right.base) ∈ {(V,B), (V,K), (V,V)}` else
  `ChildBase2(l.base, r.base)` — sequential execution: the left must be complete
  (`V` consumes its inputs and pushes nothing), the right decides the result base.
- **Computes:** `base` per table above; `input` = sequential-input join (the table
  shared with `and_b`, see below — the left's nonzero-top requirement propagates
  because the left's top element is *also* the whole fragment's);
  `dissatisfiable = false` (a satisfied left `V` never dissatisfies: it would
  abort); `unit = right.unit` (the result value comes verbatim from the right child).

#### `AndB` — `[X] [Y] BOOLAND` (`m.rs:493–497` → `c.rs:311–332`)

Identical structure, but base rule is `(B, W) → B` else `ChildBase2` and
`unit: true` (`BOOLAND` outputs canonical 0/1):

```rust
base: match (left.base, right.base) {
    (Base::B, Base::W) => Base::B,
    (x, y) => return Err(ErrorKind::ChildBase2(x, y)),
},
...
dissatisfiable: left.dissatisfiable && right.dissatisfiable,
unit: true,
```

- **Requires:** `(B, W)` — left is a plain expression, right is a wrapped one that
  also peeks at the left's result (the extra stack operand of `W` is the left's
  output).
- **Computes:** `base = B`; same input-join table as `and_v`;
  `d = left.d && right.d` (dissatisfying `BOOLAND` needs both children to push `0`);
  `unit = true`.

**Shared sequential-input join table** (`and_b` at `c.rs:318–328`, `and_v` at
`c.rs:343–353`; identical match arms):

```rust
input: match (left.input, right.input) {
    (Input::Zero, Input::Zero) => Input::Zero,
    (Input::Zero, Input::One) | (Input::One, Input::Zero) => Input::One,
    (Input::Zero, Input::OneNonZero) | (Input::OneNonZero, Input::Zero) => {
        Input::OneNonZero
    }
    (Input::OneNonZero, _)
    | (Input::AnyNonZero, _)
    | (Input::Zero, Input::AnyNonZero) => Input::AnyNonZero,
    _ => Input::Any,
},
```

Read: both zero → zero; exactly-one-total (summing with a `Zero` partner) →
`One`; one-nonzero on *either* side propagates as `AnyNonZero`… with the catch-all
`_ => Any` for combinations like `(One, One)` (two elements) where no count
guarantee can be made.

#### `OrB` — `[X] [Y] BOOLOR` (`m.rs:503–507` → `c.rs:359–383`)

```rust
pub const fn or_b(left: Self, right: Self) -> Result<Self, ErrorKind> {
    if !left.dissatisfiable {
        return Err(ErrorKind::LeftNotDissatisfiable);
    }
    if !right.dissatisfiable {
        return Err(ErrorKind::RightNotDissatisfiable);
    }
    Ok(Self {
        base: match (left.base, right.base) {
            (Base::B, Base::W) => Base::B,
            (x, y) => return Err(ErrorKind::ChildBase2(x, y)),
        },
        input: match (left.input, right.input) {
            (Input::Zero, Input::Zero) => Input::Zero,
            (Input::Zero, Input::One)
            | (Input::One, Input::Zero)
            | (Input::Zero, Input::OneNonZero)
            | (Input::OneNonZero, Input::Zero) => Input::One,
            _ => Input::Any,
        },
        dissatisfiable: true,
        unit: true,
    })
}
```

- **Requires:** `left.dissatisfiable` (else `LeftNotDissatisfiable`) **and**
  `right.dissatisfiable` (else `RightNotDissatisfiable`) — to dissatisfy a `BOOLOR`
  you push `0` to *both* children, so both must be dissatisfiable for completeness;
  **and** `(B, W)` bases else `ChildBase2`.
- **Computes:** `base = B`; input: `(Zero,Zero)→Zero`, mixed `Zero/One/OneNonZero`
  → `One`, else `Any` (note: no `AnyNonZero` result here — the nonzero-top of a
  `BOOLOR` satisfaction isn't guaranteed to be the user's own input, it may be the
  sibling's output); `dissatisfiable = true`; `unit = true`.

#### `OrD` — `[X] IFDUP NOTIF [Y] ENDIF` (`m.rs:508–512` → `c.rs:385–406`)

```rust
pub const fn or_d(left: Self, right: Self) -> Result<Self, ErrorKind> {
    if !left.dissatisfiable {
        return Err(ErrorKind::LeftNotDissatisfiable);
    }
    if !left.unit {
        return Err(ErrorKind::LeftNotUnit);
    }
    Ok(Self {
        base: match (left.base, right.base) {
            (Base::B, Base::B) => Base::B,
            (x, y) => return Err(ErrorKind::ChildBase2(x, y)),
        },
        input: match (left.input, right.input) {
            (Input::Zero, Input::Zero) => Input::Zero,
            (Input::One, Input::Zero) | (Input::OneNonZero, Input::Zero) => Input::One,
            _ => Input::Any,
        },
        dissatisfiable: right.dissatisfiable,
        unit: right.unit,
    })
}
```

- **Requires:** `left.dissatisfiable` else `LeftNotDissatisfiable`; `left.unit`
  else `LeftNotUnit` (the `IFDUP ... NOTIF` branch forwards `0` to skip — a valid
  path only if left's *satisfaction* is exactly `1` and its dissatisfaction is
  canonical); bases `(B, B)` else `ChildBase2`.
- **Computes:** `base = B`; input: `(Zero,Zero)→Zero`,
  `(One|OneNonZero, Zero)→One`, else `Any`; `d = right.d` (left already checked
  dissatisfiable); `u = right.u` (right's output is one of the two possible results).

#### `OrC` — `[X] NOTIF [Y] ENDIF` (`m.rs:513–517` → `c.rs:408–429`)

Same left-side guards (`LeftNotDissatisfiable`, `LeftNotUnit`) and same input
table as `or_d`, but the right child must be `V` and the whole thing becomes `V`:

```rust
base: match (left.base, right.base) {
    (Base::B, Base::V) => Base::V,
    (x, y) => return Err(ErrorKind::ChildBase2(x, y)),
},
...
dissatisfiable: false,
unit: false,
```

- **Requires:** `left.d`, `left.unit`, bases `(B, V)`.
- **Computes:** `base = V`; `d = false`; `u = false` (a `V` aborts rather than
  dissatisfying).

#### `OrI` — `IF [X] ELSE [Y] ENDIF` (`m.rs:518–522` → `c.rs:431–447`)

```rust
/// Constructor for the correctness properties of the `or_i` fragment
pub const fn or_i(left: Self, right: Self) -> Result<Self, ErrorKind> {
    Ok(Self {
        base: match (left.base, right.base) {
            (Base::B, Base::B) => Base::B,
            (Base::V, Base::V) => Base::V,
            (Base::K, Base::K) => Base::K,
            (x, y) => return Err(ErrorKind::ChildBase2(x, y)),
        },
        input: match (left.input, right.input) {
            (Input::Zero, Input::Zero) => Input::One,
            _ => Input::Any,
        },
        dissatisfiable: left.dissatisfiable || right.dissatisfiable,
        unit: left.unit && right.unit,
    })
}
```

- **Requires:** both children have the *same* base, one of `B`, `V` or `K` (else
  `ChildBase2`) — the `IF` consumes a 0/1 selector and both branches must produce
  stack-compatible results. **No dissatisfiability requirements** on children here.
- **Computes:** `base` = common base; `input`: both `Zero` → `One` (the single
  selector), else `Any` (note: `(Zero, One)` is also `Any` — branches are
  exclusive so no per-branch count can be promised); `d = l.d || r.d`; `u = l.u && r.u`.

#### `AndOr` — `[X] NOTIF [Y] ELSE [Z] ENDIF` (`m.rs:523–528` → `c.rs:449–477`)

```rust
pub const fn and_or(a: Self, b: Self, c: Self) -> Result<Self, ErrorKind> {
    if !a.dissatisfiable {
        return Err(ErrorKind::LeftNotDissatisfiable);
    }
    if !a.unit {
        return Err(ErrorKind::LeftNotUnit);
    }
    Ok(Self {
        base: match (a.base, b.base, c.base) {
            (Base::B, Base::B, Base::B) => Base::B,
            (Base::B, Base::K, Base::K) => Base::K,
            (Base::B, Base::V, Base::V) => Base::V,
            (x, y, z) => return Err(ErrorKind::ChildBase3(x, y, z)),
        },
        input: match (a.input, b.input, c.input) {
            (Input::Zero, Input::Zero, Input::Zero) => Input::Zero,
            (Input::Zero, Input::One, Input::One)
            | (Input::Zero, Input::One, Input::OneNonZero)
            | (Input::Zero, Input::OneNonZero, Input::One)
            | (Input::Zero, Input::OneNonZero, Input::OneNonZero)
            | (Input::One, Input::Zero, Input::Zero)
            | (Input::OneNonZero, Input::Zero, Input::Zero) => Input::One,
            _ => Input::Any,
        },
        dissatisfiable: c.dissatisfiable,
        unit: b.unit && c.unit,
    })
}
```

- **Requires:** `a.dissatisfiable` (else `LeftNotDissatisfiable`) and `a.unit`
  (else `LeftNotUnit`) — the a-branch's *result* steers the `NOTIF/ELSE`, so it
  must dissatisfy cleanly and satisfy as `1`; and
  `(a.base, b.base, c.base) ∈ {(B,B,B),(B,K,K),(B,V,V)}` else `ChildBase3` — first
  child is `B`, the other two share a base which becomes the result base.
- **Computes:** `base` = shared base of b and c (or `B`); `input`: all-zero →
  `Zero`; patterns where *both execution paths* consume exactly one element in
  total → `One` (the two `(One|OneNonZero, Zero, Zero)` rows front-load `a`'s
  input; the four `(Zero, One|OneNonZero, One|OneNonZero)` rows load it into the
  b/c branches); anything else → `Any`; `d = c.d` (dissatisfying means: satisfy
  a's `NOTIF`-skip then dissatisfy c; a was already required dissatisfiable);
  `u = b.u && c.u`.

#### `Thresh` — `[X₀] ([Xᵢ] ADD)* k EQUAL` (`m.rs:529–532` → `c.rs:479–516`)

```rust
/// Constructor for the correctness properties of the `thresh` fragment
// Cannot be constfn because it takes a closure.
pub fn threshold<'a, I>(_k: usize, subs: I) -> Result<Self, ErrorKind>
where
    I: Iterator<Item = &'a Self>,
{
    let mut num_args = 0;
    for (i, subtype) in subs.enumerate() {
        num_args += match subtype.input {
            Input::Zero => 0,
            Input::One | Input::OneNonZero => 1,
            Input::Any | Input::AnyNonZero => 2, // we only check if num args is max 1
        };
        if i == 0 && subtype.base != Base::B {
            return Err(ErrorKind::ThresholdBase(i, subtype.base));
        }
        if i != 0 && subtype.base != Base::W {
            return Err(ErrorKind::ThresholdBase(i, subtype.base));
        }
        if !subtype.unit {
            return Err(ErrorKind::ThresholdNonUnit(i));
        }
        if !subtype.dissatisfiable {
            return Err(ErrorKind::ThresholdDissat(i));
        }
    }

    Ok(Self {
        base: Base::B,
        input: match num_args {
            0 => Input::Zero,
            1 => Input::One,
            _ => Input::Any,
        },
        dissatisfiable: true,
        unit: true,
    })
}
```

- **Requires** (loop over children, index `i` starts at 0):
  - `subs[0].base == B` else `ThresholdBase(0, base)`; `subs[i>0].base == W` else
    `ThresholdBase(i, base)` — the first child runs bare, each later child is
    wrapped so it can add its result on top of the accumulator.
  - every child `unit` else `ThresholdNonUnit(i)` (`ADD` requires canonical `0`/`1`).
  - every child `dissatisfiable` else `ThresholdDissat(i)` (any subset of children
    may need to be pushed as `0`).
  - (`k` itself is ignored on this layer — named `_k`; it is used by
    `Malleability::threshold`, see `m.rs:453–454`.)
- **Computes:** `base = B`; `input` by summing child consumption (`Zero→0`,
  `One/OneNonZero→1`, `Any/AnyNonZero→2`): `0 → Zero`, `1 → One`, `≥2 → Any`
  (the inline comment notes the distinction only matters up to 1); `d = true`;
  `u = true` (`EQUAL` is canonical).
- Note the arity-k constraints (`k ≤ n`, non-zero, etc.) are *not* here; they're
  enforced by `Threshold` construction/`ScriptContext` limits.

---

## 3. Subtyping and comparison

### 3.1 Derived comparisons ≠ subtyping

All of `Base`, `Input`, `Correctness` and `Type` derive
`Copy, Clone, PartialEq, Eq, PartialOrd, Ord, Debug, Hash`
(`c.rs:8`, `c.rs:31`, `c.rs:80`, `m.rs:153`). So:

- `==` is **structural equality of every field** (`Type` equality includes
  malleability). It is *not* "same guarantees": e.g. `OneNonZero != One` even
  though everything with `OneNonZero` also has the `o` property.
- Derived `PartialOrd`/`Ord` is field-by-field lexicographic over *declaration
  order* (`base`, then `input`, then `dissatisfiable`, then `unit`), used for
  deterministic maps/sorting (`Ord`+`Hash`) — it is **not** the subtype lattice
  (e.g. `Ord`'s `K > B` since `K` is declared after `B`, which means nothing
  semantically).

The actual "one type can stand in for another" relation is the explicit
`is_subtype` chain.

### 3.2 `Input::is_subtype` (`c.rs:61–72`)

```rust
/// Check whether given `Input` is a subtype of `other`. That is,
/// if some Input is `OneNonZero` then it must be `One`, hence `OneNonZero` is
/// a subtype if `One`. Returns `true` for `a.is_subtype(a)`.
const fn is_subtype(&self, other: Self) -> bool {
    match (*self, other) {
        (x, y) if x.constfn_eq(y) => true,
        (Self::OneNonZero, Self::One)
        | (Self::OneNonZero, Self::AnyNonZero)
        | (_, Self::Any) => true,
        _ => false,
    }
}
```

Supertypes of each variant (reflexive + the three extra edges):

| self ↓ is a subtype of → | Zero | One | Any | OneNonZero | AnyNonZero |
|---|---|---|---|---|---|
| **Zero** | ✓ | | ✓ | | |
| **One** | | ✓ | ✓ | | |
| **Any** | | | ✓ | | |
| **OneNonZero** | | ✓ | ✓ | ✓ | ✓ |
| **AnyNonZero** | | | ✓ | | ✓ |

(As the rustdoc says: holding both `o` and `n` implies holding each of them —
`OneNonZero ≤ One` and `OneNonZero ≤ AnyNonZero` — and everything is a subtype of
`Any`, the absence of properties.)

### 3.3 `Correctness::is_subtype` (`c.rs:106–115`)

```rust
/// Check whether the `self` is a subtype of `other` argument .
/// This checks whether the argument `other` has attributes which are present
/// in the given `Type`. This returns `true` on same arguments
/// `a.is_subtype(a)` is `true`.
pub const fn is_subtype(&self, other: Self) -> bool {
    self.base as u8 == other.base as u8
        && self.input.is_subtype(other.input)
        && self.dissatisfiable >= other.dissatisfiable
        && self.unit >= other.unit
}
```

Component-wise, with booleans ordered `false < true`:

- `base` must be **identical** (no subtyping between B/V/K/W themselves);
- `input` per §3.2;
- `self.dissatisfiable >= other.dissatisfiable`: self may only *add* the `d`
  guarantee, never drop it (if `other` claims `d`, self must too);
- same for `unit` (`u`).

Semantics (the "sat of one type in another context" idea): `self` is usable
**anywhere `other` is expected**, because it satisfies every property `other`
advertises — same base, at least the input guarantees, at least `d`, at least `u`.
Reflexive by construction (`a.is_subtype(a) == true`).

### 3.4 `Type::is_subtype` lifts it to correctness+malleability (`m.rs:207–213`)

```rust
pub const fn is_subtype(&self, other: Self) -> bool {
    self.corr.is_subtype(other.corr) && self.mall.is_subtype(other.mall)
}
```

with `Malleability::is_subtype` (`malleability.rs:114–125`):

```rust
pub const fn is_subtype(&self, other: Self) -> bool {
    match (self, other) {
        // A malleable fragment promises nothing, so everything is a
        // subtype of it, and it is a subtype of nothing else.
        (_, Self::Malleable) => true,
        (Self::Malleable, Self::NonMalleable { .. }) => false,
        (
            Self::NonMalleable { dissat, signed },
            Self::NonMalleable { dissat: other_dissat, signed: other_signed },
        ) => dissat.is_subtype(other_dissat) && *signed >= other_signed,
    }
}
```

and `Dissat::is_subtype` (`malleability.rs:43–51`): `Unique ≤ Unknown` and
`None ≤ Unknown` (plus reflexivity). So the full relation adds the `f/e/s/m`
properties on the same "subtype = more guarantees" reading.

### 3.5 Where `is_subtype` is actually used ("check" in a foreign context)

Within the type layer itself, **`is_subtype` is not called during type-checking or
validation at all** — every child requirement is written explicitly in the
constructors above (e.g. `cast_check` requires *exactly* `Base::K`, not a subtype).
The only consumer in the crate is the policy compiler's memo-map pruning
(`src/policy/compiler.rs:286–293`, used at `:828–843`):

```rust
/// A Compilation key subtype of another if the type if subtype and other
/// attributes are equal
fn is_subtype(self, other: Self) -> bool {
    self.ty.is_subtype(other.ty)
        && self.expensive_verify == other.expensive_verify
        && self.dissat_prob == other.dissat_prob
}
```

```rust
// Check whether the new element is worse than any existing element. If there
// is an element which is a subtype of the current element and has better
// cost, don't consider this element.
let is_worse = map.iter().any(|(existing_key, existing_elem)| {
    let existing_elem_cost = existing_elem.cost_1d(sat_prob, dissat_prob);
    existing_key.is_subtype(elem_key) && existing_elem_cost <= elem_cost
});
```

i.e. an already-compiled AST whose type is a **subtype** of a new candidate's type
(and which is no more expensive) makes the candidate redundant at the same AST
position — subtyping is used to *substitute one fragment for another* in an
identical typing context (including for the compiler's own wrapper applications).

### 3.6 The top-level "B check" (`check` for a wrapped context)

The context requirement on a *whole* Miniscript is checked separately from the
typing rules, in `Miniscript::validate` (`src/miniscript/mod.rs:362–364`):

```rust
// The B check is inherently top-level.
if !params.allow_non_b && self.ty.corr.base != types::Base::B {
    return Err(ValidationError::NonBase(self.ty.corr.base));
}
```

with `allow_non_b` defined in `ValidationParams` (`src/validation.rs:39–40`:
"Allow scripts that don't have the "B" type, i.e. which are not valid scripts on
their own"). It is set to `true` only by the permissive `ValidationParams::MAX`
(`validation.rs:85`); both `SANE` (`:114`) and `CONSENSUS` (`:144`) require the
root fragment to be `B`. This is the only place a *context* accepts/rejects a
type as a whole — sub-fragment positions never consult `is_subtype`, they use the
exact per-rule base dissatisfiability/unit checks quoted in §2.

---

## Appendix: quick-reference formula table

| Fragment | Child requirements (else `ErrorKind`) | base | input | dissatisfiable | unit |
|---|---|---|---|---|---|
| `True`/`1` | — | B | Zero | false | true |
| `False`/`0` | — | B | Zero | true | true |
| `PkK` | — | K | OneNonZero | true | true |
| `PkH`, `RawPkH` | — | K | AnyNonZero | true | true |
| `Multi`, `SortedMulti` | — | B | AnyNonZero | true | true |
| `MultiA`, `SortedMultiA` | — | B | Any | true | true |
| `After`, `Older` | — | B | Zero | false | false |
| `Sha256`,`Hash256`,`Ripemd160`,`Hash160` | — | B | OneNonZero | true | true |
| `a:` (`Alt`) | B (`ChildBase1`) | W | Any | child | child |
| `s:` (`Swap`) | B (`ChildBase1`); input∈{o,on} (`SwapNonOne`) | W | Any | child | child |
| `c:` (`Check`) | K (`ChildBase1`) | B | child | child | true |
| `d:` (`DupIf`) | V (`ChildBase1`); input=Zero (`NonZeroDupIf`) | B | OneNonZero | true | false |
| `v:` (`Verify`) | B (`ChildBase1`) | V | child | false | false |
| `j:` (`NonZero`) | input∈{on,n} (`NonZeroZero`); B (`ChildBase1`) | B | child | true | child |
| `n:` (`ZeroNotEqual`) | B (`ChildBase1`) | B | child | child | true |
| `and_v` | (V,B)/(V,K)/(V,V) (`ChildBase2`) | = right base | join₁ | false | right.unit |
| `and_b` | (B,W) (`ChildBase2`) | B | join₁ | l.d ∧ r.d | true |
| `or_b` | l.d (`LeftNotDissatisfiable`); r.d (`RightNotDissatisfiable`); (B,W) | B | join₂ | true | true |
| `or_d` | l.d; l.u (`LeftNotUnit`); (B,B) | B | join₃ | r.d | r.u |
| `or_c` | l.d; l.u; (B,V) | V | join₃ | false | false |
| `or_i` | (B,B)/(V,V)/(K,K) | = child base | (z,z)→One else Any | l.d ∨ r.d | l.u ∧ r.u |
| `andor(a,b,c)` | a.d; a.u; (B,x,x) with x∈{B,K,V} (`ChildBase3`) | x | join₄ | c.d | b.u ∧ c.u |
| `thresh` | base[0]=B, base[i>0]=W (`ThresholdBase`); all u (`ThresholdNonUnit`); all d (`ThresholdDissat`) | B | Σ(0/1/2)→z/o/Any | true | true |

Input joins:
**join₁** (`and_v`/`and_b`, sequential, `c.rs:318–328`/`343–353`):
(z,z)→z; (z,o)/(o,z)→o; (z,on)/(on,z)→on; left∈{on,n} or (z,n)→n; else Any.
**join₂** (`or_b`, `c.rs:372–379`): (z,z)→z; (z,o)/(o,z)/(z,on)/(on,z)→o; else Any.
**join₃** (`or_d`/`or_c`, `c.rs:398–402`/`421–425`): (z,z)→z; (o,z)/(on,z)→o; else Any.
**join₄** (`and_or`, `c.rs:464–473`): (z,z,z)→z; (z,o,o),(z,o,on),(z,on,o),(z,on,on),(o,z,z),(on,z,z)→o; else Any.
