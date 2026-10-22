# rust-miniscript: Policy Layer Architecture (`src/policy/`)

Scope: architectural read of `rust-miniscript/src/policy/{mod.rs,semantic.rs,concrete.rs,compiler.rs}`
(read-only; no modifications made). File:line refs are to `rust-miniscript/src/…`.

Supporting docs cited by the code itself: `rust-miniscript/doc/compiler.md` (compiler
algorithm/guarantees) and `rust-miniscript/doc/taproot_compiler.pdf`.

---

## 1. Policy ASTs and normalization

### 1.1 Semantic policy (`policy/semantic.rs`)

`semantic::Policy<Pk>` is the *abstract* AST capturing only satisfaction **semantics**
(`semantic.rs:27-49`):

| Variant | Line | Meaning |
|---|---|---|
| `Unsatisfiable` | 29 | false |
| `Trivial` | 31 | true |
| `Key(Pk)` | 34 | signature |
| `After(AbsLockTime)` | 36 | CLTV |
| `Older(RelLockTime)` | 38 | CSV |
| `Sha256 / Hash256 / Ripemd160 / Hash160` | 40-46 | hash preimages (hash types are associated types of `Pk`) |
| `Thresh(Threshold<Arc<Self>, 0>)` | 48 | **only** combinator; n-ary, `MAX=0` (uncapped) |

Key structural decision: **there are no `And`/`Or` variants in the semantic AST**. `and`
desugars to `Thresh` with k=n and `or` to k=1 **at parse time** (`semantic.rs:757-774`);
conversely `thresh(1,…)` and `thresh(n,…)` are *rejected* in semantic position
(`IllegalOr`/`IllegalAnd`, `semantic.rs:778-786`, also in the math-notation parser
`semantic.rs:611-617`). This gives a single canonical combinator so that two syntactically
different but semantically equal policies compare equal.

Analysis/normalization machinery on semantic policies:

- `normalized()` (`semantic.rs:806-873`): recursive flattening — drops `Trivial`/`Unsatisfiable`
  children, recomputes `m = k − #trivials`, subtracts unsatisfiables from n, flattens nested
  and-of-ands / or-of-ors, degenerates to `Trivial`/`Unsatisfiable`/single-child as needed.
  Result is at most one `Thresh` per nesting level with `1 < m < n` or a pure and/or.
- `sorted()` (`semantic.rs:1037-1057`): canonical form (sorts threshold children via the
  `Ord` impl at `semantic.rs:72-92`, which orders first by variant name, then payload;
  locktimes compare by consensus u32, `:82-83`). Explicitly *not* a functional-equivalence
  check ("would appear to require Gröbner basis techniques", `:1034-1036`).
- `entails(other)` (`semantic.rs:187-210`): naive exponential boolean-constraint recursion
  (`first_constraint`/`satisfy_constraint`, `:230-264`), gives up (`None`) above
  `ENTAILMENT_MAX_TERMINALS = 20` (`policy/mod.rs:32`).
- Timelock queries: `relative_timelocks`/`absolute_timelocks` (`:901-925`), and **temporal
  projections** `at_age` / `at_lock_time` (`:929-981`) which prune timelocked-away branches
  to `Unsatisfiable` and then re-normalize.
- Key stats: `n_keys` (`:985-989`), `minimum_n_keys` (`:997-1028`).

### 1.2 Concrete policy (`policy/concrete.rs`)

`concrete::Policy<Pk>` is the *compilation input* AST — one level closer to script, and
annotated for optimization (`concrete.rs:47-74`):

- Same 10 leaf variants as semantic, but **three** combinators:
  - `And(Vec<Arc<Self>>)` (`:68`) — conjunction.
  - `Or(Vec<(NonZeroU32, Arc<Self>)>)` (`:71`) — disjunction **with per-child integer odds**
    (the `@N` annotations, default 1; parsed at `:1048-1062`). These odds are the only
    probability information the compiler gets.
  - `Thresh(Threshold<Arc<Self>, 0>)` (`:73`).
- Code comment at `concrete.rs:44-46`: `And`/`Or` are *in practice limited to 2 elements*
  (a "general miniscript thing"); the parser enforces exactly-two children
  (`verify_n_children(…, 2..=2)`, `:1101`, `:1107`) and the compiler re-checks binariness
  (`check_binary_ops`, `:204-217`, errors `NonBinaryArgAnd`/`NonBinaryArgOr`).

### 1.3 The pipeline between the two ASTs (important: it is one-directional)

There is **no semantic→concrete conversion** — the two are parallel front-ends, not
compilation stages of each other:

- `concrete::Policy::from_str` parses the annotated form directly (and runs
  `check_timelocks` at parse time, `concrete.rs:1007-1015`).
- The bridge is `Liftable` (`policy/mod.rs:50-53`), going **from** concrete (or from an
  actual `Miniscript`/descriptor) **to** semantic, discarding information:
  `Concrete::lift` (`mod.rs:193-227`) maps `And→Thresh(k=2)`, `Or→Thresh(k=1)` (dropping
  odds), recurses, then `.normalized()`. `Miniscript::lift` (`mod.rs:110-174`) does a
  post-order fold mapping every fragment (`AndV/AndB→and`, `AndOr→or(and(a,b),c)`,
  `Multi*`→`Thresh` of `Key`s, wrapper fragments dropped, etc.).
- The stated invariant (`mod.rs:37-39`): `Lift(Concrete) == (Concrete → Miniscript → Script
  → Miniscript) → Semantic`, modulo resource limits — i.e. compilation must be *semantics-
  preserving*, tested via `policy.lift().sorted() == ms.lift().sorted()` round-trips
  (`compiler.rs:1226-1232`).
- Lifting can fail with `LiftError::{HeightTimelockCombination, BranchExceedResourceLimits,
  RawDescriptorLift}` (`mod.rs:56-64`); `Miniscript::lift_check` (`mod.rs:99-107`) refuses
  mixed timelocks (`has_mixed_timelocks`, via `TimelockInfo::contains_unspendable_path`,
  `miniscript/analyzable.rs:45`).

So the "normalization pipeline" is: **parse concrete (validated) → compile → Miniscript**;
**lift anything → semantic for analysis**; normalization (`normalized`/`sorted`) lives
entirely on the semantic side.

### 1.4 Validity pre-pass on concrete policies

`is_valid()` (`concrete.rs:877-881`) =
- `check_timelocks` (`:818-825`): builds a bottom-up `TimelockInfo` (`timelock_info`,
  `:833-871`; combination logic `TimelockInfo::combine_threshold`,
  `miniscript/types/extra_props.rs:55-84`): for k>1 combinators, flags any branch where
  height-based and time-based locks of either kind (CLTV or CSV) would have to hold
  simultaneously = provably unspendable path.
- `check_duplicate_keys` (`:799-809`): rejects repeated keys (needed for soundness of the
  Taproot internal-key extraction trick, §2.4, and sane multi()s).

---

## 2. The compiler (`feature = "compiler"`)

### 2.0 Entry points and shared prelude

- `Policy::compile<Ctx: ScriptContext>() -> Result<Miniscript<Pk, Ctx>, CompilerError>`
  (`concrete.rs:489-498`) — generic over context (`Legacy`, `Segwitv0`, `Tap`).
- `Policy::compile_to_descriptor::<Ctx>(DescriptorCtx)` (`concrete.rs:461-480`) wraps
  `compile` for `Bare/Sh/Wsh/ShWsh` and dispatches `Tr` to the taproot compiler.
- Taproot entries: `compile_tr` (`:283-322`), `compile_tr_native` (`:333-389`),
  `compile_tr_private_experimental` (`:410-448`). See §2.4.

Every entry runs the same prelude:
1. `is_valid()` (timelocks + duplicate keys),
2. `check_binary_ops()` (`concrete.rs:204-217`),
3. `is_safe_nonmalleable()` (`concrete.rs:890-930`) returning `(signed, non_malleable)`
   computed bottom-up: leaves are signed iff `Key`; `And` needs ≥1 signed child and all
   children non-malleable; `Or` needs *all* branches signed and all non-malleable;
   `Thresh` needs `signed_count ≥ n−k+1` (signed) and `signed_count ≥ n−k &&
   non_mall_count == n` (non-malleable) (`:913-923`). Failures map to
   `TopLevelSigless` / `ImpossibleNonMalleableCompilation` *before* any search.

### 2.1 Core algorithm: dynamic programming over (policy, p, q) cells

`best_compilation` (`compiler.rs:1120-1134`) kicks off with **sat_prob = 1.0,
dissat_prob = None** and delegates to `best_t`/`best_compilations`:

- `best_compilations(policy_cache, policy, sat_prob, dissat_prob)` (`compiler.rs:915-1117`)
  computes, for each sub-policy **and each probability context**, a Pareto frontier of
  compilations. It is memoized in
  `PolicyCache = BTreeMap<(Concrete, PositiveF64, Option<PositiveF64>), BTreeMap<CompilationKey, AstElemExt>>`
  (`compiler.rs:23-26`) — the DP has *two axes*: the sub-policy and the pair
  (satisfaction probability p, optional dissatisfaction probability q).
- `AstElemExt` (`:473-480`): a candidate partial `Miniscript` (wrapped in `Arc`) plus its
  `CompilerExtData` cost record.
- `CompilationKey` (`:266-299`) = `(ty: Type, expensive_verify: bool, dissat_prob)` where
  `ty` is the full Miniscript type (`types::Type`, base/corr/etc.) and `expensive_verify`
  is `!ext.has_free_verify` (`:273-278`, built at `:823`). `is_subtype` (`:289-293`)
  compares keys component-wise with `Type::is_subtype`.

**Cost model** — `CompilerExtData { sat_cost, dissat_cost }` (`:301-310`), constants per
fragment (context-dependent signature sizes: ECDSA sig ≈ 73 B, Schnorr ≈ 66 B — `pk_k`
`:317-325`, `pk_h` `:327-340`, `multi` `:342-344`, `multi_a` `:346-351`, `hash` `:353`,
`time` `:355`) and per-combinator weighted cost functions (`and_b/and_v/and_n` `:381-397`,
`or_b/or_d/or_c/or_i` `:399-441`, `and_or` `:443-452`, `threshold` — expected cost with
k/n weighting — `:454-470`, and all casts `:357-379`).
The scalarized objective is `AstElemExt::cost_1d(p, q)` (`:483-495`):

```
cost = ms.ext.pk_cost                       // script-size bytes (ExtData, miniscript/types/extra_props.rs:143-162)
     + sat_cost  * p
     + { q * dissat_cost , q=Some, dissat exists
       { INFINITY        , q=Some, no dissat possible
       { 0               , q=None
```

i.e. **expected spending weight = static script bytes + probability-weighted witness
bytes for satisfaction and dissatisfaction** (matches `doc/compiler.md`:
`spending_weight = spk_cost + witness_cost`). `PositiveF64`
(`primitives/positive_f64.rs:27-121`) is the "probability" type: an `Ord`/`Eq`/`Hash`
newtype over `f64 > 0` with saturating arithmetic (`MIN_POSITIVE` floor), helpers
`conditional_add` (`:55`), `normalized_iter` (odds → probabilities, `:73-81`),
`k_over_n` / `one_minus_k_over_n` (`:90-105`).

**Pruning / "Ord wrappers"** — `insert_elem` (`:796-845`) is the frontier maintainer:
1. drops malleable candidates outright (`:813-815`),
2. drops context-invalid candidates (`Ctx::check_local_validity`, `:817-819`) — this is
   where consensus/standardness resource limits are enforced,
3. keeps a dominance-closed set: a new element is rejected if any existing entry whose
   `CompilationKey` is a *subtype* of it costs ≤ it (`:828-831`); otherwise all entries
   dominated by the new one are evicted (`:835-841`). BTreeMap keying relies on `Ord`
   derivations on `CompilationKey`, `Type`, and `PositiveF64` — the "smallest" candidate
   comparisons later happen via `min_by_key(PositiveF64::new(cost_1d(…)))` in
   `best_t`/`best` (`:1151`, `:1176`). Comment at `:796-803` documents the frontier
   invariant (subtyping beatings).

**Cast closure** — wrappers are explored systematically: `all_casts()` (`:731-794`) lists
the 10 wrapper transforms used (`Check`, `DupIf`, `cast_likely` = `or_i(X, false)`,
`cast_unlikely` = `or_i(false, X)`, `Verify`, `NonZero`, `cast_true` = `and_v(X, true)`,
`Swap`, `Alt`, `ZeroNotEqual`), each a `Cast {node, ast_type, ext_data, comp_ext_data}`
quadruple (`:708-729`). `insert_elem_closure` (`:847-878`) BFS-expands the closure of
each inserted candidate under all casts; `insert_best_wrapped` (`:880-911`) additionally
re-casts the `dissat=None` compilation of the same policy when the current cell has
q=Some (wrappers like `l:`/`d:` that *manufacture* a dissat path, see comment
`:880-888`).

### 2.2 Per-variant compilation stages (inside `best_compilations`)

- **Leaves** (`:939-957`): direct `AstElemExt` constructors (`unsatisfiable`, `trivial`,
  `pk_h` and `pk_k` for `Key`, timelocks with zero sat-cost / no dissat, hashlocks …).
- **`And(subs)`** (`:957-994`): children compiled at both (p,q) and (p,None); crosses the
  four Cartesian products with `and_b` (both orders — left/right swap allowed but kept as
  separate loop for output stability, comment `:985-988`), `and_v` (both orders) and
  `and_n` (`and_n` = `andor(a,b,0)`, `:592-601`).
- **`Or(subs)`** → `best_compilations_or` (`:104-238`):
  - odds normalized to `lw`, `rw` (`:112-114`) via `PositiveF64` division;
  - **andor special case**: when a branch is itself an `And`, compile
    `or(and(a,b),c)`/`or(c,and(a,b))` as `Miniscript andor(a,b,c)` for *all* combinations
    of (a-with/without-dissat) × b × c (`:143-186`, `insert_ternary` `:117-141`);
  - otherwise build the lattice of per-side dissat probabilities
    `{q + w·p, w·p, q, None}` (`:188-195`), recurse for each, and cross both orientations
    into `or_b`, `or_d`, `or_c`, and two `or_i` orientations (`:226-235`).
- **`Thresh(k, subs)`** (`:998-1110`):
  - per-branch probability splitting: each sub gets `sat = p·k/n` and
    `dissat = q + p·(1−k/n)` (with the q/None cases handled piecewise, `:1010-1017`);
  - **E/W swap heuristic**: compile every child as best E-type and best W-type
    (`best()`, `:1155-1178`, filters `ty.corr.base`, `unit`, unique-dissat), then swap
    into the **first** (E) position the child for which E-over-W advantage is *minimal*
    (`:1026-1056`) — Miniscript `thresh` requires the first child to be E and the rest W;
  - `CompilerExtData::threshold` averages sat/dissat costs over k/n (`:454-470`), then
    the assembled `Terminal::Thresh` is validated (`Miniscript::from_ast`) and inserted
    (`:1058-1064`);
  - **multisig shortcut**: if all children are keys, try `multi_a` under Schnorr /
    `multi` under ECDSA contexts (n capped via `set_maximum` against
    `MAX_PUBKEYS_IN_CHECKSIGADD` / `MAX_PUBKEYS_PER_MULTISIG`, `:1066-1090`);
  - **k==n rewrite**: `thresh(n, …)` is rewritten into a left-folded binary `And` chain
    and *recompiled* through the cache (`:1091-1097`);
  - known gap: no symmetric special-casing for k==1 (`FIXME`, `:1099`).

- **Selection**: `best_t` (`:1137-1153`) filters the root cell for base-B candidates with
  matching q and picks `min cost_1d`; `best_compilation` then enforces the root-level
  safety postcondition (`:1125-1133`): malleable ⇒ `ImpossibleNonMalleableCompilation`
  (unreachable by construction, per the comment), non-malleable-but-unsigned ⇒
  `TopLevelSigless`.
- **Limits**: if a cell ends up empty — everything pruned by
  `Ctx::check_local_validity` — the error is `LimitsExceeded` (`:1105-1112`, with a
  comment explaining this is the only possible cause given the non-malleability pre-check).
- The result is memoized back into `policy_cache` (`:1114`).

### 2.3 Properties of the search

Per `doc/compiler.md`: this is "essentially a brute force based algorithm with some
heuristics to reduce the search space", exploring the fragment space per
(sub-policy, type-class, p, q) cell and minimizing **expected spending weight**. It is
*not* globally optimal in all cases (e.g. it will not fall back to heavier-but-lower-
opcode sub-compilations if the heavyweight cell winner violates limits — it just fails
with `LimitsExceeded`; it does not optimize 1-of-n ors or split threshes), and its
output is deliberately **not a stable identifier** (may differ across versions/machines;
see the NOTE at `concrete.rs:455-459` and the doc).

### 2.4 Taproot-specific stage (taptree construction + internal-key selection)

`compile_tr` (`concrete.rs:283-322`):

1. Shared prelude (validity, binary ops, safe-non-malleable).
2. `tapleaf_probability_iter()` (`:242-244`, iterator `TapleafProbabilityIter`
   `:170-200`) flattens the policy along `Or`/1-of-n `Thresh` into `(probability, leaf
   policy)` pairs by **multiplying odds down the tree** (odds normalized per level via
   `PositiveF64::normalized_iter`); doc `:219-244` with the 2/3·1/3 example; capped
   later at `MAX_COMPILATION_LEAVES = 1024` (`:39`, `check_num_tapleaves` `:789-796`).
3. `extract_key(unspendable_key)` (`:248-263`): **elects the highest-probability bare
   `Key` leaf as the internal key**; if none, uses the caller-supplied
   `unspendable_key`; else `NoInternalKey`. This is the only "unspendable-key"
   mechanism — there is **no NUMS-point derivation** in the crate; the caller must supply
   the key (generic `Pk`; `Descriptor::new_tr` later rejects uncompressed keys ⇒
   `UncompressedTaprootInternalKey`, mapped at `:318`). The elected key is then erased
   from the script tree by `translate_unsatisfiable_pk` (`:746-771`), turning its `Key`
   nodes into `Unsatisfiable` (sound because `check_duplicate_keys` forbids repeats),
   and that leaf is skipped during compilation (`:299-303`). Result can be a bare
   key-spend `tr(key)` (`:294-295`) or internal key + tree.
4. Each surviving leaf is compiled with the standard engine `compiler::best_compilation
   ::<Pk, Tap>` (`:304`).
5. `with_huffman_tree` (`:1149-1170`) builds the `TapTree` by Huffman merging the two
   **least probable** nodes first from a `BinaryHeap<(Reverse<PositiveF64>, TapTree)>`
   min-heap — probability descending to the shallowest nodes. This is the only
   "entropy-adjacent" structure (Huffman = entropy-optimal expected depth ⇒ expected
   control-block size); errors map to `HuffmanTreeDepthExceeded` (`:309`), enforced via
   `TapTree::combine` depth checking.
6. `Descriptor::new_tr(internal_key, tree)` (`:292`) assembles the descriptor.

Variants on this stage:
- `compile_tr_private_experimental` (`concrete.rs:410-448`): replaces step-2 flattening
  with a fixed-point enumeration `enumerate_policy_tree`/`enumerate_leaves`
  (`:585-695`): a `BTreeSet<(Reverse<PositiveF64>, Arc<Policy>)>` frontier plus a
  policy→probability `BTreeMap` that **merges duplicate enumerated policies by summing
  probabilities** (`:676-689`); general k-of-n `Thresh` is expanded combinatorially by
  `generate_combination` (`:1180-1200`) — `thresh(k, n) = or of n × thresh(k, n−1)`,
  each with prob/n — then recursed on. Same Huffman step afterward.
- `compile_tr_native` (`:333-389`): like the experimental one but `enumerate_pol_native`
  (`:535-576`) additionally **distributes `And` over `Or`** (cross product) so every leaf
  is IF-free; rejects leftovers containing `OP_IF`/`NOTIF`-implementing fragments
  (`has_if_fragment`, `:1133-1145` → `IfFragmentInNativeLeaf`) and respects a caller
  `max_leaves` cap clamped to 1024 (`:341`, `TooManyTapleaves`).

---

## 3. Outputs and guarantees

### 3.1 Type of output

- `compile<Ctx>()` → `Miniscript<Pk, Ctx>` (`compiler.rs:1120-1134`), internally the
  `Arc<Miniscript>` of the best `AstElemExt`.
- Taproot paths → `Descriptor::Tr` (internal key + Huffman `TapTree`).

### 3.2 What is optimized ("optimal"?)

The objective is **expected spending weight** = static script-size contribution
(`ExtData::pk_cost`, `miniscript/types/extra_props.rs:145`) + `p·(witness sat bytes)` +
`q·(witness dissat bytes)` (`cost_1d`, `compiler.rs:486-495`) with odds from the
concrete policy normalized to probabilities, defaulting to equal odds (`@1`) when the
user gives none (`concrete.rs:1057-1062`). Within the fragment space actually explored
(Cartesian products per node × 10-cast closures × orientation swaps × multi/multi_a
special cases), the DP per (policy, p, q) cell is *exact*; globally it is a **best-
effort optimizer, not provably minimal** — `doc/compiler.md` is explicit that it does not
guarantee the most efficient miniscript, and does not backtrack across cells when the
locally optimal choice violates resource limits (it fails with `LimitsExceeded` instead;
see also the known issue ref at `compiler.rs:1473`, rust-miniscript#114, where large-n
thresh with k∈{1,2} fails to compile under Segwitv0 limits).

Taproot adds a second optimization axis: the Huffman tree minimizes expected
control-block depth given leaf probabilities (`with_huffman_tree`), while `extract_key`
moves the likeliest single-key path into the key-spend path (cheapest spend).

### 3.3 Satisfiability/safety guarantees

If the compiler returns a `Miniscript` at all (per doc/compiler.md "compiler guarantees"):

- **Valid Miniscript** (all fragments type-checked at construction:
  `AstElemExt::compose_typeck_only` runs `Type::type_check` + `ExtData::type_check`,
  `compiler.rs:562-570`; casts apply their type transforms, `:718-729`) and within the
  target context's consensus+standardness limits (`Ctx::check_local_validity` filter,
  `compiler.rs:817-819`).
- **Non-malleable**: malleable candidates are never inserted (`compiler.rs:813-815`), the
  root is re-checked (`:1125-1133`), and the whole policy is pre-screened by
  `is_safe_nonmalleable` (`concrete.rs:883-930`) so *every satisfaction path* of the
  compiled script is non-malleable.
- **Top-level requires a signature** (`TopLevelSigless` otherwise) — the
  `NonMalleable { signed }` property at the root.
- **Semantics-preserving**: enforced by design via the mod.rs:39 invariant and tested by
  `lift`-roundtrip equality up to `sorted()` (`compiler.rs:1226-1232`); Taproot variants
  are cross-checked for semantic equivalence via `entails` (`mod.rs:576-588` etc.).
- **Not deterministic / not a stable ID** (doc/compiler.md "Non-determinism and
  stability guarantees"; `concrete.rs:457-459`): different versions can produce different
  but equally valid scripts.

### 3.4 Entropy/probabilities

There is **no entropy source or randomness** anywhere in `src/policy/` (no RNG
dependencies). "Probability" is purely user-supplied branch odds (`or(N@…,M@…)`)
converted to `PositiveF64` weights; everything downstream (DP costs, Huffman tree, leaf
probabilities) is deterministic arithmetic on those odds.

---

## 4. Compile-time failure conditions

### 4.1 `CompilerError` (`compiler.rs:28-65`)

| Variant | Raised at | Condition |
|---|---|---|
| `NonBinaryArgAnd` / `NonBinaryArgOr` | `concrete.rs:204-217` | programmatically built `And`/`Or` with ≠ 2 children (parser can't produce these) |
| `TopLevelSigless` | `concrete.rs:494`, `compiler.rs:1129-1131` | some top-level satisfaction path requires no signature (e.g. bare `after(…)`, `sha256(…)`; tests `compiler.rs:1255-1271`) |
| `ImpossibleNonMalleableCompilation` | `concrete.rs:495`, `compiler.rs:1128` | policy has no all-non-malleable satisfaction set (e.g. `and(pk(A),or(after(9),after(9)))`, test `:1273-1276`) |
| `LimitsExceeded` | `compiler.rs:1105-1112`, `:1152`, `:1177` | every candidate in some DP cell was pruned by `Ctx::check_local_validity` (script size / ops / stack / height limits); also root selection with no valid typed candidate. Known case: large k-of-n under Segwitv0 (`compiler.rs:1500-1599` tests) |
| `NoInternalKey` | `concrete.rs:261` | taproot compile with no in-policy key and no caller-supplied unspendable key |
| `UncompressedTaprootInternalKey` | `concrete.rs:318`, `:385` | `Descriptor::new_tr` rejected the chosen/supplied key as uncompressed |
| `HuffmanTreeDepthExceeded` | `concrete.rs:309` | Huffman merging would exceed taptree depth 128 |
| `TooManyTapleaves { n, max }` | `concrete.rs:359`, `:790-796` | root-level disjunction enumeration exceeds `MAX_COMPILATION_LEAVES` (or caller cap; cap 0 is an immediate error, `:338-340`) |
| `IfFragmentInNativeLeaf { leaf_index }` | `concrete.rs:366-371` | native-compiled leaf still contains `OP_IF/NOTIF` fragments (enumeration budget too small) |
| `PolicyError(..)` | `concrete.rs:284`, `:465`, etc. | wraps `PolicyError::{HeightTimelockCombination, DuplicatePubKeys}` (`concrete.rs:124-130`): timelock conflict = a satisfaction path needing height- and time-based locks simultaneously (detected via `timelock_info`/`combine_threshold` — `concrete.rs:833-871`, `extra_props.rs:55-84`); duplicate keys = `check_duplicate_keys` (`:799-809`) |

Related (not compiler) errors: `LiftError::{HeightTimelockCombination,
BranchExceedResourceLimits, RawDescriptorLift}` (`policy/mod.rs:56-64`) and
`ThresholdError` (`primitives/threshold.rs:17-37`: empty threshold, k=0, k>n, n>MAX).

### 4.2 Where timelock incompatibility is decided

The "incompatible timelocks" failure class is *not* something the DP discovers during
search — it is rejected up front:

- at **parse** of concrete policies (`concrete.rs:1012`),
- at every **compile entry** via `is_valid()` (`concrete.rs:284`, `:342`, `:414`, `:465`,
  `:491`),
- and at **lift time** for miniscripts/descriptors (`mod.rs:99-107`).

The criterion itself (same `TimelockInfo` machinery shared with the miniscript type
system): within any k>1 combinator (`And`, or `Thresh`/`Or` seen as k=n / k=1
respectively — for `Or` k=1 so no check), two branches that must hold jointly may not
mix {height,time}×{CLTV,CSV} (`extra_props.rs:55-84`). E.g.
`and(after(10),after(500000000))` is rejected (`mod.rs:269`), and the compiler test
`compiler.rs:1235-1251` confirms an `and(pk, or(and(after(9),pk),and(after(1e9),pk)))`
shape compiles because the conflicting locks are in different disjunctive branches.

---

## 5. Cross-cutting summary for the Lean formalization

- Two ASTs: **semantic** = pure boolean logic normalized into a single `Thresh`
  combinator (analysis/normalization/entailment home); **concrete** = compilation
  surface with binary `And`/`Or` + odds annotations. Bridge is one-way `lift`, with
  `Lift(Concrete) == Lift(Script(compile(Concrete)))` as the informal correctness
  invariant (`mod.rs:37-39`).
- Compilation = DP over (sub-policy, sat-prob p, dissat-prob q) cells; each cell holds a
  Pareto frontier keyed by `(Type, has_free_verify, q)` (`CompilationKey`) with
  subtype-dominance pruning; per-node exploration = Cartesian composition × 10 wrapper
  casts × orientation swaps; scalar objective = expected script+witness weight; leaves
  and multisig shortcuts special-cased; k-of-n gets an E/W-swap heuristic; k=n rewritten
  as nested ands.
- Taproot = probability-flattened leaf enumeration (multiplicative odds) + internal-key
  election (highest-probability key; else caller's key — no NUMS derivation) + key-erasure
  from leaves + Huffman tree over leaf probabilities. Alternatives: fixed-point full
  enumeration (experimental) and And-over-Or distribution with IF-free leaves (native).
- Guarantees on success: valid, in-limits, non-malleable, signature-requiring,
  semantics-preserving miniscript; **not** guaranteed globally optimal, **not** stable
  across versions, deterministic given inputs, no randomness.
