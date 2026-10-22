import MiniscriptLean.Fragment
import MiniscriptLean.Rust.Types
import Std.Tactic.BVDecide

/-!
# `MiniscriptLean.Crosswalk` — Core ⇄ rust-miniscript typing agreement

The bridge module of the project. It maps rust-miniscript's structured types
(`RCorr`, `RMall` — see `MiniscriptLean/Rust/Types.lean`) into Bitcoin Core's
19-bit mask space (`MiniscriptLean/Type.lean`) and states the agreement of the
two implementations' type systems on the 12 spec-visible letters
(`B V K W z o n d u e f s m`), ignoring:
  * `x` ("expensive verify") — Core-only implementation detail;
  * `g h i j k` (timelock bits) — Core tracks these in `Type`; rust tracks the
    same information in `ExtData.timelock_info` (compared verbally in
    `notes/divergences-timelocks.md`), outside the `Type` layer.

Ground truth (per project decision): **Core's `ComputeType`** is normative.

Contents:
1. `RCorr.toBits`, `RMall.toBits` — the translation.
2. `agreed` — the per-node relation between a Core mask and a rust typing.
3. Divergence **D1** (rust's `d:` never grants `u`, even under Tapscript):
   the local fact and concrete witnesses, incl. the exact point where the two
   implementations' acceptance diverges (`andor(dv:older(1),pk,pk)`).
4. rust-side recursive typers `rustCorrOf` / `rustMallOf` / `rustTypeOf`
   (context-free, exactly as rust's `types/` layer is).
-/


namespace Miniscript

open MSType Rust

-- ---------------------------------------------------------------------------
-- 1. The translation
-- ---------------------------------------------------------------------------

/-- rust `Base` → Core base letter. -/
abbrev RBase.toBits : RBase → MSType
  | .B => MsB | .V => MsV | .K => MsK | .W => MsW

/-- rust `Input` → Core z/o/n letters: `Zero`↔z, `One`↔o, `Any`↔∅,
`OneNonZero`↔on, `AnyNonZero`↔n. -/
abbrev RInput.toBits : RInput → MSType
  | .Zero => Msz
  | .One => Mso
  | .Any => MSType.empty
  | .OneNonZero => opOr Mso Msn
  | .AnyNonZero => Msn

/-- rust `Correctness` → Core type bits (`B/V/K/W` + `z/o/n` + `d` + `u`).
This is precisely the letter rendering of `Display for Type` in rust's
`types/mod.rs`. -/
abbrev RCorr.toBits (c : RCorr) : MSType :=
  opOr (RBase.toBits c.base)
    (opOr (RInput.toBits c.input)
      (opOr (cif Msd c.dissat) (cif Msu c.unit)))

/-- rust `Malleability` → Core m/f/e/s letters. `Malleable` grants NO letters
(rust loses which of s/f/e held — Core's mask may retain them individually;
the crosswalk relation accounts for this asymmetry). -/
abbrev RMall.toBits : RMall → MSType
  | .malleable => MSType.empty
  | .nonMalleable d s =>
    opOr Msm (opOr (match d with | .none => Msf | .unique => Mse | .unknown => MSType.empty)
                   (cif Mss s))

/-- Full rust `Type` → Core mask. -/
abbrev RType.toBits (t : RType) : MSType := opOr (RCorr.toBits t.corr) (RMall.toBits t.mall)

/-- The 9 correctness letters (`B V K W z o n d u`): bits 0–8. -/
abbrev maskCorr9 : MSType := 0x1FF#19

/-- Mask of the 12 shared letters minus `u` (bit 8) — the residue class on which
rust and Core agree even under Tapscript (divergence D1 concerns only `u`). -/
abbrev maskNoU : MSType := 0x1EFF#19

/-- The per-node agreement between a (sanitized) Core mask `ty`, a rust
correctness component `rc` and rust malleability `rm`:
* always: equality on the 9 correctness letters;
* if `rm` is `nonMalleable`: full equality on the remaining shared letters
  (`m`, and `e`/`f`/`s` matching `dissat`/`signed` exactly);
* if `rm` is `malleable`: only that Core's `m` bit is unset (rust discards
  information Core keeps, e.g. `or_b`'s unconditional `s`/`e` propagation). -/
def agreed (ty : MSType) (rc : RCorr) (rm : RMall) : Prop :=
  opAnd ty maskCorr9 = RCorr.toBits rc ∧
  match rm with
  | .malleable => hasAll ty Msm = false
  | .nonMalleable d s =>
      hasAll ty Msm = true ∧ hasAll ty Mss = s ∧
      hasAll ty Mse = (d == .unique) ∧ hasAll ty Msf = (d == .none)

-- ---------------------------------------------------------------------------
-- 2. rust-side recursive typers (context-free — rust's type layer knows no
--    context; `context.rs` gates fragments separately)
-- ---------------------------------------------------------------------------

mutual

/-- rust's bottom-up `Type::type_check` over the node tree, correctness layer
(`types/mod.rs:459–538` + `correctness.rs` constructors). `none` = Rust `Err`.  -/
def rustCorrOf : MsNode → Option RCorr
  | .just0 => some corrFalse
  | .just1 => some corrTrue
  | .pkK => some corrPkK
  | .pkH => some corrPkH
  | .older _ | .after _ => some corrTime
  | .sha256 | .hash256 | .ripemd160 | .hash160 => some corrHash
  | .wrapA x => rustCorrOf x >>= castAlt
  | .wrapS x => rustCorrOf x >>= castSwap
  | .wrapC x => rustCorrOf x >>= castCheck
  | .wrapD x => rustCorrOf x >>= castDupIf
  | .wrapV x => rustCorrOf x >>= castVerify
  | .wrapJ x => rustCorrOf x >>= castNonZero
  | .wrapN x => rustCorrOf x >>= castZeroNotEqual
  | .andV x y => do let l ← rustCorrOf x; let r ← rustCorrOf y; andV l r
  | .andB x y => do let l ← rustCorrOf x; let r ← rustCorrOf y; andB l r
  | .orB x y => do let l ← rustCorrOf x; let r ← rustCorrOf y; orB l r
  | .orC x y => do let l ← rustCorrOf x; let r ← rustCorrOf y; orC l r
  | .orD x y => do let l ← rustCorrOf x; let r ← rustCorrOf y; orD l r
  | .orI x y => do let l ← rustCorrOf x; let r ← rustCorrOf y; orI l r
  | .andor x y z => do let l ← rustCorrOf x; let r ← rustCorrOf y; let c ← rustCorrOf z
                       andOr l r c
  | .thresh _ cs => do let ls ← rustCorrList cs; thresholdCorr ls
  | .multi _ _ => some corrMulti
  | .multiA _ _ => some corrMultiA

/-- rust's malleability layer (`malleability.rs` constructors), total:
typing failures cannot occur here (they degrade to `Malleable`). -/
def rustMallOf : MsNode → RMall
  | .just0 => mallFalse
  | .just1 => mallTrue
  | .pkK => mallPkK
  | .pkH => mallPkH
  | .older _ | .after _ => mallTime
  | .sha256 | .hash256 | .ripemd160 | .hash160 => mallHash
  | .wrapA x => rustMallOf x
  | .wrapS x => rustMallOf x
  | .wrapC x => mallCheck (rustMallOf x)
  | .wrapD x => mallDupIf (rustMallOf x)
  | .wrapV x => mallVerify (rustMallOf x)
  | .wrapJ x => mallNonZero (rustMallOf x)
  | .wrapN x => rustMallOf x
  | .andV x y => mallAndV (rustMallOf x) (rustMallOf y)
  | .andB x y => mallAndB (rustMallOf x) (rustMallOf y)
  | .orB x y => mallOrB (rustMallOf x) (rustMallOf y)
  | .orC x y => mallOrC (rustMallOf x) (rustMallOf y)
  | .orD x y => mallOrD (rustMallOf x) (rustMallOf y)
  | .orI x y => mallOrI (rustMallOf x) (rustMallOf y)
  | .andor x y z => mallAndOr (rustMallOf x) (rustMallOf y) (rustMallOf z)
  | .thresh k cs => mallThresh k (rustMallList cs)
  | .multi _ _ => mallMulti
  | .multiA _ _ => mallMultiA

def rustCorrList : List MsNode → Option (List RCorr)
  | [] => some []
  | x :: xs => do let c ← rustCorrOf x; let cs ← rustCorrList xs; some (c :: cs)

def rustMallList : List MsNode → List RMall
  | [] => []
  | x :: xs => rustMallOf x :: rustMallList xs

end

/-- rust's full type: corr + mall. -/
def rustTypeOf (n : MsNode) : Option RType :=
  (rustCorrOf n).map fun c => ⟨c, rustMallOf n⟩

-- ---------------------------------------------------------------------------
-- bit-level helper lemmas for the crosswalk
-- ---------------------------------------------------------------------------

/-- `hasAll (t & maskCorr9) q = hasAll t q` whenever q's letters live in the 9
correctness bits. -/
theorem hasAll_of_corr9 {q : MSType} (hq : opAnd q maskCorr9 = q) (t : MSType) :
    hasAll (opAnd t maskCorr9) q = hasAll t q := by
  unfold hasAll opAnd at *; bv_decide

/-- `hasAll` of the `d`-letter mask iff bit 7 (`d`) is set. Convenience form. -/
theorem hasAll_d_eq (t : MSType) : hasAll t Msd = getBit t 7 := by unfold hasAll getBit; bv_decide
/-- Same for the other single-letter facts used repeatedly. -/
theorem hasAll_u_eq (t : MSType) : hasAll t Msu = getBit t 8 := by unfold hasAll getBit; bv_decide
theorem hasAll_e_eq (t : MSType) : hasAll t Mse = getBit t 9 := by unfold hasAll getBit; bv_decide
theorem hasAll_f_eq (t : MSType) : hasAll t Msf = getBit t 10 := by unfold hasAll getBit; bv_decide
theorem hasAll_s_eq (t : MSType) : hasAll t Mss = getBit t 11 := by unfold hasAll getBit; bv_decide
theorem hasAll_m_eq (t : MSType) : hasAll t Msm = getBit t 12 := by unfold hasAll getBit; bv_decide
theorem hasAll_B_eq (t : MSType) : hasAll t MsB = getBit t 0 := by unfold hasAll getBit; bv_decide
theorem hasAll_V_eq (t : MSType) : hasAll t MsV = getBit t 1 := by unfold hasAll getBit; bv_decide
theorem hasAll_K_eq (t : MSType) : hasAll t MsK = getBit t 2 := by unfold hasAll getBit; bv_decide
theorem hasAll_W_eq (t : MSType) : hasAll t MsW = getBit t 3 := by unfold hasAll getBit; bv_decide
theorem hasAll_z_eq (t : MSType) : hasAll t Msz = getBit t 4 := by unfold hasAll getBit; bv_decide
theorem hasAll_o_eq (t : MSType) : hasAll t Mso = getBit t 5 := by unfold hasAll getBit; bv_decide
theorem hasAll_n_eq (t : MSType) : hasAll t Msn = getBit t 6 := by unfold hasAll getBit; bv_decide

/-- A sanitized type has exactly one base letter — bit-level form, useful to
`bv_decide` with sanitized hypotheses unfolded through `sanitized_iff_sanitizeOk`. -/
theorem Sanitized.oneBase_of {t : MSType} (h : Sanitized t) :
    (oneBase t && rulesOk t && !zeroBase t) = true := by
  rw [sanitized_iff_sanitizeOk] at h
  cases h0 : zeroBase t <;> simp_all

/-- Anything that passes `sanitize` is sanitized (trivially — `sanitize` is the
identity on what it accepts). -/
theorem sanitize_mem_sanitized {x ty : MSType} (h : MSType.sanitize x = some ty) :
    Sanitized ty := by
  have hxy : ty = x := MSType.sanitize_some_eq h
  subst hxy
  exact h

/-- `coreType` only produces sanitized masks. -/
theorem coreType_sanitized {ctx : MsContext} {n : MsNode} {ty : MSType}
    (h : coreType ctx n = some ty) : Sanitized ty := by
  cases n <;> simp only [coreType] at h <;> exact sanitize_mem_sanitized h

/-- The 9 correctness letters of `toBits`, enumerated (decided over the finite
4×5×2×2 space of `RCorr`). -/
theorem toBits_letters (rx : RCorr) :
    hasAll (RCorr.toBits rx) MsB = (rx.base == .B) ∧
    hasAll (RCorr.toBits rx) MsV = (rx.base == .V) ∧
    hasAll (RCorr.toBits rx) MsK = (rx.base == .K) ∧
    hasAll (RCorr.toBits rx) MsW = (rx.base == .W) ∧
    hasAll (RCorr.toBits rx) Msz = (rx.input == .Zero) ∧
    hasAll (RCorr.toBits rx) Mso = (rx.input == .One || rx.input == .OneNonZero) ∧
    hasAll (RCorr.toBits rx) Msn = (rx.input == .OneNonZero || rx.input == .AnyNonZero) ∧
    hasAll (RCorr.toBits rx) Msd = rx.dissat ∧
    hasAll (RCorr.toBits rx) Msu = rx.unit := by
  obtain ⟨b, i, d, u⟩ := rx
  cases b <;> cases i <;> cases d <;> cases u <;>
    simp [RCorr.toBits, RBase.toBits, RInput.toBits, cif] <;>
    first | rfl | decide

/-- Field-access simp rules for record literals (structure projections don't
iota-reduce through anonymous constructors by default in simp). -/
@[simp] theorem RCorr.base_mk (b i d u) : (⟨b, i, d, u⟩ : RCorr).base = b := rfl
@[simp] theorem RCorr.input_mk (b i d u) : (⟨b, i, d, u⟩ : RCorr).input = i := rfl
@[simp] theorem RCorr.dissat_mk (b i d u) : (⟨b, i, d, u⟩ : RCorr).dissat = d := rfl
@[simp] theorem RCorr.unit_mk (b i d u) : (⟨b, i, d, u⟩ : RCorr).unit = u := rfl

/-- From 9-letter agreement of a Core child type with a rust child type,
extract the per-letter equalities about the Core mask. -/
theorem letters_of_agree {cx : MSType} {rx : RCorr}
    (heq : opAnd cx maskCorr9 = RCorr.toBits rx) :
    hasAll cx MsB = (rx.base == .B) ∧
    hasAll cx MsV = (rx.base == .V) ∧
    hasAll cx MsK = (rx.base == .K) ∧
    hasAll cx MsW = (rx.base == .W) ∧
    hasAll cx Msz = (rx.input == .Zero) ∧
    hasAll cx Mso = (rx.input == .One || rx.input == .OneNonZero) ∧
    hasAll cx Msn = (rx.input == .OneNonZero || rx.input == .AnyNonZero) ∧
    hasAll cx Msd = rx.dissat ∧
    hasAll cx Msu = rx.unit := by
  obtain ⟨hB, hV, hK, hW, hz, ho, hn, hd, hu⟩ := toBits_letters rx
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals (
    first
      | (have h := congrArg (fun m => hasAll m MsB) heq
         rw [hasAll_of_corr9 (by decide)] at h; rw [h]; exact hB)
      | (have h := congrArg (fun m => hasAll m MsV) heq
         rw [hasAll_of_corr9 (by decide)] at h; rw [h]; exact hV)
      | (have h := congrArg (fun m => hasAll m MsK) heq
         rw [hasAll_of_corr9 (by decide)] at h; rw [h]; exact hK)
      | (have h := congrArg (fun m => hasAll m MsW) heq
         rw [hasAll_of_corr9 (by decide)] at h; rw [h]; exact hW)
      | (have h := congrArg (fun m => hasAll m Msz) heq
         rw [hasAll_of_corr9 (by decide)] at h; rw [h]; exact hz)
      | (have h := congrArg (fun m => hasAll m Mso) heq
         rw [hasAll_of_corr9 (by decide)] at h; rw [h]; exact ho)
      | (have h := congrArg (fun m => hasAll m Msn) heq
         rw [hasAll_of_corr9 (by decide)] at h; rw [h]; exact hn)
      | (have h := congrArg (fun m => hasAll m Msd) heq
         rw [hasAll_of_corr9 (by decide)] at h; rw [h]; exact hd)
      | (have h := congrArg (fun m => hasAll m Msu) heq
         rw [hasAll_of_corr9 (by decide)] at h; rw [h]; exact hu))

/-- The local fact: rust's `d:` output type always has `unit = false` —
there is no context parameter and no conditional (correctness.rs:222–236). -/
theorem castDupIf_never_unit (c out : RCorr) (h : castDupIf c = some out) :
    out.unit = false := by
  cases cb : c.base <;> cases ci : c.input <;> simp [castDupIf, cb, ci] at h <;>
    ((try subst h); first | rfl | (subst h; rfl))

/-- Under Tapscript the `u` bit of Core's WRAP_D output is always set
(miniscript.cpp:125–126: MINIMALIF is consensus in Tapscript). -/
theorem wrapD_u_tapscript (x : MSType) :
    hasAll (computeType .wrapD x empty empty [] 0 .tapscript) Msu = true := by
  -- full simp first collapses the concrete masks and the closed MsContext literal,
  -- leaving a pure bit-vector goal in `x`
  simp [computeType, msUnion, msVz, msGhijk, msMs, msNdx]
  bv_decide

/-- Under P2WSH the `u` bit of Core's WRAP_D output is never set. -/
theorem wrapD_u_p2wsh_absent (x : MSType) :
    hasAll (computeType .wrapD x empty empty [] 0 .p2wsh) Msu = false := by
  -- full simp collapses the masks; close the enum comparison `p2wsh == tapscript`
  -- explicitly, leaving a pure bit-vector goal in `x`.
  simp [computeType, msUnion, msVz, msGhijk, msMs, msNdx]
  · rw [show ((MsContext.p2wsh : MsContext) == MsContext.tapscript) = false from rfl]
    bv_decide

/-- Concrete D1 witness. `wit = andor(dv:older(1), pk(K), pk(K))`, i.e.
- dv:older(1) = wrapD (wrapV (older 1))  — `d:` of `v:older(1)`
- pk(K)     = wrapC pkK                  — `c:pk_k` -/
def d1Witness : MsNode :=
  .andor (.wrapD (.wrapV (.older 1))) (.wrapC .pkK) (.wrapC .pkK)

/-- The divergence, part 1: Bitcoin Core (Tapscript) *types* the witness node
(the `u` granted to `dv:older(1)` satisfies andor's `Bdu` requirement on its
first child), while rust-miniscript *rejects* it (`andOr` requires `a.unit`;
rust's `d:` never has `unit`). -/
theorem divergence_D1_tapscript :
    (coreType .tapscript d1Witness).isSome = true ∧ rustCorrOf d1Witness = none := by
  native_decide

/-- The divergence, part 2: under P2WSH *both* implementations reject the
witness (p2wsh `d:` has no `u`, matching the spec), confirming that the
divergence is Tapscript-specific. -/
theorem divergence_D1_p2wsh_both_reject :
    (coreType .p2wsh d1Witness).isSome = false ∧ rustCorrOf d1Witness = none := by
  native_decide

/-- The divergence, part 3: exact letter-level diff of the `d:(v:older(1))`
subnode — identical on all spec-visible letters except `u` (Core `0x4B3E1` vs
rust-letters `0x012E1`; masking off `u` (`maskNoU`) makes them equal). -/
theorem divergence_D1_localized :
    ∃ rc : RCorr, ∃ t : MSType,
      coreType .tapscript (.wrapD (.wrapV (.older 1))) = some t ∧
      rustCorrOf (.wrapD (.wrapV (.older 1))) = some rc ∧
      opAnd t maskNoU = opAnd (RType.toBits ⟨rc, rustMallOf (.wrapD (.wrapV (.older 1)))⟩) maskNoU ∧
      hasAll t Msu = true ∧
      hasAll (RCorr.toBits rc) Msu = false := by
  refine ⟨{ base := .B, input := .OneNonZero, dissat := true, unit := false }, 0x4B3E1#19, ?_⟩
  native_decide

end Miniscript