# erc1155-companion

Reach + a vendored OpenZeppelin ERC1155, verified together via the
[verified-Solidity companion contract](../verified-solidity-interop/) workflow.

Admin deploys `ERC1155Wrapped` (`oz/ERC1155Wrapped.sol`, a thin
deployer-gated wrapper around OpenZeppelin 4.5.0's `ERC1155.sol`, vendored
verbatim under `oz/`), mints `amount` units of token `id` to Recipient, and
Recipient reads back its balance.

## Why a companion, not a native primitive

Reach's `Token` primitive (`Token.new()`) compiles natively to an ERC-20
contract, but it models exactly one fungible asset per call — Reach's `T_Token`
IR type has no notion of multiple independent token IDs sharing one contract.
ERC-1155 (one contract, many IDs, `balanceOf(address,uint256)`,
`safeBatchTransferFrom`, ...) doesn't fit that model. Making it a *native*
primitive on par with `Token` would need a new IR type threaded through every
compiler pass and both connector backends, including the SMT verifier core --
a large undertaking with real soundness risk. Instead this example vendors
real OpenZeppelin `ERC1155.sol` as a companion contract and calls it through
`remote()`, verified the same three ways as `verified-solidity-interop/`.

## Scope and honest limits (v1)

- **Single-ID operations only.** `safeBatchTransferFrom`/`balanceOfBatch` are
  not exposed. Reach's `Array(T,N)` is fixed-length at compile time and there
  is no dynamic-array type for non-byte elements (only `BytesDyn`/`StringDyn`
  exist), so Solidity's `uint256[]`/`address[]` batch parameters cannot be
  given a faithful `remote()` signature. Callers needing batch semantics must
  loop `safeTransferFrom` per id from Reach -- note this is N separate calls,
  not one atomic batch call, so gas and atomicity differ from a real batch.
- **No supply-conservation proof.** solc's SMTChecker proves internal
  arithmetic/assert safety in `ERC1155Wrapped.sol` and its full OpenZeppelin
  dependency closure (overflow/underflow/div-by-zero, plus any explicit
  `assert`s). It does **not** prove ERC1155 semantic properties like "total
  supply per id is conserved across transfers" -- OZ's base `ERC1155` doesn't
  track total supply (that's the separate `ERC1155Supply` extension, not
  vendored here), and no such property is asserted in Solidity.
- **`mint`/`burn` results are `havoc` to Z3.** Only `mint`'s `amount > 0` and
  `safeTransferFrom`'s `from != to` are non-trivial `Refine` preconditions;
  every other call result is recorded as an explicit boundary assumption in
  `vr_assumptions` (see below), not proven.

## SMTChecker results are real, and `require` is not achievable here

Unlike `Vault.sol` (25 lines, no imports, proves instantly), `ERC1155Wrapped.sol`
pulls in OpenZeppelin's real `ERC1155.sol` and its dependency closure -- loops,
storage mappings, and low-level calls in `Address.sol`. Measured directly with
solc's CHC engine (`--model-checker-timeout 30000`, i.e. 30s per query, the
same targets `reach sol` uses): **6 of 14 verification conditions proven, 8
unproven**, over roughly 7 minutes wall clock, plus solc warning of 3
unsupported language features (constructs -- almost certainly the inline
assembly in `Address.sol`'s `isContract`/low-level call helpers -- that CHC
cannot model at all, not just a timeout). `--companion-check require` (the
default under `--sol`) treats anything short of `proven` as fatal, so it
cannot pass here; this is a hard limit of what solc's SMTChecker can decide
for real-world OpenZeppelin code today, not a bug in this example.

Worse for routine use: the real `reach sol` companion-check path has **no
configurable timeout** (`ETH_SolCheck.hs` hardcodes it to 0 = unbounded; there
is no `--companion-check-timeout` flag), so an actual `--companion-check warn`
run can take an unpredictable, possibly very long time per compile rather than
the bounded ~7 minutes measured above. For that reason `make run` below
compiles with `--companion-check off` by default. Run `--companion-check warn`
yourself if you want the informational SMTChecker report and are prepared for
a long-running, unbounded compile.

## Run

```sh
make run
# or, step by step:
REACH_DOCKER=0 ../../reach sol index.rsh --companion-check off
./foundry-test/run.sh   # optional; needs forge

# Optional, and can run for a long time (no timeout bound in this repo's
# companion-check pipeline as of this writing):
REACH_DOCKER=0 ../../reach sol index.rsh --companion-check warn
```

Artifacts land in `build/`:

- `index.main.sol` -- the verified generated contract
- `index.main.companion.ERC1155Wrapped.sol` -- copy of the companion source
- `index.main.abi.json` -- ABI
- `index.main.verify.json` -- machine-readable report; see `vr_solidity` for
  the SMTChecker results and `vr_assumptions` for the trust boundary

See `docs/src/guide/verified-solidity-interop/` for the full story on the
three verification layers and the `--companion-check` levels.
