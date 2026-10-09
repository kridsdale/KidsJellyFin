# Opt-in client evidence and passive playback observations

Implemented against the server's JSONL v1 contract at `b3d5fbb`. Source hooks and
offline fixtures are implemented; the emitter has not been exercised in a real
client session or verified on a physical Apple TV. No performance target is met
by these tests.

## Two separate streams

Each actual, explicitly planned start or seek gets a fresh private attempt
directory and run/clock UUID. `strict.jsonl` has only the server's exact
`run_started`, `trial_record`, and `run_finished` envelopes. The current VLC
capabilities declare video, audio, and decoder callbacks `unavailable`.
The strict record therefore preserves `unsupported_client_callback` and a failed
outcome, with the real request timestamp where available. It never turns a
mounted surface, playing state, sampled picture/audio counter, optimistic clock,
or native time receipt into a strict presentation/output success.

`supplementary.jsonl` uses a deliberately different `observation_record` envelope.
It contains closed, typed session/VLC observations: native generation and session
IDs, counter availability and deltas, counter epochs, state/buffering changes,
seek request/rejection/supersession/timeout, observed seek settlement, native end,
failure, recovery, and awaited stop/drain. Missing counters remain absent. Demux
corruption/discontinuity are packet statistics, not corrupted decoded frames.
No media names, paths, URLs, credentials, raw errors, or free-text native logs
are emitted. Explicit planned opaque IDs appear only where the contract needs them.

VLC counters are sampled every 500 ms while an observer is attached, continuing
beyond startup. Initial positive counters establish a baseline. Decreases or
availability gaps break continuity and suppress cross-epoch deltas. Seek
settlement requires a newer native time payload receipt, target convergence,
and displayed-picture advancement in the same counter epoch within ten seconds.
It remains supplementary: a main-actor receipt from a bounded SDK stream does
not establish the native callback's original timestamp, target-frame presentation,
or lossless callback completeness. Custom libVLC audio/video callbacks are not
installed; they would replace normal output and alter the path under measurement.

## Scope and activation

Normal launches do not construct capture, open evidence storage, attach observers,
or start counter polling. Developer activation requires both `--kids-evidence`
and `KIDS_EVIDENCE_PLAN` naming an owner-only, regular, no-follow plan file inside
the app container. Loading a plan never starts playback, performs probes, changes
networking, selects media, or changes an account.

Build the instrumented revision using the digest printed by:

```sh
python3 Scripts/Kids/evidence_revision.py
```

Pass that digest as `KIDS_EVIDENCE_REVISION` to the Xcode build. It is embedded in
`KidsEvidenceImplementationRevision`; a launch environment cannot override it.
The helper hashes the instrumentation's implementation inputs, not media or
credentials. Format the source before computing it: the current Xcode scheme
runs SwiftFormat during builds. Recompute after source changes and verify the
built Info.plist revision equals the final source digest. The journal records the digest
as an implementation revision, not as independent proof of a deployed binary.

The prepared plan's exact IDs/client representation are retained. Runtime checks
platform, bundle build, OS build, server/user, and the installation's vendor UUID.
The transport's `tvOS_<UUID>` device identifier is not itself the schema's UUID
`client_id`; the plan must use the vendor UUID. Network type remains the declared
plan scope, not an observed network condition. No tests here certify the family's
device, account, or currently active LAN.

A Play action captures its monotonic timestamp before preparation. Known
movie/explicit-episode/retry items bind before asynchronous work; an automatically
chosen episode binds as soon as its ID is known and before authorization. Requests
that fail before an episode is identifiable cannot be assigned a planned item
and remain unmeasured. Bindings and action nonces are one-use. Retrying needs a
fresh action and a fresh planned trial; existing private attempt directories are
never overwritten. Actual seek actions may consume separately planned seek trials.
Sustained/behavior trials remain unmeasured; session readiness/end/persistence
signals are not substituted for the required UI/renderer evidence.

## Durability and export

Disk I/O runs on a utility queue; callbacks enqueue immutable observations.
Acceptance and queue submission share the finishing lock, so an accepted
observation cannot race behind the footer. The queue is bounded at 128 pending
observations. Overflow, encoding failure, invalid data, and disk failures stop
capture with a fixed failure status. `attemptStatuses` exposes the result without
private error prose.

The journal creates fresh `0600` files in an owned `0700` directory using
`O_EXCL`/`O_NOFOLLOW`. Complete UTF-8 objects receive contiguous zero-based
sequences and newlines. It rejects duplicate JSON keys, invalid sequences, invalid
lifecycles and line limits. Limits are 32 MiB/journal and 2 MiB/line, with reserved
footer space. Acknowledgment follows the complete write and synchronization.
Write/sync failures permanently poison the journal. Already durable partial lines
are retained without inventing a complete footer.

Normal awaited session stop closes capture; preparation failure or process
termination closes it as interrupted where execution permits. Process death can
leave an unfinished run. No cross-restart clock or timing continuity is claimed.

`KidsEvidenceAttempt.export()` is an explicit local read. It requires the live
finished state, zero journal loss, and matching hashes, and returns strict JSONL,
supplementary JSONL, and a durability receipt. Receipt existence or a readable
footer alone cannot override a failed write/sync. Export never uploads anything.
The importer consumes only `strict.jsonl`; counters must not be added to its event
array. A complete journal disposition means complete recording, while the current
strict trial is still failed/unmeasured. Restart recovery/export of a previously
unfinished attempt is not implemented; preserve its artifacts for explicit review.

## Conditions and acceptance

No WAN, LAN, ingestion-load, clock-alignment, server binding, or decoder utilization
evidence is inferred. Strict conditions retain the planned load/WAN values with
`observed=false`, null artifact, and `media_properties_comparable=false`.
`condition_observations`, behavior, and server corroboration are unavailable/null;
decoder samples are empty. Independently collected condition windows and the
trusted read-only binding bridge belong to the server acceptance workflow.

Offline coverage includes storage caps/permissions/symlinks, injected partial-write
and sync errors, JSON duplicates and integer types, exact schema/nulls/privacy,
scope/nonce/retry binding, concurrent observation ordering, export/hash failure,
missing/reset counters, stale generations, seek qualifications, and session stop
ordering. The actual SDK view-mount test is excluded from this no-GUI run.
Compilation is separate from launch, playback, server import compatibility, and
physical-device acceptance. Each remains reported separately.
