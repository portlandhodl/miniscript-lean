# Miniscript — Bitcoin Script language specification

Source: https://bitcoin.sipa.be/miniscript/ (exact content mirror of
https://github.com/sipa/miniscript/blob/master/index.html, fetched 2026-10-21).

This is a verbatim markdown transcription of the full spec page. Angle-bracketed script
pushes use `<...>`; superscripts/subscripts are written `X_x` / `2^31`.

---

## Introduction

*Miniscript* is a language for writing (a subset of) Bitcoin Scripts in a structured way, enabling analysis, composition, generic signing and more.

Bitcoin Script is an unusual stack-based language with many edge cases, designed for implementing spending conditions consisting of various combinations of signatures, hash locks, and time locks. Yet despite being limited in functionality it is still highly nontrivial to:

- Given a combination of spending conditions, finding the most economical script to implement it.
- Given two scripts, construct a script that implements a composition of their spending conditions (e.g. a multisig where one of the "keys" is another multisig).
- Given a script, find out what spending conditions it permits.
- Given a script and access to a sufficient set of private keys, construct a general satisfying witness for it.
- Given a script, be able to predict the cost of spending an output.
- Given a script, know whether particular resource limitations like the ops limit might be hit when spending.

Miniscript functions as a representation for scripts that makes these sort of operations possible. It has a structure that allows composition. It is very easy to statically analyze for various properties (spending conditions, correctness, security properties, malleability, ...). It can be targeted by spending policy compilers (see below). Finally, compatible scripts can easily be converted to Miniscript form - avoiding the need for additional metadata for e.g. signing devices that support it.

Miniscript is designed for (P2SH-)P2WSH and Tapscript (as defined in BIP342) embedded scripts. Most of its constructions work fine in P2SH as well, but some of the (optional) security properties rely on Segwit-specific rules. Furthermore, the implemented policy compilers assume a Segwit-specific cost model.

Miniscript was designed and implemented by Pieter Wuille, Andrew Poelstra, and Sanket Kanjalkar at Blockstream Research, but is the result of discussions with several other people.

Links:

- This [website](http://bitcoin.sipa.be/miniscript) and C++ compiler: [code](https://github.com/sipa/miniscript)
- Bitcoin Core compatible C++ implementation: [code](https://github.com/sipa/miniscript/tree/master/bitcoin/script)
- Rust-miniscript implementation: [code](https://github.com/apoelstra/rust-miniscript)
- Talk about (an early version of) Miniscript at [SBC'19](https://cyber.stanford.edu/sbc19): [video](https://www.youtube.com/watch?v=XM1lzN4Zfks) [transcript](http://diyhpl.us/wiki/transcripts/stanford-blockchain-conference/2019/miniscript/) [slides](https://prezi.com/view/KH7AXjnse7glXNoqCxPH/)

## Policy to Miniscript compiler

Supported policies:

- `pk(NAME)`: Require public key named *NAME* to sign. *NAME* can be any string up to 16 characters.
- `after(NUM)`, `older(NUM)`: Require that the `nLockTime`/`nSequence` value is at least *NUM*. *NUM* cannot be 0.
- `sha256(HEX)`, `hash256(HEX)`: Require that the preimage of 64-character *HEX* is revealed. The special value `H` can be used as *HEX*.
- `ripemd160(HEX)`, `hash160(HEX)`: Require that the preimage of 40-character *HEX* is revealed. The special value `H` can be used as *HEX*.
- `and(POL,POL)`: Require that both subpolicies are satisfied.
- `or([N@]POL,[N@]POL)`: Require that one of the subpolicies is satisfied. The numbers N indicate the relative probability of each of the subexpressions (so `9@` is 9 times more likely than the default).
- `thresh(NUM,POL,POL,...)`: Require that NUM out of the following subpolicies are met (all combinations are assumed to be equally likely).

# Miniscript reference

## P2WSH or Tapscript?

The Miniscript specifications vary only slightly between P2WSH and Tapscript embedded scripts. Differences are pointed inline. If no information specific to the context is given you can assume it is valid for both P2WSH and Tapscript.

## Translation table

This table shows all Miniscript *fragments* and their associated semantics and Bitcoin Script. Fragments that do not change the semantics of their subexpressions are called *wrappers*. Normal fragments use a "fragment(arguments,...)" notation, while wrappers are written using prefixes separated from other fragments by a colon. The colon is dropped between subsequent wrappers; e.g. `dv:older(144)` is the `d:` wrapper applied to the `v:` wrapper applied to the `older` fragment for 144 blocks. Note how `key` expressions in this table and the followings are implicitly 32 bytes "x-only" public key in Tapscript and 33 bytes compressed public keys in P2WSH.

| Semantics | Miniscript fragment | Bitcoin Script |
|---|---|---|
| false | `0` | `0` |
| true | `1` | `1` |
| check(key) | `pk_k(key)` | `<key>` |
| check(key) | `pk_h(key)` | `DUP HASH160 <HASH160(key)> EQUALVERIFY` |
| check(key) | `pk(key) = c:pk_k(key)` | `<key> CHECKSIG` |
| check(key) | `pkh(key) = c:pk_h(key)` | `DUP HASH160 <HASH160(key)> EQUALVERIFY CHECKSIG` |
| nSequence ≥ n (and compatible) | `older(n)` | `<n> CHECKSEQUENCEVERIFY` |
| nLockTime ≥ n (and compatible) | `after(n)` | `<n> CHECKLOCKTIMEVERIFY` |
| len(x) = 32 and SHA256(x) = h | `sha256(h)` | `SIZE <20> EQUALVERIFY SHA256 <h> EQUAL` |
| len(x) = 32 and HASH256(x) = h | `hash256(h)` | `SIZE <20> EQUALVERIFY HASH256 <h> EQUAL` |
| len(x) = 32 and RIPEMD160(x) = h | `ripemd160(h)` | `SIZE <20> EQUALVERIFY RIPEMD160 <h> EQUAL` |
| len(x) = 32 and HASH160(x) = h | `hash160(h)` | `SIZE <20> EQUALVERIFY HASH160 <h> EQUAL` |
| (*X* and *Y*) or *Z* | `andor(X,Y,Z)` | `[X] NOTIF [Z] ELSE [Y] ENDIF` |
| *X* and *Y* | `and_v(X,Y)` | `[X] [Y]` |
| *X* and *Y* | `and_b(X,Y)` | `[X] [Y] BOOLAND` |
| *X* and *Y* | `and_n(X,Y)` = `andor(X,Y,0)` | `[X] NOTIF 0 ELSE [Y] ENDIF` |
| *X* or *Z* | `or_b(X,Z)` | `[X] [Z] BOOLOR` |
| *X* or *Z* | `or_c(X,Z)` | `[X] NOTIF [Z] ENDIF` |
| *X* or *Z* | `or_d(X,Z)` | `[X] IFDUP NOTIF [Z] ENDIF` |
| *X* or *Z* | `or_i(X,Z)` | `IF [X] ELSE [Z] ENDIF` |
| *X1* + ... + *Xn* = k | `thresh(k,X1,...,Xn)` | `[X1] [X2] ADD ... [Xn] ADD ... <k> EQUAL` |
| check(key1) + ... + check(keyn) = k *(P2WSH only)* | `multi(k,key1,...,keyn)` | `<k> <key1> ... <keyn> <n> CHECKMULTISIG` |
| check(key1) + ... + check(keyn) = k *(Tapscript only)* | `multi_a(k,key1,...,keyn)` | `<key1> CHECKSIG <key2> CHECKSIGADD ... <keyn> CHECKSIGADD <k> NUMEQUAL` |
| *X* (identities) | `a:X` | `TOALTSTACK [X] FROMALTSTACK` |
| *X* (identities) | `s:X` | `SWAP [X]` |
| *X* (identities) | `c:X` | `[X] CHECKSIG` |
| *X* (identities) | `t:X` = `and_v(X,1)` | `[X] 1` |
| *X* (identities) | `d:X` | `DUP IF [X] ENDIF` |
| *X* (identities) | `v:X` | `[X] VERIFY` (or `VERIFY` version of last opcode in `[X]`) |
| *X* (identities) | `j:X` | `SIZE 0NOTEQUAL IF [X] ENDIF` |
| *X* (identities) | `n:X` | `[X] 0NOTEQUAL` |
| *X* (identities) | `l:X` = `or_i(0,X)` | `IF 0 ELSE [X] ENDIF` |
| *X* (identities) | `u:X` = `or_i(X,0)` | `IF [X] ELSE 0 ENDIF` |

The `pk`, `pkh`, and `and_n` fragments and `t:`, `l:`, and `u:` wrappers are syntactic sugar for other Miniscripts, as listed in the table above. In what follows, they will not be included anymore, as their properties can be derived by looking at their expansion.

Hash preimages are constrained to 32 bytes to disallow various forms of griefing, including making non-standard(un-relayable) transactions, consensus-invalid swaps across blockchains, as well as ensure that satisfaction cost can be accurately calculated. Finally, note that `<20>` are in hex representation in this document.

## Correctness properties

Not every Miniscript expression can be composed with every other. Some return their result by putting true or false on the stack; others can only abort or continue. Some require subexpressions that consume an exactly known number of arguments, while others need a subexpression that has a nonzero top stack element to satisfy. To model all these properties, we define a correctness type system for Miniscript.

Every miniscript expression has one of four basic types:

- **"B"** Base expressions. These take their inputs from the top of the stack. When satisfied, they push a nonzero value of up to 4 bytes onto the stack. When dissatisfied, they push an exact 0 onto the stack (if dissatisfaction without aborting is possible at all). This type is used for most expressions, and required for the top level expression. An example is `older(n)` = `<n> CHECKSEQUENCEVERIFY`.
- **"V"** Verify expressions. Like "B", these take their inputs from the top of the stack. Upon satisfaction however, they continue without pushing anything. They cannot be dissatisfied (will abort instead). A "V" can be obtained using the `v:` wrapper on a "B" expression, or by combining other "V" expressions using `and_v`, `or_i`, `or_c`, or `andor`. An example is `v:pk(key)` = `<key> CHECKSIGVERIFY`.
- **"K"** Key expressions. They again take their inputs from the top of the stack, but instead of verifying a condition directly they always push a public key onto the stack, for which a signature is still required to satisfy the expression. A "K" can be converted into a "B" using the `c:` wrapper (`CHECKSIG`). An example is `pk_h(key)` = `DUP HASH160 <Hash160(key)> EQUALVERIFY`
- **"W"** Wrapped expressions. They take their inputs from one below the top of the stack, and push a nonzero (in case of satisfaction) or zero (in case of dissatisfaction) either on top of the stack, or one below. So for example a 3-input "W" would take the stack "A B C D E F" and turn it into "A B F 0" or "A B 0 F" in case of dissatisfaction, and "A B F n" or "A B n F" in case of satisfaction (with n a nonzero value). Every "W" is either `s:B` (`SWAP B`) or `a:B` (`TOALTSTACK B FROMALTSTACK`). An example is `s:pk(key)` = `SWAP <key> CHECKSIG`.

Then there are 5 type modifiers, which guarantee additional properties:

- **"z"** Zero-arg: this expression always consumes exactly 0 stack elements.
- **"o"** One-arg: this expression always consumes exactly 1 stack element.
- **"n"** Nonzero: this expression always consumes at least 1 stack element, no satisfaction for this expression requires the top input stack element to be zero.
- **"d"** Dissatisfiable: a dissatisfaction for this expression can unconditionally be constructed. This implies the dissatisfaction cannot include any signature or hash preimage, and cannot rely on timelocks being satisfied.
- **"u"** Unit: when satisfied, this expression will put an exact 1 on the stack (as opposed to any nonzero value).

This tables lists the correctness requirements for each of the Miniscript expressions, and its type properties in function of those of their subexpressions:

| Miniscript | Requires | Type | Properties |
|---|---|---|---|
| `0` | | B | z; u; d |
| `1` | | B | z; u |
| `pk_k(key)` | | K | o; n; d; u |
| `pk_h(key)` | | K | n; d; u |
| `older(n)`, `after(n)` | 1 ≤ n < 2^31 | B | z |
| `sha256(h)` | | B | o; n; d; u |
| `ripemd160(h)` | | B | o; n; d; u |
| `hash256(h)` | | B | o; n; d; u |
| `hash160(h)` | | B | o; n; d; u |
| `andor(X,Y,Z)` | *X* is Bdu; *Y* and *Z* are both B, K, or V | same as Y/Z | z=z_X z_Y z_Z; o=z_X o_Y o_Z or o_X z_Y z_Z; u=u_Y u_Z; d=d_Z |
| `and_v(X,Y)` | *X* is V; *Y* is B, K, or V | same as *Y* | z=z_X z_Y; o=z_X o_Y or z_Y o_X; n=n_X or z_X n_Y; u=u_Y |
| `and_b(X,Y)` | *X* is B; *Y* is W | B | z=z_X z_Y; o=z_X o_Y or z_Y o_X; n=n_X or z_X n_Y; d=d_X d_Y; u |
| `or_b(X,Z)` | *X* is Bd; *Z* is Wd | B | z=z_X z_Z; o=z_X o_Z or z_Z o_X; d; u |
| `or_c(X,Z)` | *X* is Bdu; *Z* is V | V | z=z_X z_Z; o=o_X z_Z |
| `or_d(X,Z)` | *X* is Bdu; *Z* is B | B | z=z_X z_Z; o=o_X z_Z; d=d_Z; u=u_Z |
| `or_i(X,Z)` | both are B, K, or V | same as X/Z | o=z_X z_Z; u=u_X u_Z; d=d_X or d_Z |
| `thresh(k,X1,...,Xn)` | 1 ≤ k ≤ n; *X1* is Bdu; others are Wdu | B | z=all are z; o=all are z except one is o; d; u |
| `multi(k,key1,...,keyn)` | 1 ≤ k ≤ n | B | n; d; u |
| `multi_a(k,key1,...,keyn)` | 1 ≤ k ≤ n | B | d; u |
| `a:X` | *X* is B | W | d=d_X; u=u_X |
| `s:X` | *X* is Bo | W | d=d_X; u=u_X |
| `c:X` | *X* is K | B | o=o_X; n=n_X; d=d_X; u |
| `d:X` | *X* is Vz | B | o; n; d; (Tapscript only) u |
| `v:X` | *X* is B | V | z=z_X; o=o_X; n=n_X |
| `j:X` | *X* is Bn | B | o=o_X; n; d; u=u_X |
| `n:X` | *X* is B | B | z=z_X; o=o_X; n=n_X; d=d_X; u |

## Detecting timelock mixing

The `nSequence` field in a transaction input, or the `nLockTime` field in transaction can be specified either as a time or height but not both. Therefore it is not possible to spend scripts that require satisfaction of both, height based timelock and time based timelock of the same type.

- **"k"** No timelock mixing. This expression does not contain a mix of heightlock and timelock of the same type. If the miniscript does not have the "k" property, the miniscript template will not match the user expectation of the corresponding spending policy.

## Resource limitations

Various types of Bitcoin Scripts have different resource limitations, either through consensus or standardness. Some of them affect otherwise valid Miniscripts:

- Scripts over 10000 bytes are invalid by consensus (bare, P2SH, P2WSH, P2SH-P2WSH). In Tapscript scripts are only implicitly bounded by the maximum standard transaction size (of 100k virtual bytes), which makes the maximum script size a bit less than 400000 bytes.
- Scripts over 520 bytes are invalid by consensus (P2SH).
- Script satisfactions where the total number of non-push opcodes plus the number of keys participating in all executed `multi`s, is above 201, are invalid by consensus (bare, P2SH, P2WSH, P2SH-P2WSH).
- Anything but `pk(key)` (P2PK), `pkh(key)` (P2PKH), and `multi(k,...)` up to n=3 is invalid by standardness (bare).
- Scripts over 3600 bytes are invalid by standardness (P2WSH, P2SH-P2WSH).
- Script satisfactions with a serialized `scriptSig` over 1650 bytes are invalid by standardness (P2SH).
- Script satisfactions with a witness consisting of over 100 stack elements (excluding the script itself) are invalid by standardness (P2WSH, P2SH-P2WSH).
- Script satisfactions that make the stack exceed 1000 elements during or before script execution are invalid by consensus (bare, P2SH, P2WSH, P2SH-P2WSH, Tapscript).

For P2WSH, a Miniscript whose script is larger than 3600 bytes is invalid. For all the other limits, Miniscript makes it easy to verify they don't impact the ability to satisfy a script. Note that this is different from verifying whether the limits are never reachable at all (which is also possible). Consider for example an `or_b(X,Y)` where both *X* and *Y* require a number of large `multi`s to be executed to satisfy. It may be the case that satisfying just one of *X* or *Y* does not exceed the ops limit, while satisfying both does. As it's never required to satisfy both, the limit does not prevent satisfaction.

## Security properties

The type system above guarantees that the corresponding Bitcoin Scripts are:

- **consensus and standardness complete**: Assuming the resource limits listed in the previous section are not violated and there is no timelock mixing, for every set of met conditions that are permitted by the semantics, a witness can be constructed that passes Bitcoin's consensus rules and common standardness rules.
- **consensus sound**: It is not possible to construct a witness that is consensus valid for a Script unless the spending conditions are met. Since standardness rules permit only a subset of consensus-valid satisfactions (by definition), this property also implies **standardness soundness**.

The completeness property has been extensively tested for P2WSH by verifying large numbers of random satisfactions for random Miniscript expressions against Bitcoin Core's consensus and standardness implementation. The soundness can be reasoned about by considering all possible execution paths through each of the fragments' scripts.

In order for these properties to not just apply to script, but to an entire transaction, it's important that the witness commits to all data relevant for verification. In practice this means that scripts whose conditions can be met without any digital signature are insecure. For example, if an output can be spent by simply passing a certain `nLockTime` (an `after(n)` fragment in Miniscript) but without any digital signatures, an attacker can modify the `nLockTime` field in the spending transaction.

# Satisfactions and malleability

## Basic satisfactions

The following table shows all valid satisfactions and dissatisfactions for every Miniscript, using satisfactions and dissatisfactions of its subexpressions. Multiple possibilities are separated by semicolons. Some options are not actually necessary to produce correct witnesses, and are called *non-canonical* options. They are listed for completeness, but marked in `[grey]` below. (Non-canonical options below are wrapped in `[...]`; "-" means none exist; an empty cell "" means the empty witness vector is a valid sat/dsat.)

| Miniscript | Dissatisfactions (dsat) | Satisfactions (sat) |
|---|---|---|
| `0` | "" (empty) | - |
| `1` | - | "" (empty) |
| `pk_k(key)` | 0 | sig |
| `pk_h(key)` | 0 key | sig key |
| `older(n)` | - | "" (empty) |
| `after(n)` | - | "" (empty) |
| `sha256(h)` | any 32-byte vector except the preimage | preimage |
| `ripemd160(h)` | any 32-byte vector except the preimage | preimage |
| `hash256(h)` | any 32-byte vector except the preimage | preimage |
| `hash160(h)` | any 32-byte vector except the preimage | preimage |
| `andor(X,Y,Z)` | dsat(Z) dsat(X); [dsat(Y) sat(X)] | sat(Y) sat(X); sat(Z) dsat(X) |
| `and_v(X,Y)` | [dsat(Y) sat(X)] | sat(Y) sat(X) |
| `and_b(X,Y)` | dsat(Y) dsat(X); [sat(Y) dsat(X)]; [dsat(Y) sat(X)] | sat(Y) sat(X) |
| `or_b(X,Z)` | dsat(Z) dsat(X) | dsat(Z) sat(X); sat(Z) dsat(X); [sat(Z) sat(X)] |
| `or_c(X,Z)` | - | sat(X); sat(Z) dsat(X) |
| `or_d(X,Z)` | dsat(Z) dsat(X) | sat(X); sat(Z) dsat(X) |
| `or_i(X,Z)` | dsat(X) 1; dsat(Z) 0 | sat(X) 1; sat(Z) 0 |
| `thresh(k,X1,...,Xn)` | All dsats [Sats/dsats with 1 ≤ #(sats) ≠ k] | Sats/dsats with #(sats) = k |
| `multi(k,key1,...,keyn)` | 0 0 ... 0 (k+1 times) | 0 sig ... sig |
| `multi_a(k,key1,...,keyn)` | 0 ... 0 (n times) | sig/0 with #(sig) = k and #(sigs/0) = n |
| `a:X` | dsat(X) | sat(X) |
| `s:X` | dsat(X) | sat(X) |
| `c:X` | dsat(X) | sat(X) |
| `d:X` | 0 | sat(X) 1 |
| `v:X` | - | sat(X) |
| `j:X` | 0; [dsat(X) (if nonzero top stack)] | sat(X) |
| `n:X` | dsat(X) | sat(X) |

The correctness properties in the previous section are based on the availability of satisfactions and dissatisfactions listed above. The requirements include a "d" for every subexpression whose dissatisfaction may be needed in building a satisfaction for the parent expression. The "d" properties themselves rely on the "d" properties of subexpressions. An interesting property is that in a well-typed Miniscript, dissatisfying a non-"d" subexpression always causes the overall script to fail, propagating the failure upwards to a point where it either causes the script to abort, or reach the top level.

A conservative simplification is made here, ignoring the existence of always-true expressions like `1`. This makes the typing rules incorrect in the following cases:

- `or_b(X,1)` and `or_b(1,X)` are complete when *X* is dissatisfiable ("d"). In that case, the condition is equivalent to 1 and is always met, and a satisfaction of the form "dsat(X)" exists.
- `or_b(1,1)` is complete, as it is equivalent to 1 and "" is a valid satisfaction.
- `and_b(X,1)` and `and_b(1,X)` are dissatisfiable ("d") when *X* is.
- `andor(1,1,Z)` is complete, as it is equivalent to 1 and "" is a valid satisfaction.
- `andor(1,Y,0)` is complete when *Y* is; it also has the same type as *Y*, despite `0` always being a "B". This is also dissatisfiable when *Y* is.
- The `1`s items listed above can be replaced with any other always-true expression.

Since all these cases of inaccurate typing involve always-true expressions that can be avoided using strictly simpler/smaller Miniscripts, we don't consider this to be a serious restriction. For Miniscripts excluding always-true expressions (except in the `and_v(X,1)` code), the typing rules match the definitions above.

## Malleability

While following the table above to construct satisfactions is sufficient for meeting the completeness and soundness properties, it does not guarantee non-malleability.

Malleability is the ability for a third party (*not* a participant in the script) to modify an existing satisfaction into another valid satisfaction. Since Segwit, malleating a transaction no longer breaks the validity of unconfirmed descendant transactions. However, unintentional malleability may still have a number of much weaker undesirable effects. If a witness can be stuffed with additional data, the transaction's feerate will go down, potentially to the point where its ability to propagate and get confirmed is impacted. Additionally, malleability can be exploited to add roundtrips to BIP152 block propagation, by trying to get different miners to mine different versions of the same transaction. Finally, malleability may interfere with the usage of hash locks as a mechanism for publishing preimages.

Because of these reasons, Miniscript is actually designed to permit non-malleable signing. As this guarantee is restricted in non-obvious ways, let's first state the assumptions:

- The attacker does not have access to any of the private keys of public keys that participate in the Script. Participants with private keys inherently have the ability to produce different satisfactions by creating multiple signatures. While it is also interesting to study the impact rogue participants can have, we treat it as a distinct problem.
- The attacker only has access to hash preimages that honest users have access to as well. This is a reasonable assumption because hash preimages are revealed once globally, and then available to everyone. On the other hand, making the assumption that attackers may have access to more preimages than honest users makes a large portion of scripts impossible to satisfy in a non-malleable way.
- The attacker gets to see exactly one satisfying witness of any transaction. If he sees multiple, it becomes possible for the attacker to mix and match different satisfactions. This is very hard to reason about.
- We restrict this analysis to scripts where no public key is repeated. If signatures constructed for one part of the script can be bound to other checks in the same script, a variant of the mixing from the previous point becomes available that is equally hard to reason about. Furthermore this situation can be avoided by using separate keys.

Malleable satisfactions or dissatisfactions appear whenever options are available to attackers distinct from the one taken by honest users. This can happen for multiple reasons:

1. Two or more options for a satisfaction or dissatisfaction are listed in the table above which are both available to attackers directly. Regardless of which option is used in the honest solution, the attacker can change the solution to the other one.
2. Two or more options for a satisfaction or dissatisfaction are listed in the table above, only one of which is available to attackers, but the honest solution uses another one. In that case, the attacker can modify the solution to pick the one available to him.
3. The honest users pick a solution that contains a satisfaction which can be turned into a dissatisfaction without invalidating the overall witness. Those are called overcomplete solutions.

## Non-malleable satisfaction algorithm

Because we assume attackers never have access to private keys, we can treat any solution that includes a signature as one that is unavailable to attackers. For others, the worst case is that the attacker has access to every solution the honest users have, but no others: for preimages this is an explicit assumption, while timelock availability is determined by the `nLockTime` and `nSequence` fields in the transaction. As long as the overall satisfaction includes at least one signature, those values are fixed, and timelock availability is identical for attackers and honest users.

In order to produce non-malleable satisfactions we make use of a function that returns the optimal satisfaction and dissatisfaction for a given expression (if any exist), or a special DONTUSE value, together with an optional HASSIG marker that tracks whether the solution contains at least one signature. To implement the function:

- Invoke the function recursively for all subexpressions, obtaining all their satisfactions/dissatisfactions.
- Iterate over all the valid satisfactions/dissatisfactions in the table above (including the non-canonical ones), taking into account:
  - The dissatisfactions for `sha256`, `ripemd160`, `hash256`, and `hash160` are always malleable (reason 1), so instead use DONTUSE there.
  - The non-canonical options for `and_b`, `or_b`, and `thresh` are always overcomplete (reason 3), so instead use DONTUSE there as well (with HASSIG flag if the original non-canonical solution had one).
  - The satisfactions for `pk_k`, `pk_h`, and `multi` can be marked HASSIG.
  - When constructing solutions by combining results for subexpressions, the result is DONTUSE if any of the constituent results is DONTUSE. Furthermore, the result gets the HASSIG tag if any of the constituents do.
- If among all valid solutions (including DONTUSE ones) more than one does not have the HASSIG marker, return DONTUSE, as this is malleable because of reason 1.
- If instead exactly one does not have the HASSIG marker, return that solution because of reason 2.
- If all valid solutions have the HASSIG marker, but all of them are DONTUSE, return DONTUSE-HASSIG. The HASSIG marker is important because while this represents a choice between multiple options that would cause malleability if used, they are not available to the attacker, and we may be able to avoid them entirely still.
- Otherwise, all not-DONTUSE options are valid, so return the smallest one (in terms of witness size).

To produce an overall satisfaction, invoke the function on the toplevel expression. If no valid satisfaction is returned, or it is DONTUSE, fail. Otherwise, if any timelocking is used in the script but the result does not have the HASSIG flag, also fail, as this represents a situation where an attacker could change the `nLockTime` or `nSequence` values to meet additional timelock conditions. Not to mention that solutions without signatures are generally insecure. If the satisfaction is both not DONTUSE and HASSIG, return it.

The above can be used to show that no non-canonical solutions listed in the satisfaction table can occur inside non-malleable satisfactions.

- Some of the non-canonical options (the `or_b`, `and_b`, and `thresh` ones) are overcomplete, and thus can clearly not appear in non-malleable satisfactions.
- The fact that non-"d" expressions cannot be dissatisfied in valid witnesses rules out the usage of the non-canonical `and_v` dissatisfaction.
- "d" expressions are defined to be unconditionally dissatisfiable, which implies that for those a non-HASSIG dissatisfaction must exist. Non-HASSIG solutions must be preferred over HASSIG ones (reason 2), and when multiple non-HASSIG ones exist, none can be used (reason 1). This lets us rule out the other non-canonical options in the table:
  - `j:X` is always "d", its non-HASSIG dissatisfaction "0" always exists, and thus rules out any usage of "dsat(X)".
  - If `andor(X,Y,Z)` is "d", a non-HASSIG dissatisfaction "dsat(Z) dsat(X)" must exist, and thus rules out any usage of "dsat(Y) sat(X)".
  - If `and_b(X,Y)` is "d", a non-HASSIG dissatisfaction "dsat(Y) dsat(X)" must exist, and thus rules out any usage of "dsat(Y) sat(X)" and "sat(Y) dsat(X)". Those are also overcomplete.
  - `thresh(k,...)` is always "d", a non-HASSIG dissatisfaction with just dissatisfactions must exist due to typing rules, and thus rules out usage of the other dissatisfactions. They are also overcomplete.

## Guaranteeing non-malleability

Now we have an algorithm that can find the optimal non-malleable satisfaction for any Miniscript, if it exists. But can we statically prove that such a solution always exists? In order to do that, we add additional properties to the type system:

- **"s"** Signed: satisfying this expression always requires a signature (predicting whether all satisfactions will be HASSIG).
- **"f"** Forced: dissatisfying this expression always requires a signature (predicting whether all dissatisfactions will be HASSIG).
- **"e"** Expressive: this requires a unique unconditional dissatisfaction to exist, and forces all conditional dissatisfactions (if any) to require a signature.

The following table lists these additional properties, and the requirements for non-malleability.

| Miniscript | Requires | Properties |
|---|---|---|
| `0` | | s, e |
| `1` | | f |
| `pk_k(key)` | | s, e |
| `pk_h(key)` | | s, e |
| `older(n)` | | f |
| `after(n)` | | f |
| `sha256(h)` | | *(none)* |
| `ripemd160(h)` | | *(none)* |
| `hash256(h)` | | *(none)* |
| `hash160(h)` | | *(none)* |
| `andor(X,Y,Z)` | e_X and (s_X or s_Y or s_Z) | s=s_Z and (s_X or s_Y); f=f_Z and (s_X or f_Y); e=e_Z and (s_X or f_Y) |
| `and_v(X,Y)` | | s=s_X or s_Y; f=s_X or f_Y |
| `and_b(X,Y)` | | s=s_X or s_Y; f=f_X f_Y or s_X f_X or s_Y f_Y; e=e_X e_Y s_X s_Y |
| `or_b(X,Z)` | e_X e_Z and (s_X or s_Z) | s=s_X s_Z; e |
| `or_c(X,Z)` | e_X and (s_X or s_Z) | s=s_X s_Z; f |
| `or_d(X,Z)` | e_X and (s_X or s_Z) | s=s_X s_Z; f=f_Z; e=e_Z |
| `or_i(X,Z)` | s_X or s_Z | s=s_X s_Z; f=f_X f_Z; e=e_X f_Z or e_Z f_X |
| `thresh(k,X1,...,Xn)` | all are e; at most k are non-s | s=at most k-1 are non-s; e=all are s |
| `multi(k,key1,...,keyn)` | | s; e |
| `multi_a(k,key1,...,keyn)` | | s; e |
| `a:X` | | s=s_X; f=f_X; e=e_X |
| `s:X` | | s=s_X; f=f_X; e=e_X |
| `c:X` | | s; f=f_X; e=e_X |
| `d:X` | | s=s_X; e |
| `v:X` | | s=s_X; f |
| `j:X` | | s=s_X; e=f_X |
| `n:X` | | s=s_X; f=f_X; e=e_X |

Using the malleability type properties it is possible to determine statically whether a script can be nonmalleably satisfied under all circumstances. In many cases it is reasonable to only accept such guaranteed-nonmalleable scripts, as unexpected behavior can occur when using other scripts.

For example, when running the non-malleable satisfaction algorithm above, adding available preimages, or increasing the `nLockTime`/`nSequence` values actually may make it fail where it succeeded before. This is because a larger set of met conditions may mean an existing satisfaction goes from nonmalleable to malleable. Restricting things to scripts that are guaranteed to be satisfiable in a non-malleable way avoids this problem.

When analysing Miniscripts for resource limits, restricting yourself to just non-malleable solutions (or even non-malleable scripts) also leads to tighter bounds, as all non-canonical satisfactions and dissatisfactions can be left out of consideration.
