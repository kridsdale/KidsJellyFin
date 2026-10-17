# KidsJellyFin Parents

An iPhone companion in `KidsJellyFin.xcodeproj`, scheme **KidsJellyFin Parents**.
Bundle ID: `com.kridsdale.JellyfinPlayer.Parents`. Team: `Z3LBQE3J8T`.
Minimum iOS: 18.6. A separate app, Keychain namespace, and source directory;
the existing kids targets retain their source membership. Unpaired TVs keep their
existing behavior; the opt-in receiver integration is described below.

## Implementation status

This is the first client implementation, not completed end-to-end parental enforcement.

The full server implementation prompt was sent to **Make YT Feature** on 2026-10-17.
Its authoritative contract is [parents-backend-handoff.md](parents-backend-handoff.md),
including the subsequently agreed command-correlation and budget-reservation fields.
The server agent acknowledged the human request and is implementing in isolation
while preserving its existing cache repair and deployment gates.

### Additional parent features implemented in the client

| Feature | Native app entry point | Capability |
| --- | --- | --- |
| Finish episode with hard stop | Tonight | finish-episode-v1 |
| Weekly viewing windows | Tonight / Settings → Family rules | routines-v1 |
| Shared daily allowance | Family rules | daily-budget-v1 |
| Ten-minute grants to deadline or daily budget | Tonight / Family rules | bonus-time-v1 |
| Pause, resume, skip | Tonight | remote-control-v1 |
| Exclude individual episodes | Shows → Episode rules | episode-exclusions-v1 |
| New-video approval inbox | YouTube → Review inbox | review-inbox-v1 |
| Unwatched-first, cooldown, preferred shows | Family rules → Shuffle | shuffle-preferences-v1 |
| Scoped, paginated viewing history | Tonight / Settings | viewing-history-v1 |
| Storage, worker, download and TV health | Settings | health-v1 |

Each write retains the captured resource revision. Editors do not silently replace
their revision with a newer background-refresh revision. Unknown write outcomes block
new changes until fresh state arrives. Child changes clear previously loaded child
data, pages reject duplicate records/repeating cursors, and replies verify account
and series scope. Five-second foreground polling reads policy/command state only;
it does not execute playback or automatically retry writes. Parent-service credentials
are stored in the app's separate Keychain namespace and restored only for the same
Jellyfin server and adult user after device unlock.

Read-only inbox entries launch the existing authenticated manager for exact immutable
snapshot review; they never auto-approve a playlist. Operational viewing reports are
labeled by their evidence source, and unknown health counts stay unknown.

Remaining allowance uses only the server's authoritative `remainingSeconds`.
Public watched seconds are floored and held/unconfirmed seconds are ceiled for
display; they cannot reconstruct the server's fractional accounting. If the
authoritative value is absent, the phone shows unknown even when every display
field is present. Playback permission still comes from the server's bounded leases.

These are implemented client features awaiting the server's advertised capabilities.
The child tvOS receiver is now implemented and locally tested; see
[receiver integration](parents-receiver-integration.md) for its activation model,
verification, and remaining backend protocol gaps. Backend source, deployment,
receiver readiness and end-to-end family acceptance remain separate milestones.

| Area | Implemented here | Remaining acceptance |
| --- | --- | --- |
| iPhone target | Separate target, scheme, SwiftUI screens, local-network declaration | Device signing/install and physical iPhone testing |
| Jellyfin | Administrator sign-in, Keychain session, validation, session list, Kid TV catalog | Adult sign-in against live server in the iPhone UI |
| YouTube | Validated playlist link, explicit clipboard handoff, embedded deployed import UI | Authenticate and exercise existing review workflow on iPhone; no live import was run for this change |
| Quiet countdown | Phone UI, scoped receiver, monotonic lease/deadline enforcement, approved ambient loop and static fallback | Backend extensions/deployment, commissioning and observed runtime acceptance |
| Show availability | Revision-checked phone contract, TV catalog/queue/playback gates | Backend policy deployment and end-to-end denial acceptance |
| App protection | Background lock through existing SwiftfinPermissions device authentication | Face ID/passcode and background transitions on a physical phone |

The app's activity generation now invalidates sign-in and device-unlock results
that return after backgrounding. A late issued Jellyfin login is never stored or
used to reopen parent controls; the app attempts to sign it out and surfaces a
cleanup failure instead of claiming success. A rejected secure-store write likewise
keeps the phone signed out and attempts to retire the newly issued server session.
Control-service connection captures the
exact URL/token it validated; editing fields or clearing them during suspension
cannot persist a different credential. Unknown mutation cancellation still requires
fresh state, rather than being treated as a harmless interrupted read.

The server agent confirmed on 2026-10-16 that the installed import service has
no countdown or show-availability API. Collection pause controls acquisition,
not viewing. The new controls therefore remain unavailable on the current server.
Generic tvOS remote-play commands remain disabled; this change does not reopen
that catalog-bypass path. No media or server configuration is changed by building
or launching the offline preview.

## Product behavior

### Delivery requirements and completion evidence

All thirteen requested phone features have source UI and scoped protocol methods.
The following acceptance items remain part of the goal; compiling the screens does
not complete them. Existing approved libraries and protected RAID media must stay
unchanged throughout commissioning.

| Requirement | Current client path | Evidence still needed to complete delivery |
| --- | --- | --- |
| Quiet countdown, then looping birds | Tonight; TV deadline/watchdog/ambient controller | Deployed backend, authorized receiver trial, deadline/EOF/error/restart observation |
| Select YouTube playlist for the archive | YouTube; embedded authenticated review manager | Phone review/import trial through existing immutable approval workflow |
| Enable/disable shows | Shows; TV catalog and playback gates | Observed denial through browse, deep-link rejection, queue advance and playback |
| Finish current episode with hard cap | Tonight; exact controller EOF plus deadline | EOF/deadline/replacement/release race trial |
| Weekly routines | Family rules; server policy lease | Deployed routine engine, DST/timezone and closure/reopen integration |
| Shared daily allowance | Family rules; explicit TV intent/surrender coordinator, durable mutation journal, short bound grants and usage reports; exact backend transaction fixture replay | Authorized runtime commissioning, concurrent-device accounting, offline/restart and physical-device acceptance |
| Extra-time grants | Tonight/Family rules | Revision conflict, stricter-rule precedence and explicit-release behavior |
| Remote pause/resume/skip | Tonight; session-bound TV commands | Current-session action/expiry/dedup/queue-backpressure trial |
| Episode exclusions | Shows → Episode rules; TV item gates | Current episode stop and all subsequent playback entry points |
| New-video review inbox | YouTube → Review inbox | Deployed read adapter and exact snapshot review flow |
| Shuffle freshness/priorities | Family rules; TV eligible candidate selection | Complete central history/context, cross-device and safe freshness fallback |
| Viewing history | Tonight/Settings | Deployed scoped reports, pagination, gap/incomplete labeling |
| Passive health | Settings | Fresh installed-service/storage/job/device adapters with honest unknown values |

The common integration sequence is: finish/freeze backend source → verify its exact
fixtures with native client code → validate the isolated startup/catalog adapter →
prepare a gated deployment/rollback → explicitly commission a test receiver →
observe runtime behavior → promote each validated capability. Source tests cannot
stand in for the final two steps. Physical iPhone/tvOS signing/install remains
unverified; the configured paid team is not installation evidence.
The ordered scope, trial matrix and rollback requirements are in
[parents-commissioning.md](parents-commissioning.md). This is a reviewable execution
plan; none of its live steps are authorized or marked complete by source checks.

- **Tonight:** select the family TV, remaining minutes, and an approved bird video.
  Start without an overlay on the TV. The phone shows acknowledged server state;
  a saved receipt alone never claims delivery or playback.
- **Shows:** select a child and enable/disable individual shows. Until policy
  support is installed, show the existing Kid TV catalog read-only. Disabling
  must never delete media or mutate its metadata files.
- **YouTube:** paste a playlist, explicitly copy its canonical link, and open
  the existing server manager inside the phone app. Paste into its playlist
  field, inspect and approve exact videos. The app does not auto-approve a
  playlist or bypass the existing immutable snapshot review process.
- **Settings:** server identity, connection refresh, import-manager address,
  and optional future control-service connection. Device authentication protects
  access after backgrounding. Jellyfin passwords are not persisted.

Settings now includes **Set up access on the server**, using the configured control
manager root in a separately authenticated ephemeral web sheet. Sign in there, then
choose its Parents entry. The frozen authenticated page is `/admin/parent-control`;
opening it directly in a fresh browser returns401, so the phone does not assume it
can skip manager login. No native Jellyfin or parent-service token is forwarded to
this browser. The backend provisioning/activation UI is reported implemented in
source but remains uninstalled; the clean authenticated handoff still requires an
integration trial. Preview mode disables the setup action.

“Done” means ending kids viewing inside KidsJellyFin and switching to looping
birds. It does not power off a television or prevent use of other Apple TV apps.
The desired long YouTube bird video must be selected by the parent and acquired
through the approved cache workflow. Store it as an explicit ambient item, outside
normal kids shuffle; use its Jellyfin item ID, never an expiring YouTube stream URL.
If it is unavailable at deadline, enforce the viewing stop with a calm static screen.

## Existing server integration

Verified unauthenticated reads from this Mac:

- `http://1531server.local:8096/System/Info/Public`: HTTP 200.
- `http://192.168.10.100:8097/api/session`: HTTP 200 with the matching Origin.
- `http://1531server.local:8097/api/session`: HTTP 403 `host_rejected`.

The import screen therefore defaults to **the IP address**, independently of the
Jellyfin address. Its WKWebView uses an ephemeral cookie store and restricts page
navigation to that origin. It sends no native Jellyfin access token. The deployed
web interface handles adult login, HttpOnly SameSite=Strict cookies, CSRF, exact
Origin, idempotency and review. Closing its sheet ends that browser session.

Server-agent contract reference (not reimplemented by the phone):

1. `GET /api/session`, then `POST /api/login` with username/password, cookie,
   Origin and CSRF; login rotates cookie/CSRF.
2. `POST /api/snapshots` with playlist URL.
3. `POST /api/snapshots/{id}/inspect-selection` with digest and selected video IDs;
   this yields a **new** immutable snapshot requiring review.
4. `POST /api/snapshots/{newID}/approve` with digest, expected revision, exact
   video/channel selection, overrides and explicit acquisition permission.
5. Approval queues work. Collections, jobs and status remain visible in that UI.

No scheduled download or playback is triggered on app launch. Server-agent bulk
repair continues independently. The phone does not change RAID permissions or
add unrestricted library roots.

The HTTP exceptions are scoped to the home server, following Apple's
[local-network ATS documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).

## New control-service contract — proposed, not deployed

`Packages/KidsParentControl` owns the transport and Codable wire types. Its
Jellyfin interface is a narrow independent HTTP client, with no file or library
mutation methods. It has no third-party dependencies. The app reuses
`SwiftfinPermissions` for device authentication.

The future service may share the import service's host, but needs a distinct
authenticated native API. The current import service **does not accept** the
Bearer-token contract below. Do not reuse a Jellyfin admin token as that token.
Provision a scoped, revocable parent-service credential through its own admin UI.
Version/capability negotiation must pass before any phone write.

### GET /api/parent/v1/capabilities

```json
{
  "version": 1,
  "serverID": "same-id-as-authenticated-jellyfin-server",
  "features": ["durable-countdown-v1", "show-availability-v1"]
}
```

Advertise a feature only after its server and TV implementations are available.
Authentication uses `Authorization: Bearer <dedicated parent-service token>`.
Reject tokens without adult authorization. Revalidate that authorization on writes.
All JSON field names below are case-sensitive; dates are RFC 3339.

### GET /api/parent/v1/dashboard

```json
{
  "serverID": "same-id-as-authenticated-jellyfin-server",
  "children": [{"id": "kid-user", "name": "Kids"}],
  "televisions": [{
    "id": "durable-device-id", "name": "Living room", "childUserID": "kid-user",
    "online": true, "canEnforceDeadline": true, "revision": 7,
    "countdown": {
      "id": "schedule-id", "deadline": "2026-10-17T02:30:00Z",
      "birdItemID": "approved-ambient-item-id", "status": "delivered"
    }
  }],
  "birdVideos": [{"id": "approved-ambient-item-id", "name": "Garden feeder"}],
  "shows": [{
    "id": "series-id", "name": "Little Bear", "childUserID": "kid-user",
    "enabled": true, "revision": 3
  }]
}
```

`countdown` may be null. Devices have durable IDs, not ephemeral Jellyfin session
IDs. Each entry binds one device to one child. `online` and
`canEnforceDeadline` must come from recent receiver handshakes, never inferred
from a generic Jellyfin session. Only approved kid shows and ambient items belong
in this response. A disabled show must remain visible to the parent so it can be
re-enabled. Do not implement this by changing the parent account's library policy.

### POST /api/parent/v1/countdowns

```json
{
  "commandID": "UUID",
  "deviceID": "durable-device-id",
  "childUserID": "kid-user",
  "durationSeconds": 900,
  "birdItemID": "approved-ambient-item-id",
  "expectedRevision": 7,
  "silent": true
}
```

Server atomically validates identities, current revision, 60–14400 second duration,
approved ambient item readiness and receiver support. It calculates the UTC deadline
from its clock, durably records the command and increments revision. Phone suspension
must have no effect on execution. The acknowledged deadline is returned by dashboard.

### POST /api/parent/v1/countdowns/cancel

```json
{"commandID":"UUID","deviceID":"durable-device-id","childUserID":"kid-user","expectedRevision":8}
```

Cancel only the exact current revision. A cancellation after the deadline must be
defined as an explicit parent release from ambient mode and delivered to the TV;
the phone must not optimistically imply that viewing resumed.

### POST /api/parent/v1/shows/availability

```json
{"commandID":"UUID","showID":"series-id","childUserID":"kid-user","enabled":false,"expectedRevision":3}
```

Change only policy records. Do not edit media, metadata sidecars, physical directories,
or the child's entire Jellyfin policy as a side effect. Server authorization must
check the series is in the pre-existing approved kids catalog. Episodes inherit
their series policy. Policy denial must win over favorites, continue watching,
shuffle, deep links, cached lists and remote play. Decide and test behavior for an
already playing episode; recommended v1 behavior is to stop it when denial arrives.

### Receipts and retries

Every write includes `Idempotency-Key` equal to `commandID`, and returns:

```json
{"commandID":"matching-UUID","status":"persisted"}
```

- Store idempotency result and state update in the same transaction.
- Same key/same payload returns its original receipt. Same key/different payload
  is rejected. Stale revision is HTTP 409 or 412; permission failure is 401/403.
- A 202/persisted receipt is not TV execution. Subsequent statuses may be
  `delivered`, `birds`, `cancelled`, or `failed`. The server must not use `birds`
  until the TV confirms actual media playback according to its supported evidence.
- Never silently retry a timed-out mutation with a new command ID. Refresh first.
- Unknown version or missing feature stays unavailable. HTTP redirect following
  is disabled for native credential-bearing requests.

## TV and server acceptance required before enabling the features

The TV source implementation now covers items 2–6 below. These remain an acceptance
checklist: source compilation does not establish live delivery or playback behavior.

1. Persist schedules, revisioned availability and idempotency records off the
   protected media tree. Recover schedules on service restart; reconcile overdue
   deadlines before allowing new kids playback.
2. Add an explicitly authenticated, profile-bound TV receiver. Preserve the
   existing catalog boundary instead of enabling unrestricted Jellyfin remote play.
3. Persist delivered deadlines on TV. Use server-time offset and a monotonic elapsed
   timer while running; re-evaluate after foregrounding/relaunch. Server events or
   polling should provide bounded delivery, reconnection and acknowledgement.
4. Enforce expired deadlines and per-show denials at **every** playback entry point,
   queue advance and catalog projection. Back/Menu/Next must not escape ambient mode.
5. Loop the approved cached bird item at EOF. Decoder/network failure shows a calm
   static background without unlocking kids content. No YouTube search or autoplay.
6. Define stale-policy behavior. V1 should fail closed for new playback when required
   policy cannot be verified; an already acknowledged deadline still fires offline.
7. Return parent-readable delivery and error state; never infer end-to-end success
   from an HTTP response, running timer, or a generic player session.

## Validation

Run package tests without accessing the home server:

```sh
xcrun swift test --package-path Packages/KidsParentControl --disable-sandbox
```

Test the actual iPhone model sources without UIKit, a simulator, real Keychain
reads, biometric prompts or network requests:

```sh
python3 Scripts/Kids/test_parents_model.py --scratch-path /private/tmp/kids-parents-model-validation
```

This creates a temporary SwiftPM harness from the checked-in model/vault sources
and `KidsParentsTests/ParentsLifecycleTests.swift`; it does not maintain a second
model implementation. Seven tests pass: late login retirement, ordinary foreground
login, rejected credential persistence, late device-auth rejection, backgrounded service connection, captured
credential persistence and unknown-mutation cancellation. Storage, transport and
device authentication are injected fakes. This is model behavior evidence, not a
physical-device biometric or screen-lock result.

Compile:

```sh
xcodebuild -project KidsJellyFin.xcodeproj -scheme 'KidsJellyFin Parents' \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -disableAutomaticPackageResolution -skipPackageUpdates -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO build
```

Launch with `--parent-preview` for clearly labeled offline sample screens. All
mutating actions and import-manager launch are disabled in this preview.

Runtime acceptance still needs: phone lock/termination during countdown; server
restart; TV restart and WAN/LAN interruption; two-parent conflicts; cancellation
delivery; disabled show across all discovery/playback routes; bird EOF/error loop;
and a reviewed YouTube import visible in Kid TV. Keep these results separate from
unit-test and compile results. Never run them against family playback implicitly.

### Recorded local checks — 2026-10-16

- Parent iPhone simulator build succeeded with signing disabled (arm64 and x86_64).
- `KidsParentControl`: 15 Swift Testing tests passed, including parameterized URL
  rejection and RFC 3339 fractional timestamp cases.
- Parent package and application import-boundary check passed; plist syntax and
  whitespace checks passed.
- Full repository boundary audit reports five pre-existing undeclared imports in
  KidsDiagnostics (`CoreFoundation`, `Darwin`, `Glibc`, `CryptoKit` across its two
  evidence files). Those files and that existing policy entry were not changed here.
- Installed and rendered the offline preview on the existing iPhone 17 Pro simulator
  running iOS 26.4. Fixed a truncated header found in the screenshot inspection.
- Native Jellyfin endpoint availability was checked without credentials: server is
  12.1.0 and the three protected read routes returned 401 as expected.
- No authenticated live import, parent-control write, video playback, RAID mutation,
  physical-device install, or end-to-end enforcement test was performed.

### Expanded feature checks — 2026-10-17

- Parent app simulator build passed with the ten additional feature screens and
  typed service methods; no compiler warnings from parent app sources.
- 29 Swift Testing tests passed. Added coverage exercises all seven mutation shapes
  used by the ten features, capability gates for all ten, exact captured revisions,
  time-zone/routine/budget/shuffle limits, cross-profile and cross-show rejection,
  cursor escaping, unknown/invalid health counts and reservation-aware budget math.
- New source remains inside the parent protocol library's Foundation-only boundary;
  project/plist syntax and whitespace checks pass.
- Rendered offline Family Rules on the iPhone 17 Pro simulator. Additional offline
  screen launch support: `--parent-preview --parent-preview-screen family|history|health|review|shuffle|routines`.
- The full backend spec was sent and acknowledged. Both parties accepted explicit
  policy-control command IDs and reservation/unconfirmed/remaining budget fields.
  The backend remains in isolated development, with its existing repair gates intact.
- No live parent write, download, TV playback, provisioning or RAID modification was
  performed as part of these checks. TV receiver/enforcement remains a distinct
  integration dependency before the corresponding capabilities can be advertised.

### Onboarding and fractional accounting checks — 2026-10-17

- Remaining allowance now requires the authoritative server value; integer display
  fields cannot reconstruct fractional accounting. The 1.23-second fixture's
  2,714-byte source SHA matches the server's reported hash, and native progress/settings
  decoding passes. Its historical history-item projection omits `id` and is intentionally
  rejected as a full DTO. The independently hash-verified 2,912-byte full-page successor
  now passes through the scoped history API with its server-issued stable ID intact.
- Parent iPhone generic simulator **clean build** passed after the setup-sheet helper
  gained a custom title. The earlier incremental build retained obsolete initializer
  references; no production build configuration workaround was introduced.
- Installed/rendered only `--parent-preview --parent-preview-screen settings` on
  the existing iPhone17Pro simulator. Inspected the setup entry and explanatory text;
  no clipping was visible. No manager page or network action was opened.

### Receiver integration — 2026-10-17

The tvOS target now contains the explicitly paired receiver, pure policy library,
separate Keychain configuration, playback/catalog gates and ambient fallback.
The full package-boundary audit passes after correcting the existing diagnostic
import inventory. Current source checks and backend gaps supersede the earlier
receiver-not-implemented status; see [receiver integration](parents-receiver-integration.md).
