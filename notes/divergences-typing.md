# Miniscript *typing* divergence report: Bitcoin Core (C++) vs rust-miniscript (Rust)

READ-ONLY comparison. No repository was modified; the only file written is this report.

**Trees compared**

- **Spec** (neutral reference): `notes/sipa-spec.md` — verbatim mirror of https://bitcoin.sipa.be/miniscript/ fetched 2026-10-21.
- **Core**: `bitcoin-core/` @ `f86c614e69256b9814c27b0dd096ee46daa71aa3`
  - type system: `src/script/miniscript.cpp` (`SanitizeType` L19–37, `ComputeType` L39–262), `src/script/miniscript.h` (Type bitmap L130–191, parser L1756–2211, decoder L2294–2703, validity/sanity L1674–1702), `src/script/script.h` L35–38 (multi key caps).
- **Rust**: `rust-miniscript/` @ `96a1c917dacc539f57c13bbcf9dc8e4fd443377a` (uses rust-bitcoin 0.32.x)
  - type system: `src/miniscript/types/correctness.rs`, `src/miniscript/types/malleability.rs`, `src/miniscript/types/mod.rs`, plus `src/miniscript/types/extra_props.rs` (timelock info), `src/miniscript/context.rs` (context gates), `src/miniscript/decode.rs` (script→AST), `src/miniscript/mod.rs` (string→AST, `from_ast`, `validate`), `src/validation.rs`, `src/primitives/{absolute,relative}_locktime.rs`, `src/primitives/threshold.rs`.

**Citation shorthands used below**

| Prefix | File |
|---|---|
| `S` | `notes/sipa-spec.md` |
| `C.cpp` / `C.h` | `bitcoin-core/src/script/miniscript.cpp` / `miniscript.h` |
| `C.script.h` | `bitcoin-core/src/script/script.h` |
| `R.corr` / `R.mall` / `R.types` / `R.ext` | `rust-miniscript/src/miniscript/types/{correctness,malleability,mod,extra_props}.rs` |
| `R.ctx` | `rust-miniscript/src/miniscript/context.rs` |
| `R.dec` | `rust-miniscript/src/miniscript/decode.rs` |
| `R.mod` | `rust-miniscript/src/miniscript/mod.rs` |
| `R.val` | `rust-miniscript/src/validation.rs` |
| `R.expr` | `rust-miniscript/src/expression/mod.rs` |
| `R.abs` / `R.rel` / `R.thr` | `rust-miniscript/src/primitives/{absolute_locktime,relative_locktime,threshold}.rs` |
| `R.lim` | `rust-miniscript/src/miniscript/limits.rs` |
| `R.ana` | `rust-miniscript/src/miniscript/analyzable.rs` |

**Property-letter correspondence** (used to line the two implementations up)

| prop | Core | Rust |
|---|---|---|
| base | `'B'/'V'/'K'/'W'` bits | `corr.base` (`Base::{B,K,V,W}`, R.corr:9–27) |
| `z`/`o`/`n` | bits (C.h:171–173) | `corr.input`: `Zero=z`, `One=o`, `OneNonZero=on`, `AnyNonZero=n`, `Any=∅` (R.corr:32–46; display R.types:170–176) |
| `d`/`u` | bits | `corr.dissatisfiable` / `corr.unit` (R.corr:86–94) |
| `m` | bit | `Malleability::NonMalleable{..}` vs `Malleable` (R.mall:63–78, `is_non_malleable` R.mall:89) |
| `s` | bit | `NonMalleable::signed` (R.mall:70–77) |
| `f` | bit | `NonMalleable{dissat: None}` (R.mall:15) |
| `e` | bit | `NonMalleable{dissat: Unique}` (R.mall:22) |
| `x` ("expensive verify") | bit | `!ext.has_free_verify` (R.ext:147) |
| `g`/`h`/`i`/`j` | bits: csv-time/csv-height/cltv-time/cltv-height (C.h:181–184) | `ext.timelock_info.{csv_with_time,csv_with_height,cltv_with_time,cltv_with_height}` (R.ext:16–24) |
| `k` (no height/time mixing) | bit | `!ext.timelock_info.contains_combination` (R.ext:26) |

⚠️ Two naming traps: Core's `Type` letter `j` (C.h:184) is the CLTV-*height* flag, unrelated to the `j:` wrapper; and Core's `k` letter (timelock-no-mix) is unrelated to `thresh`/`multi`'s `k` argument.

---

## 1. Master per-fragment table

Columns: fragment · spec `Requires` · Core requirement · rust requirement · spec computed props · Core computed props · rust computed props · divergence. Property strings are the *net* computed set for a well-typed node (Core's extra `x`,`k` bits and rust's `ExtData` are included only when informative). Divergence IDs refer to §3.

### Leaves

| Fragment | Spec Requires / props | Core Requires / computed | Rust Requires / computed | Divergence |
|---|---|---|---|---|
| `0` | — · B; z u d · mal s,e (S122, S290) | leaf · `"Bzudemsxk"` C.cpp:104 → B z u d + e s m (+x,k) | leaf · `corr::FALSE` R.corr:103–104 + `mall::FALSE` R.mall:85 → B z u d + e s m; ext x, ¬combo (R.ext:164–178) | none |
| `1` | — · B; z u · mal f (S123, S291) | leaf · `"Bzufmxk"` C.cpp:103 → B z u + f m (+x,k) | leaf · R.corr:99–100 + R.mall:82 → B z u + f m; ext (R.ext:181–195) | none |
| `pk_k` | — · K; o n d u · mal s,e (S124, S292) | leaf 1 key (C.cpp:73–74) · `"Konudemsxk"` C.cpp:89 → K o n d u + e s m (+x,k) | leaf · `pk_k()` R.corr:136–138 (K/OneNonZero/d/u) + R.mall:130 → K o n d u + e s m; ext x (R.ext:202–211) | none |
| `pk_h` | — · K; n d u · mal s,e (S125, S293) | leaf · `"Knudemsxk"` C.cpp:90 → K n d u + e s m (+x,k) | leaf · `pk_h()` R.corr:141–148 (K/AnyNonZero/d/u; FIXME-comment L145 only) + R.mall:133 → same; ext x (R.ext:246–248) | none; rust-only sibling `RawPkH` maps to this type (R.types:475) — see D3 |
| `older(n)` | 1≤n<2³¹ (S126, S42) · B; z · mal f (S294) | parse `*num<1 \|\| ≥0x80000000` C.h:2033–2034; ctor `CHECK_NONFATAL(k≥1 && k<0x80000000)` C.cpp:50–51; decode C.h:2346–2349 · `"Bzfmxk"` + `g` if bit22 set / else `h` C.cpp:91–94 | `RelLockTime::from_consensus` = bit31-clear ∧ ≠0 R.rel:42–44, 85–94; text R.expr:364–374; decode R.dec:447–448 · `Type::time()` R.corr:176–178, R.mall:155 → B z + f m; ext `csv_with_{height,time}` R.ext:478–501 | D2 (programmatic `older(0)` in rust) |
| `after(n)` | 1≤n<2³¹ (S126, S42) · B; z · mal f (S295) | parse C.h:2026–2027; ctor C.cpp:50–51; decode C.h:2352–2356 · `"Bzfmxk"` + `i` if k≥500M / else `j` C.cpp:95–98 | `AbsLockTime::from_consensus` ∈ [1, 0x7FFF_FFFF] R.abs:51–57 (MIN L17, MAX L10); text R.expr:347–357; decode R.dec:449–450 · same `Type::time()`; ext `cltv_with_{height,time}` R.ext:453–476 (split at is_block_height < 500M, R.ext:470–471) | none |
| `sha256(h)` | — (h is 32B) · B; o n d u · mal — (S127, S296) | `data_size==32` C.cpp:42–43 · `"Bonudmk"` C.cpp:99 → B o n d u + m (+k; no x — ends in `OP_EQUAL`) | fixed hash type · `Type::hash()` R.corr:171–173 + R.mall:152 → B o n d u + m; ext free-verify (R.ext:352–354) | none |
| `hash256(h)` | — · B; o n d u · mal — (S129, S298) | `data_size==32` C.cpp:42–43 · `"Bonudmk"` C.cpp:101 | `Type::hash()` (R.corr:171–173, R.mall:152); ext R.ext:377–399 | none |
| `ripemd160(h)` | — (h is 20B) · B; o n d u · mal — (S128, S297) | `data_size==20` C.cpp:44–45 · `"Bonudmk"` C.cpp:100 | `Type::hash()`; ext R.ext:402–425 | none |
| `hash160(h)` | — · B; o n d u · mal — (S130, S299) | `data_size==20` C.cpp:44–45 · `"Bonudmk"` C.cpp:102 | `Type::hash()`; ext R.ext:428–451 | none |

(Note: Core letter set’s `f` for `0` — absent, matches spec: `0` is "s,e" only. Core outputs for `0`/`1` add `m`,`x`,`k`; rust carries the same information split between `Malleability` and `ExtData`.)

### Combinators

| Fragment | Spec Requires / props | Core Requires / computed | Rust Requires / computed | Divergence |
|---|---|---|---|---|
| `and_v(X,Y)` | X is V; Y ∈ {B,K,V} → type of Y (S132) · z=zX·zY; o=zX·oY+oX·zY; n=nX+zX·nY; u=uY · mal: s=sX+sY; f=sX∨fY (S301) | `(y & "KVB").If(x<<"V")` C.cpp:144; n C.cpp:145; o C.cpp:146; z,m both, s either, f=fY+sX C.cpp:147–149; u,x from y C.cpp:150; ghij union + k with cross-conflict check C.cpp:151–156; `IsSane`… (script-len 0-add C.cpp:279) | `(V,B)→B,(V,K)→K,(V,V)→V` R.corr:337–342; input table (z/o/n formulas) R.corr:343–353; d=false; u=right.unit R.corr:354–355 · mall R.mall:239–256: NM iff both NM; f=fY∨sX; s=sX∨sY | none |
| `and_b(X,Y)` | X is B; Y is W → B (S133) · z,o,n as and_v; d=dX·dY; u · mal: s=sX+sY; f=fX·fY+sX·fX+sY·fY; e=eX·eY·sX·sY (S302) | `(x&"B").If(y<<"W")` C.cpp:158; o,n C.cpp:159–160; e C.cpp:161; d,z,m both C.cpp:162; f C.cpp:163; s either; +`ux` C.cpp:165; ghij+k-conflicts C.cpp:166–171 | `(B,W)→B` R.corr:313–317; input table R.corr:318–328; d=both, u=true R.corr:329–330 · mall R.mall:211–236 (e iff eX·eY·sX·sY L225–231; f L221–224; s=either L234) | none |
| `andor(X,Y,Z)` | X is Bdu; Y,Z both B/K/V → Y/Z's type (S131) · z=zX·zY·zZ; o=zX·oY·oZ+oX·zY·zZ; u=uY·uZ; d=dZ · mal req eX∧(sX+sY+sZ); s=sZ·(sX+sY); f=fZ·(sX+fY); e=eZ·(sX+fY) (S300) | `(y&z&"BKV").If(x<<"Bdu")` C.cpp:207; z all C.cpp:208; o C.cpp:209 (≡ spec given z⊥o, see §4.2); u,u C.cpp:210; f,d,e C.cpp:211–213; m C.cpp:214; s C.cpp:215; +x C.cpp:216; ghij union C.cpp:217; k: all-k ∧ ¬(X↔Y conflict) C.cpp:218–222 | a.d ∧ a.u (R.corr:451–456); (B,B,B)/(B,K,K)/(B,V,V) R.corr:458–463; input table = zX·(oY·oZ)+oX·(zY·zZ) R.corr:464–473; d=c.d; u=b.u∧c.u R.corr:474–475 · mall R.mall:334–357: NM iff eX∧(sX∨sY∨sZ) L343; f/e = eZ/fZ·(sX+fY) L347–354; s=(sX∨sY)∧sZ L355 | none |
| `or_b(X,Z)` | X is Bd; Z is Wd → B (S134) · z,o; d; u · mal req eX·eZ∧(sX+sZ); s=sX·sZ; e (S303) | `"B".If(x<<"Bd" && y<<"Wd")` C.cpp:173; o C.cpp:174; m iff both-e ∧ (s either) ∧ both-m C.cpp:175; z,s,e both C.cpp:176; +`dux` C.cpp:177; ghij, k=kX·kZ C.cpp:178–179 | req left.d, right.d (R.corr:361–366 = "Bd","Wd" d-part); `(B,W)→B` R.corr:368–371; input z/o R.corr:372–379; d=true,u=true R.corr:380–381 · mall R.mall:259–275: NM iff eX∧eZ∧(sX∨sZ) L267–272; e L274; s=both | none |
| `or_c(X,Z)` | X is Bdu; Z is V → V (S135) · z=zX·zZ; o=oX·zZ · mal req eX∧(sX+sZ); s=sX·sZ; f (S304) | `(y&"V").If(x<<"Bdu")` C.cpp:190; o C.cpp:191; m C.cpp:192; z,s both; +`fx` C.cpp:194; ghij; k both C.cpp:195–196 | req left.d∧left.u (R.corr:410–415); `(B,V)→V` R.corr:418; input o=oX·zZ, z=both-z R.corr:421–425; d/u false · mall R.mall:294–307: NM iff eX∧(sX∨sZ); f always; s=both | none |
| `or_d(X,Z)` | X is Bdu; Z is B → B (S136) · z; o=oX·zZ; d=dZ; u=uZ · mal req eX∧(sX+sZ); s=sX·sZ; f=fZ; e=eZ (S305) | `(y&"B").If(x<<"Bdu")` C.cpp:181; o C.cpp:182; m C.cpp:183; z,s both C.cpp:184; u,f,d,e from y C.cpp:185; +x C.cpp:186; ghij; k both C.cpp:187–188 | req left.d∧left.u (R.corr:387–392); `(B,B)→B` R.corr:395; input R.corr:398–402; d=right.d, u=right.u R.corr:403–404 · mall R.mall:278–291: NM iff eX∧(sX∨sZ); dissat=right (f/e from Z); s=both | none |
| `or_i(X,Z)` | both same type ∈{B,K,V} → same (S137) · o=zX·zZ; u=uX·uZ; d=dX+dZ · mal req sX+sZ; s=sX·sZ; f=fX·fZ; e=eX·fZ+eZ·fX (S306) | `(x&y&"VBKufs")` C.cpp:198 (common type; u,f,s both); o iff both z C.cpp:199; e cross C.cpp:200 (equivalent to spec because e⊥f, asserted C.cpp:29); m iff s either C.cpp:201; d either C.cpp:202; +x; ghij; k both C.cpp:203–205 | bases must match R.corr:434–439; input: (Zero,Zero)→One else Any = zX·zZ R.corr:440–443; d=either R.corr:444; u=both R.corr:445 · mall R.mall:310–331: NM iff sX∨sZ L318; f=fX·fZ, e=eX·fZ+eZ·fX L322–328; s=both | none (item f: no asymmetric rules anywhere) |
| `thresh(k,X1,…,Xn)` | 1≤k≤n; X1 is Bdu; Xi is Wdu → B (S138) · z=all z; o=all z but one o; d; u · mal req all e ∧ ≤k non-s; s=≤k−1 non-s (≥#s≥n−k+1); e=all s (S307) | ctor `1≤k≤n` C.cpp:54–55; per-child Bdu/Wdu else type ∅ C.cpp:237; props: `Bdu` + z iff args==0 + o iff args==1 (arg weight z→0,o→1,else2; C.cpp:241,252–254) + e iff all-e∧all-s C.cpp:255 + m iff all-e∧all-m∧#s≥n−k C.cpp:256 + s iff #s≥n−k+1 C.cpp:257; timelock union + pairwise conflicts only if k>1, and all children k C.cpp:234,242–250 | `Threshold::new`: 1≤k≤n, no MAX for Thresh (R.thr:46–52,67–70); child0 base B, others W; **plus** unit ∧ dissatisfiable per child R.corr:486–504; computed: B; input by same 0/1/2 arg weight R.corr:487–491,506–512; d,u true · mall R.mall:361–393: NM iff all-e ∧ all-NM ∧ #s≥n−k L369–378; e iff #s==n L386; s iff #s>n−k L391 | none |
| `multi(k,k1..kn)` | 1≤k≤n; B; n; d; u (S139) · mal s; e (S308) | 1≤k≤n_keys∧1≤n_keys≤20 C.cpp:52–53,75–76 + C.script.h:35; **P2WSH-only** (soft CHECK + parse/decode gates C.cpp:77, C.h:1880–1881, C.h:2380) · `"Bnudemsk"` C.cpp:224 → B **n** u d e m s (**n present ✓**) | `Threshold<Pk,20>` R.dec:155 + R.lim:35 + R.thr:46–52; Tap-context reject R.ctx:666–668 / `allow_multi` R.val:25–26,622–627 gates R.mod:423–426 · `multi()` R.corr:151–153 (B/AnyNonZero=n/d/u) + R.mall:135–136 → B n d u + e s m | none |
| `multi_a(k,k1..kn)` | 1≤k≤n; B; d; u (S140) · mal s; e (S309) | same bounds, n≤999 C.cpp:52–53,78–79 + C.script.h:38; **Tapscript-only** C.cpp:80 · `"Budemsk"` C.cpp:227 → B u d e m s (**no n ✓**) | `Threshold<Pk,999>` R.dec:159 + R.lim:38; non-Tap reject R.ctx:537–539 / `allow_multi_a` R.val:28 · `multi_a()` R.corr:160–163 (**Input::Any** → no n) + R.mall:144 → B d u + e s m | none |

### Wrappers

| Wrapper | Spec Requires / props | Core Requires / computed | Rust Requires / computed | Divergence |
|---|---|---|---|---|
| `a:X` | X is B → W (S141) · d=dX; u=uX · mal s,f,e propagate (S310) | `W`.If(x<<B); ghijk + udfems propagate; +x C.cpp:105–109 | B→W else `ChildBase1`; input→Any; d,u keep (R.corr:181–191); mall=self R.mall:158 | none |
| `s:X` | X is Bo → W (S142) · d,u propagate · mal propagate (S311) | `W`.If(x<<`Bo`); ghijk + udfemsx propagate C.cpp:110–113 | B→W; input∈{One,OneNonZero} else `SwapNonZero`→`SwapNonOne` R.corr:194–207; mall=self R.mall:161 | none |
| `c:X` | X is K → B (S143) · o=oX;n=nX;d=dX;u · mal s; f=fX; e=eX (S312) | `B`.If(x<<K); ghijk + ondfem propagate; +`us` C.cpp:114–118 (no x ✓ matches rust ext free-verify R.ext:534) | K→B; input keep (o,n); d keep; u=true (R.corr:210–220); mall=self R.mall:164 (s inherited — K implies signed, sanity R.types:220) | none |
| `d:X` | X is Vz → B (S144) · o;n;d;**(Tapscript only) u** · mal s=sX; e (S313) | `B`.If(x<<`Vz`) C.cpp:120; o=zX C.cpp:121; e=fX C.cpp:122; ghijk + m,s C.cpp:123–124; **u iff Tapscript**, with NOTE L125 C.cpp:126; +`ndx` C.cpp:127 | V→B; input must be Zero→OneNonZero else `NonZeroDupIf` R.corr:223–233; d=true; **`unit: false` unconditionally** R.corr:223–234–235; mall `cast_dissat_if_forced`: e iff child f (=None) R.mall:166–167,196–208 | **D1** [accept-set-differs] |
| `v:X` | X is B → V (S145) · z,o,n propagate · mal s=sX; f (S314) | `V`.If(x<<B); ghijk + zonms propagate; +`fx` C.cpp:128–132 | B→V; input keep; d,u false (R.corr:239–249); mall `with_dissat(None)` = f, signed keep R.mall:170,186–191 | none |
| `j:X` | X is Bn → B (S146) · o=oX;n;d;u=uX · mal s=sX; e=fX (S315) | `B`.If(x<<`Bn`) C.cpp:134; e=fX C.cpp:135; ghijk + o,u,m,s propagate C.cpp:137; +`ndx` C.cpp:138 | input must be OneNonZero/AnyNonZero else `NonZeroZero` R.corr:252–255; B stays; d=true; input,u keep R.corr:256–264; mall R.mall:172–173 → e=fX | none (item b) |
| `n:X` | X is B → B (S147) · z,o,n,d propagate; u · mal s,f,e propagate (S316) | ghijk + `Bzondfems` propagate; +`ux` C.cpp:139–142 | B stays; input,d keep; u=true (R.corr:268–278); mall=self R.mall:176 | none |

### Sugars (both sides lower them to the same desugared tree)

| Sugar | Spec | Core lowering | Rust lowering | Divergence |
|---|---|---|---|---|
| `pk(K)` = `c:pk_k(K)` ; `pkh(K)` = `c:pk_h(K)` | S65–66, S95 | parse builds `WRAP_C(PK_K)` / `WRAP_C(PK_H)` directly C.h:1983–1992; printing re-sugars C.h:911–923 | `Self::pk`/`Self::pkh` build `Check(pk_k/pk_h)` R.mod:157–176; parse names R.mod:1059–1066 | none |
| `t:X` = `and_v(X,1)` | S87 | `WRAP_T` → `AND_V(X, JUST_1)` C.h:2125–2127; print C.h:931 | wrapper char `b't'` → `AndV(new, TRUE)` R.mod:1169 (+compiler helper `cast_true` R.corr:281–291, R.mall:179 — verified ≡ expansion) | none |
| `u:X` = `or_i(X,0)` | S93 | `WRAP_U` → `OR_I(X, JUST_0)` C.h:2121–2123; print C.h:935 | `b'u'` → `OrI(new, FALSE)` R.mod:1170 (helper `cast_or_i_false` R.corr:293–309 — verified ≡) | none |
| `l:X` = `or_i(0,X)` | S92 | `l` pushes `JUST_0` then `OR_I` C.h:1964–1968; print C.h:934 | `b'l'` → `OrI(FALSE, new)` R.mod:1171 | none |
| `and_n(X,Y)` = `andor(X,Y,0)` | S76 | `AND_N` → `ANDOR(X,Y,JUST_0)` C.h:2133–2137; print C.h:966 | `"and_n"` → `AndOr(x,y,FALSE)` R.mod:1107–1109 | none |

**Net result of the master table:** exactly one property-formula divergence inside the shared language (D1), plus cross-cutting divergences D2–D9 listed below. Everything else — every `z/o/n/d/u/e/f/s/m` formula and every timelock-bit rule — is symbolically identical modulo the encodings in §0.

---

## 2. Quick answers to the special-attention questions

- **(a) `d:` `u` in Tapscript vs P2WSH** — **diverges (D1)**. Core grants `u` iff `IsTapscript` (C.cpp:125–127); rust never grants `unit` (R.corr:223–235), with no Tapscript override anywhere (`Terminal::DupIf` dispatch R.types:489), even though `allow_dup_if` is *allowed* in rust's Tap/Segwit contexts (gated only off for Legacy/Bare, R.ctx:373,751).
- **(b) `j:` interplay with `n`/`e`** — **no divergence**. Both require `Bn` (C.cpp:134; R.corr:252–255 rejecting `Input::{Zero,One,Any}`), both yield `n`,`d` and propagate `o`,`u`, and both compute `e=f_X` (C.cpp:135; R.mall:172–173 via `cast_dissat_if_forced` R.mall:196–208).
- **(c) `thresh` property formulas incl. arg counts** — **no divergence**. Identical per-child arg weighting (z=0, o=1, else 2; C.cpp:241 ↔ R.corr:487–491), `z=args==0`, `o=args==1`, children `Bdu`-then-`Wdu` (C.cpp:237 ↔ R.corr:492–503 which splits the B/W, d, u checks), `1≤k≤n` (C.cpp:54–55 ↔ R.thr:46–52), and `e/m/s` thresholds all match (C.cpp:255–257 ↔ R.mall:377–391).
- **(d) `multi` vs `multi_a` property sets** — **`multi` has `n`, `multi_a` doesn't — in spec *and* both impls. No divergence.** Core `"Bnudemsk"` vs `"Budemsk"` (C.cpp:224,227); rust `Input::AnyNonZero` vs `Input::Any` (R.corr:151–153 vs 160–163). Yes: 'n' is present in Core's MULTI.
- **(e) timelock bits g/h/i/j ↔ `TimelockInfo`, and `k`/`contains_combination`** — **no divergence (identical math)**.
  - Leaf classification is bit-identical: `older` splits on bit22 `SEQUENCE_LOCKTIME_TYPE_FLAG` (C.cpp:92–93 ↔ R.rel:64–67 → rust-bitcoin `LOCK_TYPE_MASK=0x00400000`); `after` splits at 500 000 000 (C.cpp:96–97 ↔ R.ext:470–471 → rust-bitcoin `absolute::LockTime`).
  - `k` = ¬mixing: same per-fragment rules — AND-nodes (and_v/and_b) pairwise conflict check (C.cpp:152–156,167–171 ↔ R.ext `combine_and`→`combine_threshold(2,…)` R.ext:45–47,55–84); OR-nodes plain conjunction of children, no cross check (C.cpp:179,188,196,205 ↔ R.ext `combine_or`=`combine_threshold(1,…)` R.ext:50–52; used at R.ext:703,726,749,780); `thresh` pairwise check only when k>1 (C.cpp:246–250 ↔ R.ext:69–76); `andor` checks *X↔Y only* in **both** (C.cpp:218–222 ↔ `combine_or(combine_and(a,b),c)` R.ext:806–809) — see §4.1.
  - Core stores k in the type bitmap (bit 18, C.h:185); rust stores its negation in `ext.timelock_info.contains_combination` (R.ext:26; consumers: Core `CheckTimeLocksMix` C.h:1690 ↔ rust `has_mixed_timelocks` R.ana:45 + gate R.mod:399–401).
- **(f) `or_i` asymmetric rules** — **none, in any of the three sources.** All symmetric in requirements and props (e-formula `eX·fZ+eZ·fX` is itself symmetric; Core's formulation `((x|y)&"e").If((x|y)<<"f")` C.cpp:200 equals it only due to `e`⊥`f`, asserted in `SanitizeType` C.cpp:29 and structurally true in rust where `dissat` can't be both `None` and `Unique`).
- **(g) fragments existing in only one impl** — **D3**: rust has `SortedMulti`/`SortedMultiA` (R.dec:155–161; typed *identically* to `multi`/`multi_a`, R.corr:155–168, R.mall:138–149) and `RawPkH` (R.dec:100–105; typed as `pk_h`, R.types:475; sanity gate `allow_raw_pkh` R.val:33–34/R.mod:444–446; text name `expr_raw_pkh` R.mod:1055–1058). Core's `Fragment` enum has none of these (C.h:213–245) and there are no Core-only string-parseable fragments (Core's names C.h:1933–2084 ⊂ rust's names R.mod:1054–1143 + wrappers R.mod:1160–1172). *However* Core can decode the same *script* pattern `DUP HASH160 <h> EQUALVERIFY` into its `PK_H` node via hash-keys (`FromPKHBytes`, C.h:2337–2343), so script-level accept sets mostly match; rust's is representationally richer.
- **(h) 1 ≤ n < 2³¹ vs rust locktime ranges** — **identical accept sets on all parse paths**. Core: `1≤n<0x80000000` (parse C.h:2027/2034; decode C.h:2348/2354; invariant C.cpp:50–51). Rust: `AbsLockTime` ∈ [1, 0x7FFFFFFF] (R.abs:51–57) and `RelLockTime` = "bit-31 clear ∧ ≠0" = [1, 2³¹) (R.rel:42–44, 85–94; bit31 check in rust-bitcoin `Sequence::is_relative_lock_time`). No implementation accepts values ≥2³¹ anywhere.
- **(i) n=0 in `older`/`after`** — spec forbids n=0 (S42 "NUM cannot be 0"; S126). All *text/script parsing* in both impls reject 0 (C.h:2027,2034,2348,2354; R.expr:347–374 via from_consensus; R.dec:447–450; R.abs:27–28 min error message). **Divergence D2**: rust exposes *programmatic* construction of `older(0)` — `RelLockTime::ZERO` (R.rel:39) and `from_height_unchecked(0)` (R.rel:56) + the unchecked public constructor `Miniscript::older` (R.mod:219–226), with nothing in `validate_non_top_level` re-checking it (R.mod:418–452 has no `Older` arm). `after(0)` remains unconstructible (no unchecked `AbsLockTime` zero path). Core's programmatic path hits `CHECK_NONFATAL(k>=1 && k<0x80000000UL)` (C.cpp:50–51) — which signals a bug (throws/logs via Core's check machinery) rather than silently succeeding.

---

## 3. Divergence register (rated)

Ratings: **[harmless-encoding]** = different representation/sequencing, same acceptance outcome · **[accept-set-differs]** = some miniscripts/strings accepted by one side only · **[semantically-meaningful]** = same accepted object computes different properties/semantics.

### D1 — `d:` wrapper's `u` property: Tapscript-only in Core, never in rust — **[accept-set-differs]**

- Spec: "`d:X` … o; n; d; **(Tapscript only) u**" (S144).
- Core: `"u"_mst.If(IsTapscript(ms_ctx))` — C.cpp:126 (NOTE at C.cpp:125 explains MINIMALIF is policy-only pre-Taproot).
- Rust: `unit: false` unconditionally in `Correctness::cast_dupif` — R.corr:234–235; the type constructor takes no context (R.corr:223) and no Tap override exists in the dispatch (R.types:489) or in `Tap`'s checks (R.ctx:617–737).
- Effect: under Tapscript, Core and the spec accept `d:X` where a `Bdu` child is required (`andor(dv:older(5),…)`, `or_d(dv:…,…)`, `thresh(k, d:v:…)`, andor-left …). rust rejects those trees with `LeftNotUnit`/`ChildBase*` (R.corr:390–392, 454–456, 498–500). Concrete example: `andor(dv:older(1),pk(K1),pk(K2))` is spec-valid Tapscript, types fine in Core-Tap (X=`Vz`→B o n d **u**), and fails rust's `and_or` (`a.unit` false, R.corr:454–456).
- Direction: rust is a sound **under-approximation** (it never *over*-types `d:X`); the divergence is one-sided: rust accepts strictly fewer spec-valid Tapscript composites. For the bare fragment `d:X` itself, both accept it but assign different `u` → technically also property-assignment difference on an accepted fragment, with downstream accept-set consequences.

### D2 — rust allows programmatic construction of `older(0)` — **[accept-set-differs]**

- Spec: `older(n)`/`after(n)` require 1 ≤ n < 2³¹ (S126); policy text says "NUM cannot be 0" (S42).
- Core: node construction with k=0 hits `CHECK_NONFATAL` (C.cpp:50–51); string/script entry points hard-reject 0 (C.h:2027, 2034, 2348, 2354).
- Rust: string/script entry points reject 0 (R.rel:85–94 + R.expr:364–374 + R.dec:447–448), **but** `pub const ZERO: RelLockTime` (R.rel:39) / `from_height_unchecked` (R.rel:56) + public `Miniscript::older(time)` (R.mod:219–226) construct `older(0)` without checks, and `validate_non_top_level` has no `Terminal::Older` arm to catch it (R.mod:418–452). `older(0)` then serializes (`<0> OP_CSV`), displays, and satisfies like an always-true opcode. (`after(0)` has no such hole: `AbsLockTime::from_consensus` is the only constructor and enforces ≥1, R.abs:51–57.)
- Note: semantically, an `older(0)` fragment is *less* constrained than the spec intends (CSV with 0 never aborts). rust's own sane-`s`/`m` machinery still prevents it from being a *toplevel-sane* script (sigless), so practical impact is limited, but the accepted AST set differs from both spec and Core.

### D3 — rust-only fragments: `SortedMulti`, `SortedMultiA`, `RawPkH` — **[harmless-encoding]** (typing), extension accept-set

- Rust: `Terminal::{SortedMulti, SortedMultiA}` (R.dec:155–161) typed exactly like `multi`/`multi_a` (R.corr:156–158, 165–168; R.mall:139–149; R.types:477, 479); `Terminal::RawPkH` (R.dec:100–105) typed exactly like `pk_h` (R.types:475). Core's `enum class Fragment` (C.h:213–245) contains none of these.
- Text forms `sortedmulti(…)`, `sortedmulti_a(…)`, `expr_raw_pkh(…)` exist only in rust (R.mod:1128–1143, 1055–1058). Core's stabilized script→miniscript decoder maps the `RawPkH` *script pattern* to `PK_H` with a hash-key instead (C.h:2337–2343), and sorted-multi exists in Core only at the *descriptor* layer (out of scope here).
- rust's `SANE` validation forbids `RawPkH` (R.val:112; gate R.mod:444–446; `from_str_insane` sets it off too, R.mod:974–977), so under default-policies the "usable" sets of both stay aligned. No typing-rule divergence: every one of these rust fragments reuses a shared type constructor.

### D4 — Core's text parser admits ill-typed trees; rust rejects them at parse time — **[accept-set-differs]** (API-level)

- Core: `Parse` (C.h:1854+) builds nodes first and never checks `typ != ""`; the doc comment says so explicitly (C.h:1850–1852: *"This does not check whether the script is valid… caller is expected to use IsValidTopLevel() and IsSane()"*). `FromString` returns that unchecked node (C.h:2684–2688). Validity predicates: C.h:1675–1681.
- Rust: every node passes through `Miniscript::from_ast` → `Type::type_check` (R.mod:315–331; R.types:462–538; errors like `ChildBase2`/`ThresholdBase` R.types:26–59), so `Miniscript::<_,Ctx>::from_str` fails on e.g. `and_v(0,1)` which Core's `FromString` returns as an (invalid-typed) node.
- Symmetric counter-point: Core's *script decoder* **is** strict like rust — `DecodeScript` ends with `IsValidTopLevel()` (C.h:2676–2678), matching rust's per-node `reduce0 → from_ast` (R.dec:305–309).
- Effect: `FromString`-accept ⊃ rust `from_str`-accept; the *sanely accepted* sets (`IsSane()` vs `Ctx::SANE` validation) coincide.

### D5 — rust carries `s/f/e` only under `NonMalleable`; Core computes them independently of `m` — **[harmless-encoding]**

- Rust's `Malleability` enum makes `dissat` (≈ f/e) and `signed` unrepresentable for malleable fragments (R.mall:63–78, doc comment L54–61), and `is_subtype` collapses accordingly (R.mall:114–125).
- Core's bitmap keeps the bits regardless: e.g. `thresh` sets `e=alle∧alls` even when `all_m` fails (C.cpp:255 vs 256), and `or_b` computes `e=eX·eZ` (C.cpp:176) while its `m` needs `(sX+sZ)` (C.cpp:175). Spec's own framing treats the s/f/e props as conditional on the m-requirements (S286–288 "requirements for non-malleability" column).
- No behavioral divergence: the sanity predicates both reduce to `m` (Core `IsNonMalleable` C.h:1684 ↔ rust `is_non_malleable` R.ana:37 + `allow_malleability:false` gate R.mod:358–360). Only property *introspection* of not-guaranteed-non-malleable subtrees differs.

### D6 — resource-limit *placement* in validation differs (Core folds policy limits into "valid"; rust splits consensus vs sane) — **[accept-set-differs]** (corners only)

- Core: `MaxScriptSize(P2WSH) = MAX_STANDARD_P2WSH_SCRIPT_SIZE = 3600` (C.h:284–296; policy constant) is part of `IsValid` (C.h:1675–1678), i.e. a 3601–10000-byte P2WSH miniscript is outright *invalid* in Core. Tapscript bound is derived from the 400 kWU tx-weight standardness limit (C.h:284–296 + `MAX_STANDARD_TX_WEIGHT`=400 000, policy.h:38).
- Rust: Segwitv0 consensus = 10 000-byte check (R.ctx:545–555), sanity-3600 only under `SANE` (R.ctx:502–506, R.val:103–126 + `max_script_size` gate R.mod:463–468); Tap consensus bound = whole-block weight (R.ctx:679–686) and Tap `SANE` adds *no* script-size cap (R.ctx:629–635). Ops/stack: Core `CheckOpsLimit`/`CheckStackSize` C.h:1571–1604 ↔ rust `check_local_consensus_validity` 201-op for Legacy/Segwit (R.ctx:436–449, 558–571; R.lim:9) and Tap stack+sigops reasoning (R.ctx:692–713).
- Effect: identical for every SANE-checked script; differences appear only for deliberately-`CONSENSUS`-validated objects or huge Tap scripts (≳400 k bytes: invalid-per-Core, accepted-by-rust).

### D7 — duplicated `v` wrappers: lexical reject in Core, type-level reject in rust — **[harmless-encoding]**

- Core's wrapper scan hard-rejects `"...vv...:"` upfront (C.h:1953–1957).
- Rust accepts the characters then fails typing: `v:(V)` → `ChildBase1(V)` from `cast_verify` (R.corr:239–244, 242–243).
- Same reject set, different error stage/message.

### D8 — rust supports Legacy/Bare contexts and decodes 65-byte keys before context-gating; Core's miniscript is P2WSH/Tapscript-only — **[harmless-encoding]** (scope/sequencing)

- Core context enum has exactly `P2WSH, TAPSCRIPT` (C.h:253–256); its script decoder requires 32/33-byte `pk_k` keys and 33-byte `multi` keys (C.h:2330, 2386) and rejects multi-in-Tap / multi_a-in-P2WSH (C.h:2380, 2400; parse gate C.h:1880–1881).
- rust additionally has `Legacy`/`BareCtx`/`NoChecks` (R.ctx:366,743,868), inside which `d:`/`or_i` are *banned by validation parameters* (`allow_dup_if:false`, `allow_or_i:false` — R.ctx:373–376, 751–754; gates R.mod:420–422, 441–443) rather than by typing — the typing rules themselves are context-free apart from D1's absence in rust. rust's tokenizer/decoder accepts 65-byte pubkeys (R.dec:358–362, 528–529) with context rejection later (`check_pk` R.ctx:395–401, 515–523, 646–652, 773–779 / `validate_pk` R.val:236–260).
- For the two contexts both implementations share (P2WSH≈Segwitv0, Tap), the accepted fragment/context matrix is: `multi` P2WSH-only ✓ both; `multi_a` Tap-only ✓ both; `d:`/`or_i` allowed in both contexts in both impls ✓ (rust P2WSH/Tap params: R.ctx:493–506 & 622–627 with base `CONSENSUS` defaults R.val:136–141).

### D9 — top-level "sane bundle" composition differs slightly in naming/placement, equal in content — **[harmless-encoding]**

- Core: `IsSane() = IsValidTopLevel(B ∧ size) ∧ IsSaneSubexpression(ValidSatisfactions ∧ m ∧ k ∧ ¬dupkeys) ∧ NeedsSignature(s)` (C.h:1696–1702; s/m/k predicates C.h:1684–1690).
- rust: `Ctx::SANE` params (R.val:103–126) drive `validate`: ¬dup (R.mod:396–398), ¬mixed-timelocks (R.mod:399–401 ↔ R.ana:45), ¬malleable (R.mod:358–360 ↔ R.ana:37), B-toplevel (R.mod:363–365, R.val:40), ¬sigless-branch = `non_malleable_and_requires_sig` (R.mod:368–370 ↔ R.ana:31), plus per-context size/op gates.
- Content-equal for the core invariants; rust additionally exposes `from_str_insane`/`CONSENSUS`-only modes Core doesn't have an analogue for (D6).

---

## 4. Shared quirks (verified NON-divergences worth recording)

### 4.1 `andor(X,Y,Z)` timelock-mixing: both check X↔Y conflicts only

Core's `k` for ANDOR checks `¬(gX·hY + hX·gY + iX·jY + jX·iY)` (C.cpp:218–222); rust computes `combine_or(combine_and(a,b),c)` (R.ext:806–809) — i.e. conflict-check a↔b (R.ext:69–75) then plain-union with c. Neither checks the X↔Z path explicitly. This matches execution semantics ((X,Y) or (X,Z); X's *dissatisfaction* on the Z-path never activates timelocks, cf. the `d` requirement on X, S131) and matches the spec's `k` definition ("no satisfaction mixes height and time of the same type", S151–153) — because a satisfaction visiting Z dissatisfies X, and `d`-typed X dissatisfactions cannot rely on timelocks being met (S115). **Identical in all three sources.**

### 4.2 Core's folded `o`-formulas equal the spec's quadratic ones only under `z ⊥ o`

e.g. `and_v`: Core `((x|y)&"o").If((x|y)<<"z")` (C.cpp:146) ≡ spec `o=zX·oY + oX·zY` only because `z` and `o` are mutually exclusive (asserted C.cpp:23; structurally true in rust's `Input` enum R.corr:32–46). Same pattern at C.cpp:159,174,182,191,209. rust enumerates the truth tables explicitly (R.corr:318–328, 343–353, 372–379, 398–402, 421–425, 464–473) — one representative asymmetry of the *tables*: rust `or_b` maps `(Zero, OneNonZero)→One` (R.corr:372–377), consistent with "or has no `n`" in all sources (Core sets no `n` for or_b; S134 has no `n`).

### 4.3 `d:`/`j:` `e`-formulation: "e iff child is f" vs spec's unconditional "e" for `d:`

Spec malleability table lists `d:X` props as `s=sX; e` (S313) and `j:X` as `s=sX; e=fX` (S315). Core computes `e=fX` for **both** (C.cpp:122, 135). These agree on all well-typed children because `d:` requires a `Vz` child and every `V` has `f` (`SanitizeType`: V ⇒ f, C.cpp:33; structurally in rust since `cast_verify` sets `dissat: None`, R.mall:170). Not a divergence.

### 4.4 `c:X`'s `s`

Spec grants `s` unconditionally (S312); Core sets `"us"` (C.cpp:118); rust inherits `signed` from the child but concurrent `K ⇒ signed` (sanity R.types:220 — pk_k/pk_h are both `signed:true`, R.mall:130,133) makes it unconditional too. Equal.

### 4.5 `x` (expensive-verify) ↔ `has_free_verify`

Bit-for-bit consistent across all 20 fragments/wrappers: Core's `x` flag set on {`0`,`1`,`pk_k`,`pk_h`,`older`,`after`,`a:`,`d:`,`v:`,`j:`,`n:`,`and_b`,`or_b`,`or_c`,`or_d`,`or_i`,`andor`} and absent on {hashes, `c:`, `thresh`, `multi`, `multi_a`} (C.cpp:89–227) matches rust's `has_free_verify:false/true` assignments (false: R.ext:166,183,211,247,457,482,507,546,576,589,608,635,696,722,745,773,799; true: R.ext:286,325,353,379,405,431,533,938; propagate: R.ext:520 for `s:` ↔ Core's `x∈udfemsx` C.cpp:113; from-right: R.ext:664 for `and_v` ↔ Core's `x=x_y` C.cpp:150). (Core uses `x` in `ComputeScriptLen`/`ToScript` v:-verify fusion C.cpp:280, C.h:830–834,2117; rust uses the flag in `cast_verify` sizing R.ext:572–583.)

### 4.6 Timelock leaf ranges/bits

Accept ranges `[1,2³¹)` identical (§2 h); split bits identical (§2 e): relative bit22, absolute 500 000 000. Bits 16–21 of `older` are *accepted-but-meaningless* in both (masked by BIP68 semantics), and Core additionally has a *descriptor-layer lint* for it (out of miniscript scope).

---

## 5. Bottom line

- **28 of 31 rows are byte-for-byte property-identical** (as equal as two different encodings can be); the remaining rows are all explained by **D1–D9**, of which:
  - **D1** (`d:` `u` under Tapscript) and **D2** (rust-only programmatic `older(0)`) and **D4** (Core's lax `FromString`) change accept sets;
  - **D3, D5, D7, D8, D9** are representation/scope/sequencing differences with no effect on the shared sane-accepted language;
  - **no [semantically-meaningful] divergence** (same accepted serialized miniscript with different computed safety properties) was found, with the partial exception that on an accepted `d:X` fragment in Tap context Core reports `u` per spec while rust reports `¬u` (a conservative under-approximation whose only effect is D1-style child rejection).
- The type formulas that most often harbor bugs — `thresh` arg counting, `or_i` symmetry, `j:`'s `n` gate, `multi`'s `n` vs `multi_a`'s lack of it, and all timelock `g/h/i/j/k` propagation — all agree exactly.
