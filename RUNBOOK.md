# MediaCreator Runbook

## Daily Local Run
1. `Set-Location "D:/Mundane/MediaCreator"`
2. `powershell -ExecutionPolicy Bypass -File ./ci/seed_runtime_producer_payload.ps1 -WorkspaceRoot . -Force`
3. `powershell -ExecutionPolicy Bypass -File ./ci/run_release_readiness_from_producer.ps1 -WorkspaceRoot . -ProducerPayloadPath ./runtime/producer_payload.json -RootDir . -OutputDir ./artifacts`
4. Check `artifacts/release_readiness.json` for `"decision": "pass"`.

## Branch Protection Maintenance
1. Set token in terminal: `$env:GITHUB_TOKEN = "<token>"`
2. Run: `powershell -ExecutionPolicy Bypass -File ./tools/apply-branch-protection.ps1 -Owner gregorywaaka-commits -Repo MediaCreator -Branch main -RequiredStatusCheck evaluate-gates`
3. Revoke token after use and clear terminal variable.

## Weekly Smoke Run (GitHub)
- Workflow: `.github/workflows/media-gate-weekly-smoke.yml`
- Runs weekly and can be launched manually.
- Seeds runtime producer payload and runs full readiness.

## Common Failures
- `Missing GitHub token`:
  - Set `GITHUB_TOKEN` in the current shell before running protection script.
- `Missing runtime/producer_payload.json`:
  - Run seed script first, or provide producer payload from upstream stage.
- `Release readiness failed`:
  - Open `artifacts/release_readiness.md` and inspect failing step details.

## Recovery Steps
1. Re-run dry checks:
   - `powershell -ExecutionPolicy Bypass -File ./ci/run_dry_run_gate_validation.ps1 -RootDir . -OutputDir ./artifacts`
2. Re-run production checks:
   - `powershell -ExecutionPolicy Bypass -File ./ci/run_production_gate_validation.ps1 -RootDir . -OutputDir ./artifacts -SignalsPath ./runtime/production_signals.json`
3. Re-run full readiness:
   - `powershell -ExecutionPolicy Bypass -File ./ci/run_release_readiness.ps1 -RootDir . -OutputDir ./artifacts -ProductionSignalsPath ./runtime/production_signals.json`

## Operational Notes
- Keep `main` protected.
- Treat `ci/` and `.github/workflows/` as controlled operational surfaces.
- Do not commit runtime secrets or tokens.
