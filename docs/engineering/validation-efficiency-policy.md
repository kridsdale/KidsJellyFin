# Validation efficiency: human directive and execution-history audit

Recorded October 18, 2026 (America/Los_Angeles). Tracking owner: `kids-e8f`.
Current task status and validation-attempt records belong in Beads, not here.
The operating rules are in [AGENTS.md](../../AGENTS.md#human-directed-validation-and-delivery-efficiency-2026-10-18).

## Finding

The user's criticism is substantiated: repeated expensive acceptance runs,
excessively broad checks around small changes, repeated evidence/review work,
and excessive coordination reduced delivery efficiency. Some runs exposed real
bugs; that does not justify the overall cadence. There is no measured normal
baseline from which to compute an actual standard deviation. The instruction
means a substantial practical reduction in caution and repetitive checking.

## Direct evidence of long repeated acceptance runs

Read existing xcresult summaries with `xcresulttool get test-results summary`;
no tests were executed for this audit. Durations below exclude compilation and
other orchestration. Times are Pacific Daylight Time.

| Existing acceptance artifact | Started | Runtime | Recorded outcome |
| --- | --- | --- | --- |
| `Kids-Packages-Acceptance-76.xcresult` | Oct 6, 6:47:57 PM | 404.309 s (6:44) | 70 passed |
| `Kids-Packages-Acceptance-77.xcresult` | Oct 6, 7:14:50 PM | 412.830 s (6:53) | 70 passed |
| `Kids-Packages-Acceptance-78.xcresult` | Oct 6, 7:34:44 PM | 359.379 s (5:59) | 68 passed, 2 failed |
| `Kids-Packages-Acceptance-80.xcresult` | Oct 8, 6:27:49 AM | 391.638 s (6:32) | 80 passed, 1 failed |
| `Kids-Packages-Acceptance-89.xcresult` | Oct 8, 7:46:08 AM | 389.892 s (6:30) | 90 passed |

These five observed runs alone consumed 32 minutes 38 seconds of test execution.
They establish repeated same-day long-suite execution, not that every run tested
identical source or that all those minutes were unnecessary. The new rule would
exclude the repeated same-day logical suite even following source changes.
Artifacts remain under `build/validation/`; original results are unchanged.

## Other recurring waste found

1. **Broad tests after narrow changes.** The Oct 18 execution log records native
   application-boundary suite launches at 3:03:37 PM, 3:24:34 PM and 3:26:51 PM,
   with a focused regression at 3:20:51 PM. Not every broad run was identical or
   over five minutes, but this shows the tendency to return to the entire suite
   instead of carrying forward applicable results and testing the changed seam.
2. **Reprofiling the same executable.** The existing resumed acceptance report
   explicitly records Release 85 and quiet Release 86 on the same binary. Noise
   control can justify a planned comparison; the better default is to establish
   quiet conditions first and avoid repeat profiling merely for reassurance.
3. **Disturbing the system being measured.** On Oct 18 at about 1:34 PM the driver
   reported that debugger attachment paused playback while a short server lease
   continued aging, forcing an unchanged-build repeat. Observe passively during
   playback and inspect memory only after stopping when actually needed.
4. **Coordination and checking churn.** On Oct 17, 198 tool calls contained a
   thread-read/poll and 124 contained a server message. On Oct 18 before this
   audit, 163 contained a read/poll, 210 a message and 187 a hash/signature check.
   These are overlapping tool-call counts, not unique tests or a time estimate.
   They show substantial overhead; some were necessary, but repeatedly requesting
   unchanged state and re-reviewing unchanged source did not advance features.
5. **Self-imposed deadline churn.** The log records a deployment inspection held
   because a nested ten-minute controller expired during review, despite an
   already authorized 24-hour maintenance window. New continuations, receipts
   and reviews followed. Complete preparation before starting short operational
   deadlines; avoid engineering artificial expiry/recovery work.
6. **Overly fragmented approval requests.** Thirty structured question calls were
   found across the project, including real decisions, sign-in/unlock needs and
   approvals. They were not all unnecessary. However, technical server-handoff
   sharing was split into separate requests on Oct 17 at 7:33 PM and 8:45 PM;
   later report sharing produced another approval round. Scope routine technical
   coordination correctly and retain the user's standing authorization. Genuine
   OS password, locked-desktop and missing-credential blockers remain distinct.
7. **Tracking/evidence overhead.** Frequent repeated source pins, long mirror
   notes and separate closeout/proof artifacts made overhead a large part of the
   work. Keep one authoritative result per owner and a compact reference in the
   other tracker. Do not turn every handoff into another full audit.

## Scope and limits

Audited the driver session's existing JSONL history from September 28 through
October 18, selected current result artifacts and the resumed acceptance report.
The complete backend execution log was not independently audited. Searches for
command text can include plans, process inspection or commands quoted in prose;
those counts are not reported as completed test executions. Total wasted wall
hours cannot be reliably computed from this history because waits, concurrency,
necessary work and human availability overlap.

The audit involved read-only log/result inspection and documentation/Beads
updates. It did not run a simulator test, decode, profiler, build or media action.
Historical success/failure records were preserved. Existing source and hardware
acceptance claims are not broadened by the new efficiency policy.

## Daily validation rule

Tests and equivalent expensive validations over five minutes are limited to
once per local calendar day for the same logical check, across both agents and
machines. Record the attempt before launch in its owning Bead. A failure or a new
source revision does not permit a same-day rerun. Continue with short focused
checks and other delivery work; do not ask for routine exemptions. Passing
unchanged work should not be retested merely because another day has begun.
No automation or new test framework is required for this policy change.
