# Client QA policy

QA verifies a named build against the engineering specifications. It reports what was observed and keeps unverified requirements distinct from product defects. Source changes happen in a separate delivery task after triage.

## Verdicts and evidence

- **PASS:** the stated behavior was observed on the identified build with the required preconditions.
- **FAIL:** the build produced behavior that contradicts the requirement. Record the exact step, expected result, actual result, and evidence reference.
- **BLOCKED:** a named external precondition prevented execution. A blocked case is not a product pass or failure.
- **NOT RUN:** the case was outside the run. Do not label missing coverage as a defect.

Every report identifies the canonical release version, source commit, implementation digest, app bundle version, platform, test data boundary, start/end time, and artifact hashes. Compile success, unit tests, simulator behavior, physical-device behavior, backend health, and production behavior are separate claims.

## Severity and release gates

| Priority | Meaning | Release effect |
| --- | --- | --- |
| P0 | Data loss, credential exposure, authorization escape, destructive media action, or unrecoverable service corruption | Stop work and rollback or contain immediately |
| P1 | Basic child or parent function is unusable, a required control cannot be reached, playback/control safety is broken, or the app cannot connect to its supported backend | Blocks release until fixed and verified, or explicitly deferred by the human owner |
| P2 | Supported behavior is degraded but a safe, understandable path remains | May ship only with a recorded decision and bounded impact |
| P3 | Cosmetic, copy, polish, or low-impact edge behavior | Does not block release |

P0 and P1 findings must have one canonical Bead, an owner, and a verification case. A broad specification coverage gap does not automatically become P1.

## Test order

1. Static checks and focused unit tests.
2. Build the affected app from the exact candidate commit with the release wrapper.
3. Reboot the relevant iOS simulator between client automation tests. Shutdown and boot without erasing data; record the reboot event in the run report.
4. Run focused UI automation for changed P1 paths.
5. Run bounded integration checks only where the feature crosses the client/backend boundary.
6. Perform live acceptance only when the requirement is inherently live. Never substitute mocks or previews for that claim.

Reuse unchanged passing evidence. A logical validation expected to exceed five minutes runs at most once per Pacific day across agents and hosts, per the project instructions. A new source digest justifies the smallest affected rerun, not an unrelated full suite.

## Independent QA role

An independent QA specialist writes the test plan and pass/fail report and does not edit product source. The delivery owner triages the report later. Reports are immutable evidence; addenda may narrow or supersede a specific result but do not silently rewrite the original run.
