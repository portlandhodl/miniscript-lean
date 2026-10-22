import MiniscriptLean.Crosswalk
import MiniscriptLean.Steps
import MiniscriptLean.StepsLeaves

namespace Miniscript
open MSType Rust

/-- Helper: unpack a `Sanitized` hypothesis into its three bit-level components. -/
theorem unpack_sanitized {t : MSType} (h : Sanitized t) :
    zeroBase t = false ∧ oneBase t = true ∧ rulesOk t = true := by
  have h0 := (sanitized_iff_sanitizeOk t).1 h
  rw [Bool.and_eq_true] at h0
  obtain ⟨hpos, hsan2⟩ := h0
  rw [Bool.not_eq_true'] at hpos
  rw [Bool.and_eq_true] at hsan2
  exact ⟨hpos, hsan2.1, hsan2.2⟩

-- ==================================================================
-- FAILURE direction lemmas (all wrappers).
-- ==================================================================

theorem wrapS_step_fail (cx : MSType) (rx : RCorr) (_hsx : Sanitized cx)
    (heq : opAnd cx maskCorr9 = RCorr.toBits rx) (ctx : MsContext) :
    castSwap rx = none → zeroBase (computeType .wrapS cx empty empty [] 0 ctx) = true := by
  obtain ⟨hB, _hV, _hK, _hW, _hz, ho, _hn, _hd, _hu⟩ := letters_of_agree heq
  intro hfail
  cases hb : rx.base <;> cases hi : rx.input <;> simp [castSwap, hb, hi] at hfail
  all_goals
    simp [hb, hi] at hB ho
    simp only [computeType, zeroBase, getBit, cif, hasAll, opOr, opAnd, empty,
      msBo_lit, msGhijk_lit, msUdfemsx_lit]
    simp only [hasAll] at hB ho
    bv_decide

theorem wrapC_step_fail (cx : MSType) (rx : RCorr) (_hsx : Sanitized cx)
    (heq : opAnd cx maskCorr9 = RCorr.toBits rx) (ctx : MsContext) :
    castCheck rx = none → zeroBase (computeType .wrapC cx empty empty [] 0 ctx) = true := by
  obtain ⟨hB, _hV, hK, _hW, _hz, _ho, _hn, _hd, _hu⟩ := letters_of_agree heq
  intro hfail
  cases hb : rx.base <;> simp [castCheck, hb] at hfail
  all_goals (
    simp [hb] at hK
    simp only [computeType, zeroBase, getBit, cif, hasAll, opOr, opAnd, empty,
      msGhijk_lit, msOndfem_lit, msUs_lit]
    simp only [hasAll] at hK
    bv_decide)

theorem wrapV_step_fail (cx : MSType) (rx : RCorr) (_hsx : Sanitized cx)
    (heq : opAnd cx maskCorr9 = RCorr.toBits rx) (ctx : MsContext) :
    castVerify rx = none → zeroBase (computeType .wrapV cx empty empty [] 0 ctx) = true := by
  obtain ⟨hB, _hV, _hK, _hW, _hz, _ho, _hn, _hd, _hu⟩ := letters_of_agree heq
  intro hfail
  cases hb : rx.base <;> simp [castVerify, hb] at hfail
  all_goals (
    simp only [computeType, zeroBase, getBit, cif, hasAll, opOr, opAnd, empty,
      msGhijk_lit, msZonms_lit, msFx_lit]
    bv_decide)

theorem wrapN_step_fail (cx : MSType) (rx : RCorr) (_hsx : Sanitized cx)
    (heq : opAnd cx maskCorr9 = RCorr.toBits rx) (ctx : MsContext) :
    castZeroNotEqual rx = none → zeroBase (computeType .wrapN cx empty empty [] 0 ctx) = true := by
  obtain ⟨hB, _hV, _hK, _hW, _hz, _ho, _hn, _hd, _hu⟩ := letters_of_agree heq
  intro hfail
  cases hb : rx.base <;> simp [castZeroNotEqual, hb] at hfail
  all_goals (
    simp only [computeType, zeroBase, getBit, cif, hasAll, opOr, opAnd, empty,
      msGhijk_lit, msBzondfems_lit, msUx_lit]
    simp only [hasAll] at hB
    bv_decide)

theorem wrapJ_step_fail (cx : MSType) (rx : RCorr) (_hsx : Sanitized cx)
    (heq : opAnd cx maskCorr9 = RCorr.toBits rx) (ctx : MsContext) :
    castNonZero rx = none → zeroBase (computeType .wrapJ cx empty empty [] 0 ctx) = true := by
  obtain ⟨hB, _hV, _hK, _hW, _hz, _ho, hn, _hd, _hu⟩ := letters_of_agree heq
  intro hfail
  cases hb : rx.base <;> cases hi : rx.input <;> simp [castNonZero, hb, hi] at hfail
  all_goals (
    simp [hb, hi] at hB hn
    simp only [computeType, zeroBase, getBit, cif, hasAll, opOr, opAnd, empty,
      msGhijk_lit, msOums_lit, msNdx_lit, msBn_lit]
    simp only [hasAll] at hB hn
    bv_decide)

theorem wrapD_step_fail (cx : MSType) (rx : RCorr) (_hsx : Sanitized cx)
    (heq : opAnd cx maskCorr9 = RCorr.toBits rx) (ctx : MsContext) :
    castDupIf rx = none → zeroBase (computeType .wrapD cx empty empty [] 0 ctx) = true := by
  obtain ⟨hB, hV, _hK, _hW, hz, _ho, _hn, _hd, _hu⟩ := letters_of_agree heq
  intro hfail
  cases hb : rx.base <;> cases hi : rx.input <;> simp [castDupIf, hb, hi] at hfail
  all_goals (
    simp only [computeType, zeroBase, getBit, cif, hasAll, opOr, opAnd, empty,
      msGhijk_lit, msMs_lit, msNdx_lit, msVz_lit]
    simp only [hasAll] at hV hz
    bv_decide)

-- ==================================================================
-- SUCCESS direction lemmas.
-- ==================================================================
end Miniscript
