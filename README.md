# MediaCreator

MediaCreator is a standalone, local-first gate pipeline for media release readiness.

## What It Provides
- Strict golden-vector contract validation.
- Producer payload contract validation and transform to runtime signals.
- Production gate validation against runtime signals.
- Drift and replay checks with readiness decision output.
- GitHub workflow mirror for PR/status enforcement.

## Project Layout
- `ci/`: PowerShell runners and orchestrators.
- `tests/`: JSON contracts and sample payloads.
- `runtime/`: runtime input/output payloads (`producer_payload.json`, `production_signals.json`).
- `artifacts/`: generated reports and decision outputs.
- `.github/workflows/media-gate-pipeline.yml`: CI mirror of local run path.

## Local-First Quick Start
From repo root:

```powershell
powershell -ExecutionPolicy Bypass -File ./ci/seed_runtime_producer_payload.ps1 -WorkspaceRoot . -Force
powershell -ExecutionPolicy Bypass -File ./ci/run_release_readiness_from_producer.ps1 -WorkspaceRoot . -ProducerPayloadPath ./runtime/producer_payload.json -RootDir . -OutputDir ./artifacts -UpdateBaseline
```

Expected result:
- `artifacts/release_readiness.json` with `decision = "pass"` on a clean sample run.

## Main Local Commands
- Seed producer payload: `./ci/seed_runtime_producer_payload.ps1 -WorkspaceRoot . -Force`
- Transform producer->signals: `./ci/write_runtime_signals_from_producer.ps1 -WorkspaceRoot . -ProducerPayloadPath ./runtime/producer_payload.json -OutputPath ./runtime/production_signals.json -Force`
- Run full readiness from producer payload: `./ci/run_release_readiness_from_producer.ps1 -WorkspaceRoot . -ProducerPayloadPath ./runtime/producer_payload.json -RootDir . -OutputDir ./artifacts`
- Run readiness directly from existing signals: `./ci/run_release_readiness.ps1 -RootDir . -OutputDir ./artifacts -ProductionSignalsPath ./runtime/production_signals.json`

## CI Behavior
CI runs the same path as local execution:
1. verify `runtime/producer_payload.json` exists,
2. run producer->signals transform,
3. run full release readiness,
4. upload `artifacts/`.

## Enable Branch Protection (One Command)
Set a token with repo admin permission, then run:

```powershell
$env:GITHUB_TOKEN = "<your-token>"
powershell -ExecutionPolicy Bypass -File ./tools/apply-branch-protection.ps1 -Owner gregorywaaka-commits -Repo MediaCreator -Branch main -RequiredStatusCheck evaluate-gates
```

This enforces PR review, conversation resolution, and requires the `evaluate-gates` status check on `main`.

## Notes
- Local scripts are the source of truth.
- GitHub workflow is an enforcement mirror for branch protection and auditability.
