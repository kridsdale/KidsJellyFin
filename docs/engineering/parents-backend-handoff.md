# Build request: KidsJellyFin Parents backend, protocol v1

Human authorization, 2026-10-17: “First build and send a full spec design doc prompt
to the server agent to build their backend that you need with protocol spec. Then
build those extra features.” This is an implementation request for the server chat
**Make YT Feature**, on 1531Server. The peer Mac owns iPhone/tvOS source changes.

Implement the backend below alongside the existing kids cache service. Preserve
ongoing cache-repair work: finish or reach a durable safe checkpoint before changing
the deployed service. Acknowledge this contract, flag actual incompatibilities early,
then implement and test without repeatedly seeking approval for routine decisions.
Use isolated development/test state before a scoped service rollout. Do not run
family playback, import videos, or change current viewing policy as acceptance
tests without a separate explicit runtime test request. Report build/test/deployment
and actual end-to-end acceptance separately.

## Product outcome and hard boundaries

One iPhone app administers the existing Jellyfin server and approved kids catalog:

1. Quiet countdown; at deadline, stop kids content and loop an approved cached bird
   video. This leaves the TV powered on. No warning/countdown appears to the child.
2. Parent-selected YouTube playlist review/download through the existing cache UI.
3. Per-child show availability that controls both discovery and playback.
4. Finish this episode, capped by an explicit hard deadline.
5. Weekly viewing windows (school-night/weekend routines).
6. Daily minutes shared across devices/sessions.
7. Explicit extra-time grants, including a one-tap ten-minute grant.
8. Remote pause/resume/skip of the approved kids app session only.
9. Individual episode exclusions.
10. Inbox for newly discovered playlist videos requiring explicit review.
11. Shuffle preferences: unwatched-first, repeat cooldown, prioritized shows.
12. Simple viewing history with visible evidence limitations.
13. Passive server/download/storage/TV health.

Existing media on the RAID must NEVER be erased or modified. Persist control state,
tokens, events and logs outside media roots. The only existing media-write permission
is the dedicated managed YouTube cache under its already audited confinement.
Do not widen that boundary, scan arbitrary RAID folders, or expose adult material.
Do not replace the original Plex-derived approved library mapping. Show/episode
restrictions are policy records, not file renames, sidecar edits or content deletion.

No unrestricted Jellyfin proxy, generic remote-play bypass, YouTube search in the
kids app, automatic full-playlist approval, or implicit parent/child account creation.

## Existing integrations

Jellyfin: http://1531server.local:8096, server ID obtained from authenticated
System/Info. Import UI: http://192.168.10.100:8097; hostname on port 8097 currently
returns host_rejected. Preserve that service's cookie + exact Origin + CSRF +
idempotency protocol and immutable snapshot/inspect-selection/approve workflow.
The iPhone initially embeds the existing UI for review, avoiding duplicate approval
logic. Collection pause/resume affects acquisition, never viewing availability.

The client currently implements these capability-gated routes and wire types in
Packages/KidsParentControl. All new routes use camelCase JSON, UUID strings, UTF-8,
RFC 3339 UTC timestamps (fractional seconds accepted), integer revisions >= 0 and
bounded payloads. Query parameters are limited to the read routes specified below.
Unknown JSON keys may be ignored for forward compatibility, but unknown enum values
must fail safely. Route v1 must preserve the shapes below; discuss changes explicitly.

## Authentication and deployment

Prefix: /api/parent/v1. Native parent requests use a **dedicated scoped opaque Bearer
token**, not the Jellyfin administrator token and not the import UI cookie. Add an
adult-admin-only provisioning/revocation screen to the existing authenticated admin
UI: show the new token once; store only a secure verifier/hash; expiry <= 30 days;
never log secrets. The operator can paste the token into the phone's advanced setup.
Bind it to Jellyfin server ID, adult user ID, parent role, and selected child/device
scope. Revalidate adult permission on writes and revoke on disabled/deleted account.
Use constant-time verification and rate limits. Native Bearer endpoints must not
accept cookie authentication, so they have no ambient-cookie CSRF exposure. Keep
existing web endpoints' CSRF rules intact. Do not enable CORS or open router ports.

Read-only TV policy uses a separate, device-bound receiver credential provisioned
by an adult, with no access to parent mutation/history/import APIs. Durable device
IDs are installation identities, not Jellyfin session IDs. Do not send adult secrets
to the kids account. Existing Jellyfin login remains independent.

Only advertise supported features. If TV enforcement is not ready, implement/store
the server feature but leave its capability unadvertised and reject live writes.
Source/test readiness does not establish runtime enforcement. Coordinate receiver
requirements with the peer client chat; do not implement the iPhone app here.

## Reads: exact shapes

GET /capabilities
```json
{"version":1,"serverID":"JF-ID","features":["durable-countdown-v1","show-availability-v1","finish-episode-v1","routines-v1","daily-budget-v1","bonus-time-v1","remote-control-v1","episode-exclusions-v1","review-inbox-v1","shuffle-preferences-v1","viewing-history-v1","health-v1"]}
```

GET /dashboard — retain this initial client shape:
```json
{"serverID":"JF-ID","children":[{"id":"kid","name":"Kids"}],"televisions":[{"id":"tv","name":"Living room","childUserID":"kid","online":true,"canEnforceDeadline":true,"revision":7,"countdown":{"id":"schedule","deadline":"2026-10-18T02:30:00Z","birdItemID":"birds","status":"delivered"}}],"birdVideos":[{"id":"birds","name":"Garden feeder"}],"shows":[{"id":"series","name":"Little Bear","childUserID":"kid","enabled":true,"revision":3}]}
```
countdown may be null. TV online/enforcement readiness comes from recent authenticated
receiver heartbeats, not a generic Jellyfin session. Bird IDs must be published,
approved, locally available ambient items; exclude them from normal kids shuffle.
Disabled shows remain in the parent's list so they can be re-enabled.

GET /profiles/{childUserID}/settings
```json
{"childUserID":"kid","revision":4,"timeZone":"America/Los_Angeles","routines":[{"id":"UUID","name":"After school","weekdays":[2,3,4,5,6],"startMinute":900,"endMinute":1080,"enabled":true}],"budget":{"enabled":false,"dailyMinutes":60,"usedSeconds":600,"bonusSeconds":0,"localDate":"2026-10-17"},"shuffle":{"preferUnwatched":true,"repeatCooldownDays":7,"preferredShowIDs":["series"]},"excludedEpisodeIDs":[]}
```
Weekdays use ISO Monday=1 ... Sunday=7. Minute range 0...1439; v1 requires start < end
(overnight windows are two rules). Empty enabled routine list means no routine
restriction. If enabled rules exist, only their union allows normal kids viewing.
timeZone is an IANA identifier; profile timezone is authoritative for routine/budget.
Defaults preserve current behavior: no routines, budget disabled, no exclusions,
neutral shuffle. Do not change family policy just by installing the service.

GET /profiles/{childUserID}/episodes?showID=series&cursor=opaque (cursor optional)
```json
{"childUserID":"kid","showID":"series","items":[{"id":"episode","name":"A Snowy Day","showID":"series","season":1,"episode":2,"excluded":false}],"nextCursor":null}
```
Use existing approved series membership and scoped pagination; never arbitrary IDs.

GET /review-inbox?cursor=opaque (optional)
```json
{"items":[{"id":"entry","collectionID":"collection","snapshotID":"snapshot","title":"Little Bear playlist","newVideoCount":2,"createdAt":"2026-10-17T19:00:00Z","status":"needsReview"}],"nextCursor":null}
```
Use the existing complete immutable snapshots. No native auto-approval route is
requested. Review launches the existing manager; stale snapshot approval must fail.
Unavailable/unknown items remain unavailable/unknown. Retain exact membership review.

GET /profiles/{childUserID}/history?cursor=opaque (optional)
```json
{"childUserID":"kid","items":[{"id":"event","itemID":"episode","title":"A Snowy Day","deviceName":"Living room","startedAt":"2026-10-17T19:00:00Z","watchedSeconds":420,"evidence":"clientReported"}],"nextCursor":null}
```
Only approved kids entries. Retain up to 30 days, bounded storage. Actual viewing
duration derives from bounded, deduplicated receiver progress intervals, excluding
pause/buffering, not wall time since play was requested. Evidence values:
clientReported / jellyfinReported / incomplete. These are operational observations,
not proof of rendered frames/audio or a successful physical playback trial.

GET /health
```json
{"observedAt":"2026-10-17T19:00:00Z","jellyfin":"healthy","worker":"idle","storageFreeBytes":100000000000,"pendingJobs":2,"failedJobs":0,"televisions":[{"id":"tv","name":"Living room","online":true,"lastSeen":"2026-10-17T18:59:58Z"}],"issues":[]}
```
Status values healthy/degraded/unavailable/unknown and worker state are descriptive
strings. Numbers may be null if unknown; never report unknown as zero. Read passive
stored health/status only; no playback, file decode, RAID scan or network reconfigure.

## Writes: common rules and receipts

All POSTs require `Idempotency-Key: <commandID UUID>` and matching body commandID.
Atomic transaction: authorization + scope checks + expectedRevision check + state
change + idempotency result. Same key/payload returns the original receipt; different
payload is 409. A reused key must not target a different resource. Revision conflicts
are 409/412; permission 401/403; missing capability 501; invalid input 422; expired
command/target session 409. Return error JSON {error:code,message:nonsecret text}.

```json
{"commandID":"matching-UUID","status":"persisted"}
```
Persisted does not mean delivered. Dashboard/command status progresses through
persisted/delivered/applied/birds/cancelled/failed as applicable. A phone timeout is
an ambiguous outcome: it refreshes rather than blindly sending a new command.
GET /commands/{commandID} returns the same receipt plus optional errorCode; retain
receipts >= 7 days within bounded retention. TV acknowledgements cannot mark an
unexecuted action complete. Playback evidence limitations must remain explicit.

POST /countdowns
```json
{"commandID":"UUID","deviceID":"tv","childUserID":"kid","durationSeconds":900,"birdItemID":"birds","expectedRevision":7,"silent":true}
```
Duration 60...14400, online compatible receiver required. Server calculates/persists
UTC deadline using its clock, checks ambient readiness, increments TV revision.

POST /countdowns/cancel
```json
{"commandID":"UUID","deviceID":"tv","childUserID":"kid","expectedRevision":8}
```
Cancels pending countdown or explicitly releases ambient mode, with current revision.
Phone waits for TV-applied state before claiming viewing resumed.

POST /shows/availability
```json
{"commandID":"UUID","showID":"series","childUserID":"kid","enabled":false,"expectedRevision":3}
```
Revision is that show/profile pair's revision from dashboard. Preserve original
approved catalog and enforce denial on descendants, including already playing item.

POST /finish-episode
```json
{"commandID":"UUID","deviceID":"tv","childUserID":"kid","maxDurationSeconds":1800,"birdItemID":"birds","expectedRevision":8}
```
Bind to the receiver's currently playing episode and playback session at acceptance.
No active eligible episode => 409. End on native EOF of that episode or server hard
deadline, whichever comes first. Do not carry permission over to a different episode.
This never extends an earlier daily-budget/routine/deadline restriction.

POST /routines
```json
{"commandID":"UUID","childUserID":"kid","expectedRevision":4,"timeZone":"America/Los_Angeles","routines":[{"id":"UUID","name":"After school","weekdays":[1,2,3,4,5],"startMinute":900,"endMinute":1080,"enabled":true}]}
```
Atomically replaces this profile's routine list only. Max 32 rules, unique IDs,
1...7 weekdays, no duplicate days, valid timezone. DST spring gaps advance to first
valid local instant; fall repeated hour belongs to the same local date/window and
never grants a second budget. Timezone changes do not mint a fresh allowance.

POST /budgets
```json
{"commandID":"UUID","childUserID":"kid","expectedRevision":4,"enabled":true,"dailyMinutes":60}
```
0...1440 minutes, shared across all paired devices for that profile/local date.
Concurrent active sessions debit actual duration independently. Server grants bounded
short playback leases from remaining allowance; reserve/debit centrally so offline
TVs cannot each spend the entire remaining daily budget. Offline lease expiry locks
new content. A parent bonus is explicit; changing limit does not reset used time.

POST /bonuses
```json
{"commandID":"UUID","childUserID":"kid","deviceID":"tv","target":"countdown","seconds":600,"expectedRevision":8}
```
target countdown => TV revision; adds to current pending deadline only. target budget
=> profile settings revision, deviceID null; adds to today's shared budget only.
seconds 60...3600. Does not override routine closure or a different stricter limit.
No implicit release from ambient mode: require explicit cancel/release for that.

POST /remote
```json
{"commandID":"UUID","deviceID":"tv","childUserID":"kid","action":"pause","expectedRevision":8}
```
action pause/resume/skip. Bind to active receiver playback session; expire undelivered
commands after 30 seconds and never replay on a later session. Skip chooses the next
authorized item via kids queue rules, never an arbitrary media ID. Do not send generic
Jellyfin PlayNow because current tvOS disables it to protect the catalog boundary.

POST /episodes/availability
```json
{"commandID":"UUID","childUserID":"kid","episodeID":"episode","excluded":true,"expectedRevision":4}
```
Revision is profile settings revision. Membership checked server-side through the
approved series. A show denial always wins; unexcluding an episode cannot enable
its disabled show. Exclusion applies to current playback and all queue entry points.

POST /shuffle
```json
{"commandID":"UUID","childUserID":"kid","expectedRevision":4,"preferUnwatched":true,"repeatCooldownDays":7,"preferredShowIDs":["series"]}
```
Cooldown 0...30 days, <=100 distinct approved show IDs. Never affects ordered playback
progress. Restrict eligibility first, then select preferred/unwatched/fresh candidates;
if all eligible candidates are recent, relax freshness, never catalog restrictions.
Priorities do not escape the child's currently selected show unless the queue mode
explicitly supports cross-show shuffle. No claim of that mode in current client.

## Receiver protocol: backend work and client integration boundary

GET /api/kids/v1/policy with device Bearer token (bound device/profile/server).
Return complete, revisioned snapshot:
```json
{"serverID":"JF-ID","childUserID":"kid","deviceID":"tv","revision":10,"serverTime":"2026-10-17T19:00:00Z","validUntil":"2026-10-17T19:00:30Z","viewingAllowed":true,"blockedShowIDs":[],"blockedEpisodeIDs":[],"deadline":null,"finishPlaybackSessionID":null,"birdItemID":"birds","shuffle":{"preferUnwatched":true,"repeatCooldownDays":7,"preferredShowIDs":[]},"commands":[]}
```
deadline can be an RFC3339 UTC string. validUntil is the centrally granted lease
expiry constrained by budget/routine/deadline, max 30 seconds. Poll at 5 seconds while
foreground; receiver keeps the accepted deadline/lease locally and uses monotonic
elapsed time to prevent wall-clock rollback extending a session. On restart or stale
policy it locks new normal playback until fresh policy is verified. Unpaired existing
TV behavior stays unchanged until adult explicitly enables parental enforcement.

commands items: {commandID:UUID,action:pause|resume|skip,playbackSessionID:string,
expiresAt:timestamp}. Reject session mismatch/expired commands locally. Remote IDs
are deduplicated durably before execution; every action remains subject to policy.

POST /api/kids/v1/events with device Bearer and Idempotency-Key matching eventID:
```json
{"eventID":"UUID","deviceID":"tv","childUserID":"kid","policyRevision":10,"playbackSessionID":"session","itemID":"episode","kind":"progress","positionSeconds":120,"elapsedPlayingSeconds":5,"commandID":null}
```
Kinds heartbeat/started/progress/paused/buffering/ended/stopped/commandApplied/
commandFailed/ambientStarted/ambientFailed. Server timestamps receipt. Validate finite
nonnegative positions; bound elapsedPlayingSeconds to its lease interval; never
count arbitrary jumps, duplicate events, paused/buffering time, or playback requests
as watched time. Reject mismatched current leases/session identities. Recent played
item plus bounded progress drives history; EOF plus supported player observation is
stronger than clock inference, still not physical frame/audio certification.

The peer client will implement receiver integration separately. Return pairing/UI
contract early: provision receiver token through existing adult web UI, show once,
server-bound and device-bound, never child account's Jellyfin admin privileges.

## Acceptance and rollout

Automated tests with fake clocks/fake receiver: auth/scoping; cross-server rejection;
UUID/body idempotency; crash between state/receipt; parallel-parent conflicts; restart
and overdue timer recovery; EOF vs hard deadline race; cancelled/replaced schedules;
weekdays/DST/timezone changes; zero-budget/multiple TVs/lease overspend bounds;
paused/buffering exclusions; episode inherits denied series; skip to denied item;
late remote command cannot hit new session; unknown status stays unknown; review
snapshot races retain original approval safety; storage paths/confinement remain exact.

Roll out schema migration with backup/rollback of control DB only, off RAID. New
features disabled by default. Existing cache jobs and original library audit remain
healthy. Capabilities are promoted per feature after receiver readiness; read-only
review/history/health can ship independently. Do not claim all capabilities complete
because routes compile or HTTP 202 was returned.

Please report: authoritative base URL; provisioning screens/token flow; exact route
compatibility; versioned schema/test fixtures; commits/tests; deployed service state;
which capabilities are advertised versus awaiting TV acceptance; unresolved blockers.
Do not include credentials in reports. Continue this backend implementation in the
server chat; send concise coordination updates to the peer when permitted by the
human's explicit request to coordinate this backend handoff.

## Agreed additive clarification — server coordination, 2026-10-17

The server agent identified and the client accepted two protocol additions:

- Receiver snapshots add optional `policyControl: {commandID: UUID, kind:
  "countdown" | "finishEpisode" | "release"}`. The receiver echoes that exact ID
  for commandApplied/ambientStarted/commandFailed. Deadline or media ID alone cannot
  identify the command through cancellation/replacement. Remote `commands[]` stays
  unchanged. Missing receiver correlation keeps those capabilities disabled.
- Budget adds nonnegative `reservedSeconds`, `unconfirmedSeconds`, and authoritative
  `remainingSeconds`. `usedSeconds` is confirmed bounded playback only. Remaining
  time subtracts confirmed usage and all held/unconfirmed reservations. The phone
  uses authoritative remainingSeconds; without it, remaining time displays unknown.
  This supersedes the earlier two-reservation-field fallback: public used/history
  seconds are floored and held/unconfirmed seconds are ceiled for display, while
  authoritative remaining floors the full-precision calculation. Missing reports never
  silently refund allowance; history marks those intervals incomplete.

The server agent acknowledged the human authorization and is implementing in an
isolated checkout, preserving the pinned cache service and current repair gates.
This acknowledgement does not establish backend completion or deployment.

## Receiver integration clarification — 2026-10-17

The peer now has an implemented tvOS receiver. Its implementation/acceptance record
is [parents-receiver-integration.md](parents-receiver-integration.md). Agreed
extensions below are not all implemented or frozen in the backend; keep enforcement
capabilities disabled until they are tested and commissioned.

- Device identity is the displayed raw installation UUID, without `tvOS_`. Preserve
  its exact spelling/case when issuing the scoped receiver credential. The receiver
  echoes the verified policy's device ID for subsequent events.
- An event receipt's `commandID` echoes request **eventID**, not request.commandID.
  The latter identifies the parent action. Retain all ten event keys, including nulls.
- Pairing is not activation. Add optional `enforcementEnabled`: explicit true
  activates, missing does not activate/deactivate, explicit false deactivates only
  with authenticated correlated `policyControl.kind == release`. Activation is
  persisted locally before granting normal playback. Activated launch/outage/501
  holds viewing until a fresh lease. Preserve spent/reserved/unconfirmed allowance.
- Never-activated heartbeat has revision 0, null session/item/position/command and
  zero elapsed. It only establishes reachability, never budget/history/lease/readiness.
  Its receipt follows ordinary event idempotency. The receiver may discard only
  this no-usage heartbeat on 409 if it races activation, then fetch policy again.
- Idle countdown/release ACKs and preparation-failure ambientFailed may lack a
  session/item/position. Server now reports this source branch implemented: all
  three must be null, elapsed zero, and commandID must identify the exact delivered
  current scoped control. Remote ACKs cannot use it; ambientStarted requires an
  actual nonempty controller session. Backend reports 63 policy/wire/HTTP tests,
  no deployment/readiness promotion. The branch is now frozen as control-correlated
  only: the client suppresses ambient playback/events on generic routine/budget/lease
  holds and keeps its static fallback. birdItemID alone does not authorize playback.
  Never invent a control ID. A future generic branch requires a separate contract.
- Accept queued evidence against its original granted lease/revision and remote
  delivery, including prior revisions; never relabel it with a newer policy revision.
  Backend checkpoint `8890ead` now implements bounded recovery in source. Missing
  usage cannot refund reservations. Installed integration remains a gate.
- Add optional `shuffleContext: {watchedItemIDs: [...], recentItemIDs: [...]}` scoped
  to approved items, plus the now-frozen `complete:boolean`. The client requires
  explicit true for history ranking; missing/false is not evidence of never watched.
  Keep shuffle readiness off pending completeness/cross-device tests.

Adult credential provisioning uses existing manager cookie, exact Origin and CSRF:
GET/POST `/api/parent-admin/v1/credentials`, POST
`/api/parent-admin/v1/credentials/{tokenID}/revoke`. Issue an explicit receiver role
for exactly one child and installation UUID; never reuse Jellyfin credentials.
The first response exposes its secret once. Exact retry returns metadata and
`secretShown:false, token:null`; a lost secret requires explicit revoke/new issuance.
This flow is backend source only as of the receiver implementation record.

### Adult enforcement route — backend source update

Server now reports `POST /api/parent-admin/v1/devices/{exactInstallationUUID}/enforcement`
implemented behind separately default-off `receiver-enforcement-v1`, using existing
adult cookie/Origin/CSRF. Body: `{commandID, childUserID, expectedRevision, enabled}`
with matching idempotency key. Enable needs trusted independently supplied receiver
evidence and a fresh authenticated heartbeat. Only the explicit gate emits optional
`enforcementEnabled`. Disable preserves spent allowance, moves only this device's
held reservation to unconfirmed, and emits false+release without a viewing lease.
Five transaction tests are reported passing. This is neither commissioning nor
deployment. Prior-lease/delivery recovery is now source-tested against exact native
fixtures. Complete shuffle context, startup/catalog adapter and observed runtime
behavior remain gates.

### Heartbeat and UUID clarification

Activated idle and disabled idle heartbeats use the latest policy revision, null
session/item/position/command, elapsed0. Actual normal/authorized ambient heartbeat
carries its controller, item and numeric position; it still has elapsed0/commandnull
and cannot mint a lease or usage. The server must have stored the exact accepted
ambientStarted binding before accepting ambient heartbeat; release clears it.

Discard only no-usage heartbeat409 for the four frozen stale codes:
`lease_mismatch`, `lease_expired_or_mismatched`, `policy_revision_mismatch`,
`heartbeat_session_mismatch`. Fetch fresh scoped policy afterward. Other409 reasons,
including idempotency/key mismatch, clock rollback and restore-review requirements,
stay fail closed. No progress/control/ambient evidence is silently discarded.

The backend first requires original event/command body UUID spelling to equal its
original idempotency header, then normalizes these UUID identities together. Correlated
command UUIDs and command paths normalize too; installation/child/Jellyfin subjects
must never be normalized. Native Swift emits uppercase UUIDs. The joined native
UUID transaction fixture is now independently hash-verified and replayed by native
tests; differently spelled installation subjects are rejected before event send
and policy admission.

### Queued evidence recovery — frozen source contract

Backend checkpoint `8890ead` reports162 distinct joined tests with no skips in a
RAID-denied loopback sandbox. Exact `historical-usage.json` and `late-ack.json`
fixtures, independently hashed on the peer, are recorded in the receiver integration
document. The peer has51 protocol tests and37 actual-source application boundary
tests passing with injected transports and fake playback drivers. This is source
compatibility, not deployment or runtime readiness.

- A normal controller that never produces the operational started callback emits
  no normal usage/stopped reports. Preparation heartbeat remains all-null/zero.
- Started queues before subsequent normal evidence. Pause/buffering transitions
  carry zero elapsed; prior accrued playing time is flushed first, using the
  corresponding observed position. Renewed ALLOW is remembered only after flushing
  the old grant's accrued interval. Queued event values/bytes remain immutable.
- Historical usage requires an actual returned ALLOW and the server's accepted
  controller/item binding. It can replace matching uncertain usage, never refund
  unobserved allowance, cross accounting periods or change current DENY/lease state.
- A late ACK with exact delivered command/device/child/revision/epoch proof can be
  persisted as inert evidence. Its ordinary `{commandID:eventID,status:persisted}`
  receipt acknowledges storage only. Expired/superseded commands stay failed or
  cancelled; no action/time/session/policy state is revived. Fresh release remains
  a separate current command and acknowledgement.
- The bounded recovery window is seven days. Unknown/never-delivered/cross-subject,
  epoch and idempotency-integrity failures remain failures. The client retains them
  and holds rather than discarding evidence. A delayed first-start report after an
  external policy change uses the separately gated extension below.
- Five-second foreground polling/heartbeat capacity must be demonstrated before
  commissioning. The one-second watchdog is local and does not generate receipts.
  No cadence, registration limit or production storage limit changed on the peer.

### Delayed first-start recovery — agreed extension, commissioning off

`unconfirmed-start-recovery-v1` is separately default-off and requires this validated
receiver implementation; old clients cannot be commissioned to ignore reset fields.
An original actually returned ALLOW plus exact scope/catalog proof may retain an
otherwise unbound controller's reports only as private unconfirmed evidence. Parent
show/time DENY remains effective. No confirmed history/used credit, new controller,
lease, quota refund, media read/import or existing parent-control change follows.
Retire only that original still-unbound reservation to unconfirmed so another
controller cannot share its uncertain interval. Unknown/never-issued grants fail.

The persisted event receipt adds both fields:

```json
{"commandID":"EVENT-UUID","status":"persisted","evidenceDisposition":"unconfirmed","unconfirmedPlaybackSessionID":"EXACT-SUBMITTED-SESSION"}
```

Only normal started/progress/paused/buffering/ended/stopped with no command ID and
nonempty item/session may use this metadata. Unknown disposition, incomplete pair,
wrong event/session or control/ambient/heartbeat use fails closed. Native receipt
decoding is separate from parent-action receipts. A malformed receipt retains the
queued event and sets a reporting fault.

The receiver stops/retires only the exact matching active controller; replacement
sessions are untouched. Preserve/drain the immutable old FIFO and actual stop, then
read fresh policy. Never autoplay or manufacture a start from a persistence receipt.
A later normal user Play uses fresh permission and a new real controller/start.
The actual8,979-byte `unconfirmed-first-start.json` transaction fixture now matches
the supplied SHA-256 exactly and passes native API replay; the backend reports177
distinct joined tests with no skips. Exact proof/hash and trace are in the receiver
integration document. Source tests do not establish installed capability or
household acceptance.

### Playback grants — agreed source draft, lifecycle integration unfinished

The idle-polling budget defect blocks daily-budget commissioning. Under separately
default-off `playback-grants-v1`, policy GET is read-only when no current grant is
valid. It must not reserve time merely because foreground browsing is allowed.
Policy adds `playbackIntentRequired`, `playbackIntentAvailable`, `playbackIntentID`,
`leasePlaybackSessionID`, and `leaseItemID`. Availability permits requesting intent;
only fresh, finite, exact intent/controller/item permission permits transport.

Intent POST `/api/kids/v1/playback-intents` has exactly commandID/deviceID/childUserID/
expectedRevision/playbackSessionID/itemID. Use the actual prepared controller before
driver.start. The matching idempotency receipt is persistence only. Fetch current
policy afterward, including after an exact retry; a cached receipt cannot extend an
expired grant. GET may renew an observed playing controller while allowed, never
idle/prepared/long-paused by itself.

Surrender POST `/api/kids/v1/playback-surrenders` has exactly commandID/deviceID/
childUserID/playbackIntentID/playbackSessionID/itemID, deliberately no policyRevision.
Locally hold/pause first, flush prior actual evidence in FIFO order, then surrender.
Auto-renewals retain the intent ID. Explicit resume gets a new intent even for the
same controller, so an old surrender cannot revoke a resumed generation. Pending
evidence/surrender resolves before new intent. Neither receipt grants playback.

Only future capacity attributable to that intent can be released, using accepted
server time and original expiry, bounded by still-held/attributable uncertainty.
Past uncertainty and confirmed usage remain charged. Already-expired/unknown-period/
unproven provenance releases zero; reset boundaries clamp grants and existing clock/
restore/integrity guards remain. Server transaction fixtures are still pending.

The native DTO/HTTP foundation has55 protocol tests passing and its neutral optional
resume callback has21 session tests passing. These helpers are UNWIRED. Preparation,
paused/held controller retention, UI/remote resume, safe buffer-readiness admission,
sticky required-mode validation and quota retirement need complete runtime wiring
and tests after the transaction contract freezes. Native intent/surrender receipts
must use receiver capacity, preserving the separate adult-control reserve. No
configured feature, trusted-readiness record, deployed policy or family account changed.
