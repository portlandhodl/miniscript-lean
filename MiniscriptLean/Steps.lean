import MiniscriptLean.Crosswalk

namespace Miniscript
open MSType Rust

theorem wrapA_step_fail (cx : MSType) (rx : RCorr)
    (_hsx : Sanitized cx)
    (heq : opAnd cx maskCorr9 = RCorr.toBits rx) (ctx : MsContext) :
    castAlt rx = none → zeroBase (computeType .wrapA cx empty empty [] 0 ctx) = true := by
  obtain ⟨hB, _hV, _hK, _hW, _hz, _ho, _hn, _hd, _hu⟩ := letters_of_agree heq
  intro hfail
  obtain ⟨rb, _ri, _rd, _ru⟩ := rx
  cases rb with
  | B => simp [castAlt] at hfail
  | K | V | W =>
    have hxB : hasAll cx MsB = false := by rw [hB]; rfl
    simp [computeType, msUnion, zeroBase, hxB, msUdfems, msGhijk]
    bv_decide

theorem wrapA_step_succ (cx : MSType) (rb : RBase) (ri : RInput) (rd ru : Bool)
    (hsx : Sanitized cx)
    (heq : opAnd cx maskCorr9 = RCorr.toBits ⟨rb, ri, rd, ru⟩) (out : RCorr) (ctx : MsContext)
    (hsucc : castAlt ⟨rb, ri, rd, ru⟩ = some out) :
    MSType.sanitize (computeType .wrapA cx empty empty [] 0 ctx) =
      some (computeType .wrapA cx empty empty [] 0 ctx) ∧
    opAnd (computeType .wrapA cx empty empty [] 0 ctx) maskCorr9 = RCorr.toBits out ∧
    hasAll (computeType .wrapA cx empty empty [] 0 ctx) Msf = hasAll cx Msf ∧
    hasAll (computeType .wrapA cx empty empty [] 0 ctx) Mse = hasAll cx Mse ∧
    hasAll (computeType .wrapA cx empty empty [] 0 ctx) Msm = hasAll cx Msm ∧
    hasAll (computeType .wrapA cx empty empty [] 0 ctx) Mss = hasAll cx Mss := by
  obtain ⟨hB, _hV, _hK, _hW, _hz, _ho, _hn, hd, hu⟩ := letters_of_agree heq
  have hsan0 := (sanitized_iff_sanitizeOk cx).1 hsx
  rw [Bool.and_eq_true] at hsan0
  obtain ⟨hpos, hsan2⟩ := hsan0
  rw [Bool.not_eq_true'] at hpos
  rw [Bool.and_eq_true] at hsan2
  obtain ⟨h1b, hrules⟩ := hsan2
  cases rb with
  | K | V | W => simp [castAlt] at hsucc
  | B =>
    simp only [castAlt] at hsucc
    obtain rfl := Option.some.inj hsucc
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
    · have hBt : hasAll cx MsB = true := by rw [hB]; rfl
      have hzb : zeroBase (computeType .wrapA cx empty empty [] 0 ctx) = false := by
        simp only [zeroBase, computeType, msUnion, List.foldl, cif, opOr, opAnd,
          empty, msUdfems, msGhijk, hBt]
        bv_decide
      have hok : (oneBase (computeType .wrapA cx empty empty [] 0 ctx) &&
                  rulesOk (computeType .wrapA cx empty empty [] 0 ctx)) = true := by
        simp only [oneBase, rulesOk, computeType, msUnion, List.foldl, cif, opOr, opAnd,
          empty, hasAll, msUdfems, msGhijk, hasAll_B_eq, hasAll_V_eq, hasAll_K_eq,
          hasAll_W_eq, hasAll_z_eq, hasAll_o_eq, hasAll_n_eq, hasAll_d_eq, hasAll_u_eq]
        simp only [zeroBase, oneBase, rulesOk, getBit] at hpos h1b hrules
        simp only [Bool.and_eq_true, Bool.or_eq_true, Bool.not_eq_true'] at hpos h1b hrules
        bv_decide
      simp [MSType.sanitize, hzb, hok]
    · -- the 9-letter mask equality
      have hd' : hasAll cx Msd = rd := by simpa using hd
      have hu' : hasAll cx Msu = ru := by simpa using hu
      simp only [computeType, msUnion, List.foldl, cif, hasAll, opOr, opAnd, empty,
        msUdfems_lit, msGhijk_lit, RCorr.toBits, RBase.toBits, RInput.toBits]
      rw [← hd', ← hu']
      bv_decide
    all_goals
      simp [computeType, msUnion, cif, opOr, opAnd, hasAll]
      bv_decide

/-- TEMPLATE: full wrapA step agreement (failure + success branches combined). -/
theorem wrapA_step (cx : MSType) (rx : RCorr) (hsx : Sanitized cx)
    (heq : opAnd cx maskCorr9 = RCorr.toBits rx) (ctx : MsContext) :
    (castAlt rx = none → zeroBase (computeType .wrapA cx empty empty [] 0 ctx) = true) ∧
    (∀ out : RCorr, castAlt rx = some out →
      MSType.sanitize (computeType .wrapA cx empty empty [] 0 ctx) =
        some (computeType .wrapA cx empty empty [] 0 ctx) ∧
      opAnd (computeType .wrapA cx empty empty [] 0 ctx) maskCorr9 = RCorr.toBits out ∧
      hasAll (computeType .wrapA cx empty empty [] 0 ctx) Msf = hasAll cx Msf ∧
      hasAll (computeType .wrapA cx empty empty [] 0 ctx) Mse = hasAll cx Mse ∧
      hasAll (computeType .wrapA cx empty empty [] 0 ctx) Msm = hasAll cx Msm ∧
      hasAll (computeType .wrapA cx empty empty [] 0 ctx) Mss = hasAll cx Mss) := by
  obtain ⟨rb, ri, rd, ru⟩ := rx
  refine ⟨wrapA_step_fail cx ⟨rb, ri, rd, ru⟩ hsx heq ctx, ?_⟩
  intro out hout
  exact wrapA_step_succ cx rb ri rd ru hsx heq out ctx hout

end Miniscript
