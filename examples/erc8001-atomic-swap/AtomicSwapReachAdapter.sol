// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "./erc8001/examples/AtomicSwap.sol";

// A hand-written companion contract wrapping ERC-8001's AtomicSwap example
// (vendored from github.com/KBryan/erc8001atomicswap, MIT-licensed per its
// per-file SPDX headers). `reach sol` runs solc's SMTChecker (CHC engine)
// over this file plus its full import closure (AtomicSwap + ERC8001 +
// IERC8001 + the vendored OpenZeppelin dependency closure under oz/).
//
// This file sits flat, directly alongside index.rsh (not nested under a
// subdirectory) for the same reason as ERC1155Wrapped.sol in
// examples/erc1155-companion/: Reach's real Solidity codegen path reads the
// ContractCode target under a synthetic source name with no directory
// component, so *this file's own* imports must be written relative to the
// compiler's working directory. Everything this file imports (erc8001/,
// oz/) resolves normally beneath that once loaded, since only the entry
// file itself is affected.
//
// Why an adapter, not calling AtomicSwap/ERC8001 directly via remote():
// IERC8001.proposeCoordination/acceptCoordination/executeCoordination take
// struct parameters containing `address[] participants` -- Reach's
// Array(T,N) is fixed-length at compile time and there is no dynamic-array
// type for non-byte elements, so those functions cannot be given a
// faithful `remote()` signature. This adapter exposes a flat,
// primitive-typed, exactly-2-participant facade instead; AtomicSwap's own
// _executeCoordinationHook already hard-requires exactly 2 participants
// (see InvalidParticipantCount), so specializing to 2 participants loses no
// capability of this specific example.
//
// acceptCoordination is deliberately NOT wrapped here (confirmed by an
// actual failing Foundry run, not just reading the source): it requires
// `msg.sender == attestation.participant`. `proposeCoordination` and
// `executeCoordination` have no such check (they validate via ECDSA
// recovery against a signer field instead), but ANY wrapper around
// acceptCoordination -- in this adapter or any other contract -- breaks
// this check for every caller, because Solidity can only invoke an
// `external` function of the same contract via a `this.` self-call (a real
// message call to `address(this)`), which resets msg.sender to the calling
// contract's own address regardless of who called the wrapper. This is not
// fixable by changing how the wrapper is written; it is a hard consequence
// of `acceptCoordination` being declared `external` with a `calldata`
// struct parameter (barring re-deriving its logic by hand, which would mean
// no longer verifying against the real, unmodified companion). The
// practical fix, used throughout this example: participants call
// IERC8001(companion).acceptCoordination(...) directly with the real
// struct-typed calldata, which is perfectly normal for a plain Solidity or
// ethers.js/viem caller -- it is only Reach's remote() that cannot express
// a struct-with-dynamic-array parameter. See index.rsh's header comment.
//
// Every field Reach passes as UInt (256-bit) is width-checked and narrowed
// to the real uint64 ERC-8001 expects (expiry/nonce) before use -- Reach's
// remote() computes this contract's function selectors from ITS OWN
// declared Fun signatures (UInt -> uint256), not by introspecting Solidity
// source, so this adapter's external functions are deliberately declared
// with full-width uint256 parameters throughout, matching what Reach's
// remote() ABI encoder actually produces. Passing the truncation-checked
// values on to the inherited uint64-typed ERC-8001 fields (via `this.`
// external self-calls, which naturally ABI-re-encode memory arguments as
// calldata) keeps ERC8001.sol and AtomicSwap.sol otherwise unmodified.
//
// The payload's administrative fields (version, conditionsHash, timestamp,
// metadata) are fixed constants rather than caller-supplied: the spec
// documents them as informational/opaque to Core, and ERC8001 requires the
// exact same payload bytes to be reconstructed at execute time as were
// committed to intent.payloadHash at propose time. Using fixed constants
// (rather than e.g. block.timestamp at propose time) makes the payload
// fully deterministic from the swap terms alone, so executeSwap can
// reconstruct it without the caller needing to carry propose-time state
// forward off-chain.
contract AtomicSwapReachAdapter is AtomicSwap {
  bytes32 private constant PAYLOAD_VERSION = bytes32(0);
  bytes32 private constant PAYLOAD_CONDITIONS_HASH = bytes32(0);
  uint256 private constant PAYLOAD_TIMESTAMP = 0;

  function _buildPayload(address tokenA, uint256 amountA, address tokenB, uint256 amountB)
    private pure returns (CoordinationPayload memory payload)
  {
    SwapTerms memory terms = SwapTerms({tokenA: tokenA, amountA: amountA, tokenB: tokenB, amountB: amountB});
    payload = CoordinationPayload({
      version: PAYLOAD_VERSION,
      coordinationType: SWAP_TYPE,
      coordinationData: abi.encode(terms),
      conditionsHash: PAYLOAD_CONDITIONS_HASH,
      timestamp: PAYLOAD_TIMESTAMP,
      metadata: ""
    });
  }

  function _toU64(uint256 v) private pure returns (uint64) {
    require(v <= type(uint64).max, "value exceeds uint64");
    return uint64(v);
  }

  // Alice (the proposer) signs the AgentIntent off-chain via EIP-712 against
  // this contract's domain ({name: "ERC-8001", version: "1"}, this chain id,
  // this contract's address) before calling proposeSwap. Per ERC8001, the
  // proposer auto-accepts if listed as a participant (they always are here),
  // so no separate acceptSwap call is needed for partyA.
  function proposeSwap(
    uint256 expiry,
    uint256 nonce,
    address partyA,
    address partyB,
    address tokenA,
    uint256 amountA,
    address tokenB,
    uint256 amountB,
    bytes calldata signatureA
  ) external returns (bytes32 intentHash) {
    require(uint160(partyA) < uint160(partyB), "participants not ascending");

    address[] memory participants = new address[](2);
    participants[0] = partyA;
    participants[1] = partyB;

    CoordinationPayload memory payload = _buildPayload(tokenA, amountA, tokenB, amountB);
    bytes32 payloadHash = keccak256(abi.encode(
      payload.version,
      payload.coordinationType,
      keccak256(payload.coordinationData),
      payload.conditionsHash,
      payload.timestamp,
      keccak256(payload.metadata)
    ));

    AgentIntent memory intent = AgentIntent({
      payloadHash: payloadHash,
      expiry: _toU64(expiry),
      nonce: _toU64(nonce),
      agentId: partyA,
      coordinationType: SWAP_TYPE,
      coordinationValue: 0,
      participants: participants
    });

    intentHash = this.proposeCoordination(intent, signatureA, payload);
  }

  // No acceptSwap here -- see the file-level comment above. Bob (the
  // acceptor) calls IERC8001(this).acceptCoordination(...) directly,
  // signing an AcceptanceAttestation off-chain via EIP-712 against this
  // contract's domain first. PAYLOAD_CONDITIONS_HASH (bytes32(0)) is the
  // conditionsHash convention this example's off-chain signer must use for
  // attestation.conditionsHash, matching proposeSwap's payload convention.

  // Anyone may call this once the swap is Ready. Reconstructs the same
  // deterministic payload built in proposeSwap so payloadHash matches.
  // Returns only `bool success`, not the full (bool, bytes) pair
  // executeCoordination itself returns -- AtomicSwap's own execution hook
  // always returns empty result bytes on success, so there's nothing
  // meaningful to expose there. This also sidesteps a real ABI mismatch
  // (confirmed by an actual failing Foundry run): Reach's remote() decodes
  // a Tuple(...)-typed return as a single struct-shaped value, which is
  // ABI-encoded with an outer offset word; Solidity's native multi-value
  // return `(bool, bytes memory)` has no such wrapping (each value gets
  // its own top-level slot). The two encodings aren't interchangeable, so
  // a `Tuple(Bool, BytesDyn)` remote() return type over a genuine
  // multi-value Solidity return fails to decode. A single-value return
  // doesn't hit this mismatch.
  function executeSwap(
    bytes32 intentHash,
    address tokenA,
    uint256 amountA,
    address tokenB,
    uint256 amountB
  ) external returns (bool success) {
    CoordinationPayload memory payload = _buildPayload(tokenA, amountA, tokenB, amountB);
    (success, ) = this.executeCoordination(intentHash, payload, "");
  }
}
