# CLAUDE.md — verified-solidity

> Project instructions for Claude Code. The full agent configuration lives in
> [`AGENTS.md`](../AGENTS.md) (human-readable) and [`manifest.yml`](../manifest.yml)
> (machine-readable). Read those for navigation, architecture, risk areas, and
> review expectations. This file holds only the essentials.

## What this repo is

An independent continuation of Reach: a DSL and verifying compiler for
decentralized applications, with a first-class verified-Solidity output mode.
One `.rsh` program compiles to Solidity/EVM and Algorand TEAL contracts plus a
JS frontend interface, with Z3-based formal verification on every compile;
`reach sol` emits a verified `.sol` + ABI + verification report (or nothing, if
verification fails). Monorepo: Haskell compiler in `hs/` (GHC 9.6.7,
lts-22.44), TypeScript runtime in `js/stdlib/`, docs in `docs/`, ~255 example
DApps in `examples/`.

## Key commands

```bash
cd hs && make expand          # fast sanity check (generates package.yaml, Version.hs, stdlib.sol)
cd hs && make hs-build        # build compiler + CLI (slow: long stack build)
cd hs && make hs-test         # golden tests; filter with HS_TEST_ARGS='-p <pattern>'
cd hs && make hs-test-accept  # accept new golden outputs after intentional changes
cd hs && make hs-format       # ormolu, formats in place
REACH_DOCKER=0 ./reach compile examples/argz/index.rsh   # compile an example locally
REACH_DOCKER=0 ./reach sol examples/verified-solidity/index.rsh  # verified-Solidity mode
```

`make expand` hazard: stock `mo` crashes under macOS bash 3.2 and leaves
`hs/src/Reach/Version.hs` EMPTY (make then thinks it's up to date) — `rm` the
target and rerun with a fixed mo. See AGENTS.md Known Issues.

Docker daemon is required for `js/`, `docs/`, and image builds (`make`).

## Hard rules

- Never edit generated files: `hs/package.yaml`, `hs/src/Reach/Version.hs`,
  `hs/sol/stdlib.sol` — edit `hs/package.open.yaml` / `VERSION` / `hs/sol/stdlib_reach.sol`
  and run `make expand`.
- Never hand-edit golden outputs in `hs/t/` — use `make hs-test-accept` and review the diff.
- Do not touch vendored OpenZeppelin under `hs/sol/openzeppelin-contracts-*`.
- High-risk areas (bugs become deployed financial contracts or void safety proofs):
  `hs/src/Reach/Connector/`, `hs/src/Reach/Verify/`, `hs/smt2/`, `hs/sol/`,
  `hs/rsh/stdlib.rsh`, `js/stdlib/`. Flag changes there for human review.
- Version strings live only in `VERSION` and `DEPS`; a `VERSION` bump needs a
  changelog entry in `docs/src/changelog/index.md`.
- Docs prose uses semantic newlines (one sentence per line).
