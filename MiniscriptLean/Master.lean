import MiniscriptLean.Crosswalk
import MiniscriptLean.StepsWrappers

namespace Miniscript
open MSType Rust

-- ---------------------------------------------------------------------------
-- The node-level correspondence and per-fragment obligations
-- ---------------------------------------------------------------------------

/-- Malleability letters agreement between a Core mask and a rust `Malleability`.
When rust says `Malleable`, Core's mask must not carry `m` (rust discards info);
when `NonMalleable`, the `f`/`e`/`s` letters match exactly. -/
def mallBits (t : MSType) (rm : RMall) : Prop :=
  match rm with
  | .malleable => hasAll t Msm = false
  | .nonMalleable d s =>
      hasAll t Msm = true ∧ hasAll t Mss = s ∧
      hasAll t Mse = (d == .unique) ∧ hasAll t Msf = (d == .none)

/-- The nine correctness letters of a Core mask equal the rust `RCorr` mapping,
and the mask's malleability letters agree with `rm`. -/
def agreeWith (t : MSType) (rc : RCorr) (rm : RMall) : Prop :=
  opAnd t maskCorr9 = RCorr.toBits rc ∧ mallBits t rm

/-- Obligation for a unary wrapper step. `e` is the u-correction for wrapD's
tapscript divergence D1 — zero for all other wrappers. For wrapD use
`(cif Msu (decide (ctx = .tapscript)))`. -/
def WrapObligation (frag : Fragment) (castF : RCorr → Option RCorr)
    (mallF : RMall → RMall) (eCorr : MSType) (ctx : MsContext) : Prop :=
  ∀ (cx : MSType) (rx : RCorr) (rmx : RMall),
    Sanitized cx → opAnd cx maskCorr9 = RCorr.toBits rx → mallBits cx rmx →
    ((castF rx = none →
        zeroBase (computeType frag cx empty empty [] 0 ctx) = true) ∧
     (∀ out, castF rx = some out →
        let T := computeType frag cx empty empty [] 0 ctx
        MSType.sanitize T = some T ∧
        opAnd T maskCorr9 = opOr (RCorr.toBits out) (opAnd eCorr maskCorr9) ∧
        mallBits T (mallF rmx)))

/-- Obligation for a binary combinator step. -/
def BinObligation (frag : Fragment) (corrF : RCorr → RCorr → Option RCorr)
    (mallF : RMall → RMall → RMall) (ctx : MsContext) : Prop :=
  ∀ (cx cy : MSType) (rx ry : RCorr) (rmx rmy : RMall),
    Sanitized cx → Sanitized cy →
    opAnd cx maskCorr9 = RCorr.toBits rx → opAnd cy maskCorr9 = RCorr.toBits ry →
    mallBits cx rmx → mallBits cy rmy →
    ((corrF rx ry = none →
        zeroBase (computeType frag cx cy empty [] 0 ctx) = true) ∧
     (∀ out, corrF rx ry = some out →
        let T := computeType frag cx cy empty [] 0 ctx
        MSType.sanitize T = some T ∧
        opAnd T maskCorr9 = RCorr.toBits out ∧
        mallBits T (mallF rmx rmy)))

/-- Obligation for `andor` (ternary). -/
def TernObligation (frag : Fragment)
    (corrF : RCorr → RCorr → RCorr → Option RCorr)
    (mallF : RMall → RMall → RMall → RMall) (ctx : MsContext) : Prop :=
  ∀ (cx cy cz : MSType) (rx ry rz : RCorr) (rmx rmy rmz : RMall),
    Sanitized cx → Sanitized cy → Sanitized cz →
    opAnd cx maskCorr9 = RCorr.toBits rx → opAnd cy maskCorr9 = RCorr.toBits ry →
    opAnd cz maskCorr9 = RCorr.toBits rz →
    mallBits cx rmx → mallBits cy rmy → mallBits cz rmz →
    ((corrF rx ry rz = none →
        zeroBase (computeType frag cx cy cz [] 0 ctx) = true) ∧
     (∀ out, corrF rx ry rz = some out →
        let T := computeType frag cx cy cz [] 0 ctx
        MSType.sanitize T = some T ∧
        opAnd T maskCorr9 = RCorr.toBits out ∧
        mallBits T (mallF rmx rmy rmz)))

/-- Obligation for a leaf/constant fragment (incl. parameterized older/after,
multi/multiA): restricted to the shared letters the two agree. -/
def LeafObligation (core : MSType) (rc : RCorr) (rm : RMall) : Prop :=
  MSType.restrict12 core = RType.toBits ⟨rc, rm⟩

/-- Pointwise relation over equally-shaped lists. -/
inductive ZipRel {α β : Type} (p : α → β → Prop) : List α → List β → Prop
  | nil : ZipRel p [] []
  | cons {a b as bs} : p a b → ZipRel p as bs → ZipRel p (a :: as) (b :: bs)

/-- Obligation for `thresh`: the list-fold correspondence over child masks. -/
def ThreshObligation (ctx : MsContext) : Prop :=
  ∀ (k : Nat) (xsC : List MSType) (xsR : List RCorr) (rms : List RMall),
    ZipRel (fun c r => Sanitized c ∧ opAnd c maskCorr9 = RCorr.toBits r) xsC xsR →
    ZipRel (fun c m => mallBits c m) xsC rms →
    (thresholdCorr xsR = none →
      zeroBase (computeType .thresh empty empty empty xsC k ctx) = true) ∧
    (∀ out, thresholdCorr xsR = some out →
      ∃ T, MSType.sanitize (computeType .thresh empty empty empty xsC k ctx) = some T ∧
        opAnd T maskCorr9 = RCorr.toBits out)

-- ---------------------------------------------------------------------------
-- Custom eliminator for MsNode giving child-wise hypotheses (incl. thresh)
-- ---------------------------------------------------------------------------

/-- Children of a node as a list. -/
def MsNode.children : MsNode → List MsNode
  | .just0 | .just1 | .pkK | .pkH | .older _ | .after _ | .sha256 | .hash256
  | .ripemd160 | .hash160 | .multi _ _ | .multiA _ _ => []
  | .wrapA x | .wrapS x | .wrapC x | .wrapD x | .wrapV x | .wrapJ x | .wrapN x => [x]
  | .andV x y | .andB x y | .orB x y | .orC x y | .orD x y | .orI x y => [x, y]
  | .andor x y z => [x, y, z]
  | .thresh _ cs => cs

/-- Height of a node. -/
def MsNode.height : MsNode → Nat
  | .just0 | .just1 | .pkK | .pkH | .sha256 | .hash256 | .ripemd160 | .hash160
  | .older _ | .after _ | .multi _ _ | .multiA _ _ => 0
  | .wrapA x | .wrapS x | .wrapC x | .wrapD x | .wrapV x | .wrapJ x | .wrapN x =>
      MsNode.height x + 1
  | .andV x y | .andB x y | .orB x y | .orC x y | .orD x y | .orI x y =>
      max (MsNode.height x) (MsNode.height y) + 1
  | .andor x y z => max (max (MsNode.height x) (MsNode.height y)) (MsNode.height z) + 1
  | .thresh _ cs => cs.foldr (fun c acc => max (MsNode.height c) acc) 0 + 1

/-- Any member of a `thresh` list has height below the accumulated fold. -/
theorem foldr_max_height_mem {c : MsNode} {cs : List MsNode} (h : c ∈ cs) :
    MsNode.height c ≤ cs.foldr (fun c acc => max (MsNode.height c) acc) 0 := by
  induction cs with
  | nil => simp at h
  | cons x xs ih =>
    simp only [List.mem_cons] at h
    rcases h with rfl | hr
    · simp only [List.foldr_cons]; exact Nat.le_max_left _ _
    · have hb := ih hr
      simp only [List.foldr_cons]
      exact Nat.le_trans hb (Nat.le_max_right _ _)

/-- A child has strictly smaller height than the parent. -/
theorem height_lt_of_mem_children {c n : MsNode} (h : c ∈ MsNode.children n) :
    MsNode.height c < MsNode.height n := by
  cases n with
  | thresh k cs =>
    simp only [MsNode.children] at h
    simp only [MsNode.height]
    exact Nat.lt_succ_of_le (foldr_max_height_mem h)
  | wrapA _ | wrapS _ | wrapC _ | wrapD _ | wrapV _ | wrapJ _ | wrapN _ =>
    simp only [MsNode.children, List.mem_singleton] at h
    cases h
    simp [MsNode.height]
  | andV _ _ | andB _ _ | orB _ _ | orC _ _ | orD _ _ | orI _ _ =>
    simp only [MsNode.children, List.mem_cons, List.mem_singleton, List.not_mem_nil,
      false_or, or_false] at h
    rcases h with rfl | rfl <;> simp [MsNode.height] <;> omega
  | andor _ _ _ =>
    simp only [MsNode.children, List.mem_cons, List.mem_singleton, List.not_mem_nil,
      false_or, or_false] at h
    rcases h with rfl | (rfl | rfl) <;> simp [MsNode.height] <;> omega
  | just0 | just1 | pkK | pkH | sha256 | hash256 | ripemd160 | hash160 =>
    simp only [MsNode.children] at h; cases h
  | older _ | after _ =>
    simp only [MsNode.children] at h; cases h
  | multi _ _ | multiA _ _ =>
    simp only [MsNode.children] at h; cases h

/-- Custom eliminator for `MsNode` with child-wise hypotheses. -/
theorem MsNode.induction (P : MsNode → Prop)
    (step : ∀ n, (∀ c ∈ MsNode.children n, P c) → P n) (n : MsNode) : P n :=
  step n fun c hc => MsNode.induction P step c
termination_by MsNode.height n
decreasing_by exact height_lt_of_mem_children hc

/-- The complete per-fragment step table at context `ctx`: the modular work-list
that composes into the whole-tree typing equivalence at a given context.
**Status:** the obligations are fully specified here; the master induction is the
connection point; leaves and a first wrapper (`a:`) are proved in `StepsLeaves.lean`
and `Steps.lean`, with `wrapS`'s failure-direction in `StepsWrappers.lean`.
Filling the remaining combinator obligations is mechanical replication of those
proven patterns. -/
structure FragSteps (ctx : MsContext) : Prop where
  wA : WrapObligation .wrapA castAlt mallPass empty ctx
  wS : WrapObligation .wrapS castSwap mallPass empty ctx
  wC : WrapObligation .wrapC castCheck mallCheck empty ctx
  wD : WrapObligation .wrapD castDupIf mallDupIf (cif Msu (decide (ctx = .tapscript))) ctx
  wV : WrapObligation .wrapV castVerify mallVerify empty ctx
  wJ : WrapObligation .wrapJ castNonZero mallNonZero empty ctx
  wN : WrapObligation .wrapN castZeroNotEqual mallPass empty ctx
  andV : BinObligation .andV andV mallAndV ctx
  andB : BinObligation .andB andB mallAndB ctx
  orB : BinObligation .orB orB mallOrB ctx
  orC : BinObligation .orC orC mallOrC ctx
  orD : BinObligation .orD orD mallOrD ctx
  orI : BinObligation .orI orI mallOrI ctx
  andor : TernObligation .andor andOr mallAndOr ctx
  thresh : ThreshObligation ctx

end Miniscript
