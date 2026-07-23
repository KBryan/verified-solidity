# verified-solidity-interop

Reach + hand-written Solidity, verified together.

The Reach program (`index.rsh`) escrows a deposit and pays it out using
`net()` from the hand-written companion contract `Vault.sol`, which it
deploys and calls on chain. Compiling with `reach sol` applies three
verification layers:

1. **Z3 (Reach pipeline)** verifies the orchestration — balance
   sufficiency, overflow, token linearity — and *proves* the `Refine`
   precondition of every `v.net(amt)` call at the call site.
2. **solc SMTChecker (CHC)** proves the `assert`s written inside
   `Vault.sol` (plus automatic overflow/underflow/div-by-zero checks).
   A violable assert fails the compile: verified-or-absent extends to
   companion code.
3. The `Refine` **postcondition** (`n <= amt`) is runtime-enforced in the
   generated contract and recorded as an explicit boundary assumption in
   `index.main.verify.json` (`vr_assumptions`), so nothing is silently
   trusted.

## Run

```sh
make run
# or, step by step:
REACH_DOCKER=0 ../../reach sol index.rsh
./foundry-test/run.sh   # optional; needs forge
```

Artifacts land in `build/`:

- `index.main.sol` — the verified generated contract
- `index.main.companion.Vault.sol` — copy of the companion source
- `index.main.abi.json` — ABI
- `index.main.verify.json` — machine-readable report; see `vr_solidity`
  for the SMTChecker results and `vr_assumptions` for the trust boundary

See `docs/src/guide/verified-solidity-interop/` for the full story,
including the `--companion-check` levels.
