import MiniscriptLean.Crosswalk

/-! Leaf-level cross-implementation agreement: Core's constant leaf masks vs
rust's constant `Correctness`/`Malleability` constructors, modulo the 12 shared
spec letters.

Older/after are parameterized by the leaf value; the variability lives entirely
outside the shared letters (Core's `g/h/i/j` timelock bits; in rust those live
in `ExtData`), hence the `restrict12` restriction. -/

namespace Miniscript
open MSType Rust

section leaves

/-- `0` (just0). -/
theorem agree_just0 (ctx : MsContext) :
    restrict12 (computeType .just0 empty empty empty [] 0 ctx) =
    RType.toBits ⟨corrFalse, mallFalse⟩ := by
  cases ctx <;> decide

/-- `1` (just1). -/
theorem agree_just1 (ctx : MsContext) :
    restrict12 (computeType .just1 empty empty empty [] 0 ctx) =
    RType.toBits ⟨corrTrue, mallTrue⟩ := by
  cases ctx <;> decide

/-- `pk_k`/`pk_h` leaves. -/
theorem agree_pkK (ctx : MsContext) :
    restrict12 (computeType .pkK empty empty empty [] 0 ctx) =
    RType.toBits ⟨corrPkK, mallPkK⟩ := by
  cases ctx <;> decide

theorem agree_pkH (ctx : MsContext) :
    restrict12 (computeType .pkH empty empty empty [] 0 ctx) =
    RType.toBits ⟨corrPkH, mallPkH⟩ := by
  cases ctx <;> decide

/-- Hash-lock leaves share one mask. -/
theorem agree_sha256 (ctx : MsContext) :
    restrict12 (computeType .sha256 empty empty empty [] 0 ctx) =
    RType.toBits ⟨corrHash, mallHash⟩ := by
  cases ctx <;> decide

theorem agree_hash256 (ctx : MsContext) :
    restrict12 (computeType .hash256 empty empty empty [] 0 ctx) =
    RType.toBits ⟨corrHash, mallHash⟩ := by
  cases ctx <;> decide

theorem agree_ripemd160 (ctx : MsContext) :
    restrict12 (computeType .ripemd160 empty empty empty [] 0 ctx) =
    RType.toBits ⟨corrHash, mallHash⟩ := by
  cases ctx <;> decide

theorem agree_hash160 (ctx : MsContext) :
    restrict12 (computeType .hash160 empty empty empty [] 0 ctx) =
    RType.toBits ⟨corrHash, mallHash⟩ := by
  cases ctx <;> decide

/-- `multi`/`multi_a` masks are argument-independent after the shared-letter
restriction (context gating of `multi`/`multi_a` is a `wellFormed` condition). -/
theorem agree_multi (k nkeys : Nat) (ctx : MsContext) :
    restrict12 (computeType .multi empty empty empty [] k ctx) =
    RType.toBits ⟨corrMulti, mallMulti⟩ := by
  cases ctx <;> simp only [computeType, msMulti] <;> decide

theorem agree_multiA (k nkeys : Nat) (ctx : MsContext) :
    restrict12 (computeType .multiA empty empty empty [] k ctx) =
    RType.toBits ⟨corrMultiA, mallMultiA⟩ := by
  cases ctx <;> simp only [computeType, msMultiA] <;> decide

/-- `older n`: Core sets `g` (relative **time**) iff bit 22 of `n` is set
(BIP68), else `h`; both lie outside the shared 12 letters. -/
theorem agree_older (n : Nat) (ctx : MsContext) :
    restrict12 (computeType .older empty empty empty [] n ctx) =
    RType.toBits ⟨corrTime, mallTime⟩ := by
  simp only [computeType, MSType.cif, msUnion, List.foldl]
  cases ctx <;> (first | decide | (split <;> split <;> decide))

/-- `after n`: Core sets `i` iff `n ≥ 500000000`, else `j`; likewise. -/
theorem agree_after (n : Nat) (ctx : MsContext) :
    restrict12 (computeType .after empty empty empty [] n ctx) =
    RType.toBits ⟨corrTime, mallTime⟩ := by
  simp only [computeType, MSType.cif, msUnion, List.foldl]
  cases ctx <;> (first | decide | (split <;> split <;> decide))

/-- Every leaf mask sanitizes to itself in both contexts: leaf typing is total
(matching both implementations' behavior). -/
theorem leaves_sanitized (ctx : MsContext) :
    Sanitized (computeType .just0 empty empty empty [] 0 ctx) ∧
    Sanitized (computeType .just1 empty empty empty [] 0 ctx) ∧
    Sanitized (computeType .pkK empty empty empty [] 0 ctx) ∧
    Sanitized (computeType .pkH empty empty empty [] 0 ctx) ∧
    Sanitized (computeType .sha256 empty empty empty [] 0 ctx) ∧
    Sanitized (computeType .hash256 empty empty empty [] 0 ctx) ∧
    Sanitized (computeType .ripemd160 empty empty empty [] 0 ctx) ∧
    Sanitized (computeType .hash160 empty empty empty [] 0 ctx) ∧
    Sanitized (computeType .older empty empty empty [] 42 ctx) ∧
    Sanitized (computeType .after empty empty empty [] 42 ctx) ∧
    Sanitized (computeType .multi empty empty empty [] 3 ctx) ∧
    Sanitized (computeType .multiA empty empty empty [] 3 ctx) := by
  unfold Sanitized; cases ctx <;> decide

end leaves

end Miniscript
