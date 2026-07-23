# verified-solidity

Write a smart contract once, get **formally verified Solidity** out.

This is an actively maintained, independent continuation of the
[Reach](https://github.com/reach-sh/reach-lang) language and verifying compiler
(Apache-2.0; see `LICENSE` and `NOTICE`), with a modernized toolchain
(solc 0.8.26, z3 4.12.5, GHC 9.6.7) and a first-class **verified-Solidity
output mode**: the compiler runs Z3-based formal verification (token
linearity, balance sufficiency, arithmetic overflow, assertion honesty under
both honest and dishonest participant models) on every compile and — only if
verification succeeds — emits a self-contained `.sol` file, its ABI, and a
machine-readable verification report that drop into standard Ethereum tooling
(Foundry, Hardhat, ethers, viem). No Docker, no JS runtime, no Algorand
toolchain required for this path.

```sh
REACH_DOCKER=0 ./reach sol examples/verified-solidity/index.rsh
# build/: index.main.sol  index.main.abi.json  index.main.verify.json
```

If verification fails, the compile exits nonzero with a counterexample witness
and emits no Solidity — verified-or-absent by construction. See
`examples/verified-solidity/` and `docs/src/guide/verified-solidity/` for the
worked example, and `specs/verified-solidity-compiler.md` for the design.

The full Reach platform (JS runtime, Algorand backend, dockerized devnets,
~255 example DApps) remains in-tree and functional.

# Development

If you want to work on the Reach compiler, you'll need:
- stack v2.15 or newer (the resolver targets GHC 9.6)
- `z3`
- `solc`
- [`goal`](https://github.com/algorand/go-algorand) OR link [`goal-devnet`](https://github.com/reach-sh/reach-lang/blob/master/scripts/goal-devnet) to `goal` in your `PATH`
- `mo`

The versions of our dependencies are specified in [`DEPS`](https://github.com/reach-sh/reach-lang/blob/master/DEPS).

Installation on macOS:
```
$ brew tap ethereum/ethereum
$ brew install haskell-stack z3 solidity
$ curl -sSL https://git.io/get-mo -o mo && chmod +x mo && sudo mv mo /usr/local/bin/
```

Installation on Ubuntu:
```
$ sudo apt update
$ sudo apt install z3
$ sudo snap install solc
$ curl -sSL https://get.haskellstack.org/ | sh
$ curl -sSL https://git.io/get-mo -o mo && chmod +x mo && sudo mv mo /usr/local/bin/
```

These instructions may not install the exactly correct versions, and that may
matter. If it does, consult `hs/Dockerfile.reachc` to learn how to get specific
versions.

The source code is in the `hs` directory.
