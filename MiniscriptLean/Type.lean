import Std.Tactic.BVDecide

/-!
# `MiniscriptLean.Type` — Bitcoin Core's Miniscript `Type` bitmask, in Lean 4

Faithful model of Bitcoin Core's `Type` class (`src/script/miniscript.h`, lines 130–191)
and `SanitizeType` (`src/script/miniscript.cpp`, lines 19–37) at commit `f86c614e`.

Design decisions:
* Core represents a `Type` as a `uint32_t` bitmask, of which 19 bits (0–18) are used.
  We use `BitVec 19` — an exact-width model — so that every algebraic fact about the
  operators is decidable via `bv_decide`.
* `a << b` in Core (**note the direction**) means "a's properties are a superset of b's";
  our `hasAll a b` matches (`miniscript.h:152–154`).
* `SanitizeType`'s `CHECK_NONFATAL` calls are runtime preconditions in C++ (they throw).
  Here `sanitize` is a total function returning `Option`: `none` iff Core would either
  produce the empty type (`num_types == 0`) or trip one of the 14 sanity relations
  (R1–R14, `notes/core-types.md` §3).
-/

namespace Miniscript

/-- Miniscript types: exactly the 19 low bits of Core's `Type::m_flags`.
Bit layout (char → bit): `B`0 `V`1 `K`2 `W`3 `z`4 `o`5 `n`6 `d`7 `u`8 `e`9
`f`10 `s`11 `m`12 `x`13 `g`14 `h`15 `i`16 `j`17 `k`18. -/
abbrev MSType := BitVec 19

namespace MSType

/-- `""_mst`: the empty type. Used by Core to mark ill-typed fragments. -/
abbrev empty : MSType := 0#19

/-- `Type::operator|` — union of properties. -/
abbrev opOr (a b : MSType) : MSType := a ||| b

/-- `Type::operator&` — intersection of properties. -/
abbrev opAnd (a b : MSType) : MSType := a &&& b

/-- `Type::operator<<` (`a << b` ⇔ a has all properties of b ⇔ a ⊇ b).
Core: `(b.m_flags & ~a.m_flags) == 0`. -/
abbrev hasAll (a b : MSType) : Bool := decide ((b &&& ~~~a) = empty)

/-- `Type::If` — `t.If(c)` is `t` when `c` holds, else the empty type. -/
abbrev cif (t : MSType) (c : Bool) : MSType := if c then t else empty

/-- Test whether bit `i` (0-based) of the mask is set. -/
abbrev getBit (t : MSType) (i : Nat) : Bool := (((t >>> i) &&& 1#19) != empty)

/-- The single-letter property masks, i.e. Core's `"B"_mst`, `"V"_mst`, …
(values match `_mst`, see `notes/core-types.md` §1.2). -/
abbrev MsB : MSType := 1#19
/-- V, bit 1 -/
abbrev MsV : MSType := 2#19
/-- K, bit 2 -/
abbrev MsK : MSType := 4#19
/-- W, bit 3 -/
abbrev MsW : MSType := 8#19
/-- z, bit 4 -/
abbrev Msz : MSType := 16#19
/-- o, bit 5 -/
abbrev Mso : MSType := 32#19
/-- n, bit 6 -/
abbrev Msn : MSType := 64#19
/-- d, bit 7 -/
abbrev Msd : MSType := 128#19
/-- u, bit 8 -/
abbrev Msu : MSType := 256#19
/-- e, bit 9 -/
abbrev Mse : MSType := 512#19
/-- f, bit 10 -/
abbrev Msf : MSType := 1024#19
/-- s, bit 11 -/
abbrev Mss : MSType := 2048#19
/-- m, bit 12 -/
abbrev Msm : MSType := 4096#19
/-- x, bit 13 -/
abbrev Msx : MSType := 8192#19
/-- g, bit 14 (relative time timelock) -/
abbrev Msg : MSType := 16384#19
/-- h, bit 15 (relative height timelock) -/
abbrev Msh : MSType := 32768#19
/-- i, bit 16 (absolute time timelock) -/
abbrev Msi : MSType := 65536#19
/-- j, bit 17 (absolute height timelock) -/
abbrev Msj : MSType := 131072#19
/-- k, bit 18 (no height/time lock mixing) -/
abbrev Msk : MSType := 262144#19

-- ---------------------------------------------------------------------------
-- Algebraic facts about the operators (bit-vector decidable arithmetic)
-- ---------------------------------------------------------------------------

theorem opOr_comm (a b : MSType) : opOr a b = opOr b a := by bv_decide
theorem opOr_assoc (a b c : MSType) : opOr (opOr a b) c = opOr a (opOr b c) := by bv_decide
theorem opAnd_comm (a b : MSType) : opAnd a b = opAnd b a := by bv_decide
theorem opAnd_assoc (a b c : MSType) : opAnd (opAnd a b) c = opAnd a (opAnd b c) := by
  bv_decide
theorem opOr_empty (a : MSType) : opOr a empty = a := by bv_decide
theorem opAnd_empty (a : MSType) : opAnd a empty = empty := by bv_decide

theorem hasAll_refl (t : MSType) : hasAll t t = true := by bv_decide

theorem hasAll_empty (t : MSType) : hasAll t empty = true := by bv_decide

theorem empty_hasAll_iff_eq_empty (q : MSType) :
    hasAll empty q = true ↔ q = empty := by bv_decide

theorem hasAll_trans {a b c : MSType}
    (h₁ : hasAll a b = true) (h₂ : hasAll b c = true) :
    hasAll a c = true := by
  bv_decide

/-- `hasAll t q` exactly when `q ∧ a = q` ("q's bits are contained in a's"). -/
theorem hasAll_iff_eq (a b : MSType) :
    hasAll a b = true ↔ b &&& a = b := by bv_decide

/-- `hasAll` distributes over `opOr` on the right:
`t << (q₁|q₂) ⟺ (t << q₁) ∧ (t << q₂)`. -/
theorem hasAll_opOr_right (t a b : MSType) : hasAll t (opOr a b) = (hasAll t a && hasAll t b) := by
  bv_decide

theorem cond_true (t : MSType) : cif t true = t := by simp [cif]
theorem cond_false (t : MSType) : cif t false = empty := by simp [cif]

-- ---------------------------------------------------------------------------
-- `SanitizeType` (miniscript.cpp lines 19–37)
-- ---------------------------------------------------------------------------

/-- Number of base-type bits (B/V/K/W) set in `t` (kept for readability). -/
def numTypes (t : MSType) : Nat :=
  (getBit t 0).toNat + (getBit t 1).toNat + (getBit t 2).toNat + (getBit t 3).toNat

/-- No base-type bit set: bit-level `num_types == 0`. -/
abbrev zeroBase (t : MSType) : Bool := !(getBit t 0 || getBit t 1 || getBit t 2 || getBit t 3)

/-- Exactly one base-type bit set: bit-level `CHECK_NONFATAL(num_types == 1)`. -/
abbrev oneBase (t : MSType) : Bool :=
  ( getBit t 0 && !getBit t 1 && !getBit t 2 && !getBit t 3) ||  -- B only
  (!getBit t 0 &&  getBit t 1 && !getBit t 2 && !getBit t 3) ||  -- V only
  (!getBit t 0 && !getBit t 1 &&  getBit t 2 && !getBit t 3) ||  -- K only
  (!getBit t 0 && !getBit t 1 && !getBit t 2 &&  getBit t 3)     -- W only

/-- The thirteen remaining sanity relations R2–R14 of `SanitizeType`
(`miniscript.cpp:20–36`), as Bool logic. -/
abbrev rulesOk (t : MSType) : Bool :=
     !(getBit t 4 && getBit t 5)    -- R2:  ¬(z ∧ o)
  && !(getBit t 6 && getBit t 4)    -- R3:  ¬(n ∧ z)
  && !(getBit t 6 && getBit t 3)    -- R4:  ¬(n ∧ W)
  && !(getBit t 1 && getBit t 7)    -- R5:  ¬(V ∧ d)
  && (!getBit t 2 || getBit t 8)    -- R6:  K → u
  && !(getBit t 1 && getBit t 8)    -- R7:  ¬(V ∧ u)
  && !(getBit t 9 && getBit t 10)   -- R8:  ¬(e ∧ f)
  && (!getBit t 9 || getBit t 7)    -- R9:  e → d
  && !(getBit t 1 && getBit t 9)    -- R10: ¬(V ∧ e)
  && !(getBit t 7 && getBit t 10)   -- R11: ¬(d ∧ f)
  && (!getBit t 1 || getBit t 10)   -- R12: V → f
  && (!getBit t 2 || getBit t 11)   -- R13: K → s
  && (!getBit t 4 || getBit t 12)   -- R14: z → m

/-- Faithful total model of `SanitizeType` (`miniscript.cpp:19–37`):
* `num_types == 0` → `none` (Core returns `""_mst`),
* `num_types == 1` plus R2–R14 → `some t`,
* anything else → `none` (Core would throw via `CHECK_NONFATAL`; our theorems
  about `computeType` show this branch is unreachable for computed types). -/
def sanitize (t : MSType) : Option MSType :=
  if zeroBase t then none
  else if oneBase t && rulesOk t then some t else none

/-- Bridge: the bit-level `zeroBase` exactly characterizes `numTypes = 0`. -/
theorem zeroBase_iff_numTypes_zero (t : MSType) : zeroBase t = true ↔ numTypes t = 0 := by
  cases h0 : getBit t 0 <;> cases h1 : getBit t 1 <;> cases h2 : getBit t 2 <;>
    cases h3 : getBit t 3 <;> simp_all [zeroBase, numTypes]

/-- `t` passes `SanitizeType` unchanged (i.e. it is a valid Miniscript type). -/
def Sanitized (t : MSType) : Prop := sanitize t = some t

/-- `sanitize` never modifies a type it accepts. -/
theorem sanitize_some_eq {t u : MSType} (h : sanitize t = some u) : u = t := by
  unfold sanitize at h
  split at h <;> simp_all

/-- Unfolded Boolean characterization of sanity, for use in bit-level
arguments. -/
theorem sanitized_iff_sanitizeOk (t : MSType) :
    Sanitized t ↔ (!zeroBase t && (oneBase t && rulesOk t)) = true := by
  show (if zeroBase t then none
        else if (oneBase t && rulesOk t) then some t else none) = some t ↔ _
  cases hz : zeroBase t
  · cases h1 : (oneBase t && rulesOk t) <;> simp
  · simp

/-- Decidability of sanity. -/
instance : Decidable (Sanitized t) := by
  unfold Sanitized; exact decidable_of_decidable_of_iff (by rfl)

/-- The 12 spec-visible letters shared with rust-miniscript's `Type`
(rust has neither `x` (bit 13) nor the timelock bits `g/h/i/j/k` (14–18)
inside `Type`; those live in rust's `ExtData`). -/
abbrev maskSpec12 : MSType := 0x1FFF#19

/-- Mask off everything outside the 12 shared letters. -/
abbrev restrict12 (t : MSType) : MSType := opAnd t maskSpec12

end MSType

end Miniscript
