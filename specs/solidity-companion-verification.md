# Feature: Solidity Companion Contracts with Verified Boundaries

## Feature Description
Let developers write hand-authored Solidity alongside a Reach program and get formal verification properties out of the combined system.

Today the pieces half-exist but do not compose into a verified product:
- `ContractCode({ETH: 'child.sol:Contract'})` already lets a Reach program embed and even **compile** raw Solidity (see `examples/new-contract1/`), deploy it with `new Contract(...)`, and call it with `remote(ctc, interface)`.
- `remote` interfaces already accept `Refine` types, so preconditions on arguments are **proven** by Z3 at every call site and postconditions on results are **runtime-enforced** in the generated contract.
- But the SMT verifier models every `DLE_Remote` / `DLE_ContractNew` result as an unconstrained havoc variable (`hs/src/Reach/Verify/SMT.hs:1246,1285`), the companion Solidity itself is never analyzed, none of this is admitted or reported by the verified-Solidity mode (`reach sol`), and `verify.json` is silent about the trust boundary.

This feature turns "Reach + hand-written Solidity" into a first-class verified workflow with three explicit layers:
1. **Orchestration layer (existing, surfaced)**: the Reach program is Z3-verified as today; refinement preconditions on companion calls are proven at every call site, and postconditions are runtime-enforced and assumed by the verifier.
2. **Companion layer (new)**: each companion `.sol` is run through solc's built-in SMTChecker (CHC engine; `assert`, overflow, div-by-zero targets) during compilation. Developers write properties directly in their Solidity as `assert(...)` statements — literally "write Solidity and get formal verification properties." Violated properties fail the compile in `--sol` mode (verified-or-absent extends to companion code).
3. **Transparency layer (new)**: `verify.json` gains a `vr_solidity` section enumerating every companion module, its SMTChecker property results (proven / violated / unknown, with counterexamples), and every boundary assumption (each remote call's assumed postcondition, or "havoc" when the interface declares none) — so CI and auditors can see exactly what was proven versus assumed.

## User Story
As a Solidity/EVM developer using the verified-Solidity workflow
I want to write parts of my system as hand-authored Solidity (existing libraries, gas-tuned code, patterns Reach cannot express) alongside my Reach program
So that I still get machine-checked verification properties — proven call-site preconditions, checked companion-contract assertions, and an auditable report of every remaining assumption — instead of losing all guarantees the moment raw Solidity enters the system.

## Problem Statement
The `reach sol` mode promises "verified-or-absent" Solidity, but real systems almost always need some hand-written Solidity (an existing ERC-20, an oracle adapter, a gas-critical routine). Today the developer faces a cliff:
1. `ContractCode` + `remote` technically work in a full compile, but the verified-Solidity mode neither documents nor tests this path, and the emitted artifacts/report ignore companion code entirely.
2. The verifier havocs every remote result, silently weakening every downstream theorem, and `verify.json` gives no indication that a trust boundary exists — a report can read "verified: true" while depending on completely unanalyzed Solidity.
3. The companion Solidity itself gets zero analysis: no overflow checking, no assertion checking, nothing — even though the pinned toolchain (solc 0.8.26 + z3 4.12.5) ships everything needed to run solc's SMTChecker.
4. There is no worked example, no docs, and no golden test locking any of this behavior in.

## Solution Statement
Build on the existing `ContractCode` → `new Contract` → `remote` pipeline rather than inventing new syntax:

1. **Admit companion Solidity into `--sol` mode.** Allow `ContractCode({ETH: 'path.sol:Name'})` (and `.json`/`.bin` forms) when `ccSolOnly` is set, copy the companion source into `build/` alongside the emitted artifacts, and record the module in the report. ALGO keys are simply unused when connectors are restricted to ETH.
2. **Run SMTChecker over companion `.sol` sources.** In `Reach.Connector.ETH_solc`, add a second standard-json invocation with `settings.modelChecker = {engine: "chc", targets: [assert, overflow, divByZero], ...}` for each companion source at `ContractCode` evaluation time. Parse the model-checker diagnostics into structured results. Detect at runtime whether the local solc has a usable SMT solver (z3 dynamically loaded or Eldarica); if not, results degrade to status `skipped` — never silently, always recorded in the report. In `--sol` mode, a `violated` property is fatal (compile dies, no artifacts), and `skipped`/`unknown` are recorded as open assumptions.
3. **Surface boundary assumptions.** Extend `Reach.VerifyReport` with `vr_solidity :: [SolModuleReport]` (module path, contract name, per-property results, counterexample text) and `vr_assumptions :: [BoundaryAssumption]` (call-site source location, remote function, assumed postcondition text or `"havoc"`). Populate the assumption list where `DLE_Remote`/`DLE_ContractNew` hit `unbound` in `SMT.hs` — observation only, zero change to the SMT encoding.
4. **Ship the workflow**: a `examples/verified-solidity-interop/` example (Reach escrow orchestrating a hand-written Solidity vault with `assert`-stated invariants, plus a Foundry test), golden tests for pass/fail/skip paths, and a docs guide that is honest about the three layers (proven / checked / assumed).

Compiling refinement postconditions into standalone SMTChecker harnesses (to discharge the boundary assumptions themselves) is explicitly future work — see Notes.

## Relevant Files
Use these files to implement the feature:

- `hs/src/Reach/Connector/ETH_solc.hs` — solc standard-json invocation (`try_compile_sol` at ~159, single-source `"sources"` map at ~191, solc exec at ~262). Add the model-checker invocation path, solver-availability probe, and diagnostic parsing here. **HIGH-RISK AREA — flag for human review; the existing compile path must stay byte-identical.**
- `hs/src/Reach/Connector/ETH_Solidity.hs` — `ccPath`/`ccSol`/`ccJson` (~1905–1927) resolve `ContractCode` ETH values, `compile_sol_` compiles companion `.sol`; hook the SMTChecker run and module-report capture where `ccSol` compiles the source. `DLE_Remote` emission at ~960 and `DLE_ContractNew` at ~1134 need no codegen change. **HIGH-RISK AREA — artifact/report additions only.**
- `hs/src/Reach/Verify/SMT.hs` — `DLE_Remote`/`DLE_ContractNew`/`DLE_ContractFromAddress` havoc at 1246/1285/1286 via `unbound` (1289); add assumption-recording (append to the report accumulator) at these points. `doClaim` (1290) and `verify1` (771) are reference only. **HIGH-RISK AREA — observation only; no encoding, solver, or die-logic changes.**
- `hs/src/Reach/Verify/Shared.hs` — `vo_report :: Maybe (IORef VerifyReportAccum)` (line 19); the accumulator is already threaded — reuse it for boundary assumptions.
- `hs/src/Reach/VerifyReport.hs` — report types (`VerifyReport` at 83, `VerifyFailure` at 23, accumulator at 57); add `SolModuleReport`, `SolPropertyResult`, `BoundaryAssumption` types with stable JSON field names (public CI contract, per the module's own header comment).
- `hs/src/Reach/Compiler.hs` — `--sol`-mode guards (93–104: verification required, ETH connector required, restricted output list) and report emission (260–268). Extend the allowed-output list with companion `.sol` copies, and merge Solidity-module results into the report before `writeVerifyReport`; make `violated` SMTChecker results fatal here (before artifact emission).
- `hs/src/Reach/Eval/Core.hs` — `SLPrim_ContractCode` handler (~4276) reads and validates `ContractCode` values; this is where companion sources are first resolved (via `LC_RefFrom "ContractCode"`), so trigger companion compilation/analysis (or at least registration) here. `SLPrim_remote` (~3834) and `doInteractiveCall` (~4497, refinement pre/post wiring) are reference only — no eval-semantics changes.
- `hs/src/Reach/CommandLine.hs` — add `co_solCompanionCheck :: SolCompanionCheckLevel` (`require` | `warn` | `off`, default `warn`; forced `require`-or-explicit in `--sol` mode) following the existing option patterns (~101).
- `hs/app/reachc/Main.hs` — thread the new option into `CompilerConfig` (69–92).
- `hs/src/Reach/AST/DLBase.hs` — `DLContractNew`/`dcn_code` (856–876), `DLE_Remote` (912), `ClaimType` (551) — reference for IR carriers; expected to need no change (companion metadata can live in the compiler-level registry rather than the IR).
- `hs/test/Reach/Test_Compiler.hs` — golden harness; `sol_only*` fixtures get `--sol` + artifact listing (`solOnlyArgs` 50–54, `solOnlyArtifacts` 56–68). Extend the fixture-prefix convention to `sol_companion*` and make the harness copy fixture-adjacent `.sol` companion files into the compile dir.
- `hs/t/y/`, `hs/t/n/` — golden fixtures (see New Files).
- `hs/package.open.yaml` — register any new module (never edit generated `package.yaml`); run `make expand`.
- `scripts/reach-sol` — mention companion-source artifacts in its output listing; keep shellcheck-clean.
- `examples/new-contract1/` — the existing `ContractCode` example; regression reference, do not modify.
- `examples/verified-solidity/` — pattern for the new example's layout and Foundry test (`foundry-test/run.sh`).
- `docs/src/guide/verified-solidity/` — existing guide to extend with the interop chapter (semantic newlines).
- `AGENTS.md`, `manifest.yml` — register new paths/commands after implementation.
- `DEPS` — solc 0.8.26 / z3 4.12.5 pins; no bump anticipated, but the SMTChecker solver-probe messaging must reference these.

### New Files
- `hs/src/Reach/Connector/ETH_SolCheck.hs` — self-contained SMTChecker driver: solver-availability probe (cached per-process), standard-json `modelChecker` request builder, diagnostic parser producing `SolModuleReport`. Kept out of the existing high-risk compile path so `ETH_solc.hs` changes stay minimal.
- `hs/t/y/sol_companion.rsh` + `sol_companion_child.sol` + `.txt` — golden: `--sol` compile of a Reach app deploying/calling a companion contract whose `assert`s all prove; artifacts line includes the companion copy.
- `hs/t/y/sol_companion_skip.rsh` + `.sol` + `.txt` — golden: solver unavailable / check level `warn` → compile succeeds, report records `skipped` (harness pins the level via fixture args to keep the golden deterministic).
- `hs/t/n/sol_companion_vfail.rsh` + `.sol` + `.txt` — golden: companion `assert` violable → SMTChecker counterexample printed, nonzero exit, no artifacts in `--sol` mode.
- `hs/t/n/sol_companion_refine.rsh` + `.sol` + `.txt` — golden: caller violates a `Refine` precondition on a companion interface → existing Z3 theorem failure with witness (locks the caller-side proof behavior in `--sol` mode).
- `hs/test/Reach/Test_SolCheck.hs` — unit tests for the diagnostic parser (canned solc model-checker JSON → statuses) and the report JSON shape.
- `examples/verified-solidity-interop/index.rsh`, `Vault.sol`, `Makefile`, `README.md`, `foundry-test/` — worked example: Reach escrow + hand-written vault with asserted invariants; Foundry test deploys the emitted main `.sol` together with `Vault.sol` and exercises a full round trip.
- `docs/src/guide/verified-solidity/interop.md` — the guide chapter (three-layer verification story, what is proven vs. checked vs. assumed, reading `vr_solidity`/`vr_assumptions` in CI).
- `specs/solidity-companion-verification.md` — this plan.

## Implementation Plan
### Phase 1: Foundation
Report vocabulary and plumbing with zero behavior change. Add `SolModuleReport`/`SolPropertyResult`/`BoundaryAssumption` to `Reach.VerifyReport` (+ accumulator fields + `ToJSON`), the `co_solCompanionCheck` flag surface, and the `ETH_SolCheck` module skeleton (probe + parser) with unit tests against canned solc output. Nothing calls the new code yet; the full golden suite must stay green with zero accepts.

### Phase 2: Core Implementation
Wire the behavior. (a) Boundary assumptions: at the three `unbound` sites in `SMT.hs`, append a `BoundaryAssumption` (source location, callee name, declared postcondition text or `"havoc"`) to the existing `vo_report` accumulator — observation only. (b) Companion analysis: when `ccSol`/`ccJson`/`ccBin` resolve a `ContractCode` ETH value, register the module; for `.sol` sources additionally invoke the SMTChecker driver and capture results (for `.json`/`.bin`, record status `opaque-bytecode`). (c) Enforcement: in `Compiler.hs`, merge module results into the report; die (before artifact emission) on `violated` always, and on `skipped`/`unknown` only when the check level is `require`; `--sol` mode defaults to `require` unless the user passes an explicit lower level.

### Phase 3: Integration
Make it a product: companion-source copies in `build/` and the `--sol` allowed-output list, `scripts/reach-sol` output listing, golden fixtures (`sol_companion*` prefix + harness support for fixture-adjacent `.sol` files), the `examples/verified-solidity-interop/` example with Foundry test, the docs chapter, and AGENTS.md/manifest.yml registration.

## Step by Step Tasks
IMPORTANT: Execute every step in order, top to bottom.

### 1. Baseline
- Confirm clean baseline: `cd hs && make expand && make hs-build && make hs-test` → 812/812 (macOS: Docker up + goal shim on PATH; see AGENTS.md Known Issues for the `mo`/bash and accept-run hazards).
- Verify the pinned solc's SMTChecker status locally: `solc --model-checker-engine chc --model-checker-targets assert` on a scratch contract; record whether z3 loads dynamically (this determines whether local goldens exercise `proven` or `skipped` paths).

### 2. Report types (no behavior change)
- In `hs/src/Reach/VerifyReport.hs`: add `SolPropertyResult { spr_target, spr_status ∈ proven|violated|unknown|skipped|opaque-bytecode, spr_at, spr_counterexample }`, `SolModuleReport { smr_path, smr_contract, smr_solcVersion, smr_properties }`, `BoundaryAssumption { ba_at, ba_callee, ba_kind ∈ remote|contractNew|contractFromAddress, ba_assumed }`; extend `VerifyReport` with `vr_solidity`, `vr_assumptions` and the accumulator with matching add-functions. Keep JSON field names stable and snake-prefixed like existing fields.
- Extend `hs/test/Reach/Test_VerifyReport.hs` (or add cases alongside) to lock the new JSON shape.
- `cd hs && make hs-build && make hs-test HS_TEST_ARGS='-p VerifyReport'` — green.

### 3. Flag surface (no behavior change)
- `hs/src/Reach/CommandLine.hs`: add `co_solCompanionCheck` (`--companion-check=require|warn|off`, default `warn`); thread through `hs/app/reachc/Main.hs` into a new `CompilerConfig` field in `hs/src/Reach/Compiler.hs`. Unused as yet.
- Full suite still zero-accept green.

### 4. SMTChecker driver module
- Create `hs/src/Reach/Connector/ETH_SolCheck.hs`: build a standard-json request with `settings.modelChecker = {engine: "chc", targets: ["assert","overflow","divByZero"], timeout: <ms>, invariants: ["contract"], showUnproved: true}`; run `solc --standard-json` (mirror the exec pattern at `ETH_solc.hs:262`); parse `errors[]` diagnostics (model-checker warnings carry `errorCode` values — map 6328-style "might happen"→`unknown`/`violated` per message shape, absence of a target's diagnostic + `showUnproved` semantics → `proven`); implement the solver-availability probe (compile a 3-line contract with a trivially false assert; if no counterexample diagnostic appears, mark solver-unavailable → everything `skipped`).
- Register the module in `hs/package.open.yaml`; run `make expand`.
- Add `hs/test/Reach/Test_SolCheck.hs` with canned solc JSON fixtures for each status; wire into `hs/test/Main.hs`.

### 5. Companion registration + analysis at ContractCode resolution
- In `hs/src/Reach/Connector/ETH_Solidity.hs` (`ccPath`/`ccSol`/`ccJson`/`ccBin`): thread a registry (compiler-level `IORef`, plumbed the same way `vo_report` is) recording each resolved ETH companion module; for `.sol:` values run the `ETH_SolCheck` driver (respecting `--verify-timeout`-style budget) and store the `SolModuleReport`; `.json`/`.bin` register as `opaque-bytecode`.
- Ensure the analysis runs once per distinct source path even if `ContractCode` is evaluated multiple times (keyed cache in the registry).
- Non-`--sol` compiles: results are report-only (and printed as a summary line), never fatal at `warn`.

### 6. Boundary assumptions in the verifier (HIGH-RISK — observation only)
- In `hs/src/Reach/Verify/SMT.hs` at the `DLE_Remote` (1246), `DLE_ContractNew` (1285), `DLE_ContractFromAddress` (1286) cases: before calling `unbound`, append a `BoundaryAssumption` to the `vo_report` accumulator when present (`Nothing` accumulator ⇒ exact existing behavior). The assumed-postcondition text comes from the remote interface's declared refinement when available (pretty-print the `SLTypeFun` range refinement, else `"havoc"`).
- Re-run the full golden suite: stdout goldens byte-identical, zero accepts.

### 7. Enforcement + artifacts in `--sol` mode
- `hs/src/Reach/Compiler.hs`: merge the companion registry into the report before `writeVerifyReport` (~266); die with a clear error (listing violated properties + counterexamples) on any `violated` result — always — and on `skipped`/`unknown` when the effective level is `require`; make `--sol` default the level to `require` (explicit `--companion-check=warn` opts out, recorded in the report).
- Extend the `--sol` allowed-output list (~103) so companion sources are copied into `build/` as `<src>.<app>.companion.<name>.sol`, and `verify.json` references them by that name.
- Manual check: build a scratch example with a companion vault; `REACH_DOCKER=0 ./reach sol …` emits main `.sol` + `.abi.json` + `.verify.json` + companion copy, and `verify.json` contains populated `vr_solidity` and `vr_assumptions`.

### 8. Golden tests
- Extend `hs/test/Reach/Test_Compiler.hs`: `sol_companion*` basenames get `--sol` + artifact listing like `sol_only*`, plus copy fixture-adjacent `*_child.sol`/named `.sol` files next to the compile input; pin `--companion-check` per fixture (deterministic goldens regardless of local solver availability — the `skip` fixture forces the probe off via a test-only env/flag).
- Add the four fixtures from New Files; generate goldens via `make hs-test-accept HS_TEST_ARGS="-p '/sol_companion/'"` and review the accepted diffs by hand (never hand-edit).
- Run the full suite; only the new tests appear, zero unexpected accepts.

### 9. Example, wrapper, docs
- Create `examples/verified-solidity-interop/` (Reach escrow + `Vault.sol` with asserted invariants, `Refine`d remote interface, Makefile, README) and `foundry-test/` mirroring `examples/verified-solidity/foundry-test/run.sh` (guard behind `command -v forge`); confirm the round trip passes locally.
- Update `scripts/reach-sol` artifact listing (shellcheck-clean; `make sh-lint`).
- Write `docs/src/guide/verified-solidity/interop.md` (semantic newlines): the three layers, exactly what is proven vs. runtime-checked vs. assumed, `vr_solidity`/`vr_assumptions` consumption in CI, solver-availability caveats, and the honest limits (no verification of `.bin`/`.json` bytecode; refinement postconditions on companions are assumed, not proven).
- Update `AGENTS.md` (Navigation, Run Locally) and `manifest.yml`; new user-facing error codes documented in `docs/` per repo convention.

### 10. Validation
- Run every command in `Validation Commands`; all must pass with zero regressions. Format (`make hs-format`) before the final test run.

## Testing Strategy
### Unit Tests
- `Test_SolCheck.hs`: model-checker diagnostic parser over canned solc 0.8.26 JSON — one fixture per status (`proven`, `violated` with counterexample text, `unknown`, solver-unavailable → `skipped`); request-builder shape (engine/targets/timeout).
- `Test_VerifyReport.hs` additions: JSON field names for `vr_solidity`/`vr_assumptions` locked (public CI contract).
- CommandLine parse test: `--companion-check` levels; `--sol` default is `require`.

### Integration Tests
- Golden `t/y/sol_companion`: full `--sol` compile with a passing companion — artifacts include the companion copy; report populated.
- Golden `t/y/sol_companion_skip`: solver-off path — compile succeeds at `warn`, `skipped` recorded.
- Golden `t/n/sol_companion_vfail`: violable companion `assert` — nonzero exit, counterexample in stdout, no artifacts.
- Golden `t/n/sol_companion_refine`: caller violates a companion-interface precondition — existing Z3 witness output, proving the caller-side layer in `--sol` mode.
- Full existing suite (812) as the regression net — default-mode and `sol_only*` output byte-identical.
- Manual/CI-optional: `examples/verified-solidity-interop/foundry-test/run.sh` end-to-end deploy of main + companion contracts.

### Edge Cases
- `ContractCode` with only ALGO keys under `--sol` → clear user error (ETH code required), not a crash.
- Companion `.sol` that fails plain solc compilation → existing compile error surfaces before any SMTChecker run.
- Companion `.sol` importing other files (`import "./lib.sol"`) → either supported via solc `--allow-paths` relative resolution or rejected with a clear error — decide during step 5 and test whichever holds.
- Same companion source referenced by two `ContractCode` values → analyzed once, reported once.
- SMTChecker timeout → status `unknown` with the timeout noted, honoring the configured budget; `require` level makes it fatal.
- `.bin`/`.json` (pre-compiled) companions in `--sol` mode → `opaque-bytecode` is fatal at `require` unless the user explicitly passes `warn` (no silent unverified bytecode in a "verified" artifact set).
- Companion contract name containing Solidity-reserved/`solReservedNames` collisions with generated code → companion is a separate compilation unit, but the `build/` copy filename must not collide with the main `.sol`; assert distinct names.
- Verification disabled via the accursed env var + companion present → existing `--sol` refusal already covers it; non-`--sol` compiles skip companion enforcement too (report-only).

## Acceptance Criteria
- A Reach program using `ContractCode({ETH: 'vault.sol:Vault'})` + `new Contract` + `remote` with `Refine`d interfaces compiles under `REACH_DOCKER=0 ./reach sol` and emits main `.sol`, `.abi.json`, `.verify.json`, and the companion source copy.
- `verify.json` contains: `vr_solidity` with per-property SMTChecker statuses for every companion module, and `vr_assumptions` with one entry per remote/contract-new call site (declared postcondition text or `"havoc"`).
- A violable `assert` in companion Solidity makes the `--sol` compile exit nonzero with the counterexample and emit no artifacts.
- A Reach-side call violating a companion interface `Refine` precondition fails Z3 verification exactly as ordinary assertions do (witness printed).
- With no SMT solver available to solc, compiles at `warn` succeed with `skipped` statuses recorded; `--sol` (default `require`) refuses with an actionable message naming the `DEPS`-pinned z3.
- Default-mode compiles and all pre-existing goldens are byte-identical (zero accepts); full suite 812 + new tests passing.
- Example round trip (`examples/verified-solidity-interop/foundry-test/run.sh`) passes with local forge.
- Docs chapter exists and states the proven/checked/assumed boundaries honestly; AGENTS.md and manifest.yml updated.

## Validation Commands
Execute every command to validate the feature works correctly with zero regressions.

- `cd hs && make expand` — regenerate `package.yaml`/`Version.hs`/`stdlib.sol`; exit 0 (macOS: bash-4 `mo` fix per AGENTS.md).
- `cd hs && make hs-build` — full compiler build; exit 0.
- `cd hs && make hs-test HS_TEST_ARGS="-p SolCheck"` — SMTChecker driver unit tests.
- `cd hs && make hs-test HS_TEST_ARGS="-p VerifyReport"` — report-shape tests including new fields.
- `cd hs && make hs-test HS_TEST_ARGS="-p '/sol_companion/'"` — the four new goldens in isolation.
- `cd hs && make hs-test` — full golden suite: 812 pre-existing + new tests, **zero unexpected accepts** (Docker up + goal shim; `docker info` first per the accept-run hazard).
- `REACH_DOCKER=0 ./reach sol examples/verified-solidity-interop/index.rsh && ls examples/verified-solidity-interop/build/*.sol examples/verified-solidity-interop/build/*.abi.json examples/verified-solidity-interop/build/*.verify.json` — end-to-end artifact check including the companion copy.
- `python3 -c "import json,glob; d=json.load(open(glob.glob('examples/verified-solidity-interop/build/*.verify.json')[0])); assert d['vr_verified'] is True; assert len(d['vr_solidity'])>=1; assert len(d['vr_assumptions'])>=1; assert all(p['spr_status']=='proven' for m in d['vr_solidity'] for p in m['smr_properties'])"` — report contract check.
- `examples/verified-solidity-interop/foundry-test/run.sh` — Foundry deploy + interaction round trip (guarded on `command -v forge`).
- `REACH_DOCKER=0 ./reach sol examples/verified-solidity/index.rsh` — pre-existing companion-free `--sol` flow unchanged.
- `make sh-lint` — shellcheck over the updated `scripts/reach-sol`.
- `cd hs && make hs-format` — ormolu clean.

## Notes
- **Scope honesty (docs must repeat this)**: companion Solidity properties are verified by solc's SMTChecker (CHC), a different engine and trust base than Reach's Z3 pipeline; interface `Refine` postconditions on companion calls remain *assumed + runtime-enforced*, not proven — the report says so explicitly. Compiling refinement postconditions into generated SMTChecker harnesses (discharging those assumptions mechanically) is the natural follow-up and is deliberately out of scope here: it requires modeling constructor state and reusing the DL→Sol expression emitter outside the connector, a substantially larger change.
- **solc SMTChecker solver reality**: official solc 0.8.26 binaries load z3 dynamically (`libz3`) when present and otherwise cannot discharge CHC queries; brew/apt installs vary. Hence the runtime probe + `skipped` status + `require`-by-default only in `--sol` mode. If probing proves too flaky across platforms, fallback design: `modelChecker.solvers: ["smtlib2"]` emitting queries that reachc feeds to its own pinned z3 — more work, tracked as a follow-up, not needed for v1.
- **High-risk areas touched** (`hs/src/Reach/Verify/SMT.hs`, `hs/src/Reach/Connector/`): per repo policy these require human review. The plan restricts SMT.hs to accumulator appends at existing havoc sites and keeps the new solc invocation in a separate module (`ETH_SolCheck.hs`) so the production compile path in `ETH_solc.hs` is untouched.
- No new Haskell dependencies anticipated (`aeson`, `process`, `containers` already present); `uv add` does not apply (Haskell/stack project — any dependency change goes in `hs/package.open.yaml` + `make expand`).
- New user-facing error codes (companion violated / opaque bytecode under require / solver unavailable) need docs entries per the repo's error-code convention.
- Golden determinism: SMTChecker output can vary with solver availability and version — fixtures must pin `--companion-check` and use a test-only switch to force the probe result, so goldens never depend on the host having `libz3` loadable by solc.
- Future considerations: (a) refinement-postcondition harness generation (above); (b) `vr_assumptions` for `DLE_Interact`/`DLE_GetUntrackedFunds` havocs too — same mechanism, wider transparency; (c) SARIF export of `vr_solidity` for GitHub code scanning; (d) multi-file companion projects via solc `--standard-json` source maps once the import edge case (step 5) demands it.
