'reach 0.1';

// Reach + a vendored ERC-8001 (Agent Coordination Framework) companion,
// verified together via the verified-Solidity companion contract workflow
// (see ../verified-solidity-interop/). ERC-8001 defines a minimal
// propose -> accept -> execute primitive for multi-party, EIP-712-signed
// coordination (https://eips.ethereum.org/EIPS/eip-8001); its "Hello World"
// is AtomicSwap, a trustless two-party token swap, vendored here from
// github.com/KBryan/erc8001atomicswap (MIT, per-file SPDX headers) and
// wrapped by AtomicSwapReachAdapter.sol (see that file for why a wrapper is
// needed rather than calling AtomicSwap/ERC8001 directly via remote()).
//
// IMPORTANT ARCHITECTURAL FINDING, confirmed by an actual Foundry run, not
// just reading the source: ERC8001.acceptCoordination requires
// `msg.sender == attestation.participant` -- the accepting party must be
// the direct on-chain caller. Reach's `remote()` mechanism always calls out
// *through* the app's own generated ReachContract, so the companion never
// sees a participant's real address as msg.sender, only ReachContract's.
// This makes `acceptCoordination` fundamentally incompatible with being
// called via `remote()` from a Reach consensus step, for ANY Reach app,
// not just this adapter's design -- there is no wrapper-contract workaround
// that preserves both the caller-identity check and Reach-mediated calling,
// short of forking ERC8001's actual logic (which would defeat verifying
// against the real, unmodified companion). `proposeCoordination` and
// `executeCoordination` have no such check and work fine through
// `remote()`.
//
// The fix used here: Bob calls IERC8001(companion).acceptCoordination(...)
// DIRECTLY (an ordinary wallet transaction, outside this Reach program,
// using the real struct-typed calldata -- fine for a plain caller, just
// not expressible via remote()) after Alice's propose step, using the
// intentHash and adapter address this program exposes. This program then
// only orchestrates deploy + propose (Alice) and execute (Bob, after his
// own out-of-band accept has landed) -- both of which route through
// `remote()` safely.
// If Bob's accept hasn't happened yet, the executeSwap `remote()` call
// below simply fails (AtomicSwap's own ERC8001_NotReady), same as any
// other companion precondition violation.
//
// Alice deploys the adapter, then signs an AgentIntent off-chain (EIP-712,
// domain {name:"ERC-8001", version:"1", chainId, verifyingContract:adapter})
// proposing to swap `amountA` of `tokenA` for `amountB` of `tokenB` with
// Bob, and publishes it on-chain via proposeSwap. Bob then (out of band,
// see above) reviews the terms, signs an AcceptanceAttestation, and calls
// acceptCoordination on the companion himself. Once that's landed, Bob (or anyone;
// this program has Bob do it) triggers execution through this program.
//
// Approval is also NOT handled by this program, for a related but distinct
// reason: ERC-8001's signatures establish *agreement*, not fund custody, so
// the actual transfer still goes through each token's own allowance
// mechanism, and each party must separately call
// token.approve(adapterAddress, amount) before execute -- out of band,
// exactly like approving a DEX router before a swap. This program has no
// way to do it for them even if it wanted to: it never learns tokenA/
// tokenB's on-chain Contract handle (only their Address, supplied as plain
// data), and Reach's type system provides Contract.fromAddress
// (Address -> Maybe(Contract)) but no documented reverse conversion from a
// deployed Contract value back to a plain Address, which a remote call's
// argument position would need. See foundry-test/Deploy.t.sol for where
// both out-of-band steps (accept, approve) happen in the verified round
// trip.
//
// IMPORTANT, read before wiring up a real frontend: Reach cannot compute
// the EIP-712 digest itself (that would mean re-implementing
// AGENT_INTENT_TYPEHASH struct-hashing by hand and keeping it byte-for-byte
// in sync with the Solidity source -- fragile and unverified). The
// `signIntent` interact call below MUST be implemented by a real EIP-712
// signer (e.g. ethers.js `signer.signTypedData(domain, types, value)` or
// viem's equivalent) using the domain and struct types documented in
// AtomicSwapReachAdapter.sol and ERC8001.sol; the `Contract` value passed
// to it is what the JS SDK calls contract info, from which
// `ctc.getContractAddress()` yields the real address needed for the
// EIP-712 domain's `verifyingContract` field. Bob's out-of-band acceptance
// signing (outside this program entirely, per the finding above -- there is
// no `signAcceptance` interact call here to wire up) needs the same
// EIP-712 treatment in a real frontend, against a
// `AcceptanceAttestation` struct instead of `AgentIntent`. This repo's Foundry
// test (foundry-test/Deploy.t.sol) exercises the real on-chain contract
// logic with genuine ECDSA signatures produced via `vm.sign` against a
// digest computed the same way Solidity computes it -- it does not
// exercise an actual ethers/viem signing flow, which is outside what this
// environment can run end-to-end.
//
// Redundant consensus, stated plainly: Reach's own participant/consensus
// model already guarantees Alice and Bob agree before anything publishes.
// Layering ERC-8001's independent signature-based propose/accept/execute on
// top answers the same "did both parties agree" question twice, through two
// mechanisms that don't know about each other -- and, per the finding
// above, the "accept" leg can't even run through Reach's own consensus
// mechanism. That's legitimate here as a demonstration of ERC-8001
// compliance (the actual point of this example), not as added security
// against a Reach-level attacker.
//
// Verification layers (see docs/src/guide/verified-solidity-interop/):
//  1. Z3 proves this program's orchestration and the trivial Refine
//     precondition declared below.
//  2. solc's SMTChecker analyzes internal arithmetic/assert safety across
//     the adapter + AtomicSwap + ERC8001 + IERC8001 + the vendored OZ
//     closure. It does NOT and cannot prove cross-contract properties (the
//     two transferFrom calls net out correctly) or cryptographic ones
//     (a signature really came from the claimed signer -- that's ordinary
//     ecrecover, checked at runtime, never "proven"). As with
//     erc1155-companion, `require` is not achievable on a closure this
//     size; see README.md for measured numbers.
//  3. Every companion call result is otherwise `havoc` to Z3; see
//     vr_assumptions in the compiled report.

export const main = Reach.App(() => {
  setOptions({ connectors: [ETH] });

  const Alice = Participant('Alice', {
    partyB: Address,
    tokenA: Address,
    amountA: UInt,
    tokenB: Address,
    amountB: UInt,
    expiryA: UInt,
    nonceA: UInt,
    ready: Fun([], Null),
    // signIntent(adapterCtc) -> EIP-712 signature over the AgentIntent
    // built from the terms above (agentId = Alice's own address).
    signIntent: Fun([Contract], BytesDyn),
  });
  const Bob = Participant('Bob', {
    ready: Fun([], Null),
  });

  init();

  Alice.only(() => {
    const partyB = declassify(interact.partyB);
    const tokenA = declassify(interact.tokenA);
    const amountA = declassify(interact.amountA);
    const tokenB = declassify(interact.tokenB);
    const amountB = declassify(interact.amountB);
    assume(amountA > 0 && amountB > 0);
    assume(partyB != Alice);
  });
  Alice.publish(partyB, tokenA, amountA, tokenB, amountB);
  require(amountA > 0 && amountB > 0);
  require(partyB != Alice);
  commit();

  Alice.only(() => {
    interact.ready();
  });
  Alice.publish();
  const AdapterCode = ContractCode({ ETH: 'AtomicSwapReachAdapter.sol:AtomicSwapReachAdapter' });
  const adapterNew = new Contract(AdapterCode, {});
  const adapter = adapterNew();
  const swap = remote(adapter, {
    proposeSwap: Refine(
      Fun([UInt, UInt, Address, Address, Address, UInt, Address, UInt, BytesDyn], Bytes(32)),
      (([expiry, nonce, pA, pB, tA, amtA, tB, amtB, sig]) => pA != pB),
      ((args, result) => true)),
    // Bool only, not Tuple(Bool, BytesDyn) -- see AtomicSwapReachAdapter.sol's
    // executeSwap comment for a confirmed ABI-encoding mismatch between
    // Reach's Tuple(...) remote() return decoding and Solidity's native
    // multi-value return encoding.
    executeSwap: Fun([Bytes(32), Address, UInt, Address, UInt], Bool),
  });
  commit();

  Alice.only(() => {
    const expiryA = declassify(interact.expiryA);
    const nonceA = declassify(interact.nonceA);
    assume(expiryA > 0 && nonceA > 0);
    const sigA = declassify(interact.signIntent(adapter));
  });
  Alice.publish(expiryA, nonceA, sigA);
  require(expiryA > 0 && nonceA > 0);
  const intentHash = swap.proposeSwap(
    expiryA, nonceA, Alice, partyB, tokenA, amountA, tokenB, amountB, sigA);
  commit();

  // Out of band, between here and Bob's next publish: Bob reviews the
  // proposed terms (readable via the adapter's own getCoordinationStatus,
  // or off-chain), signs an AcceptanceAttestation, and calls
  // acceptCoordination(intentHash, attestation) on the deployed companion
  // directly -- see the header comment for why this can't go through
  // remote().

  Bob.only(() => {
    interact.ready();
  });
  Bob.publish();
  const execSuccess = swap.executeSwap(intentHash, tokenA, amountA, tokenB, amountB);
  commit();

  exit();
});
