# Break-Glass Runbook (Prepared)

## Policy
- Break-glass is owner-only.
- Every override requires:
  - ticket ID
  - explicit reason
  - time window
  - post-incident review entry

## Procedure
1. Confirm release class and failing gates.
2. Verify requestor identity is owner.
3. Create incident ticket.
4. Record exact failing reason codes.
5. Apply time-limited override token.
6. Run gated publish once.
7. Revoke override token immediately after use.
8. Publish incident summary and remediation actions.

## Audit Fields
- ticket_id
- requested_by
- approved_by
- release_id
- gate_failures
- business_impact
- expiration_utc
- remediation_owner
- remediation_due_date
