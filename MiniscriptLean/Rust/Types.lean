/-!
# `MiniscriptLean.Rust.Types` — rust-miniscript's type system, transcribed
#
# Faithful Lean 4 model of rust-miniscript v13.0.0 (commit `96a1c917`):
# * `src/miniscript/types/correctness.rs` (`Base`, `Input`, `Correctness` constructors)
# * `src/miniscript/types/malleability.rs` (`Dissat`, `Malleability` constructors)
#
# as extracted in `notes/rust-types-correctness.md` / `notes/rust-types-malleability.md`.
# Typing failures are `none` (Rust `Err`); malleability *never* errors — it degrades to
# `Malleable` (rust semantics, see §2 of the malleability note).
-/

namespace Miniscript.Rust

/-- rust `Base` (declaration order B, K, V, W as in the source). -/
inductive RBase | B | K | V | W deriving Repr, DecidableEq

/-- rust `Input`: spec letters z / o / (–) / on / n. -/
inductive RInput | Zero | One | Any | OneNonZero | AnyNonZero deriving Repr, DecidableEq

/-- rust `Dissat`: None↔f, Unique↔e, Unknown↔(no letter). -/
inductive RDissat | none | unique | unknown deriving Repr, DecidableEq

/-- rust `Malleability`. -/
inductive RMall | malleable | nonMalleable (dissat : RDissat) (signed : Bool)
deriving Repr, DecidableEq

/-- rust `Correctness` (`dissat`↔d, `unit`↔u). -/
structure RCorr where
  base : RBase
  input : RInput
  dissat : Bool
  unit : Bool
deriving Repr, DecidableEq

/-- rust `Type`. -/
structure RType where
  corr : RCorr
  mall : RMall
deriving Repr, DecidableEq

--------------------------------------------------------------------------------
-- Subtyping (notes §3 of the correctness note)
--------------------------------------------------------------------------------

/-- rust `Input::is_subtype` (correctness.rs:61-72). -/
def RInput.isSubtype (a b : RInput) : Bool :=
  (a == b) || (a == .OneNonZero && b == .One) || (a == .OneNonZero && b == .AnyNonZero) || b == .Any

/-- rust `Dissat::is_subtype` (malleability.rs:43-51). -/
def RDissat.isSubtype (a b : RDissat) : Bool :=
  (a == b) || b == .unknown

/-- rust `Malleability::is_subtype` (malleability.rs:114-125): `signed ≥ signed`. -/
def RMall.isSubtype : RMall → RMall → Bool
  | _, .malleable => true
  | .malleable, .nonMalleable _ _ => false
  | .nonMalleable d s, .nonMalleable d' s' => RDissat.isSubtype d d' && (!s' || s)

/-- rust `Correctness::is_subtype` (correctness.rs:106-115). -/
def RCorr.isSubtype (a b : RCorr) : Bool :=
  (a.base == b.base) && a.input.isSubtype b.input && (!b.dissat || a.dissat) && (!b.unit || a.unit)

/-- rust `Type::is_subtype` (types/mod.rs:207-213). -/
def RType.isSubtype (a b : RType) : Bool :=
  a.corr.isSubtype b.corr && a.mall.isSubtype b.mall

theorem RInput.isSubtype_refl (x : RInput) : RInput.isSubtype x x = true := by
  unfold RInput.isSubtype; simp

theorem RInput.isSubtype_trans {a b c : RInput}
    (h₁ : RInput.isSubtype a b = true) (h₂ : RInput.isSubtype b c = true) :
    RInput.isSubtype a c = true := by
  cases a <;> cases b <;> cases c <;> simp_all [RInput.isSubtype]

theorem RDissat.isSubtype_refl (x : RDissat) : RDissat.isSubtype x x = true := by
  unfold RDissat.isSubtype; simp

theorem RDissat.isSubtype_trans {a b c : RDissat}
    (h₁ : RDissat.isSubtype a b = true) (h₂ : RDissat.isSubtype b c = true) :
    RDissat.isSubtype a c = true := by
  cases a <;> cases b <;> cases c <;> simp_all [RDissat.isSubtype]

private theorem bool_ge_trans {x y z : Bool} (h₁ : (!y || x) = true) (h₂ : (!z || y) = true) :
    (!z || x) = true := by
  cases x <;> cases y <;> cases z <;> simp_all

/-- Implication-as-disjunction transitivity: `(x=false ∨ y=true) → (y=false ∨ z=true)`
gives `(x=false ∨ z=true)`. Used to chain the Bool-coded `≥` constraints. -/
theorem bool_impl_trans {x y z : Bool} (h₁ : x = false ∨ y = true) (h₂ : y = false ∨ z = true) :
    x = false ∨ z = true := by
  cases x <;> cases y <;> cases z <;> simp_all

theorem RMall.isSubtype_refl (x : RMall) : RMall.isSubtype x x = true := by
  cases x <;> simp [RMall.isSubtype, RDissat.isSubtype_refl]

theorem RMall.isSubtype_trans {a b c : RMall}
    (h₁ : RMall.isSubtype a b = true) (h₂ : RMall.isSubtype b c = true) :
    RMall.isSubtype a c = true := by
  match a, b, c with
  | _, _, .malleable => rfl
  | .malleable, .nonMalleable _ _, _ => simp_all [RMall.isSubtype]
  | .nonMalleable _ _, .malleable, .nonMalleable _ _ => simp_all [RMall.isSubtype]
  | .nonMalleable da sa, .nonMalleable db sb, .nonMalleable dc sc =>
    simp only [RMall.isSubtype, Bool.and_eq_true] at h₁ h₂ ⊢
    exact ⟨RDissat.isSubtype_trans h₁.1 h₂.1, bool_ge_trans h₁.2 h₂.2⟩

theorem RCorr.isSubtype_refl (x : RCorr) : RCorr.isSubtype x x = true := by
  unfold RCorr.isSubtype; simp [RInput.isSubtype_refl]

theorem RCorr.isSubtype_trans {a b c : RCorr}
    (h₁ : RCorr.isSubtype a b = true) (h₂ : RCorr.isSubtype b c = true) :
    RCorr.isSubtype a c = true := by
  obtain ⟨ab, ai, ad, au⟩ := a
  obtain ⟨bb, bi, bd, bu⟩ := b
  obtain ⟨cb, ci, cd, cu⟩ := c
  simp only [RCorr.isSubtype, Bool.and_eq_true, Bool.or_eq_true, Bool.not_eq_true',
    beq_iff_eq] at h₁ h₂ ⊢
  obtain ⟨⟨⟨hab, hai⟩, had⟩, hau⟩ := h₁
  obtain ⟨⟨⟨hbc, hbi⟩, hcd⟩, hcu⟩ := h₂
  exact ⟨⟨⟨hab.trans hbc, RInput.isSubtype_trans hai hbi⟩, bool_impl_trans hcd had⟩,
    bool_impl_trans hcu hau⟩

theorem RType.isSubtype_refl (x : RType) : RType.isSubtype x x = true := by
  unfold RType.isSubtype; simp [RCorr.isSubtype_refl, RMall.isSubtype_refl]

theorem RType.isSubtype_trans {a b c : RType}
    (h₁ : RType.isSubtype a b = true) (h₂ : RType.isSubtype b c = true) :
    RType.isSubtype a c = true := by
  obtain ⟨ac, am⟩ := a
  obtain ⟨bc, bm⟩ := b
  obtain ⟨cc, cm⟩ := c
  simp only [RType.isSubtype, Bool.and_eq_true] at h₁ h₂ ⊢
  exact ⟨RCorr.isSubtype_trans h₁.1 h₂.1, RMall.isSubtype_trans h₁.2 h₂.2⟩

--------------------------------------------------------------------------------
-- Correctness leaf constants (notes §2.1)
--------------------------------------------------------------------------------

def corrTrue   : RCorr := ⟨.B, .Zero, false, true⟩
def corrFalse  : RCorr := ⟨.B, .Zero, true, true⟩
def corrPkK    : RCorr := ⟨.K, .OneNonZero, true, true⟩
def corrPkH    : RCorr := ⟨.K, .AnyNonZero, true, true⟩
def corrMulti  : RCorr := ⟨.B, .AnyNonZero, true, true⟩
def corrMultiA : RCorr := ⟨.B, .Any, true, true⟩
def corrTime   : RCorr := ⟨.B, .Zero, false, false⟩
def corrHash   : RCorr := ⟨.B, .OneNonZero, true, true⟩

--------------------------------------------------------------------------------
-- Unary wrappers (notes §2.2)
--------------------------------------------------------------------------------

def castAlt (c : RCorr) : Option RCorr :=
  match c.base with
  | .B => some { base := .W, input := .Any, dissat := c.dissat, unit := c.unit }
  | _ => none

def castSwap (c : RCorr) : Option RCorr :=
  match c.base with
  | .B =>
    match c.input with
    | .One | .OneNonZero => some { base := .W, input := .Any, dissat := c.dissat, unit := c.unit }
    | _ => none
  | _ => none

def castCheck (c : RCorr) : Option RCorr :=
  match c.base with
  | .K => some { base := .B, input := c.input, dissat := c.dissat, unit := true }
  | _ => none

/-- d: — NOTE: rust sets `unit := false` unconditionally, whereas the spec/Core grant
`u` in Tapscript only. This is divergence **D1** (rust under-approximates), recorded
formally in `MiniscriptLean.Crosswalk`. -/
def castDupIf (c : RCorr) : Option RCorr :=
  match c.base with
  | .V =>
    match c.input with
    | .Zero => some { base := .B, input := .OneNonZero, dissat := true, unit := false }
    | _ => none
  | _ => none

def castVerify (c : RCorr) : Option RCorr :=
  match c.base with
  | .B => some { base := .V, input := c.input, dissat := false, unit := false }
  | _ => none

def castNonZero (c : RCorr) : Option RCorr :=
  match c.input with
  | .OneNonZero | .AnyNonZero =>
    match c.base with
    | .B => some { base := .B, input := c.input, dissat := true, unit := c.unit }
    | _ => none
  | _ => none

def castZeroNotEqual (c : RCorr) : Option RCorr :=
  match c.base with
  | .B => some { base := .B, input := c.input, dissat := c.dissat, unit := true }
  | _ => none

/-- `t:` sugar constructor (= `and_v(c,1)`); used by the policy compiler. -/
def castTrue (c : RCorr) : Option RCorr :=
  match c.base with
  | .V => some { base := .B, input := c.input, dissat := false, unit := true }
  | _ => none

/-- `l:` / `u:` sugar constructor (correctness.rs:293-309). -/
def castOrIFalse (c : RCorr) : Option RCorr :=
  match c.base with
  | .B =>
    some { base := .B,
           input := match c.input with | .Zero => .One | _ => .Any,
           dissat := true,
           unit := c.unit }
  | _ => none

--------------------------------------------------------------------------------
-- Input join tables (notes §2.4: join₁–join₄)
--------------------------------------------------------------------------------

/-- Sequential-input join shared by `and_v` and `and_b`. -/
def andInputJoin : RInput → RInput → RInput
  | .Zero, .Zero => .Zero
  | .Zero, .One | .One, .Zero => .One
  | .Zero, .OneNonZero | .OneNonZero, .Zero => .OneNonZero
  | .OneNonZero, _ | .AnyNonZero, _ | .Zero, .AnyNonZero => .AnyNonZero
  | _, _ => .Any

/-- `or_b` input join. -/
def orBInputJoin : RInput → RInput → RInput
  | .Zero, .Zero => .Zero
  | .Zero, .One | .One, .Zero | .Zero, .OneNonZero | .OneNonZero, .Zero => .One
  | _, _ => .Any

/-- `or_d`/`or_c` input join. -/
def orDInputJoin : RInput → RInput → RInput
  | .Zero, .Zero => .Zero
  | .One, .Zero | .OneNonZero, .Zero => .One
  | _, _ => .Any

/-- `or_i` input join. -/
def orIInputJoin : RInput → RInput → RInput
  | .Zero, .Zero => .One
  | _, _ => .Any

/-- `andor` input join. -/
def andOrInputJoin : RInput → RInput → RInput → RInput
  | .Zero, .Zero, .Zero => .Zero
  | .Zero, .One, .One | .Zero, .One, .OneNonZero | .Zero, .OneNonZero, .One
  | .Zero, .OneNonZero, .OneNonZero | .One, .Zero, .Zero | .OneNonZero, .Zero, .Zero => .One
  | _, _, _ => .Any

--------------------------------------------------------------------------------
-- Combinators (notes §2.4)
--------------------------------------------------------------------------------

def andV (l r : RCorr) : Option RCorr :=
  match l.base, r.base with
  | .V, .B | .V, .K | .V, .V =>
    some { base := r.base, input := andInputJoin l.input r.input, dissat := false, unit := r.unit }
  | _, _ => none

def andB (l r : RCorr) : Option RCorr :=
  match l.base, r.base with
  | .B, .W =>
    some { base := .B, input := andInputJoin l.input r.input,
           dissat := l.dissat && r.dissat, unit := true }
  | _, _ => none

def orB (l r : RCorr) : Option RCorr :=
  if !l.dissat then none
  else if !r.dissat then none
  else match l.base, r.base with
  | .B, .W => some { base := .B, input := orBInputJoin l.input r.input, dissat := true, unit := true }
  | _, _ => none

def orD (l r : RCorr) : Option RCorr :=
  if !l.dissat then none
  else if !l.unit then none
  else match l.base, r.base with
  | .B, .B => some { base := .B, input := orDInputJoin l.input r.input, dissat := r.dissat, unit := r.unit }
  | _, _ => none

def orC (l r : RCorr) : Option RCorr :=
  if !l.dissat then none
  else if !l.unit then none
  else match l.base, r.base with
  | .B, .V => some { base := .V, input := orDInputJoin l.input r.input, dissat := false, unit := false }
  | _, _ => none

def orI (l r : RCorr) : Option RCorr :=
  match l.base, r.base with
  | .B, .B | .V, .V | .K, .K =>
    some { base := l.base, input := orIInputJoin l.input r.input,
           dissat := l.dissat || r.dissat, unit := l.unit && r.unit }
  | _, _ => none

def andOr (a b c : RCorr) : Option RCorr :=
  if !a.dissat then none
  else if !a.unit then none
  else match a.base, b.base, c.base with
  | .B, .B, .B => some { base := .B, input := andOrInputJoin a.input b.input c.input,
                         dissat := c.dissat, unit := b.unit && c.unit }
  | .B, .K, .K => some { base := .K, input := andOrInputJoin a.input b.input c.input,
                         dissat := c.dissat, unit := b.unit && c.unit }
  | .B, .V, .V => some { base := .V, input := andOrInputJoin a.input b.input c.input,
                         dissat := c.dissat, unit := b.unit && c.unit }
  | _, _, _ => none

/-- `Correctness::threshold` (correctness.rs:479-516). Index-carrying fold. -/
def thresholdCorr (subs : List RCorr) : Option RCorr :=
  match thresholdCorr.go 0 0 subs with
  | none => none
  | some args =>
    some { base := .B,
           input := match args with | 0 => .Zero | 1 => .One | _ => .Any,
           dissat := true, unit := true }
where
  go (idx acc : Nat) : List RCorr → Option Nat
    | [] => some acc
    | c :: rest =>
      if idx == 0 && c.base != .B then none
      else if idx != 0 && c.base != .W then none
      else if !c.unit then none
      else if !c.dissat then none
      else
        let w := match c.input with
          | .Zero => 0 | .One | .OneNonZero => 1 | .Any | .AnyNonZero => 2
        go (idx + 1) (acc + w) rest

--------------------------------------------------------------------------------
-- Malleability leaf constants (cross-checked against Core's constant masks in
-- notes/core-types.md §2.1 / notes/rust-types-malleability.md §2)
--------------------------------------------------------------------------------

def mallTrue   : RMall := .nonMalleable .none    false  -- f          (Core "Bzufmxk")
def mallFalse  : RMall := .nonMalleable .unique  true   -- s e        (Core "Bzudemsxk")
def mallPkK    : RMall := .nonMalleable .unique  true   -- s e        (Core "Konudemsxk")
def mallPkH    : RMall := .nonMalleable .unique  true   -- s e        (Core "Knudemsxk")
def mallTime   : RMall := .nonMalleable .none    false  -- f          (Core "Bzfmxk")
def mallHash   : RMall := .nonMalleable .unknown false  -- (m only)   (Core "Bonudmk")
def mallMulti  : RMall := .nonMalleable .unique  true   -- s e        (Core "Bnudemsk")
def mallMultiA : RMall := .nonMalleable .unique  true   -- s e        (Core "Budemsk")

--------------------------------------------------------------------------------
-- Malleability wrapper casts
--------------------------------------------------------------------------------

/-- a:, s:, n: pass malleability through unchanged. -/
def mallPass (m : RMall) : RMall := m

/-- c: (`Check`): rust's `cast_check` is the *identity* cast
(`malleability.rs:163-164`). The spec's unconditional `s` on `c:`-outputs is
still recovered extensionally: every constructible K-fragment has `signed = true`
(correctness lemma `RType.K_is_signed`-equivalents live elsewhere). We transcribe
the code, not the cross-layer invariant. -/
def mallCheck : RMall → RMall := id

/-- d: (`DupIf`): `e` unconditionally, `s=sX`; never `f`. -/
def mallDupIf : RMall → RMall
  | .nonMalleable _ s => .nonMalleable .unique s
  | .malleable => .malleable

/-- v: (`Verify`): `f` unconditionally, `s=sX`. -/
def mallVerify : RMall → RMall
  | .nonMalleable _ s => .nonMalleable .none s
  | .malleable => .malleable

/-- j: (`NonZero`): `e=fX`, `s=sX` (`cast_dissat_if_forced`). -/
def mallNonZero : RMall → RMall
  | .nonMalleable d s => .nonMalleable (if d == .none then RDissat.unique else RDissat.unknown) s
  | .malleable => .malleable

--------------------------------------------------------------------------------
-- Malleability combinators. Any failed spec "Requires" degrades to `.malleable`
-- (rust never errors on malleability; notes/rust-types-malleability.md §2).
--------------------------------------------------------------------------------

/-- and_v: `f=fY∨sX`, `s=sX∨sY`; never `e`. -/
def mallAndV : RMall → RMall → RMall
  | .nonMalleable dx sx, .nonMalleable dy sy =>
    .nonMalleable (if dy == .none || sx then RDissat.none else RDissat.unknown) (sx || sy)
  | _, _ => .malleable

/-- and_b: `f=fXfY∨sXfX∨sYfY`, `e=eXeYsXsY`, `s=sX∨sY`. -/
def mallAndB : RMall → RMall → RMall
  | .nonMalleable dx sx, .nonMalleable dy sy =>
    let dissat :=
      if dx == .unique && dy == .unique && sx && sy then RDissat.unique
      else if (dx == .none && dy == .none) || (sx && dx == .none) || (sy && dy == .none)
      then RDissat.none
      else RDissat.unknown
    .nonMalleable dissat (sx || sy)
  | _, _ => .malleable

/-- or_b: requires eX eZ ∧ (sX∨sZ), else malleable; `s=sXsZ`, `e`. -/
def mallOrB : RMall → RMall → RMall
  | .nonMalleable .unique sx, .nonMalleable .unique sy =>
    if sx || sy then .nonMalleable .unique (sx && sy) else .malleable
  | _, _ => .malleable

/-- or_d: requires eX ∧ (sX∨sZ), else malleable; `s=sXsZ`, `f=fZ`, `e=eZ`. -/
def mallOrD : RMall → RMall → RMall
  | .nonMalleable dx sx, .nonMalleable dy sy =>
    if dx == .unique && (sx || sy) then .nonMalleable dy (sx && sy) else .malleable
  | _, _ => .malleable

/-- or_c: requires eX ∧ (sX∨sZ), else malleable; `s=sXsZ`, `f`. -/
def mallOrC : RMall → RMall → RMall
  | .nonMalleable dx sx, .nonMalleable _ sy =>
    if dx == .unique && (sx || sy) then .nonMalleable .none (sx && sy) else .malleable
  | _, _ => .malleable

/-- or_i: requires sX∨sZ, else malleable; `s=sXsZ`, `f=fXfZ`, `e=eXfZ∨eZfX`. -/
def mallOrI : RMall → RMall → RMall
  | .nonMalleable dx sx, .nonMalleable dy sy =>
    if sx || sy then
      let dissat :=
        if (dx == .unique && dy == .none) || (dy == .unique && dx == .none) then RDissat.unique
        else if dx == .none && dy == .none then RDissat.none
        else RDissat.unknown
      .nonMalleable dissat (sx && sy)
    else .malleable
  | _, _ => .malleable

/-- andor: requires eX ∧ (sX∨sY∨sZ), else malleable;
`s=sZ(sX∨sY)`, `f=fZ(sX∨fY)`, `e=eZ(sX∨fY)`. -/
def mallAndOr : RMall → RMall → RMall → RMall
  | .nonMalleable dx sx, .nonMalleable dy sy, .nonMalleable dz sz =>
    if dx == .unique && (sx || sy || sz) then
      let dissat :=
        if dz == .unique && (sx || dy == .none) then RDissat.unique
        else if dz == .none && (sx || dy == .none) then RDissat.none
        else RDissat.unknown
      .nonMalleable dissat (sz && (sx || sy))
    else .malleable
  | _, _, _ => .malleable

/-- thresh: requires all children `e`, else malleable; requires `n − #s ≤ k`
i.e. `#s ≥ n − k` (at most k non-signed), else malleable; `s ⟺ #s ≥ n−k+1`,
`e ⟺ #s = n`. The required side condition `1 ≤ k ≤ n` is furnished by
`Threshold::validate_k_n` upstream of the type layer. -/
def mallThresh (k : Nat) (cs : List RMall) : RMall :=
  if cs.all fun | .nonMalleable .unique _ => true | _ => false then
    let ns := cs.countP fun | .nonMalleable _ true => true | _ => false
    let n := cs.length
    if n - ns ≤ k then
      .nonMalleable (if ns == n then RDissat.unique else RDissat.unknown) ((n - ns) + 1 ≤ k)
    else .malleable
  else .malleable

--------------------------------------------------------------------------------
-- Sanity invariants (notes §1.4): `K ⇒ u`; `V ⇒ ¬u ∧ ¬d`; `W ⇒ input ∉ {on, n}`.
--------------------------------------------------------------------------------

/-- `Correctness::sanity_checks` as a predicate (debug_asserts in Rust). -/
def saneCorr (c : RCorr) : Prop :=
  (c.base = .K → c.unit = true) ∧
  (c.base = .V → c.unit = false ∧ c.dissat = false) ∧
  (c.base = .W → c.input ≠ .OneNonZero ∧ c.input ≠ .AnyNonZero)

theorem saneCorr_true   : saneCorr corrTrue   := by simp [saneCorr, corrTrue]
theorem saneCorr_false  : saneCorr corrFalse  := by simp [saneCorr, corrFalse]
theorem saneCorr_pkK    : saneCorr corrPkK    := by simp [saneCorr, corrPkK]
theorem saneCorr_pkH    : saneCorr corrPkH    := by simp [saneCorr, corrPkH]
theorem saneCorr_multi  : saneCorr corrMulti  := by simp [saneCorr, corrMulti]
theorem saneCorr_multiA : saneCorr corrMultiA := by simp [saneCorr, corrMultiA]
theorem saneCorr_time   : saneCorr corrTime   := by simp [saneCorr, corrTime]
theorem saneCorr_hash   : saneCorr corrHash   := by simp [saneCorr, corrHash]

/-! Wrapper/combinator preservation of `saneCorr`. Uniform proof pattern:
`cases h : c.field` pins the matched fields; `simp [fn, h, …] at e` iota-reduces the
constructor's matches (impossible branches die by `none ≠ some`); `subst e`
substitutes the output record; `simp_all [saneCorr]` closes the residual sanity goal,
instantiating the children's conditional sanity facts as needed. -/

theorem castAlt_sane {c c' : RCorr} (_h : saneCorr c) (e : castAlt c = some c') :
    saneCorr c' := by
  cases hb : c.base <;> simp [castAlt, hb] at e <;> subst e <;> simp_all [saneCorr]

theorem castSwap_sane {c c' : RCorr} (_h : saneCorr c) (e : castSwap c = some c') :
    saneCorr c' := by
  cases hb : c.base <;> cases hi : c.input <;> simp [castSwap, hb, hi] at e <;> subst e <;>
    simp_all [saneCorr]

theorem castCheck_sane {c c' : RCorr} (_h : saneCorr c) (e : castCheck c = some c') :
    saneCorr c' := by
  cases hb : c.base <;> simp [castCheck, hb] at e <;> subst e <;> simp_all [saneCorr]

theorem castDupIf_sane {c c' : RCorr} (_h : saneCorr c) (e : castDupIf c = some c') :
    saneCorr c' := by
  cases hb : c.base <;> cases hi : c.input <;> simp [castDupIf, hb, hi] at e <;> subst e <;>
    simp_all [saneCorr]

theorem castVerify_sane {c c' : RCorr} (_h : saneCorr c) (e : castVerify c = some c') :
    saneCorr c' := by
  cases hb : c.base <;> simp [castVerify, hb] at e <;> subst e <;> simp_all [saneCorr]

theorem castNonZero_sane {c c' : RCorr} (_h : saneCorr c) (e : castNonZero c = some c') :
    saneCorr c' := by
  cases hi : c.input <;> cases hb : c.base <;> simp [castNonZero, hi, hb] at e <;> subst e <;>
    simp_all [saneCorr]

theorem castZeroNotEqual_sane {c c' : RCorr} (_h : saneCorr c)
    (e : castZeroNotEqual c = some c') : saneCorr c' := by
  cases hb : c.base <;> simp [castZeroNotEqual, hb] at e <;> subst e <;> simp_all [saneCorr]

theorem castTrue_sane {c c' : RCorr} (_h : saneCorr c) (e : castTrue c = some c') :
    saneCorr c' := by
  cases hb : c.base <;> simp [castTrue, hb] at e <;> subst e <;> simp_all [saneCorr]

theorem castOrIFalse_sane {c c' : RCorr} (_h : saneCorr c) (e : castOrIFalse c = some c') :
    saneCorr c' := by
  cases hb : c.base <;> cases hi : c.input <;> simp [castOrIFalse, hb, hi] at e <;> subst e <;>
    simp_all [saneCorr]

theorem andV_sane {l r c : RCorr} (hl : saneCorr l) (hr : saneCorr r)
    (e : andV l r = some c) : saneCorr c := by
  cases hl' : l.base <;> cases hr' : r.base <;> simp [andV, hl', hr'] at e <;> subst e <;>
    simp_all [saneCorr]

theorem andB_sane {l r c : RCorr} (_hl : saneCorr l) (_hr : saneCorr r)
    (e : andB l r = some c) : saneCorr c := by
  cases hl' : l.base <;> cases hr' : r.base <;> simp [andB, hl', hr'] at e <;> subst e <;>
    simp_all [saneCorr]

theorem orB_sane {l r c : RCorr} (_hl : saneCorr l) (_hr : saneCorr r)
    (e : orB l r = some c) : saneCorr c := by
  cases hd : l.dissat <;> cases hd' : r.dissat <;> cases hl' : l.base <;> cases hr' : r.base <;>
    simp [orB, hd, hd', hl', hr'] at e <;> subst e <;> simp_all [saneCorr]

theorem orD_sane {l r c : RCorr} (_hl : saneCorr l) (_hr : saneCorr r)
    (e : orD l r = some c) : saneCorr c := by
  cases hd : l.dissat <;> cases hu : l.unit <;> cases hl' : l.base <;> cases hr' : r.base <;>
    simp [orD, hd, hu, hl', hr'] at e <;> subst e <;> simp_all [saneCorr]

theorem orC_sane {l r c : RCorr} (_hl : saneCorr l) (_hr : saneCorr r)
    (e : orC l r = some c) : saneCorr c := by
  cases hd : l.dissat <;> cases hu : l.unit <;> cases hl' : l.base <;> cases hr' : r.base <;>
    simp [orC, hd, hu, hl', hr'] at e <;> subst e <;> simp_all [saneCorr]

theorem orI_sane {l r c : RCorr} (_hl : saneCorr l) (_hr : saneCorr r)
    (e : orI l r = some c) : saneCorr c := by
  cases hl' : l.base <;> cases hr' : r.base <;> simp [orI, hl', hr'] at e <;> subst e <;>
    simp_all [saneCorr]

theorem andOr_sane {a b c out : RCorr} (_ha : saneCorr a) (hb : saneCorr b) (hc : saneCorr c)
    (e : andOr a b c = some out) : saneCorr out := by
  cases hd : a.dissat <;> cases hu : a.unit <;> cases hab : a.base <;> cases hbb : b.base <;>
    cases hcb : c.base <;> simp [andOr, hd, hu, hab, hbb, hcb] at e <;> subst e <;>
    simp_all [saneCorr]

theorem thresholdCorr_sane {subs : List RCorr} {c : RCorr}
    (e : thresholdCorr subs = some c) : saneCorr c := by
  unfold thresholdCorr at e
  split at e
  · contradiction
  · cases (Option.some.inj e); simp [saneCorr]

end Miniscript.Rust
