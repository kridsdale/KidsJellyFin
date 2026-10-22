# Independent backend QA rerun test plan

Date:21 October 2026 Pacific /22 October UTC. Canonical audit:jf-server.3.8.

## Scope and evidence rules

The frozen 91 requirement engineering specification remains unchanged. Execute real backend methods in isolated internal scratch and safe authenticated reads against the real installed service. Root/client QA exclusively owns simulator and live-media actions. No production source, service, configuration, policy, account, approval, job, media or history repairs are part of this audit. A fixture may contain synthetic data; it must never be called a production observation.

## Consolidated regression procedure

1. Read canonical ownership, AGENTS, frozen spec and prior evidence. Establish unique QA ownership.
2. Copy installed runtime files verbatim and hash all 77files. Keep existing111test-module oracles and their scripts/deployment/native/docs prerequisites separate and unchanged. Record every loaded kids_cache module origin under the isolated tree.
3. Execute Python3.12 unittest discovery across the entire tests directory, collecting PASS/FAIL/ERROR per case. No test filtering to hide failures.
4. If a QA-only prerequisite is absent, retain the error and execute only never-loaded/never-reached cases after supplying that existing prerequisite. Do not repeat a completed functional assertion.
5. Preserve test-oracle and deployed-source mismatches as findings; do not change expectations or code to get green results.

Actual commands: `python3.12 -B run-current-suite.py` and completion-only `python3.12 -B complete-neverloaded-current-suite.py`. Both use unittest discovery and immutable copied runtime code. `current-completed-suite-coverage-manifest.json` lists every discovered test ID; `current-completed-suite-results.json` lists every actual result.

## Real installed-service cases

| Case | Steps | Expected |
|---|---|---|
| LIVE-01 | Use existing parent credential; GET capabilities, dashboard, health, inbox and selected child settings once each. |200; honest data/empty state, no fabricated metrics or inbox. |
| LIVE-02 | GET protected dashboard anonymously and with invalid credential; request admin-only parent route with parent credential. |401; parent identity does not grant operator powers. |
| LIVE-03 | Use separate temporary Jellyfin admin and restricted sessions with distinct device identities; read catalog and logout each. |200 read;204 logout; no retained test credential. |
| LIVE-04 | Inspect restricted account policy, visible libraries and catalog original-source membership. Read an admin-only scheduled-task route. |Non-admin; two permitted libraries; no forbidden original source; admin route403. |
| LIVE-05 | Read original allowlist and internal staging references; compare exact original catalog source identities without reading video payload. |6747parts/6490sources,227 movies/49 series/5847 episodes; disclose discrepancies and managed additions. |
| LIVE-06 | Query kernel policy for live Jellyfin process against five write classes, protected aliases and internal positive control; no write attempts. |Protected inquiries denied, internal positive allowed. |
| LIVE-07 | Visit manager anonymous protected APIs; ordinary short-lived adult login, read status/collections/jobs/telemetry/audit/purge plans, logout. |Protected anonymous401; adult reads200; logout200; no acquisition or purge. |
| LIVE-08 | Inspect storage/status and native jobs read-only. |Measured values distinguished from unknown; no inferred worker success. |
| LIVE-09 | Export actual telemetry locally; inspect all sample groups and client measurement provenance. |Unknown remains unknown, p95 absent below 20 samples, no external upload. |
| LIVE-10 | Inspect persistent config and exact configured receiver commission read-only. |No inference from old finite trial; report actual expiry/build/child/revocation matches and current enforcement. |

## Requirement-by-requirement acceptance

Each case below retains the frozen expected behavior. Executed related regression tests establish only backend contract evidence. PASS for the whole requirement requires all its observable clauses, including client/operational behavior when stated. Otherwise record FAIL acceptance_not_verified separately from an actual test assertion difference.

### TC-SYS-01: Household operation

Expected: The system must support local household use without exposing administrative or playback services to the public internet. Ordinary local playback must not require a cloud account or an active connection to the acquisition website.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 67. Live evidence: No direct production observation in this backend run.

### TC-SYS-02: Child viewer

Expected: A restricted child viewer may discover and play only the media authorized for that account and allowed by the current parental policy. A child viewer must not acquire administrative powers through a playback password, a device identity, or access to the household network.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 67. Live evidence: No direct production observation in this backend run.

### TC-SYS-03: Parent

Expected: An authenticated, authorized parent may inspect and change the viewing policies for the children and televisions within that parent's scope. Parent authority must be checked when an operation is performed; a saved login must not preserve powers that have been revoked.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 67. Live evidence: No direct production observation in this backend run.

### TC-SYS-04: Adult collection administrator

Expected: An enabled administrator may review sources, approve specific acquisitions, change presentation, and perform explicitly scoped retention and removal operations. A child account and the television Parents PIN must not authorize these operations.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 67. Live evidence: No direct production observation in this backend run.

### TC-SYS-05: Operator

Expected: The household operator may configure services, inspect health and evidence, manage private credentials, and authorize maintenance. Automated agents must stay within the operator's standing permissions. The system must not create accounts or change account privileges merely to recover from an error.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 67. Live evidence: No direct production observation in this backend run.

### TC-LIB-01: Original media immutability

Expected: Original media on `/Volumes/HDD_RAID`, including aliases to that volume, must remain unchanged. No original file or folder may be written, deleted, renamed, moved, have permissions or extended attributes changed, or receive artwork, sidecars, or metadata. The media server's process-level write protection must cover the entire protected volume. A staging reference must never become a route for modifying its source.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 94. Live evidence: raid_process_policy.json, baseline_reconciliation.json

### TC-LIB-02: Exact migration membership

Expected: The original migration must contain exactly the files included in the approved one-time Plex index. Being located beside an approved file, or within its source folder, must never grant import permission. Original media must remain exposed through individual-file staging rather than broad source-folder mappings or directory links.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 94. Live evidence: baseline_reconciliation.json, catalog_admin.json

### TC-LIB-03: Six library boundaries

Expected: The original libraries must remain separate: Kid Movies, Anime Series, Movies, TV Shows, Anime Movies, and Kid TV. Library identity, collection type, and original membership must not be silently exchanged or merged.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 94. Live evidence: catalog_admin.json

### TC-LIB-04: Baseline reconciliation

Expected: The original migration baseline must reconcile 227 movies, 49 series, 5,847 episodes, and 6,747 file-part entries referring to 6,490 unique source files. These are baseline reconciliation quantities, not caps on subsequently approved additions. Missing, unexpected, duplicate, or incorrectly assigned original video entries must be disclosed.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 94. Live evidence: baseline_reconciliation.json, catalog_admin.json

### TC-LIB-05: Child separation

Expected: The restricted household player must be limited to Kid TV and Kid Movies. Other libraries, neighboring files, source-folder names, and their search results or recommendations must not leak through browsing, playback selection, metadata, or parental queues.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 94. Live evidence: catalog_child.json, child-authority-check.json

### TC-LIB-06: Independent curation

Expected: Future additions and changes must be explicitly curated independently of Plex. Plex's index is a migration baseline, not an ongoing authority for new imports. A later broad Plex scan must not expand Jellyfin's permitted media.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 94. Live evidence: No direct production observation in this backend run.

### TC-LIB-07: Coexistence and retirement

Expected: Plex must remain available until the operator explicitly authorizes retirement. Any integration of managed media into either server must preserve exact membership and prevent neighboring imports. Retirement must not be an automatic side effect of a successful test or deployment.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 94. Live evidence: http_summary.json

### TC-VIEW-01: Restricted discovery

Expected: The child app must show permitted movies, shows, seasons, and episodes with useful names, artwork, ordering, and details. Search, when offered, must use the same account and policy restrictions as ordinary browsing.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 82. Live evidence: No direct production observation in this backend run.

### TC-VIEW-02: Policy-aware choices

Expected: Disabled shows and excluded episodes must not become playable through a different screen, a saved item, a queue, Next, or Shuffle. A policy change must affect subsequent selection and must not leave an obsolete permissive choice usable indefinitely.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 82. Live evidence: No direct production observation in this backend run.

### TC-VIEW-03: Stable identity

Expected: Item identity and episode numbering must survive presentation changes, source title changes, ordinary refresh, and normal client relaunch. A title or artwork change must not create duplicate watch history or make a different file inherit progress.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 82. Live evidence: No direct production observation in this backend run.

### TC-VIEW-04: Normal navigation

Expected: Play, Back, explicit close, and the standard television remote menu action must produce predictable navigation. Leaving playback must release that playback session normally and preserve its legitimate progress. A transient background refresh must not cancel a user's navigation or playback choice silently.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 82. Live evidence: No direct production observation in this backend run.

### TC-VIEW-05: Ordered next selection

Expected: Next and ordered episode advancement must select the next eligible episode in the intended series order. They must respect exclusions and show availability, handle the end of the eligible sequence explicitly, and never substitute unrelated media.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 82. Live evidence: No direct production observation in this backend run.

### TC-VIEW-06: Shuffle

Expected: Shuffle must select from the authorized eligible pool and honor the configured preferred shows, unwatched preference, and repeat cooldown where the required viewing data is available. Missing viewing data must be disclosed; it must not be treated as proof that everything is unwatched.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 82. Live evidence: No direct production observation in this backend run.

### TC-PLAY-01: Actual playback

Expected: Selecting an authorized item must render its video and produce its available audio on a supported client. A successful server response, a created session, or a ready player alone is not proof of rendered playback.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 113. Live evidence: No direct production observation in this backend run.

### TC-PLAY-02: Continuous viewing

Expected: Permitted playback must continue across ordinary authorization renewals without stopping at an internal renewal boundary. Renewals must continue to apply current limits and must not turn expired or denied authority into unlimited viewing.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 113. Live evidence: No direct production observation in this backend run.

### TC-PLAY-03: Playback controls

Expected: Pause, resume, seek, normal end of media, and normal stop must preserve the correct item and position. Pause and buffering must not be counted as confirmed watched time. Seeking must not create fictitious watched duration.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 113. Live evidence: No direct production observation in this backend run.

### TC-PLAY-04: Resume

Expected: A subsequent visit must offer the saved progress and resume the same item at the corresponding position, subject to current authorization. Progress must remain meaningful after normal app relaunch and must not be transferred to another item.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 113. Live evidence: No direct production observation in this backend run.

### TC-PLAY-05: Local independence

Expected: Already approved, available local media must remain playable when the external acquisition website or ordinary internet access is unavailable, provided the required local services and current parental authority remain available. Internet unavailability and local server unavailability must be distinguished.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 113. Live evidence: No direct production observation in this backend run.

### TC-PLAY-06: Media compatibility

Expected: The system must support its approved household client and disclose unsupported streams rather than presenting a false playback success. Direct playback or streaming should retain a compatible source; necessary adaptation must preserve the requested content and use audio the approved Apple TV client can stream.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 113. Live evidence: No direct production observation in this backend run.

### TC-PLAY-07: Truthful failure

Expected: Playback denial, unavailable media, an unsupported stream, and a failed start must be visible to the user. The system must not enter an unexplained permanent spinner or silently drop an accepted Play action. Failed or uncertain playback reporting must remain recoverable without deleting the evidence.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 113. Live evidence: No direct production observation in this backend run.

### TC-PARENT-01: Connection and identity

Expected: The Parents app must connect to the intended household server, retain its authorized pairing, and identify the intended child and television. Reconnection must not silently adopt another server or another child's state.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 67. Live evidence: deployed-read-checks.json, current-runtime-eligibility.json

### TC-PARENT-02: Discovery

Expected: Local discovery must identify the correct server and compatible service without broadcasting credentials. A service that has stopped must not continue to appear as a verified live service indefinitely. A saved connection must remain usable independently of discovery when its identity is still valid.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 67. Live evidence: No direct production observation in this backend run.

### TC-PARENT-03: Dashboard

Expected: The parent must be able to inspect child profiles, television status, actual enforcement status, current playback or quiet-time state, current deadlines, allowance, confirmed watched time, and pending actions. Missing or stale observations must be labeled rather than presented as current facts.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 67. Live evidence: deployed-read-checks.json

### TC-PARENT-04: Enable and disable

Expected: The parent must be able to request activation or deactivation of supported viewing controls. The displayed state must come from saved server state rather than an optimistic switch position. A disabled policy and a currently blocked viewing session must not be conflated. Obsolete control authority must not survive a change of enforcement state.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 67. Live evidence: No direct production observation in this backend run.

### TC-PARENT-05: Responsive actions

Expected: Background reads must not silently discard user commands. An operation must indicate whether it is in progress, saved, applied by the television, refused, failed, or of uncertain outcome. A saved command is not an applied command.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 67. Live evidence: No direct production observation in this backend run.

### TC-PARENT-06: Safe retries

Expected: A duplicate submission must not award extra time, advance twice, or perform a second destructive action. Conflicting concurrent changes must be detected. After a timeout or ambiguous response, the app must reconcile the original action before offering or performing another mutation.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 67. Live evidence: No direct production observation in this backend run.

### TC-POLICY-01: Daily allowance

Expected: A parent may enable or disable a daily viewing allowance and set its duration. Usage must be associated with the correct child, day, and configured timezone, and shared correctly across that child's supported devices. Changing the allowance must not erase legitimate existing usage or history.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 122. Live evidence: No direct production observation in this backend run.

### TC-POLICY-02: Honest accounting

Expected: Confirmed watched time, reserved time, and time whose consumption cannot be established must remain distinguishable. Unknown time must not be silently converted to free time or charged as fabricated confirmed viewing. Duplicate, late, paused, or replayed reports must not inflate credit or usage.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 122. Live evidence: No direct production observation in this backend run.

### TC-POLICY-03: Day and timezone behavior

Expected: Daily reset must occur according to the selected local day, including daylight-saving transitions. Clock or timezone changes must not manufacture extra allowance, revive expired authority, or erase the evidence needed to reconcile viewing.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 122. Live evidence: No direct production observation in this backend run.

### TC-POLICY-04: Extra time

Expected: The parent may grant an explicit allowance bonus or extend a supported pending countdown. Each action must apply once, affect the intended child or television, and be visible in the resulting allowance or deadline. An expired or inapplicable target must not receive an undisclosed extension.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 122. Live evidence: No direct production observation in this backend run.

### TC-POLICY-05: Weekly routines

Expected: The parent may create, inspect, edit, and remove enabled weekly viewing windows with days, local start and end times, and a timezone. The app must communicate invalid or unsupported schedules clearly. Overlapping windows must have consistent behavior, and routine editing must not corrupt another rule.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 122. Live evidence: No direct production observation in this backend run.

### TC-POLICY-06: Show and episode controls

Expected: A parent may disable or restore a show and exclude or restore individual episodes within the authorized child libraries. These choices must affect ordinary Play, Next, Shuffle, and remote advancement consistently without authorizing new media.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 122. Live evidence: No direct production observation in this backend run.

### TC-POLICY-07: Offline profile editing

Expected: Supported profile settings, including show availability, allowances, routines, episode exclusions, and shuffle preferences, must remain editable when the television is not actively playing. The app must distinguish profile editing from a live remote action that requires a reachable television.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 122. Live evidence: No direct production observation in this backend run.

### TC-POLICY-08: Remote pause and resume

Expected: The parent may pause or resume the intended active playback session. A stale command must not control a different item, session, child, or television. The result must reflect actual television acknowledgment or explicitly remain pending or unconfirmed.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 122. Live evidence: No direct production observation in this backend run.

### TC-POLICY-09: Remote skip

Expected: A parent may advance an eligible episode to the next authorized episode. No next eligible episode, unsupported content, or a stale session must produce an explicit refusal. A failed request must not be reported as an advance, and one request must not cause multiple advances.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 122. Live evidence: No direct production observation in this backend run.

### TC-POLICY-10: Quiet countdown

Expected: The parent may start a finite silent countdown for the intended television using a selected approved quiet-time item. The deadline must remain effective if the phone closes or disconnects. Pausing, buffering, or reopening an app must not extend the deadline silently.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 122. Live evidence: No direct production observation in this backend run.

### TC-POLICY-11: Finish current episode

Expected: The parent may allow the current episode to finish, subject to an explicit maximum duration. This action must remain bound to that episode and session, prevent ordinary automatic advancement at the boundary, and transition to the approved quiet-time state when the end or maximum duration is reached.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 122. Live evidence: No direct production observation in this backend run.

### TC-POLICY-12: Quiet-time transition and release

Expected: At a binding viewing boundary, ordinary playback must stop and the selected approved birds or other quiet-time media must be shown when available. A quiet-time failure must be visible and must not resume ordinary viewing without authority. Quiet-time state must be reported distinctly from normal viewing. The parent may explicitly cancel or release the applicable control without reviving obsolete commands.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 122. Live evidence: No direct production observation in this backend run.

### TC-ACCESS-01: Primary PIN gate

Expected: The television Parents PIN remains the primary route to the protected Parents interface. Correct and incorrect entry, closing the interface, and returning from background must have explicit behavior. A stored PIN must not be silently discarded during an ordinary reconnect.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 0. Live evidence: No direct production observation in this backend run.

### TC-ACCESS-02: Automatic phone request

Expected: Displaying the television PIN interface must automatically create one finite background request for optional phone approval. The user must not have to choose a separate Ask parent action. The PIN remains usable while this request is pending.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 0. Live evidence: No direct production observation in this backend run.

### TC-ACCESS-03: Parent decision

Expected: A signed-in, authorized Parents phone on the same LAN may discover the request, authenticate its identity, show the requesting television, and offer Yes or No. Discovery information must not itself grant approval or contain the PIN, an administrator credential, or a reusable authorization secret. Foreground phone behavior must not be represented as guaranteed delivery to a locked or background phone.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 0. Live evidence: No direct production observation in this backend run.

### TC-ACCESS-04: Scope and expiry

Expected: A phone request must be bound to the specific server, child, television, and unlock purpose, be usable at most once, and expire within 60 seconds. The first valid terminal decision must win. Approval for another device, child, server, expired request, or previously cancelled request must not unlock the interface.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 0. Live evidence: No direct production observation in this backend run.

### TC-ACCESS-05: Cancellation and effect

Expected: Correct PIN entry, closing or backgrounding the PIN interface, and changing the relevant account must cancel its pending phone request. Phone approval may unlock only the intended Parents interface. It must not grant playback, alter allowance or deadlines, issue credentials, change accounts, or expand library access. Failure of phone approval must leave the PIN route available.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 0. Live evidence: No direct production observation in this backend run.

### TC-CURATE-01: Adult interface

Expected: Routine media administration must be available through an authenticated adult interface, including collection review, approvals, activity, settings, retention actions, and health. Routine adding and removing managed media must not require the household user to operate a command line.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 95. Live evidence: No direct production observation in this backend run.

### TC-CURATE-02: Finite source review

Expected: The administrator may submit a supported finite public playlist and inspect its complete inventory before acquisition. Source identity, channel, order, duration and language when known, duplicates, and unavailable entries must be disclosed. An incomplete inventory must not be presented as an approvable complete review.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 95. Live evidence: No direct production observation in this backend run.

### TC-CURATE-03: Exact approval

Expected: Approval must bind the exact reviewed video identities, selected language, order, presentation choices, administrator, and review revision. A stale review or changed identity must not be silently approved. Membership in a playlist, a child-suitability label, or a thumbnail must not substitute for explicit household approval and acquisition permission.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 95. Live evidence: No direct production observation in this backend run.

### TC-CURATE-04: Source changes

Expected: Checking for source changes must produce another review. New members must remain unapproved; reordered or renamed source entries must not change existing local identities automatically. A removed or private upstream video must not automatically delete a retained local copy or authorize a substitute.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 95. Live evidence: No direct production observation in this backend run.

### TC-CURATE-05: Parent presentation

Expected: Parents may provide display names, language preferences, and artwork choices while retaining source attribution and stable local identities. Collection and episode metadata must be usable by the household clients and media-server tagging. Presentation changes must not silently reacquire or replace approved audio or video.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 95. Live evidence: No direct production observation in this backend run.

### TC-CURATE-06: Artwork

Expected: Artwork may be derived from the acquired approved video, explicitly approved source artwork, or explicitly approved generated placeholders. Derived artwork must come from that acquired material. A failed artwork operation must not silently switch to a different artwork source or permission mode.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 95. Live evidence: No direct production observation in this backend run.

### TC-ACQUIRE-01: Signed-out acquisition

Expected: Downloads must use logged-out access, without a signed-in browser, cookies, Google login, Gmail connection, or a bypass of private, unavailable, or age-restricted access. An unavailable selected entry must be reported and must not be replaced by a neighbor or another rendition with a different identity.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 158. Live evidence: No direct production observation in this backend run.

### TC-ACQUIRE-02: Conservative acquisition

Expected: Acquisition must limit its resource consumption, pace bulk requests, and handle source-side throttling and extraction changes explicitly. Retrying must remain bounded and preserve exact approval. Tool maintenance must not silently broaden permitted sources or activate unreviewed service changes.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 158. Live evidence: No direct production observation in this backend run.

### TC-ACQUIRE-03: Source preservation

Expected: Reuse a retained, validated compatible source rather than downloading or encoding it again unnecessarily. A changed source under the same upstream identity must not overwrite retained approved bytes automatically.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 158. Live evidence: No direct production observation in this backend run.

### TC-ACQUIRE-04: Video quality

Expected: New YouTube acquisitions must target retained AV1 or HEVC video, preserve source HDR and frame rate, and retain source resolution up to 4K. The system must avoid unnecessary video re-encoding when the acquired source is already suitable. A required compatibility transformation must disclose its effect; an inferior obsolete rendition must not silently replace a better approved source.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 158. Live evidence: No direct production observation in this backend run.

### TC-ACQUIRE-05: Audio and language

Expected: Audio must be compatible with the approved Apple TV client and retain the explicitly selected available language. Unknown language must remain unknown. A missing or changed selected track must stop for review rather than silently choosing another dub.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 158. Live evidence: No direct production observation in this backend run.

### TC-ACQUIRE-06: Readiness

Expected: Downloaded, validated, published, indexed, and playable are distinct states. Ready must require the applicable media validation, correct indexing, and restricted-account access checks. Client playback claims must refer to actual client evidence rather than mere file existence or server-side decoding.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 158. Live evidence: No direct production observation in this backend run.

### TC-PUBLISH-01: Narrow publication

Expected: Only exact approved managed files may become child-visible. Publication must not make staging debris, unreviewed playlist additions, failed outputs, arbitrary adjacent files, or quiet-time-only assets available as ordinary child selections.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 193. Live evidence: No direct production observation in this backend run.

### TC-PUBLISH-02: Correct metadata

Expected: Managed episodes must retain stable show and episode identity, correct numbering, matching names and artwork, and consistent client metadata after indexing. Ordinary metadata updates must preserve existing playback position and viewing identity.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 193. Live evidence: No direct production observation in this backend run.

### TC-PUBLISH-03: Accurate activity

Expected: The adult interface must distinguish queued work, downloading, media preparation, validation, publication, indexing, ready, paused, cancelled, and failed states. Progress must reflect acknowledged work; an interrupted or uncertain operation must not be shown as complete.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 193. Live evidence: No direct production observation in this backend run.

### TC-PUBLISH-04: Pause cancel and retry

Expected: Pausing must stop new work without revoking approval. Cancellation must stop the intended owned work and prevent further publication from it. Retry must continue the same approved identity or exact unresolved operation, without adopting new assets or automatically repeating an uncertain external mutation.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 193. Live evidence: No direct production observation in this backend run.

### TC-RETAIN-01: Distinct lifetimes

Expected: Temporary acquisition/cache material and permanent archival media must occupy distinct identifiable folders and have distinct visible states. An acquired video that is known to play correctly with metadata may graduate to long-lived archival storage through an explicit, traceable promotion. Download completion alone is not graduation.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 147. Live evidence: No direct production observation in this backend run.

### TC-RETAIN-02: Long-lived media

Expected: Promoted archival media must not expire or be evicted as disposable cache. A source's disappearance from YouTube must not automatically remove the local archive. Growing managed storage must not require making a redundant bulk backup of reacquirable download bytes merely as part of resizing.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 147. Live evidence: No direct production observation in this backend run.

### TC-RETAIN-03: Unpublish and restore

Expected: The administrator may remove one managed collection membership or explicitly remove it everywhere, with those scopes distinguished. Unpublication must remove the intended managed visibility and prevent new restricted playback while retaining recoverable owned bytes. Restoring must be a fresh authorized action and must re-establish applicable indexing and access checks.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 147. Live evidence: No direct production observation in this backend run.

### TC-RETAIN-04: Active playback during removal

Expected: The system must attempt the defined handling of active managed playback during removal, and distinguish confirmed stop from an unconfirmed or failed stop. It must not promise immediate removal merely because a server request was accepted.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 147. Live evidence: No direct production observation in this backend run.

### TC-RETAIN-05: Permanent purge

Expected: Purge must require a separate preview of exact owned assets, affected references and bytes, plus explicit destructive confirmation. Shared approved assets, unknown files, currently required metadata, and original RAID media must be retained. A changed preview must invalidate the old deletion authorization.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 147. Live evidence: No direct production observation in this backend run.

### TC-RETAIN-06: Interrupted cleanup

Expected: An interrupted purge must remain tied to its original exact plan, disclose partial completion, and not adopt additional files on retry. Failed temporary outputs may be cleaned only when their ownership and stopped producer are established. There must be no automatic eviction of approved content or deletion of unknown data.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 147. Live evidence: No direct production observation in this backend run.

### TC-STORE-01: Dedicated managed storage

Expected: Managed cache storage must support growth and retain a verifiable identity. Missing, substituted, full, or unsuitable storage must suspend the affected work safely. The system must not create a substitute directory and pretend that missing storage is available.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 186. Live evidence: No direct production observation in this backend run.

### TC-STORE-02: Protected data boundary

Expected: Managed storage permissions must not grant access to original protected RAID content. All configuration, catalogs, credentials, logs, test evidence, and backups must stay on the internal disk. A separately authorized managed-cache location is not general permission to modify original RAID media.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 186. Live evidence: No direct production observation in this backend run.

### TC-STORE-03: Capacity

Expected: The adult interface must distinguish measured use, configured admission limits, available capacity, and any actual enforced quota. Missing measurements must not appear as zero. Low space must prevent unsafe admission without silently deleting approved content.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 186. Live evidence: No direct production observation in this backend run.

### TC-STORE-04: Recovery without duplication

Expected: Interrupted acquisition, processing, publication, or indexing must reconcile acknowledged state and continue safely. It must not duplicate media, overwrite unknown files, silently repeat an ambiguous external action, or mark incomplete work ready. Preserved source data and valid completed work must be reusable.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 186. Live evidence: No direct production observation in this backend run.

### TC-OPS-01: Service startup

Expected: After the operating system makes the required account context and storage available, required household services must start without manually launching each application. Dependency failures must be reported honestly. Startup must not be achieved by disabling FileVault, enabling automatic login, changing public exposure, or silently weakening media protection.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 82. Live evidence: No direct production observation in this backend run.

### TC-OPS-02: Honest service health

Expected: Health must distinguish a running process from authenticated, usable media service, usable managed storage, working restricted-account access, and actual protected-volume policy. Missing observations must remain unknown or unverified. A scan completion must not stand in for playback evidence.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 82. Live evidence: No direct production observation in this backend run.

### TC-OPS-03: Bounded automatic recovery

Expected: Authorized automation may detect and repair reversible service and monitor faults on the internal disk, with bounded attempts and retained diagnostic evidence. It must not reboot, change accounts or security settings, disable Plex, modify protected media, or perform destructive recovery without the relevant operator authorization.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 82. Live evidence: No direct production observation in this backend run.

### TC-OPS-04: Independent fallback assessment

Expected: Maintenance must support API-based fallback assessment independent of a monthly interactive-agent quota. The operator may configure Gemini as the preferred provider and GPT as an alternative. Fallback assessment must support the requested 12-hour cadence and disclose unavailable credentials or providers. Requested model selection is the provider's current high-capability Pro class at high reasoning effort; unsupported mappings must not be represented as honored.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 0. Live evidence: No direct production observation in this backend run.

### TC-OPS-05: No delegated authority expansion

Expected: A fallback provider or another agent must not acquire permissions merely by sending a message. Failure to reach an agent or a coordination transport must be distinguished from failure of the media service. Monitoring must not turn quiet, unchanged operation into repeated unnecessary model activity or alerts.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 82. Live evidence: No direct production observation in this backend run.

### TC-ALERT-01: Household notification

Expected: Low-urgency outage and recovery notices must be deliverable to the single configured household-owner email recipient. Delivery must not require connecting Gmail to ChatGPT. No additional human recipient, SMS, phone paging, or push alert may be introduced without authorization.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 0. Live evidence: No direct production observation in this backend run.

### TC-ALERT-02: Signal quality

Expected: A missing success signal and a demonstrated media-service outage must be distinguished. Alerts must identify the affected function and whether recovery is verified. Duplicate alerts should be suppressed during an unchanged incident, while material changes or unresolved actionable blockers remain reportable.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 56. Live evidence: No direct production observation in this backend run.

### TC-ALERT-03: Redaction

Expected: Notifications and shared summaries must not contain credentials, authorization secrets, private media titles, source paths, or private monitoring URLs. Authenticated adult interfaces may show the information necessary to administer their own media, but public or child-facing errors must not disclose protected information.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 56. Live evidence: No direct production observation in this backend run.

### TC-RECOVER-01: Internal control backups

Expected: Recoverable control data must include the information needed to preserve household configuration, library approvals, permissions, policy, usage, history, and revocations. Backups and their evidence must remain on the internal disk and be protected from unauthorized access.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 82. Live evidence: No direct production observation in this backend run.

### TC-RECOVER-02: Restoration semantics

Expected: Restoration must preserve valid identity and history, reconcile retained managed media, and honor revocations newer than the backup. Restoring must not silently republish revoked content, revive expired playback rights, create replacement accounts, or authorize new acquisition.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 82. Live evidence: No direct production observation in this backend run.

### TC-RECOVER-03: Honest recovery evidence

Expected: Readable backup files, consistent data, a complete application restore, release rollback, reboot recovery, and outage recovery are distinct capabilities. The operator must be able to determine which was actually exercised. A partial check must not be presented as proof of all recovery functions.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 82. Live evidence: No direct production observation in this backend run.

### TC-STATS-01: Installation-specific reporting

Expected: The system must provide an adult-only report of observed acquisition, processing, storage, playback and stream behavior for this installation. Available observations should include input/output video and audio characteristics, resolution, frame rate, HDR, direct playback/streaming versus transcoding, and measured throughput or timings where recorded.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 35. Live evidence: manager_telemetry.json

### TC-STATS-02: Evidence quality

Expected: Reports must distinguish server activity, client-rendered video, client audio output, and hardware-decoder evidence. Server CPU usage must not be labeled client decoder utilization. Absent samples must be unknown, not zero. Percentiles and comparisons must disclose sample size and comparable conditions; p95 must not be reported from fewer than 20 measured samples.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 21. Live evidence: statistics-summary.json

### TC-STATS-03: Local export and decisions

Expected: The administrator must be able to export a private, useful statistics report for later tactical decisions. Export must not require an external upload. A shareable summary must omit credentials and private source/media identifiers while retaining honest quantities, units, conditions and missing-data limits.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 17. Live evidence: manager_telemetry.json, statistics-summary.json

### TC-UX-01: Clear administration

Expected: Adult interfaces must expose the relevant collection, policy, storage, work and service state with usable labels, consistent navigation, and explicit confirmation for destructive actions. A disconnected demonstration must be distinguishable from the live installation.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 53. Live evidence: No direct production observation in this backend run.

### TC-UX-02: Errors without lost intent

Expected: User actions must not disappear silently. Errors must distinguish refusal, unavailable dependencies, conflicting state, failed operations, and uncertain outcomes. Recovery must preserve the original operation's evidence rather than clearing journals or pretending acknowledgment.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 53. Live evidence: No direct production observation in this backend run.

### TC-UX-03: Account and application continuity

Expected: Ordinary reconnect, app restart and supported updates must preserve the relevant saved server identity, pairing, parental access state, policy, progress, and viewing history. Unsupported combinations must be disclosed rather than silently reset to a less restrictive state.

Execute the listed related test IDs in Test-Results.json as part of consolidated discovery; inspect named live evidence where available. Compare every expected clause and record unresolved client/production prerequisites explicitly.

Existing related backend cases: 53. Live evidence: No direct production observation in this backend run.
