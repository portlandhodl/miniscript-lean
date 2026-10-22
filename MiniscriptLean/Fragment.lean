import MiniscriptLean.Type

/-!
# `MiniscriptLean.Fragment` — Bitcoin Core's `ComputeType`, ported

Faithful port of Bitcoin Core's Miniscript fragment type computation
(`src/script/miniscript.cpp:39–262`, commit `f86c614e`), transcribed from
`notes/core-types.md` §2. Formulas are reproduced term-for-term with the C++
quoted in doc comments; Core's `CHECK_NONFATAL` pre-flight conditions live in
`MsNode.wellFormed` instead (they are preconditions, not part of the computed
value).

`MSType` operations used: `opOr` (Core `|`), `opAnd` (Core `&`), `hasAll`
(Core `<<`; note Core's direction: `a << b` ⇔ a has all of b), `cif` (`.If`).
-/


namespace Miniscript

open MSType

/-- Core's `MiniscriptContext` (miniscript.h:253): only P2WSH and Tapscript exist
in Bitcoin Core's descriptor layer. -/
inductive MsContext where
  | p2wsh | tapscript
deriving Repr, DecidableEq

/-- Core's `enum class Fragment` (miniscript.h:213–245). -/
inductive Fragment where
  | just0 | just1 | pkK | pkH | older | after
  | sha256 | hash256 | ripemd160 | hash160
  | wrapA | wrapS | wrapC | wrapD | wrapV | wrapJ | wrapN
  | andV | andB | orB | orC | orD | orI | andor
  | thresh | multi | multiA
deriving Repr, DecidableEq

-- ---------------------------------------------------------------------------
-- Combined letter masks, giving Core's multi-letter `"…"_mst` literals
-- ---------------------------------------------------------------------------

/-- Build a mask from a list of letters: the analogue of `"...”_mst`. -/
abbrev msUnion (l : List MSType) : MSType := l.foldl opOr MSType.empty

abbrev msKVB       := msUnion [MsK, MsV, MsB]
abbrev msBo        := msUnion [MsB, Mso]
abbrev msBn        := msUnion [MsB, Msn]
abbrev msBd        := msUnion [MsB, Msd]
abbrev msBdu       := msUnion [MsB, Msd, Msu]
abbrev msWdu       := msUnion [MsW, Msd, Msu]
abbrev msWd        := msUnion [MsW, Msd]
abbrev msVz        := msUnion [MsV, Msz]
abbrev msGhijk     := msUnion [Msg, Msh, Msi, Msj, Msk]
abbrev msGhij      := msUnion [Msg, Msh, Msi, Msj]
abbrev msUdfems    := msUnion [Msu, Msd, Msf, Mse, Msm, Mss]
abbrev msUdfemsx   := msUnion [Msu, Msd, Msf, Mse, Msm, Mss, Msx]
abbrev msOndfem    := msUnion [Mso, Msn, Msd, Msf, Mse, Msm]
abbrev msZonms     := msUnion [Msz, Mso, Msn, Msm, Mss]
abbrev msOums      := msUnion [Mso, Msu, Msm, Mss]
abbrev msBzondfems := msUnion [MsB, Msz, Mso, Msn, Msd, Msf, Mse, Msm, Mss]
abbrev msMz        := msUnion [Msm, Msz]
abbrev msDzm       := msUnion [Msd, Msz, Msm]
abbrev msMs        := msUnion [Msm, Mss]
abbrev msZse       := msUnion [Msz, Mss, Mse]
abbrev msZs        := msUnion [Msz, Mss]
abbrev msVBKufs    := msUnion [MsV, MsB, MsK, Msu, Msf, Mss]
abbrev msUfde      := msUnion [Msu, Msf, Msd, Mse]
abbrev msUx        := msUnion [Msu, Msx]
abbrev msSf        := msUnion [Mss, Msf]
abbrev msNdx       := msUnion [Msn, Msd, Msx]
abbrev msFx        := msUnion [Msf, Msx]
abbrev msUs        := msUnion [Msu, Mss]
abbrev msBKV       := msUnion [MsB, MsK, MsV]

-- leaf masks (values verified against notes/core-types.md §2.1)
abbrev msJust0  : MSType := msUnion [MsB, Msz, Msu, Msd, Mse, Msm, Mss, Msx, Msk] -- "Bzudemsxk" 0x43B91
abbrev msJust1  : MSType := msUnion [MsB, Msz, Msu, Msf, Msm, Msx, Msk]           -- "Bzufmxk"   0x43511
abbrev msPkK    : MSType := msUnion [MsK, Mso, Msn, Msu, Msd, Mse, Msm, Mss, Msx, Msk] -- "Konudemsxk" 0x43BE4
abbrev msPkH    : MSType := msUnion [MsK, Msn, Msu, Msd, Mse, Msm, Mss, Msx, Msk]      -- "Knudemsxk"  0x43BC4
abbrev msHash   : MSType := msUnion [MsB, Mso, Msn, Msu, Msd, Msm, Msk]               -- "Bonudmk"    0x411E1
abbrev msTime   : MSType := msUnion [MsB, Msz, Msf, Msm, Msx, Msk]                    -- "Bzfmxk"     0x43411
abbrev msMulti  : MSType := msUnion [MsB, Msn, Msu, Msd, Mse, Msm, Mss, Msk]          -- "Bnudemsk"   0x41BC1
abbrev msMultiA : MSType := msUnion [MsB, Msu, Msd, Mse, Msm, Mss, Msk]               -- "Budemsk"    0x41B81

/-- `CTxIn::SEQUENCE_LOCKTIME_TYPE_FLAG = 1 << 22` (primitives/transaction.h:100). -/
abbrev sequenceLocktimeTypeFlag : Nat := 0x400000
/-- `LOCKTIME_THRESHOLD = 500000000` (script/script.h:48). -/
abbrev locktimeThreshold : Nat := 500000000

/-- The no-mixing cross check of AND_V/AND_B/ANDOR on the (x,y) sides:
`(g_x·h_y + h_x·g_y + i_x·j_y + j_x·i_y)` — negated
(miniscript.cpp:151–155, 166–170, 217–221). -/
abbrev noTimelockCross (x y : MSType) : Bool :=
  !((hasAll x Msg && hasAll y Msh) || (hasAll x Msh && hasAll y Msg) ||
    (hasAll x Msi && hasAll y Msj) || (hasAll x Msj && hasAll y Msi))

-- ---------------------------------------------------------------------------
-- THRESH fold (miniscript.cpp:229–262)
-- ---------------------------------------------------------------------------

/-- Accumulator for the THRESH loop: `all_e`, `all_m`, `args` (z→0, o→1, else 2
weighting), `num_s`, and the timelock accumulator `acc_tl` (starts at `"k"`). -/
structure ThreshAcc where
  allE : Bool
  allM : Bool
  args : Nat
  numS : Nat
  accTl : MSType

/-- One THRESH iteration; index 0 requires `Bdu`, later ones `Wdu`.
Returns `none` exactly where Core `return ""_mst`s inside the loop. -/
def threshStep (k i : Nat) (t : MSType) (st : ThreshAcc) : Option ThreshAcc :=
  if hasAll t (if i == 0 then msBdu else msWdu) then
    some {
      allE := st.allE && hasAll t Mse
      allM := st.allM && hasAll t Msm
      args := st.args + (if hasAll t Msz then 0 else if hasAll t Mso then 1 else 2)
      numS := st.numS + (hasAll t Mss).toNat
      accTl := opOr (opAnd (opOr st.accTl t) msGhij)
        (cif Msk (hasAll (opAnd st.accTl t) Msk &&
          (k ≤ 1 || noTimelockCross st.accTl t)))
    }
  else none

/-- The full THESH loop, left fold over children types. -/
def threshRun (k : Nat) (subs : List MSType) : Option ThreshAcc :=
  go 0 ⟨true, true, 0, 0, Msk⟩ subs
where
  go (i : Nat) (st : ThreshAcc) : List MSType → Option ThreshAcc
    | [] => some st
    | t :: ts =>
      match threshStep k i t st with
      | none => none
      | some st' => go (i + 1) st' ts

-- ---------------------------------------------------------------------------
-- ComputeType (miniscript.cpp:39–262)
-- ---------------------------------------------------------------------------

/-- Bitcoin Core's `internal::ComputeType`. Children types `x y z` are
`""_mst` (= `empty`) for absent or ill-typed children; `subs` is only used by
`thresh`; `arg` is the leaf value for `older`/`after` and the threshold for
`thresh`/`multi`/`multiA`. Context gates for `multi`/`multiA` are pre-flight
conditions (see `MsNode.wellFormed`), exactly like Core's CHECK_NONFATAL. -/
def computeType (frag : Fragment) (x y z : MSType) (subs : List MSType) (arg : Nat)
    (ctx : MsContext) : MSType :=
  match frag with
  | .just1 => msJust1
  | .just0 => msJust0
  | .pkK   => msPkK
  | .pkH   => msPkH
  -- "g".If(k & SEQUENCE_LOCKTIME_TYPE_FLAG) | "h".If(!…) | "Bzfmxk"
  | .older =>
    opOr (opOr (cif Msg ((arg &&& sequenceLocktimeTypeFlag) != 0))
               (cif Msh ((arg &&& sequenceLocktimeTypeFlag) == 0)))
         msTime
  | .after =>
    opOr (opOr (cif Msi (decide (locktimeThreshold ≤ arg)))
               (cif Msj (decide (arg < locktimeThreshold))))
         msTime
  | .sha256 | .hash256 | .ripemd160 | .hash160 => msHash
  -- WRAP_A (cpp:105–109)
  | .wrapA =>
    opOr (cif MsW (hasAll x MsB))
      (opOr (opAnd x msGhijk) (opOr (opAnd x msUdfems) Msx))
  -- WRAP_S (cpp:110–113)
  | .wrapS =>
    opOr (cif MsW (hasAll x msBo))
      (opOr (opAnd x msGhijk) (opAnd x msUdfemsx))
  -- WRAP_C (cpp:114–118)
  | .wrapC =>
    opOr (cif MsB (hasAll x MsK))
      (opOr (opAnd x msGhijk) (opOr (opAnd x msOndfem) msUs))
  -- WRAP_D (cpp:119–127)
  | .wrapD =>
    opOr (cif MsB (hasAll x msVz))
    (opOr (cif Mso (hasAll x Msz))
    (opOr (cif Mse (hasAll x Msf))
    (opOr (opAnd x msGhijk)
    (opOr (opAnd x msMs)
    (opOr (cif Msu (ctx == .tapscript)) msNdx)))))
  -- WRAP_V (cpp:128–132)
  | .wrapV =>
    opOr (cif MsV (hasAll x MsB))
      (opOr (opAnd x msGhijk) (opOr (opAnd x msZonms) msFx))
  -- WRAP_J (cpp:133–138): B.If(x<<Bn) | o.If(x<<f? no e.If(x<<f)) | (x&ghijk) | (x&oums) | ndx
  | .wrapJ =>
    opOr (cif MsB (hasAll x msBn))
      (opOr (cif Mse (hasAll x Msf))
        (opOr (opAnd x msGhijk)
          (opOr (opAnd x msOums) msNdx)))
  -- WRAP_N (cpp:139–142)
  | .wrapN =>
    opOr (opAnd x msGhijk) (opOr (opAnd x msBzondfems) msUx)
  -- AND_V (cpp:143–156)
  | .andV =>
    opOr (cif (opAnd y msKVB) (hasAll x MsV))
      (opOr (opAnd x Msn)
        (opOr (cif (opAnd y Msn) (hasAll x Msz))
          (opOr (cif (opAnd (opOr x y) Mso) (hasAll (opOr x y) Msz))
            (opOr (opAnd (opAnd x y) msMz)
              (opOr (opAnd (opOr x y) Mss)
                (opOr (cif Msf (hasAll y Msf || hasAll x Mss))
                  (opOr (opAnd y msUx)
                    (opOr (opAnd (opOr x y) msGhij)
                      (cif Msk (hasAll (opAnd x y) Msk && noTimelockCross x y))))))))))
  -- AND_B (cpp:157–171)
  | .andB =>
    opOr (cif (opAnd x MsB) (hasAll y MsW))
      (opOr (cif (opAnd (opOr x y) Mso) (hasAll (opOr x y) Msz))
        (opOr (opAnd x Msn)
          (opOr (cif (opAnd y Msn) (hasAll x Msz))
            (opOr (cif (opAnd (opAnd x y) Mse) (hasAll (opAnd x y) Mss))
              (opOr (opAnd (opAnd x y) msDzm)
                (opOr (cif Msf (hasAll (opAnd x y) Msf || hasAll x msSf || hasAll y msSf))
                  (opOr (opAnd (opOr x y) Mss)
                    (opOr msUx
                      (opOr (opAnd (opOr x y) msGhij)
                        (cif Msk (hasAll (opAnd x y) Msk && noTimelockCross x y)))))))))))
  -- OR_B (cpp:172–179)
  | .orB =>
    opOr (cif MsB (hasAll x msBd && hasAll y msWd))
      (opOr (cif (opAnd (opOr x y) Mso) (hasAll (opOr x y) Msz))
        (opOr (cif (opAnd (opAnd x y) Msm) (hasAll (opOr x y) Mss && hasAll (opAnd x y) Mse))
          (opOr (opAnd (opAnd x y) msZse)
            (opOr (msUnion [Msd, Msu, Msx])
              (opOr (opAnd (opOr x y) msGhij)
                (opAnd (opAnd x y) Msk))))))
  -- OR_C (cpp:189–196)
  | .orC =>
    opOr (cif (opAnd y MsV) (hasAll x msBdu))
      (opOr (cif (opAnd x Mso) (hasAll y Msz))
        (opOr (cif (opAnd (opAnd x y) Msm) (hasAll x Mse && hasAll (opOr x y) Mss))
          (opOr (opAnd (opAnd x y) msZs)
            (opOr msFx
              (opOr (opAnd (opOr x y) msGhij)
                (opAnd (opAnd x y) Msk))))))
  -- OR_D (cpp:180–188)
  | .orD =>
    opOr (cif (opAnd y MsB) (hasAll x msBdu))
      (opOr (cif (opAnd x Mso) (hasAll y Msz))
        (opOr (cif (opAnd (opAnd x y) Msm) (hasAll x Mse && hasAll (opOr x y) Mss))
          (opOr (opAnd (opAnd x y) msZs)
            (opOr (opAnd y msUfde)
              (opOr Msx
                (opOr (opAnd (opOr x y) msGhij)
                  (opAnd (opAnd x y) Msk)))))))
  -- OR_I (cpp:197–205)
  | .orI =>
    opOr (opAnd (opAnd x y) msVBKufs)
      (opOr (cif Mso (hasAll (opAnd x y) Msz))
        (opOr (cif (opAnd (opOr x y) Mse) (hasAll (opOr x y) Msf))
          (opOr (cif (opAnd (opAnd x y) Msm) (hasAll (opOr x y) Mss))
            (opOr (opAnd (opOr x y) Msd)
              (opOr Msx
                (opOr (opAnd (opOr x y) msGhij)
                  (opAnd (opAnd x y) Msk)))))))
  -- ANDOR (cpp:206–222)
  | .andor =>
    opOr (cif (opAnd (opAnd y z) msBKV) (hasAll x msBdu))
      (opOr (opAnd (opAnd (opAnd x y) z) Msz)
        (opOr (cif (opAnd (opOr x (opAnd y z)) Mso) (hasAll (opOr x (opAnd y z)) Msz))
          (opOr (opAnd (opAnd y z) Msu)
            (opOr (cif (opAnd z Msf) (hasAll x Mss || hasAll y Msf))
              (opOr (opAnd z Msd)
                (opOr (cif (opAnd z Mse) (hasAll x Mss || hasAll y Msf))
                  (opOr (cif (opAnd (opAnd (opAnd x y) z) Msm)
                              (hasAll x Mse && hasAll (opOr (opOr x y) z) Mss))
                    (opOr (opAnd (opAnd z (opOr x y)) Mss)
                      (opOr Msx
                        (opOr (opAnd (opOr (opOr x y) z) msGhij)
                          (cif Msk (hasAll (opAnd (opAnd x y) z) Msk && noTimelockCross x y))))))))))))
  -- MULTI (cpp:223–225): context/key-range checks are pre-flight (wellFormed)
  | .multi  => msMulti
  -- MULTI_A (cpp:226–228)
  | .multiA => msMultiA
  -- THRESH (cpp:229–262)
  | .thresh =>
    match threshRun arg subs with
    | none => MSType.empty
    | some st =>
      let n := subs.length
      opOr msBdu
      (opOr (cif Msz (decide (st.args = 0)))
      (opOr (cif Mso (decide (st.args = 1)))
      (opOr (cif Mse (st.allE && decide (st.numS = n)))
      (opOr (cif Msm (st.allE && st.allM && decide (st.numS ≥ n - arg)))
      (opOr (cif Mss (decide (st.numS ≥ n - arg + 1)))
            st.accTl)))))

-- ===========================================================
-- Literal forms of every mask (native_decide-verified provenance, used by bv_decide pipelines)
-- ===========================================================

theorem msKVB_lit : msKVB = 7#19 := by decide
theorem msBo_lit : msBo = 33#19 := by decide
theorem msBn_lit : msBn = 65#19 := by decide
theorem msBd_lit : msBd = 129#19 := by decide
theorem msBdu_lit : msBdu = 385#19 := by decide
theorem msWdu_lit : msWdu = 392#19 := by decide
theorem msWd_lit : msWd = 136#19 := by decide
theorem msVz_lit : msVz = 18#19 := by decide
theorem msGhijk_lit : msGhijk = 507904#19 := by decide
theorem msGhij_lit : msGhij = 245760#19 := by decide
theorem msUdfems_lit : msUdfems = 8064#19 := by decide
theorem msUdfemsx_lit : msUdfemsx = 16256#19 := by decide
theorem msOndfem_lit : msOndfem = 5856#19 := by decide
theorem msZonms_lit : msZonms = 6256#19 := by decide
theorem msOums_lit : msOums = 6432#19 := by decide
theorem msBzondfems_lit : msBzondfems = 7921#19 := by decide
theorem msMz_lit : msMz = 4112#19 := by decide
theorem msDzm_lit : msDzm = 4240#19 := by decide
theorem msMs_lit : msMs = 6144#19 := by decide
theorem msZse_lit : msZse = 2576#19 := by decide
theorem msZs_lit : msZs = 2064#19 := by decide
theorem msVBKufs_lit : msVBKufs = 3335#19 := by decide
theorem msUfde_lit : msUfde = 1920#19 := by decide
theorem msUx_lit : msUx = 8448#19 := by decide
theorem msSf_lit : msSf = 3072#19 := by decide
theorem msNdx_lit : msNdx = 8384#19 := by decide
theorem msFx_lit : msFx = 9216#19 := by decide
theorem msUs_lit : msUs = 2304#19 := by decide
theorem msBKV_lit : msBKV = 7#19 := by decide
theorem msJust0_lit : msJust0 = 277393#19 := by decide
theorem msJust1_lit : msJust1 = 275729#19 := by decide
theorem msPkK_lit : msPkK = 277476#19 := by decide
theorem msPkH_lit : msPkH = 277444#19 := by decide
theorem msHash_lit : msHash = 266721#19 := by decide
theorem msTime_lit : msTime = 275473#19 := by decide
theorem msMulti_lit : msMulti = 269249#19 := by decide
theorem msMultiA_lit : msMultiA = 269185#19 := by decide

-- ---------------------------------------------------------------------------
-- The Miniscript node tree and Core's bottom-up typing
-- ---------------------------------------------------------------------------

/-- Miniscript AST: mirrors Core's `Node<KeyType>` with payloads abstracted
(only the *count* of keys and the timelock *value* affect typing). -/
inductive MsNode where
  | just0 | just1 | pkK | pkH
  | older (n : Nat) | after (n : Nat)
  | sha256 | hash256 | ripemd160 | hash160
  | wrapA (x : MsNode) | wrapS (x : MsNode) | wrapC (x : MsNode) | wrapD (x : MsNode)
  | wrapV (x : MsNode) | wrapJ (x : MsNode) | wrapN (x : MsNode)
  | andV (x y : MsNode) | andB (x y : MsNode)
  | orB (x y : MsNode) | orC (x y : MsNode) | orD (x y : MsNode) | orI (x y : MsNode)
  | andor (x y z : MsNode)
  | thresh (k : Nat) (cs : List MsNode)
  | multi (k nkeys : Nat) | multiA (k nkeys : Nat)
deriving Repr

/-- The fragment a node is built from. -/
def MsNode.frag : MsNode → Fragment
  | .just0 => .just0 | .just1 => .just1 | .pkK => .pkK | .pkH => .pkH
  | .older _ => .older | .after _ => .after
  | .sha256 => .sha256 | .hash256 => .hash256
  | .ripemd160 => .ripemd160 | .hash160 => .hash160
  | .wrapA _ => .wrapA | .wrapS _ => .wrapS | .wrapC _ => .wrapC | .wrapD _ => .wrapD
  | .wrapV _ => .wrapV | .wrapJ _ => .wrapJ | .wrapN _ => .wrapN
  | .andV _ _ => .andV | .andB _ _ => .andB
  | .orB _ _ => .orB | .orC _ _ => .orC | .orD _ _ => .orD | .orI _ _ => .orI
  | .andor _ _ _ => .andor
  | .thresh _ _ => .thresh
  | .multi _ _ => .multi | .multiA _ _ => .multiA

/-- Timelock value / threshold argument of a node (0 where absent). -/
def MsNode.arg : MsNode → Nat
  | .older n | .after n => n
  | .thresh k _ => k
  | .multi k _ => k
  | .multiA k _ => k
  | _ => 0

mutual

/-- Core's bottom-up `Node::CalcType` over the whole tree (miniscript.h:779–794 +
`SanitizeType`): children whose typing failed are fed upward as `""_mst`,
exactly like Core. Returns `none` iff the sanitized type is empty
(equivalently, the C++ node's type would be `""_mst`). -/
def coreType (ctx : MsContext) : MsNode → Option MSType
  | .just0      => MSType.sanitize (computeType .just0 empty empty empty [] 0 ctx)
  | .just1      => MSType.sanitize (computeType .just1 empty empty empty [] 0 ctx)
  | .pkK        => MSType.sanitize (computeType .pkK empty empty empty [] 0 ctx)
  | .pkH        => MSType.sanitize (computeType .pkH empty empty empty [] 0 ctx)
  | .older n    => MSType.sanitize (computeType .older empty empty empty [] n ctx)
  | .after n    => MSType.sanitize (computeType .after empty empty empty [] n ctx)
  | .sha256     => MSType.sanitize (computeType .sha256 empty empty empty [] 0 ctx)
  | .hash256    => MSType.sanitize (computeType .hash256 empty empty empty [] 0 ctx)
  | .ripemd160  => MSType.sanitize (computeType .ripemd160 empty empty empty [] 0 ctx)
  | .hash160    => MSType.sanitize (computeType .hash160 empty empty empty [] 0 ctx)
  | .wrapA x    => MSType.sanitize (computeType .wrapA (child ctx x) empty empty [] 0 ctx)
  | .wrapS x    => MSType.sanitize (computeType .wrapS (child ctx x) empty empty [] 0 ctx)
  | .wrapC x    => MSType.sanitize (computeType .wrapC (child ctx x) empty empty [] 0 ctx)
  | .wrapD x    => MSType.sanitize (computeType .wrapD (child ctx x) empty empty [] 0 ctx)
  | .wrapV x    => MSType.sanitize (computeType .wrapV (child ctx x) empty empty [] 0 ctx)
  | .wrapJ x    => MSType.sanitize (computeType .wrapJ (child ctx x) empty empty [] 0 ctx)
  | .wrapN x    => MSType.sanitize (computeType .wrapN (child ctx x) empty empty [] 0 ctx)
  | .andV x y   => MSType.sanitize (computeType .andV (child ctx x) (child ctx y) empty [] 0 ctx)
  | .andB x y   => MSType.sanitize (computeType .andB (child ctx x) (child ctx y) empty [] 0 ctx)
  | .orB x y    => MSType.sanitize (computeType .orB (child ctx x) (child ctx y) empty [] 0 ctx)
  | .orC x y    => MSType.sanitize (computeType .orC (child ctx x) (child ctx y) empty [] 0 ctx)
  | .orD x y    => MSType.sanitize (computeType .orD (child ctx x) (child ctx y) empty [] 0 ctx)
  | .orI x y    => MSType.sanitize (computeType .orI (child ctx x) (child ctx y) empty [] 0 ctx)
  | .andor x y z =>
      MSType.sanitize (computeType .andor (child ctx x) (child ctx y) (child ctx z) [] 0 ctx)
  | .thresh k cs =>
      MSType.sanitize (computeType .thresh empty empty empty (coreTypeList ctx cs) k ctx)
  | .multi k _  => MSType.sanitize (computeType .multi empty empty empty [] k ctx)
  | .multiA k _ => MSType.sanitize (computeType .multiA empty empty empty [] k ctx)

/-- Child type fed upward, `""_mst` when the child is ill-typed. -/
def child (ctx : MsContext) (n : MsNode) : MSType := (coreType ctx n).getD empty

/-- Per-child types of a `thresh` node. -/
def coreTypeList (ctx : MsContext) : List MsNode → List MSType
  | [] => []
  | m :: ms => child ctx m :: coreTypeList ctx ms

end

-- ---------------------------------------------------------------------------
-- Pre-flight validity (Core's CHECK_NONFATAL layer + rules from the tests)
-- ---------------------------------------------------------------------------

mutual

/-- Core's `CHECK_NONFATAL` pre-flight conditions plus text-parser bounds, as a
decidable predicate over trees. Context gates: `multi` only under P2WSH, `multi_a`
only under Tapscript; `1 ≤ n < 2^31` for `older`/`after`; `1 ≤ k ≤ …`;
key-count bounds `n ≤ 20` (multi) / `n ≤ 999` (multi_a). -/
def MsNode.wellFormed (ctx : MsContext) : MsNode → Bool
  | .just0 | .just1 | .pkK | .pkH | .sha256 | .hash256 | .ripemd160 | .hash160 => true
  | .older n | .after n => decide (1 ≤ n ∧ n < 0x80000000)
  | .wrapA x | .wrapS x | .wrapC x | .wrapD x | .wrapV x | .wrapJ x | .wrapN x =>
      MsNode.wellFormed ctx x
  | .andV x y | .andB x y | .orB x y | .orC x y | .orD x y | .orI x y =>
      MsNode.wellFormed ctx x && MsNode.wellFormed ctx y
  | .andor x y z =>
      MsNode.wellFormed ctx x && MsNode.wellFormed ctx y && MsNode.wellFormed ctx z
  | .thresh k cs =>
      decide (1 ≤ k ∧ k ≤ cs.length) && MsNode.listWellFormed ctx cs
  | .multi k nkeys =>
      decide (ctx ≠ .tapscript) && decide (1 ≤ nkeys ∧ nkeys ≤ 20) && decide (1 ≤ k ∧ k ≤ nkeys)
  | .multiA k nkeys =>
      decide (ctx = .tapscript) && decide (1 ≤ nkeys ∧ nkeys ≤ 999) && decide (1 ≤ k ∧ k ≤ nkeys)

/-- All children of a `thresh` are well-formed. -/
def MsNode.listWellFormed (ctx : MsContext) : List MsNode → Bool
  | [] => true
  | m :: ms => MsNode.wellFormed ctx m && MsNode.listWellFormed ctx ms

end

end Miniscript
