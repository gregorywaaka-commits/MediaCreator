# Gate Engine Contract (Template)

## Inputs
- request_id (string)
- release_class (open|licensed|protected)
- run_mode (draft|production)
- metrics_payload (object)
- evidence_payload (object)
- policy_thresholds (object from policy/thresholds_v1)

## Required Evaluations
1. Quality gate
2. Deconstruction gate
3. Robustness/OoD gate
4. Leakage/memorization gate
5. Compliance/provenance gate
6. Documentation gate
7. Watermark/credential gate (licensed/protected only)

## Tie-Break Order (Locked)
1. Safety/compliance fail overrides quality pass for licensed/protected outputs.
2. For open outputs, missing docs/watermark can route to warn-only by policy.
3. InD pass + OoD fail must return conditional hold.
4. Human review can release only with explicit owner break-glass justification.

## Output Contract
- decision: pass|hold|warn|block_release
- decision_reasons: string[]
- gate_results: map<string, pass|warn|fail>
- release_class: string
- break_glass_used: boolean
- artifacts:
  - json_report_path
  - markdown_report_path

## Non-Negotiables
- Never silently downgrade a block to warn.
- Every warn/block must include explicit machine-readable reason codes.
- All outputs must be reproducible from logged inputs and policy version.
