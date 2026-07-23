# {#guide-verified-solidity-interop} Verified Solidity interop: companion contracts

The verified Solidity workflow can include hand-written Solidity alongside your Reach program.
You reference a `.sol` source with `ContractCode`, deploy it with `new Contract`, and call it with `remote`; the compiler verifies the combination and reports exactly what was proven, what is checked at runtime, and what remains assumed.

```reach
const VaultCode = ContractCode({ ETH: 'Vault.sol:Vault' });
const vaultNew = new Contract(VaultCode, {});
const vault = vaultNew();
const v = remote(vault, {
  net: Refine(
    Fun([UInt], UInt),
    (([a]) => a >= 100 && a <= 1000000),
    (([a], n) => n <= a)),
});
const n = v.net(amt);
```

See `examples/verified-solidity-interop/` for the complete worked example, including a Foundry test that exercises the emitted contract together with its companion.

## Three verification layers

Be precise about what is verified by which engine; the layers are different and the report distinguishes them.

1. **Proven by Z3 (the Reach pipeline).**
The Reach program is verified exactly as in the companion-free workflow: token linearity, balance sufficiency, arithmetic overflow, and assertion honesty under both honest and dishonest participant models.
When a `remote` interface uses `Refine`, the precondition is proven at every call site: passing an argument that could violate it is a verification failure with a counterexample witness.

2. **Proven by solc's SMTChecker (the companion contract).**
Every companion `.sol` source is compiled a second time with solc's built-in model checker (the CHC engine), targeting every `assert` you wrote plus the automatic overflow, underflow, and division-by-zero checks.
You state properties directly in Solidity as `assert(...)` statements, and the compiler proves them or produces a counterexample.
In `--sol` mode a violated property aborts the compile and no artifacts are emitted: verified-or-absent extends to companion code.

3. **Assumed and runtime-enforced (the boundary).**
The Z3 verifier does not model the companion's behavior; the result of every `remote` call (and of `new Contract`) is treated as unconstrained — a havoc value.
A `Refine` postcondition narrows this: it is compiled into a runtime check in the generated contract, and the verifier assumes it downstream.
It is not proven against the companion's code.
Every such boundary is enumerated in the verification report so nothing is silently trusted.

## The report

`<src>.<app>.verify.json` gains two sections.

`vr_solidity` lists each companion module with its per-property SMTChecker results:

```json
"vr_solidity": [
  { "smr_path": "Vault.sol",
    "smr_contract": "Vault",
    "smr_artifact": "index.main.companion.Vault.sol",
    "smr_solcVersion": "0.8.26+...",
    "smr_properties": [
      { "spr_target": "Assertion violation",
        "spr_status": "proven",
        "spr_at": "Vault.sol:14:5",
        "spr_counterexample": null } ] } ]
```

`spr_status` is one of `proven`, `violated` (with the counterexample), `unknown` (the solver could not decide within the timeout), `skipped` (solc found no SMT solver), or `opaque-bytecode` (the companion was referenced as pre-compiled `.bin`/`.json` and cannot be analyzed).

`vr_assumptions` lists every place the verifier treated an external contract's behavior as unconstrained:

```json
"vr_assumptions": [
  { "ba_at": "./index.rsh:46:16:application",
    "ba_kind": "remote",
    "ba_callee": "net",
    "ba_assumed": "havoc: UInt" } ]
```

The companion source is also copied into the output directory as `<src>.<app>.companion.<Contract>.sol` so the artifact set is self-contained.

## Check levels

The `--companion-check` flag controls how strictly companion results gate the compile:

+ `require` (the default in `--sol` mode): anything short of `proven` — including `skipped`, `unknown`, and `opaque-bytecode` — is fatal.
+ `warn` (the default otherwise): results are reported; only a `violated` property is fatal, and only in `--sol` mode.
+ `off`: no companion analysis runs.

With `--sol`, pass `--companion-check warn` explicitly to accept unproven companion code; the report still records everything.

## Solver availability

solc's SMTChecker discharges its queries through an SMT solver that it loads dynamically (typically `libz3`).
If solc cannot find one, every companion property is reported as `skipped`; at the default `--sol` level this aborts the compile with a message naming the `DEPS`-pinned z3 version.
Install z3 so that solc can load it, or lower the check level.

## Honest limits

+ `Refine` postconditions on companion calls are assumed and runtime-enforced, not proven against the Solidity; proving them would require generating SMTChecker harnesses, which is future work.
+ Pre-compiled companions (`.bin` / `.json` forms of `ContractCode`) are never analyzed; they are reported as `opaque-bytecode`.
+ The SMTChecker and the Reach pipeline are different engines with different trust bases; a `proven` companion property is a proof about the companion source under solc's semantics, not part of the Z3 proof of the Reach program.
