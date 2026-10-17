# Parent controls: tvOS receiver integration

Implementation record, 2026-10-17. This describes local client source and automated
checks, not a deployed or commissioned parental-control system. The iPhone app and
its backend request are documented in [parents-app.md](parents-app.md) and
[parents-backend-handoff.md](parents-backend-handoff.md).

## What changed

The same Xcode project now has a native iPhone parent target and an opt-in tvOS
receiver. The receiver connects parent policy to the existing kids catalog, queue,
player lifecycle and PIN-protected settings. It never changes media files, library
roots, Jellyfin account permissions or RAID configuration.

| Responsibility | Owner |
| --- | --- |
| Parent/receiver JSON and scoped HTTP | KidsParentControl |
| Pure lease, deadline, command and eligibility decisions | KidsViewingControl |
| Receiver configuration host port | KidsAccounts |
| Separate receiver Keychain entry | SwiftfinCredentials and tvOS account adapter |
| Polling, local watchdog, playback/events and ambient lifecycle | KidsApplication |
| Pairing settings, held screen and ambient presentation | KidsExperience |
| Parent phone UI, authentication and capability-gated editors | KidsParents target |

Unpaired installations preserve their previous behavior. Pairing alone also leaves
enforcement off: an administrator must explicitly commission and activate it.

## Credentials and activation

The TV's existing parent PIN protects pairing/unpairing. Pairing requires a
dedicated, scoped receiver token and the control-service URL. The displayed raw
installation UUID must be used as-is by the provisioning service. Do not add a
Jellyfin transport prefix or rewrite letter case. The token is separate from both
the child's Jellyfin login and the phone's adult control credential.

The current manager origin is `http://192.168.10.100:8097`; its hostname origin is
rejected by the deployed service. New native routes are still backend source work.
Do not attempt to provision by treating the existing manager as the future API.

Activation requires a scoped policy response with explicit `enforcementEnabled:true`.
The TV stores its activation marker before permitting enforced normal playback.
After activation, a restart, unreadable secure configuration, network failure,
unsupported response or stale lease cannot silently restore unrestricted playback.
An authenticated `enforcementEnabled:false` plus correlated release may deactivate;
an omitted field never deactivates. A grown-up can explicitly unpair using the PIN.
Token replacement preserves the activation marker and any completed-control latch.

Pairing is not evidence of commissioning. A never-activated heartbeat reports only
reachability: revision 0, no playback session/item/position/command, zero elapsed.
It does not mint a lease, debit time, create history or claim deadline readiness.
Activated idle heartbeats use the latest policy revision with the same null/zero
shape. While playing, heartbeat includes the actual controller/item/position but
still zero elapsed and no command ID. After explicit deactivation, retain the latest
disabled-policy revision and return to the null idle shape; a heartbeat never enables
enforcement. An ambient heartbeat requires the server's acknowledged current ambient
controller binding and never consumes kids allowance.

## Viewing and playback

Every normal playback entry obtains a serialized policy refresh before preparation.
Eligibility is rechecked after metadata authorization and player preparation. Home
catalog, episode lists, ordered advance, shuffle and remote skip all intersect
the original Kid TV/Kid Movies binding with the current policy. Denied shows also
deny their episodes; the designated ambient item is excluded from ordinary viewing.
Generic Jellyfin remote PlayNow remains disabled.

Leases last at most 30 seconds. The client subtracts the request's whole round trip
from the usable duration and tracks expiry/deadline with a monotonic clock. A
five-second foreground poll is separate from the one-second enforcement watchdog,
so slow metadata/player preparation does not stop expiry enforcement. New playback
joins an in-flight refresh rather than spending stale permission after a session ends.

### Explicit playback admission and daily-budget accounting

Source audit confirmed that the root receiver monitor polls foreground policy every
five seconds on home/browse, during preparation, and while paused/buffering, not only
during operational playback. Backgrounding suspends it. The backend agent identified
that its earlier generic policy GET allocated a30-second held budget whenever
global viewing is allowed. Together these source behaviors can reserve allowance
without actual viewing and repeatedly age unknown reservations into unconfirmed.
This is not a reported live incident: Parents/daily-budget enforcement is uninstalled.

Daily-budget commissioning therefore additionally requires a separately gated,
explicit playback-intent/surrender contract. Browse authorization must not reserve
spendable viewing time. Actual playback must obtain a bounded reservation; offline
unknown intervals must not be refunded merely from missing reports/idle heartbeat.
The receiver now exposes the actual prepared controller/item before activePlayback
assignment and driver.start, and uses this seam for admission. Resume, automatic
buffer recovery and surrender share the same coordinator. Daily-budget readiness
remains off pending separate runtime commissioning. Unknown past allowance cannot
be refunded as an idle-polling workaround.

The frozen PG-v1-draft3 `playback-grants-v1` wire adapter is implemented, tested and
called by the receiver runtime when required mode is active. Policy DTOs add optional
`playbackIntentRequired`, `playbackIntentAvailable`, `playbackIntentID`,
`leasePlaybackSessionID` and `leaseItemID`. Browse availability is not viewing
permission. Intent POST uses exactly commandID/deviceID/childUserID/expectedRevision/
playbackSessionID/itemID; surrender POST uses exactly commandID/deviceID/childUserID/
playbackIntentID/playbackSessionID/itemID. Surrender deliberately omits revision:
the persisted intent generation identifies revocation across auto-renewals.
Both use scoped receiver bearer, the exact matching command idempotency key and
deterministic retry bytes. Only the ordinary correlated persisted receipt is
accepted; it grants no permission. A fresh policy must still bind the exact intent,
controller, item and usable lease before frames.
POST persists only a bounded prepared intent, with no grant or reservation. Fresh
GET rechecks policy and allocates reservation atomically with an actual ALLOW.
No issued ALLOW means no reserved time. Once ALLOW may have been issued, unobserved
start/expiry remains uncertain. Exact POST retry cannot revive a terminal denied or
expired prepared request or replay cached permission.

Auto-renewal retains one intent generation. Explicit resume creates a new intent
even for the same controller; delayed surrender must not revoke that newer
generation. The player library now offers a neutral optional onResumeRequested
callback, tested to leave paused transport unchanged until the host acts. It has
no HTTP/account dependencies. The application configures it only in activated
required mode. Backend transaction fixtures and native fake-driver tests validate
the source sequence; they do not establish runtime capability readiness.

Required-mode validation is now implemented: all five keys must be present, with
explicit nulls distinguishable from missing nullable bindings. Policy round trips
preserve those nulls. Learning required mode saves a durable receiver configuration
marker before accepting enforced playback; pairing/token replacement, activation
and completed-control latching preserve it. Restarted strict mode rejects missing,
false, or malformed required fields, including incomplete deactivation replies.
Explicit parent disable retains the remembered mode for future reactivation.

Read-only catalog eligibility has a separate local30-second freshness bound and
never substitutes for transport authority. The exact playback predicate additionally
requires the locally admitted intent ID and raw controller/item match. IntentAvailable
may be false while the existing own reservation still permits playback. Prestart,
grant capture and watchdog paths use that strict predicate. Only the coordinator's
fresh exact policy check sets the locally admitted ID. Catalog, episode and shuffle
selection use the separate browse predicate before any viewing reservation.
The final transport gate also rejects a known reporting fault, closing the race
where metadata/player preparation finishes after an integrity fault was detected.

Admission409 errors now retain a distinct mutation-conflict type. Only the frozen
revision_conflict/active_intent_exists/controller_mismatch prove a new intent was
refused without commitment. Idempotency/epoch/subject/unknown/malformed conflicts
do not. Helpers do not refresh/retry/rewrite action IDs automatically.

The implemented native integration sequence is:

1. Persist captured intent/surrender requests before POST in a scope-specific private
   application-support ledger, then serialize them with the existing policy flight.
   Drain actual evidence FIFO before surrender or new intent; preserve unknown POST
   outcomes and identical retry bodies. On restart resolve and retire orphaned
   preparations before any GET that could allocate their ALLOW. Do not replay media
   or infer an operational controller from the ledger. Keep tokens out of it.
2. Use read-only browse eligibility for catalog, episode and shuffle selection before
   metadata/player preparation. After the
   actual controller exists, persist intent only; a fresh current GET atomically
   allocates reservation/ALLOW. Validate the exact finite binding before driver.start.
3. Separate global policy holds from per-controller local revocation. Local pause
   must override even an old still-valid lease until surrender and a new intent plus
   fresh binding succeed. Retain genuinely paused/prepared objects without frames.
4. Route UI and remote resume through one scoped coordinator. Background, parent
   pause, identity changes and stop invalidate late admission completions.
   Close the old per-intent announcement only after known surrender; a resumed
   generation on the same controller needs a new actual started observation before
   progress. The original once-per-controller began flag alone is insufficient;
   neither a grant nor a paused old controller is a resumed-frame callback.
5. Retain the first finite grant during initial preparation, without GET renewal or
   automatic new intents for an unstarted controller. After actual start, a long
   buffering hold may request a new intent only for the same controller/item after
   readiness while held. Never autoplay a replacement item for recovery.
6. Handle ordinary stop, EOF, cancellation, replacement and orphaned startup intents:
   retain evidence, await actual driver drain where applicable, then surrender the
   exact old generation before a new intent. Do not manufacture started/stopped usage
   for preparation that never produced operational start.
7. Replay frozen backend transactions and test idle, prepared, playing, paused,
   buffering, unknown/retried POSTs, same-controller resume, stale surrender, scope/
   background races, clock/reset boundaries and restart. Keep capabilities off until
   separate source/runtime commissioning gates pass. The synthetic tests cover
   pause/resume, readiness while held, lost POST receipts and background races;
   household and physical-device trials remain deferred.

`KidsAdmissionJournal` stores only the captured mutation identities and original
revision, not tokens, grants or playback authority. Its scope includes service,
server, child and installation; files are bounded, owner-only and synchronized
before sending. Corrupt or foreign-scope state fails closed. Restart marks an
orphaned preparation abandoned and replays its original unknown POST before exact
surrender, before a policy GET could allocate a new ALLOW. It never reconstructs
an operational player. Unpairing does not silently erase this accounting state.

Local pause revocation overrides an otherwise valid cached grant. Actual transport
evidence drains FIFO before surrender; a resume then creates a new generation on
the same controller. That generation emits a new started report only after actual
unpaused forward-clock observation. Remote Resume schedules outside the policy
flight, rechecks its command expiry after asynchronous waits, and acknowledges the
original delivery revision rather than a newer playback grant revision.

Buffer recovery additionally requires a new native buffer-fill readiness transition
while held, on the same already operational controller/item. A paused state or a
buffering boolean becoming false alone cannot trigger it. Recovery is limited to
three attempts with failure backoff; stable playback resets that budget. If the
native SDK does not provide readiness while paused, manual Resume remains the
fallback. Stop sets its local terminal flag before pause callbacks, awaits native
drain, then surrenders; duplicate terminal reports are bounded and suppressed.

The accepted accounting refinement distinguishes unknown past from future capacity:
at verified surrender time on the server, only unused future capacity attributable
to that exact intent may be released, bounded by its original expiry and remaining
held/attributable uncertainty. Past unknown time and confirmed usage remain charged.
Expired/unknown-period/unproven reservations release no future capacity; clock,
restore and integrity guards remain mandatory. A reported5s, server-elapsed7s,
30-second grant should retain used5/pastUnknown2 while releasing future23, rather
than consuming30 seconds on each confirmed pause. The saved backend transaction
fixture proves this partition in its synthetic HTTP/auth/SQLite run; it does not
prove installed runtime behavior.

An activated TV starts held until fresh permission arrives. Missing usage reports
remain a backend reservation/accounting concern, not an assumed refund. A full
128-event queue causes a viewing hold. The queue is memory resident; a process crash
can lose unacknowledged operational reports. The backend must preserve unconfirmed
reservations, and history must not claim complete observation after a gap.
Command processing stops before claiming more actions when the queue reaches120,
leaving eight slots for stop/progress callbacks and acknowledgements. A burst cannot
execute commands whose results would be dropped. Nonrecoverable structured event
conflicts set a reporting fault, so the watchdog holds playback without waiting for
the previous permission lease to expire.

An explicit countdown/finish end persists its command latch, preventing a restart
from resuming kids viewing before release. Ordinary lease/routine/budget holds may
recover after fresh permission. Finish-episode applies to one exact controller UUID
and natural EOF, bounded by the hard deadline. It cannot transfer to a later episode.

Remote pause/resume/skip applies only to the captured playback UUID and expires
within 30 seconds. The TV claims command IDs durably before execution in its own
application-support directory. The bounded ledger contains only command/session IDs.
It is separate from RAID media. Session changes cannot inherit earlier actions.

## Quiet end and ambient playback

At a hold, normal playback stops and the child sees a quiet screen. Ambient playback
requires a correlated countdown/finish control that has reached its deadline or has
its exact completed-control latch, plus the approved Jellyfin bird item. An item ID
alone is not authority. Routine/budget/lease holds without that authority remain
static and emit no ambient events. The client authorizes the bird item
through the original catalog boundary and starts an isolated ambient controller.
Episode ambient items require authorization of their series as well. Ambient playback
does not update kids episode checkpoints, advance a kids queue or debit kids viewing.

The ambient controller loops at natural EOF. Back/PlayPause cannot escape to kids
content. Parents can open the existing protected settings. Preparation/decoder/network
failures have a bounded retry budget and then leave the quiet static screen.
No child YouTube search, live YouTube URL or uncontrolled autoplay is introduced.
This stops viewing inside this app; it does not power off the TV or lock other apps.

The design currently requires the bird item to belong to the original approved
Jellyfin kids binding. A server-side ambient item outside that boundary cannot be
used by this client without a separately reviewed authorization design.

## Events, history and shuffle

Receiver requests carry only the receiver bearer, with no Jellyfin admin token or
identity override headers. Events encode exactly ten keys, retaining explicit nulls.
Idempotency-Key is the original eventID. A receipt's misleadingly named commandID
must equal that eventID; request.commandID separately correlates the parent action.
Playback session ID is the controller UUID, not Jellyfin's transport play-session ID.
Event encoding uses sorted keys so retrying the same immutable event preserves the
actual request bytes. Server code reports that body/header UUID spelling must match
exactly first; event and command UUIDs then normalize together, including correlated
control IDs. Swift's uppercase UUID representation is expected. Installation/child/
Jellyfin identity spelling remains unchanged. A joined backend transaction fixture
for the uppercase native case now has an exact tested fixture, described below.

Receiver409 errors preserve their structured code. Only a no-usage heartbeat
(elapsed0, commandIDnull, exact local scope) may be discarded on `lease_mismatch`,
`lease_expired_or_mismatched`, `policy_revision_mismatch` or
`heartbeat_session_mismatch`, followed by a fresh policy fetch. Usage/control/ambient
reports are never discarded this way. Unknown errors, missing codes, idempotency/key
conflicts, clock rollback and restore-review requirements remain fail closed.

Reports retain their original policy revision. Operational progress excludes pauses,
buffering, nonfinite positions, implausible jumps and delayed samples; residual
progress is queued before ended/stopped. Preparation alone never queues normal
started/progress/stopped or a controller-bound heartbeat. The actual operational
start callback precedes subsequent usage in FIFO order. Activation may adopt an
already-begun, non-ended controller; it cannot invent a start for a preparing player.
Paused/buffering transitions carry zero elapsed time, after any accrued playing
interval. If activation cannot be saved securely, existing playback pauses and stops
while the process remains held; a successful durable activation is not claimed.
This is operational observation, not physical frame or
audio certification. AmbientStarted likewise means the supported player callback,
not independently verified pictures or sound.
Normal started/progress/paused/buffering/ended/stopped retain the controller's last
actually granted viewing revision. A later DENY snapshot cannot replace that grant
provenance; a subsequent allowed lease may advance it for that same controller only
after the accrued interval is flushed under the previous grant.
Already-queued events stay immutable. Heartbeat/control/ambient observations retain
their separately captured current policy/delivery revision. Explicit deactivation
ends enforced accounting under the old grant before the receiver transitions off,
even if the underlying controller keeps playing in the parent-authorized unenforced
state. Backend checkpoint `8890ead` implements bounded retrospective acceptance
in source; deployed integration and runtime acceptance remain outstanding.

Preferred shows move earlier on the home screen. Shuffle remains inside the chosen
show, applies catalog restrictions before freshness, and may relax freshness only.
Central watched/recent context is optional and now requires explicit
`shuffleContext.complete:true` before applying history preferences. Missing/false
cannot classify items as unwatched or fresh. Server shuffle capability must remain
off until context completeness and cross-device semantics are tested.

## Backend integration status

Server chat: **Make YT Feature**, isolated backend branch `feature/parents-backend-v1`.
The server agent supplied deterministic fixtures produced through its DB/auth/policy
facade with synthetic metadata. Initial policy/budget/receipt examples are semantic
JSON copies. The later enforcement fixture is now checked in verbatim at
`Packages/KidsParentControl/Tests/KidsParentControlTests/Fixtures/enforcement.json`.
Its raw SHA-256 was independently computed on this Mac and exactly matches the
server's `6714d7ff91dd84d01cc7dab9ae0c0b83ce44ee898829b36cc29e0ecd45fe4839`.
Executable tests decode enabled/disabled policy, correlate event/release receipts,
and preserve 501 readiness denial and the bootstrap409 race. These tests are
cross-language fixture compatibility evidence, not a live API result.

The subsequent `Fixtures/heartbeats.json` also matches the server's exact raw
6531-byte fixture and SHA-256
`ca7767191250ccf977926fbac1d460d6462cb9c7ccd0d5895ded91983b9dfd9b`.
Its four event vectors exercise all-null idle, normal playback, ambient start and
ambient heartbeat field preservation, receipt correlation and deterministic re-send.
Three rejection vectors preserve structured stale-session errors. Original lowercase
event/control UUID fixture strings are compared as UUID identities after Swift's
normal uppercase encoding; other fields remain identical. The backend's accounting
snapshots are recorded provenance, not a locally executed database assertion.

The 2,714-byte `Fixtures/fractional-seconds.json` independently matches SHA-256
`4ff001d23b50f3945fe9f1b8b43afb576590ff1ad0bdcc910865f6ea0458c300`.
Native tests preserve the 1.23-second progress payload and decode integer public
budget values before/after lease expiry (`usedSeconds=1`, reserved29→0,
unconfirmed0→29, authoritative remaining270 throughout). Its historical history-item
vector is an explicit excerpt with its `id` removed; native code rejects it as an incomplete history
DTO. The public DTO's stable identity requirement is unchanged.

The exact successor `Fixtures/fractional-seconds-full-page.json` is 2,912 bytes and
independently matches SHA-256
`d632615282071b25bc5203accaff41c8845ff67c1f3294af2150bd4c0f38ef52`.
It captures the actual history-page response with its server-issued deterministic
history ID. A positive test through ParentControlAPI capability negotiation and
the scoped history route verifies child scope, ID, fractional timestamp, integral
watched duration and null page cursor. No client-side ID was fabricated, and the
older excerpt remains rejected. This is fixture/source compatibility, not deployed
service or household-history acceptance.

The backend checkpoint `ed4cbccd960d5ec9e64e3b6dcce385e697559f41` reports142 joined
source tests with no skips, including real HTTP/auth/SQLite UUID transactions,
activation UI and historical control-delivery receipts. Its raw3,664-byte
`Fixtures/native-uuid-transaction.json` matches SHA-256
`e466215b9e2d6007dc8bce68910a90ed669083fd9e09d5456e0936d45b6b8744`.
Native tests replay uppercase event/control UUIDs against canonical lowercase
receipts, preserve the installation subject exactly, and keep header/body UUID
spelling equal. The receiver now rejects installation aliases both before sending
events and before accepting policy. No commissioning follows from these source tests.

Backend successor `8890ead` reports162 distinct joined tests with no skips in its
RAID-denied loopback sandbox. Two additional raw recovery fixtures independently
match the supplied bytes and hashes on this Mac:

| Fixture | Bytes | SHA-256 |
| --- | --- | --- |
| `historical-usage.json` | 4011 | `7b1ab300ea59d95f1682c7e21616af54e27dedf48b078f3ee1b6ed9a7cf343b5` |
| `late-ack.json` | 5012 | `179c2cc0f16ff6387fe033f281571b136148f6555054aa6b64b1a7b542fc9aa5` |

The native wire tests retain an old granted revision through a current DENY and
retry identical encoded reports. Late command evidence receives only an ordinary
event-persistence receipt; the original expired action stays failed. A subsequent
fresh release has its own policy and acknowledgement. Backend accounting snapshots
are server-executed provenance, not local database tests. Unknown, never-delivered,
cross-subject, epoch and integrity failures still fail closed; the source recovery
window is seven days. First-start evidence delayed until after a policy change is
handled by the additional gated contract below, not by these older fixtures.

### Delayed first-start recovery

The agreed source extension is separately default-off
`unconfirmed-start-recovery-v1`. With original returned-ALLOW/scope proof, the
server may retain otherwise unbound normal evidence privately as unconfirmed.
It cannot create confirmed viewing history/usage, refund uncertainty, grant a
lease, unblock a show or revive a command. The original still-unbound reservation
is conservatively retired to unconfirmed rather than reused by another controller.

Its event receipt adds the exact pair
`evidenceDisposition:"unconfirmed"` and
`unconfirmedPlaybackSessionID:<submitted session>`. The native dedicated
ReceiverEventReceipt validates event ID/status, exact session spelling, nonempty
item/session, no control ID, and normal started/progress/paused/buffering/ended/stopped
kind. Unknown, incomplete, mismatched, ambient/control/heartbeat metadata fails
closed and cannot acknowledge/pop the event. A malformed receipt sets the
reporting-fault hold, just as an integrity conflict does.

On a valid receipt the receiver holds and stops only the matching active controller,
retains/drains immutable queued reports and the real stop under their original
grant, then fetches fresh policy. The16-event send batch remains bounded across
polls, but an unconfirmed backlog must drain completely before that GET. A backlog
spanning several batches cannot briefly restore permission midway. A late receipt
cannot stop a replacement controller.
There is no automatic replay or manufactured start. The normal user Play entry may
create a genuinely new controller/start after fresh permission. Installed
gate/readiness and observed runtime acceptance are still required.

The server's frozen `Fixtures/unconfirmed-first-start.json` is8,979 bytes and
independently matches SHA-256
`e4ea2c07d54e28fcb966a3a14ee5e4b1e86306247b3f56f181377314e43d074d`.
Its actual isolated transaction trace is now replayed through the native API:
old ALLOW, current DENY, exact repeated unconfirmed start receipt, private progress/
real stop, continuing DENY, explicitly changed parent policy, new operational start/
progress and late private old terminal. The original queued bytes/revision remain
unchanged; only the old session is named by reset metadata. Backend source reports177
distinct joined tests with no skips. Its accounting/history/replacement snapshots
are provenance of server-executed transactions, not locally rerun database assertions.
Current immutable catalog eligibility remains required independently of current
show/time/budget permission; removed or unverified catalog items still fail review.
The gate requires this capability in independently verified receiver evidence before
granting policy under the configured extension. It remains off and uncommissioned.

Server checkpoint `4fd4269fe0ef60990b7030873ac10272942cd8c4` contains that gated
reset/capacity source. Its successor cherry-pick
`99af7381e0bd7f524b3240f6ada2679f8689d3a7` integrates deployed repair `9070055`;
the server reports byte-identical pipeline/publication/storage runtime files and202
focused source tests passing under RAID denial. Its subsequent combined Parents/cache
run passed379 distinct tests with no skips. Complete shuffle context, installed
catalog/startup adapters and deployment remain separate gates. This repair integration
is not a live service change.

### Actual playback-grants transaction join

The server's exact `Fixtures/playback-grants-transaction-v2.json` is12,038 bytes and
independently matches SHA-256
`dfe03b83d750c12bdcde7b62d286600b8203196023ba60525bcfdfb044421746`.
Native replay now passes the real loopback HTTP/auth/SQLite trace: idle availability
with no spendable lease, ordinary intent receipt/exact retry, fresh bound GET,
actual started/progress/paused evidence, surrender/exact retry, held zero-lease GET,
new intent for the same controller, stale old surrender leaving the new binding
unchanged, observed resumed start, playing renewal and current-generation surrender.
Structured conflict vectors distinguish definite refusal from idempotency failure.

The accounting snapshots record backend-executed evidence: idle/prepared without
ALLOW reserves0; playing5s then surrender at server7s leaves used5/unknown2; outage
uncertainty remains charged while only attributable current future capacity releases.
These are not locally rerun database assertions or a native playback trial. Server
checkpoint `31d0234` reports407 joined tests with no skips under RAID/external-network
denial, plus its600,000-row capacity test. Final tests fence old-generation terminal
effects and disable/re-enable cycles. Full native lifecycle wiring and later runtime
commissioning remain open; passing this fixture cannot promote the capability.

The original 19-fixture bundle was reported with SHA-256
`1a6609c64ca36ede6714f30187be0c4cb16db86caf26a7884dab0b7ac6d8cc99`.
The later never-activated heartbeat fixture was reported with SHA-256
`37c040fd5eb18819a973183f415c476bd531953eec0318a59ca8ba7cf6d79a10`.
These are provenance supplied by the server agent, not independently recomputed
hashes on this Mac.

As of this record, the server confirmed these remaining compatibility gates:

1. Validate activation/deactivation across the client and backend. The server now
   reports source implementation of the adult-only enforcement route below, with
   default-off readiness and five real-transaction tests. It is not commissioned
   or deployed; trusted receiver evidence cannot be inferred from these tests.
2. Validate the newly implemented idle command ACK/ambient-failure contract together
   with the client. The server reports source support and 63 policy/wire/HTTP tests:
   null session/item/position is accepted only with a concrete exact delivered control
   command ID and zero elapsed. Remote-command ACKs cannot use this idle shape;
   ambientStarted requires an actual controller session. This is not deployed.
3. Integrate source-complete queued-report/control recovery against the client,
   including the new gated first-start outage extension. Validate original-grant accounting without
   minting permission, refunding uncertainty or reviving obsolete commands.
4. Freeze complete watched/recent context and test shuffle across devices.
5. Finish the startup/catalog adapter and runtime evidence gates, then deploy the
   scoped APIs after integrating the deployed repair source. The independent V2
   cache-maintenance goal is now reported complete; that is not Parents readiness.

The adult credential issue/list/revoke/show-once UI is reported implemented in
backend `kids_cache/static/parent-control.html/.js/.css`, with a manager entry and
offline DOM verification. It is not installed. Its served route is requested for
native Settings onboarding. The backend checkpoint also reports the per-device
activation screen implemented in source, including gated enable/disable and
uncertain-result handling. Installed integration and commissioning remain open.

Receipt sizing is a rollout gate: one uninterrupted five-second heartbeat stream
produces120,960 events in seven days, exceeding the backend's earlier50,000 global
receipt cap before other devices/transitions. Policy polling is five seconds, the
one-second watchdog is local, and normal progress replaces idle heartbeats when
queued. Background polling is suspended. The server agent is resolving capacity
and admission limits; no live load has been generated. The server now reports an
actual600,000-row private SQLite test passing with separate550,000 receiver and
50,000 adult receipt reserves, exact retry at capacity, seven-day retention and
about193MB peak receipt storage. Its proposed admission profile is two registered
TV installations, not an unlimited fleet. Neither profile nor limits are deployed.

Joined transaction proof of uppercase native UUID correlation is now source-tested
on the backend and matched by exact native fixture tests.
The fractional playing sample's integral public budget/history output is now tested
against exact backend fixtures. Public used/history seconds are confirmed
floored; held/unconfirmed seconds are ceiled; authoritative remaining floors the
full-precision calculation. Native models remain Int, but now refuse to reconstruct
remaining permission from rounded display fields. Missing authoritative remaining
shows unknown. The backend retains fractional internal accounting.

Backend source now provides adult-cookie/Origin/CSRF
`POST /api/parent-admin/v1/devices/{exactInstallationUUID}/enforcement` with
`commandID`, `childUserID`, `expectedRevision`, `enabled` and a matching
idempotency key. The separately default-off `receiver-enforcement-v1` gate controls
this path. Enabling additionally requires independently injected trusted receiver
evidence and a fresh authenticated heartbeat. `enforcementEnabled` is emitted only
under that explicit gate. Disabling moves only that TV's held reservation to
unconfirmed, preserves spend, emits correlated false+release and grants no viewing
lease. Source tests cover disabled501, absent/stale readiness, CAS/idempotency/scope,
disable/release ACK and the initial-heartbeat activation race.

The server reports 87 joined tests passed and 141 distinct parent/legacy-web cases
covered (140 initially passed, one Node case skipped then separately passed with
bundled Node). Those are server-reported source checks, not locally rerun tests or
cross-layer/runtime acceptance. The original 19 core fixtures remain unchanged.

The client's idle control ACK/preparation-failure encoding supplies that all-null,
zero-elapsed shape and the policy's command ID. Its ambientStarted callback supplies
the controller UUID. The server subsequently froze this branch as control-correlated
only. Client playback/events now require that exact due/completed authority; generic
routine/budget/lease holds stay static. Changing/removing authority stops existing
ambient playback, and async preparation/failure cannot be relabeled with a replacement
control's ID. No generic hold-observation contract is implemented. Readiness stays off.

The backend's current source defaults advertise only read-only health, review inbox
and viewing history. Enforcement readiness remains off. No credentials were issued,
receiver paired, policy activated, service deployed or family trial run by this work.

## Verification

Local checks on 2026-10-17:

| Check | Result |
| --- | --- |
| KidsParentControl transport/feature/fixture tests | 60 passed |
| KidsViewingControl pure policy tests | 22 passed |
| KidsAccounts configuration contracts | 19 passed |
| SwiftfinCredentials namespace contracts | 9 passed |
| KidsApplicationBoundaryTests, fake hosts/controllers on tvOS Simulator | 50 passed |
| KidsPlaybackSession lifecycle/passive observations/neutral resume admission | 21 passed |
| VLCPlaybackOwnershipTests, fake native engine on tvOS Simulator | 21 passed |
| Parent iPhone model lifecycle, actual sources in isolated macOS harness | 7 passed |
| Package ownership/import/dependency audit | Passed, 55 libraries |
| Architecture-checker unit tests | 25 passed |
| Evidence revision input/symlink tests | 2 passed |

The application tests verify activated-without-lease denial, pairing-only behavior,
foreign/unreadable secure configuration, PIN protection, preview write denial and
existing identity/catalog/playback boundary cases. Added integration cases exercise
durable activation/deactivation, failed secure-store writes, bootstrap409 recovery,
byte-identical lost-receipt retries before policy refresh, single-flight concurrent
refresh, actual controller heartbeat fields, progress409 retention and four allowed
stale heartbeat errors versus six rejected integrity/unknown errors. A64-command
burst with an existing queue backlog verifies every executed action retains its ACK
and processing stops before overflow. Denial → final progress/stopped → release and
explicit mid-playback deactivation verify last-grant provenance without relabeling
queued reports. They use an
injected transport and isolated temporary command ledger, and do not exercise real
video or contact a server.
The evidence revision input set now includes the receiver, policy, credential,
account, TV experience and host-adapter sources so a build can be tied to this code.

`KidsJellyFin tvOS` and `KidsJellyFin Parents` generic simulator builds both passed
(arm64 and x86_64), with signing disabled. The iPhone target's Debug and optimized
Release simulator configurations also passed after the optional admission adapter
update; no device signing,
archive export, upload or physical installation follows from that result.
The TV app is rebuilt through KidsValidation with `ONLY_ACTIVE_ARCH=NO`. Application
cases cover preparation without operational reports, real fake-driver readiness
before usage, old-grant flush before renewal, secure-store failure, full bounded
evidence drainage before fresh policy, learned required-mode persistence and the
reporting-fault veto. Admission cases additionally cover zero-reservation browsing,
fresh exact binding before start, same-controller pause/surrender/resume with a new
observed started event, unknown POST replay and retirement before restart GET,
background during pending grant, actual buffer-readiness recovery, credential-free
durability, corrupt/foreign journal rejection and remote Resume expiry/ACK provenance.
Source fingerprints identify these builds; they do not certify a runtime budget trial.
After the final source changes and formatting, the built TV app's
`KidsEvidenceImplementationRevision` matches source SHA-256
`9e221e392a933a8ac1c7f5821fde9bee7f0a7cc338c8744d63ec41264cf00cf1`.
The shared-flight regression ensures a completed refresh is retired before a newly
staged intent must be sent. A further readiness-loss test holds a granted resume
before transport and preserves the earlier observed generation for terminal evidence;
neither receipt nor admission alone can relabel it as newly observed playback.

The separately preserved backend `shuffle-context-transaction.json` is10,470 bytes,
SHA-256 `16d96994be1ff33c5b32930767e324761b46c76480b7d3358920f7d152c70559`.
Native API replay verifies fresh empty context, durable positive viewing facts,
explicitly incomplete stale/unknown intervals and subsequent independent positive
userdata. Metadata enrichment preserves used5/unknown30/reserved0; it never refunds
quota. The sender reports425 joined source tests at checkpoint `0e239f5`. These are
server-executed synthetic tests, not installed service or family playback evidence.
The build retains existing lint/third-party VLC/SVGKit warnings and Apple's optional
App Intents metadata warning; it is not warning-free. No physical-device signing or
installation is implied. `git diff --check` and project/parent plist syntax passed.

Reproduce package checks with `xcrun swift test --build-system native
--package-path Packages/<package> --disable-sandbox` for the four packages above.
This checkout's default SwiftPM build engine stalled during SDK-stat-cache generation;
the native engine completed. This is a tooling workaround, not a product change.

The application boundary suite runs through the existing KidsValidation scheme:

```sh
xcodebuild -project KidsJellyFin.xcodeproj -scheme KidsValidation \
  -destination 'platform=tvOS Simulator,id=C185BD69-BF46-4520-AC7E-8174AEA534E3' \
  -only-testing:KidsUITests/KidsApplicationBoundaryTests \
  -disableAutomaticPackageResolution -skipPackageUpdates -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO test
```

Select an available simulator ID when reproducing on another Mac. These tests use
synthetic hosts/controllers; they do not call a household service or play media.

## Acceptance still required

Use an explicitly authorized isolated test profile/device after the backend gaps
are closed. Verify activation persistence, expiry while offline, TV/app/server
restart, countdown replacement/release and EOF/deadline races; deny a show through
every browse/queue/playback route; test budget reservations with concurrent TVs;
observe ambient EOF/error/recovery, lock protection and parent delivery states.
Exercise a reviewed YouTube import separately through the existing immutable
snapshot workflow. Record actual playback evidence and unsupported observations.
Only then promote each corresponding capability. Build success and persisted
receipts cannot replace these runtime acceptance checks.
