# Repository Maturity Classification

**Date**: 2026-07-22 (previous classification: Level 1 on 2026-07-21)
**Level**: 3 (More)
**Justification**: Level 2 is satisfied — AGENTS.md and manifest.yml carry real project content, and the documented validation commands are verified working end-to-end (`make hs-build` PASS, `make hs-test` 812/812 PASS on lts-22.44/GHC 9.6.7, `make sh-lint` clean on tracked scripts, `make hs-format` fixed via `hs/ormolu-tool/` and verified idempotent, `make expand` PASS — see `.agent/baseline.md`). Level 3 is satisfied on top of that: a documented risk model with per-path severity exists in AGENTS.md, skills are defined (`.claude/commands/prime`, `skills/*.md`, `.adws/skills/`), and templates exist (`.adws/templates/`, `.github/PULL_REQUEST_TEMPLATE.md`, issue templates). Level 4 is not met: the risk model is /prime-generated rather than team-customized, and escalation paths are generic (GitHub issues) rather than named team channels.

Note: on 2026-07-22 the `.adws` installer overwrote the real AGENTS.md and manifest.yml with blank templates (backups at `*.backup.1784773667`); this /prime run restored and refreshed them. Without that restore the repo would have presented as Level 0 despite its actual maturity.

## What Exists
- Real AGENTS.md and manifest.yml (restored from backup and refreshed 2026-07-22)
- Extensive Makefile-driven build system (root, `hs/`, `js/`, `docs/`) with documented, verified targets
- Haskell golden-test suite: 812/812 PASS on the modernized toolchain (GHC 9.6.7, solc 0.8.26, z3 4.12.5)
- Verified-Solidity output mode with its own example, golden tests, and Foundry deploy test
- CI via CircleCI and GitHub Actions
- Risk model, review checklists, and escalation triggers in AGENTS.md
- Skills and templates: `.claude/commands/`, `skills/`, `.adws/` framework scaffolding
- Design specs in `specs/`

## What is Missing
- hadolint and ag not installed locally (`make docker-lint`, `make check` unavailable)
- `goal` not on PATH — full `hs-test` needs the Docker-backed goal shim rebuilt per the recipe in AGENTS.md/baseline
- Stock `mo` broken under macOS bash 3.2 (workaround documented; durable fix is `brew install bash` or upgrading mo)
- Team-specific risk overrides and named escalation contacts (Level 4)

## Path to Next Level (Level 4)
- Have the team review and customize the /prime-generated risk table (e.g., formally designate `ETH_solc.hs` evmVersion changes as requiring human sign-off, which baseline already flags)
- Replace generic escalation channels with named team handles/contacts
- Install hadolint + ag and wire `make docker-lint` / `make check` into CI or pre-commit
