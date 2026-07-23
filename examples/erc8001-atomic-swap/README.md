# erc8001-atomic-swap

Reach + a vendored ERC-8001 (Agent Coordination Framework) companion,
verified together via the [verified-Solidity companion contract](../verified-solidity-interop/)
workflow. ERC-8001 (https://eips.ethereum.org/EIPS/eip-8001) defines a
minimal propose -> accept -> execute primitive for multi-party,
EIP-712-signed coordination; its "Hello World" is `AtomicSwap`, a trustless
two-party token swap, vendored here from
[github.com/KBryan/erc8001atomicswap](https://github.com/KBryan/erc8001atomicswap)
(MIT-licensed per its per-file SPDX headers; the upstream repo has no
repo-level LICENSE file at the time of writing).

Alice deploys `AtomicSwapReachAdapter.sol` (a thin, hand-written wrapper
around the vendored `AtomicSwap`/`ERC8001`/`IERC8001` contracts -- see that
file for the full design rationale), signs an `AgentIntent` off-chain via
EIP-712, and publishes it on-chain via `proposeSwap`. Bob reviews, signs an
`AcceptanceAttestation`, and calls `acceptCoordination` on the companion
**directly** (not through Reach -- see below). Once accepted, Bob triggers
`executeSwap` through Reach, which atomically moves both tokens.

## Two real, load-bearing findings from actually running this, not just reading the spec

1. **`acceptCoordination` cannot be called via `remote()`, for any Reach app,
   not just this one.** It requires `msg.sender == attestation.participant`.
   Reach's `remote()` always calls out *through* the app's own generated
   contract, so the companion never sees a participant's real address as
   `msg.sender` -- only the generated contract's. There is no
   wrapper-contract workaround, because Solidity can only invoke another
   `external` function of the same contract via a `this.` self-call, which
   itself resets `msg.sender`. The fix used here: Bob calls
   `IERC8001(companion).acceptCoordination(...)` directly, an ordinary
   wallet transaction outside this Reach program. `proposeCoordination` and
   `executeCoordination` have no such check and work fine through
   `remote()`. See `AtomicSwapReachAdapter.sol` and `index.rsh`'s header
   comments for the full detail.
2. **A `Tuple(Bool, BytesDyn)` `remote()` return type does not decode a
   genuine Solidity multi-value return `(bool, bytes memory)`.** Reach
   decodes a `Tuple(...)`-typed return as a single struct-shaped value,
   which the ABI spec wraps with an outer offset word; Solidity's native
   multi-value return has no such wrapping (each value gets its own
   top-level slot). The mismatch causes a bare `abi.decode` failure --
   confirmed by an actual Foundry revert with empty revert data (consistent
   with a low-level ABI-decode panic under `--via-ir`), not a hypothesis.
   The fix: `executeSwap` returns only `bool success` (`AtomicSwap`'s
   execution hook always returns empty result bytes on success here anyway,
   so nothing is lost).

Both are documented in code comments at their exact site, not just here.

## SMTChecker results (measured, not achievable at `require`)

As with `erc1155-companion`, `--companion-check require` (the default under
`--sol`) is not achievable here: this compiled closure is much larger than
the trivial `Vault.sol` case -- the adapter plus `AtomicSwap` + `ERC8001` +
`IERC8001` + 7 vendored OpenZeppelin files, including `ecrecover`-based
signature verification and loops over the participants array. The real
`reach sol` companion-check path has **no configurable timeout**
(`ETH_SolCheck.hs` hardcodes it to unbounded; there is no
`--companion-check-timeout` flag), so `make run` below compiles with
`--companion-check off` by default, same as `erc1155-companion` and for the
same reason. Run `--companion-check warn` yourself for the informational
SMTChecker report if you're prepared for a long, unbounded compile.

## Run

```sh
make run
# or, step by step:
REACH_DOCKER=0 ../../reach sol index.rsh --companion-check off
./foundry-test/run.sh   # optional; needs forge
```

`foundry-test/Deploy.t.sol` exercises the **full real round trip**: genuine
EIP-712 digests (computed the same way `ERC8001.sol` computes them), real
ECDSA signatures via `vm.sign`, Bob's direct `acceptCoordination` call, and
Reach-orchestrated deploy/propose/execute -- confirmed by asserting both
tokens' balances actually moved between Alice and Bob. It does not exercise
an ethers.js/viem `signTypedData` flow; see `index.rsh`'s header comment for
why that's outside what this environment can run end-to-end.

Artifacts land in `build/`:

- `index.main.sol` -- the verified generated contract
- `index.main.companion.AtomicSwapReachAdapter.sol` -- copy of the companion source
- `index.main.abi.json` -- ABI
- `index.main.verify.json` -- machine-readable report; see `vr_solidity` for
  the SMTChecker results and `vr_assumptions` for the trust boundary

See `docs/src/guide/verified-solidity-interop/` for the full story on the
three verification layers and the `--companion-check` levels.
