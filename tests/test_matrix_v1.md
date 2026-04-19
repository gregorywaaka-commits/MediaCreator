# Test Matrix v1 (Prepared)

## Purpose
Map each locked decision and gate rule to executable tests.

## Matrix
1. release-class-missing-doc-open
- input: open release, missing model card
- expected: warn (not block)

2. release-class-missing-doc-licensed
- input: licensed release, missing model card
- expected: block_release

3. release-class-missing-doc-protected
- input: protected release, missing datasheet
- expected: block_release

4. watermark-open-skip
- input: open release
- expected: watermark gate skipped

5. watermark-licensed-retry-warn
- input: licensed release, watermark fail then fail
- expected: retry once, then warn

6. leak-test-production-target
- input: production run
- expected: 10000-sample lane selected unless constrained

7. leak-test-constrained-floor
- input: constrained runner
- expected: floor is 5000 samples

8. tie-break-safety-over-quality
- input: high quality pass but compliance fail on licensed output
- expected: block_release

9. tie-break-open-warn-path
- input: open output, doc fail, quality pass
- expected: warn with remediation reason code

10. break-glass-owner-only
- input: override requested by non-owner
- expected: deny override
