# Parents integration commissioning

This is the execution and acceptance plan for the iPhone Parents app, the tvOS
receiver and the new server control API. It is not a record of completed runtime
trials. The source specification remains [parents-backend-handoff.md](parents-backend-handoff.md);
the requirements and source evidence are in [parents-app.md](parents-app.md) and
[parents-receiver-integration.md](parents-receiver-integration.md).

## Current checkpoint

- Admission base commit: `0524f3ba`; client recovery checkpoint `86c3d963` is
  published on `kridsdale/KidsJellyFin`, branch `feature/kids-release-candidate`.
  Source publication does not deploy or commission the parent service.
- Built/source implementation digest:
  `1c06b1a4508e1a56df2063d775c7475a27a5d14a2bc57f34bb04541b2f1f7233`.
- Synthetic checks: application56, protocol64, policy22, playback-session21 and
  VLC ownership21 tests passed. The55-library dependency audit passed.
- Current Debug and optimized Release tvOS simulator builds both passed and
  independently match the source digest. No signed-device install or live trial
  is implied by those build results.
- Backend runtime source is frozen at `c799d2d62d408d01be5cdd745fa2ec4b5b673213`,
  package SHA-256 `e6f44633ee7035e19c02cefee8b86e66abf6653a5937f8f6259278c88d0df17f`.
  The server reports492 distinct joined tests with no failures/errors/skips and one
  separately enforced native-policy startup/drain test. The600,000-row storage
  fixture passes. This is uninstalled source, not receiver runtime acceptance.
- The4,580-byte build transaction is frozen unchanged and passes native replay.
  Backend packaging commit `91c80e66` supplies a concrete code/private-config
  staging packet, with18 targeted packaging tests passing. Its payload manifest is
  `6c1d77e9ff58a4f91e5653aaa9ca79d8a7fae17044eb1a66dbfadda9779a6080`;
  its sanitized review hashes to
  `528ff5f70ed3dde2a4df723d375359dac052e7f8ec820c96b9be33bb8e08dc8c`.
  The candidate expires2026-10-17 at22:12:45 Pacific; changed/expired inputs refuse,
  with no silent extension. No root source copy or private config staging has run.
  The exact proposed profile compiles and denies RAID reads/writes and family-root
  writes. Positive write permission for the real trial directory is unverified
  because it does not exist; recheck after separately approved config staging.
  Production monitor/SRE orchestration remains engineering work, beyond the tested
  paired-file transaction component. The current packet has no production command.
- One offline preview UI check on a fresh TV simulator observed its real vendor
  installation ID and this build. Installed bundle identity/build and cloud sync
  `NO` were cross-checked separately; the simulator is shut down. The private
  identity receipt is for staging only, never receiver-runtime acceptance.
- Deployment, scoped credentials, receiver activation and household playback:
  not performed by this work. Physical-device/iCloud trials remain deferred.

## Scope to approve before execution

The first runtime stage uses one explicitly selected simulator installation and the
existing, explicitly configured Jellyfin child identity, with isolated trial control
state and dedicated receiver/parent control credentials. It does not create a new
Jellyfin account or alter the existing child's permissions. Record the
exact Jellyfin server ID, approved Kid TV/Kid Movies library IDs, selected safe
episode/movie/bird IDs, receiver vendor UUID, child ID, client build and backend
commit before provisioning. Do not substitute a Jellyfin transport-prefixed device
ID for the receiver's vendor UUID.

The backend agent must first supply the concrete executable/configuration, state
directory, bind address/port, immutable payload and staging manifest, and stop/rollback
commands. The finite trial uses port18097 and no launchd service; verify the port and
fresh installed-state guards in the prepared packet before approval. A later
production package additionally needs its service definition, migration/backup and
paired monitor/SRE changes. A prepared packet is not permission to execute it.

Approval for this stage must explicitly cover privileged payload staging, starting
the finite trial process, issuing isolated control credentials, activating only the
test receiver, and playing only the selected approved items. The trial configuration
expires within four hours; an expired packet needs fresh guards and configuration.
Per-client faults and restart of the
new optional process are separate from rebooting the host, stopping Jellyfin or
changing household networking. Those broader actions require their own scope.

Existing RAID media, staging links, library roots, child permissions and import
publication state remain untouched. All control state/backups and trial evidence
live off RAID. No library scan or import is needed for the initial control trials.
Isolated control state does not isolate Jellyfin viewing history: playback through
the existing child can change watched/resume state for the selected items. Include
those effects in playback approval. If restoration is approved, capture only those
items first and reject restoration over concurrent family changes; never reset the
whole child's history. Stage-only preparation does not change viewing history.

## Ordered execution

1. **Record and stage.** Capture exact source/build identities and the backend's
   validated inventory snapshot. Confirm the two approved library IDs and selected
   media IDs. Back up only the new control database/configuration as directed by
   the reviewed rollout; no media backup/mutation is part of this operation.
2. **Install without enforcement.** Start the optional backend with readiness and
   enforcement disabled. Check startup/maintenance-lock behavior and health using
   its supported read interface. Existing Jellyfin and import services keep their
   existing behavior. Do not equate a listening port with successful activation.
3. **Connect the adult app.** Use the iPhone simulator GUI to authenticate the adult
   Jellyfin account and connect its separate parent-service credential. Verify the
   server identity and capability list. An absent capability must stay unavailable.
   Capture the phone's state without exposing tokens/passwords.
4. **Pair the isolated TV.** Enter the dedicated receiver token in the TV's existing
   PIN-protected settings. Verify raw installation identity and authenticated idle
   heartbeat. Pairing alone must leave enforcement off and mint no viewing grant.
5. **Commission narrowly.** Use the backend's reviewed readiness gate for this
   exact receiver/build. Activate only the test profile. Reopening the app must
   remain held until a fresh scoped policy arrives. Execute the core grant trials
   below before enabling budget-dependent controls more broadly.
6. **Exercise features.** Run each applicable acceptance row below independently.
   Record server persistence, receiver action and visible playback separately.
   Promote only the capability whose full dependency set has passed.
7. **Close out.** Stop test playback, flush/resolve pending evidence and surrender
   the exact current intent. Disable the test gate, retire test credentials and
   verify the isolated receiver returns to its intended parent-selected state.
   Preserve evidence and accounting; deleting the journal/database is not cleanup.

## Core grant trials

| Trial | Action | Required observation |
| --- | --- | --- |
| Authentication scope | Use only approved test credentials; check missing, retired and wrong-scope credentials through the reviewed trial facility | Rejected requests cannot reveal another child or obtain policy/mutation authority; raw secrets never enter exported evidence |
| Catalog boundary | Compare the exact approved Kid TV/Kid Movies bindings with browse, queue and explicit-item paths | No unapproved library/item becomes accessible; show/episode restrictions apply without changing media or library mappings |
| Policy binding | Exercise exact child/device/controller/item and freshness checks | A policy for another binding, an expired lease or a receipt alone cannot authorize playback |
| Idle and preparation | Leave home open; prepare an item without starting | Idle polls and intent POST alone reserve/debit zero; no invented started event |
| First start | Play the selected item | Intent receipt precedes fresh exact bound policy; actual controller starts only after usable ALLOW |
| Pause and resume | Pause, wait, then resume the same controller | Evidence FIFO precedes exact surrender; local hold overrides cached lease; new intent precedes resume; new started follows actual resumed output |
| Lost receipt | Interrupt only the test request after persistence | Original command/body is retried; no duplicate reservation or automatic playback from receipt |
| Historical evidence drain | Retire a controller while its observed events remain queued, using the reviewed isolated fault facility | Original event identities/provenance drain without authorizing playback, refunding unknown past or applying old events to a replacement controller |
| Background and replacement | Background/stop while a grant is pending | Late reply cannot start/resume an old controller or cross identity; exact orphan is retired |
| Buffer hold | Induce an isolated test-client stall, then restore availability | Pause/surrender occurs; automatic recovery requires new readiness while held on the same controller/item; attempts are bounded |
| Readiness lost again | Lose readiness during the resume grant request | No transport resume and no new-generation usage claim; terminal evidence retains its observed provenance |
| Lease/outage expiry | Block only the test client's control connection | Monotonic expiry holds playback; stale policy/unknown POST is not authority; past uncertainty is retained |
| Client/service restart | Restart only the isolated app/new control process | No autoplay from persisted mutation state; unknown intent resolves/surrenders before allocating GET; activation/accounting survive |
| Reviewed server restore | Use the backend's reviewed isolated recovery, then fresh same-scope credentials | Exact old-epoch proof produces the structured recovery fault; parent PIN is required to archive old pending actions/reports; write failure retains them; fresh runtime has no grant; backend spend/uncertainty and local enforcement markers remain intact |
| Two receivers | After separate approval, use two isolated TV identities for one child | Shared allowance is conserved; own reservation is not double-counted; one surrender cannot revoke/refund the other's intent |
| Civil reset/restore | Use the backend's isolated clock/restore test facility | Reset clamps reservation lifetime; restoring old state does not recreate spendable authority or refund unknown past |

Do not alter the Mac's system clock or the household router to execute these tests.
Where a deterministic clock/transport fault is unavailable in the installed test
environment, retain the synthetic result and mark that runtime trial unobserved.

## Runtime evidence handoff

The frozen backend contract is `c799d2d6`,
`kids_cache/parents/commissioning.py`, `CommissionManager.install`. Its operator
readiness envelope has exactly these top-level keys:

```text
schemaVersion, purpose, id, serverID, childUserID, deviceID,
receiverTokenID, clientBuildSHA256, backendSourceSHA256, contracts,
created, expires, operatorApproved, actualReceiverTrial,
safetyChecks, contractChecks, files
```

For production acceptance, `schemaVersion` is1, `purpose` is
`receiver-runtime-acceptance`, `id` is a canonical UUID, `contracts` is a unique
nonempty selection of the backend's known wire contracts, and the operator must
explicitly approve actual receiver trials. Do not produce an approved envelope
before observing the trials. The envelope binds the actual receiver token ID and
scope, not a raw token or a trial token substituted for a production token.
The backend checks the current credential/scope/epoch when installing. Production
evidence must be created within24 hours; expiry cannot exceed created+180 days or
the actual credential expiry (currently at most30 days).

**Open handoff engineering:** proof from the isolated trial cannot be relabeled
with a different production token ID. The backend is implementing a guarded
same-state/same-token handoff; it is not yet a validated or executed path. That
handoff must prevent a second active trial authority, preserve all safety history
and credential expiry, and leave enforcement off until explicit production
commissioning. Do not substitute a copied database or rewritten receipt scope.

`files` contains1–64 entries, each with exactly `path`, `sha256` and `bytes`.
Each entry names a private internal regular JSON file, at most2MiB, in the same
directory as the envelope; symlink following is forbidden. Each receipt must bind
the same six scope fields: `serverID`, `childUserID`, `deviceID`, `receiverTokenID`,
`clientBuildSHA256` and `backendSourceSHA256`. It must declare
`kind: receiver-runtime-trial` and `synthetic: false` only for a real trial.
Extra receipt fields may record case identifiers, timestamps, actual human/XCTest
observations and captured-artifact hashes. Exclude raw credentials and media paths.

The exact `safetyChecks` keys are listed below. All must be supported by actual
observations before being approved; a source test, preview or copied Boolean
cannot establish the corresponding runtime behavior.

| Safety key | Evidence from the ordered trials |
| --- | --- |
| `auth_scope` | Authentication-scope refusals and unchanged authority |
| `library_boundary` | Exact approved catalog and all playback entry points |
| `policy_binding` | Child/device/controller/item binding and finite freshness |
| `intent_start` | Intent receipt, fresh bound policy and actual start ordering |
| `pause_resume` | Observed pause, surrender and fresh-intent resume |
| `buffer_resume` | Same-controller held recovery with newly observed readiness |
| `stop_cancel_eof` | Actual stop/cancellation/EOF and terminal provenance |
| `historical_drain` | Retired-controller evidence drains without new authority |
| `unknown_post_recovery` | Original unknown request replay and conservative recovery |
| `outage_watchdog` | Isolated outage/expiry causes actual hold |
| `restart_journal` | App/control restart preserves and resolves pending state |
| `race_fencing` | Late callbacks/replacements cannot revive retired authority |
| `control_semantics` | Actual behavior for each selected feature contract |

`contractChecks` has exactly the selected `contracts` as keys. Each value is a
nonempty list of hashes of referenced receipt JSON files. The backend validates
scope and structure; it does not interpret or attest the extra observation fields.
The operator must review the underlying facts and artifacts independently. Keep
unsupported native frame/audio callbacks labeled unsupported; weaker counters,
heartbeats, leases or screenshots alone do not prove audible/visible playback.
The offline412-byte installation-identity receipt and synthetic fixtures cannot
serve as runtime acceptance.

There is currently **no check-only envelope-validation CLI**. In particular,
`run_parent_operator.py commission --install-evidence ... --expect ... --confirm`
installs the registry and must never be used for linting. `--inspect` and
`--reconcile` do not provide check-only envelope validation. Any future nonmutating
preflight helper needs explicit implementation and verification; its absence does
not authorize installation. Registry installation remains a separately approved
action after evidence review.

## Feature acceptance matrix

| Requirement | Runtime evidence needed |
| --- | --- |
| Quiet countdown and birds | No TV countdown overlay; saved versus delivered states distinguishable; deadline stops kid playback; only approved bird plays and loops; bird errors leave a quiet static fallback |
| YouTube playlist selection | Separately authorized phone trial reaches the existing authenticated immutable snapshot review; exact reviewed additions appear in Kid TV; no unreviewed approval or mutation of existing media |
| Show availability | Disabled show disappears from all child browse/queue paths; stale deep links and explicit episode requests fail; current playback follows the specified stop policy; files remain unchanged |
| Finish episode | Exact current controller may finish only until the hard cap; EOF, replacement, release and deadline races do not transfer permission to a new episode |
| Weekly routines | Correct child/timezone; opening/closing boundaries enforce; DST and timezone changes preserve the specified rule; no implicit release of stricter controls |
| Daily allowance | Core grant trials pass; two isolated TVs conserve one allowance; idle/paused/prepared time cannot repeatedly consume reservations; unknown past is not refunded |
| Extra time | Captured revision is enforced; ten minutes reach the selected countdown or child's budget only; stricter routines/explicit holds remain authoritative |
| Pause/resume/skip | Exact session, expiry and durable dedup verified; Resume obtains fresh intent; stale/expired commands fail; skip remains inside approved eligible catalog |
| Episode exclusions | Excluded item cannot enter via explicit selection, ordered advance, shuffle or remote skip; current item obeys the stop rule |
| Review inbox | Scoped, paginated snapshot entries reach exact existing manager review; stale snapshots cannot authorize replacement content |
| Shuffle freshness | Same-child complete history affects preference; incomplete/stale coverage falls back safely; no history enrichment changes quota |
| Viewing history | Exact child, stable IDs and pagination; observed reports versus gaps/unknown intervals labeled honestly; no fabricated completion from a lease |
| Passive health | Installed adapters report fresh observations with timestamps; missing/stale service/storage/worker/TV values stay unknown; viewing does not trigger repair/download work |

The physical iPhone stage additionally verifies signing/install, Face ID/passcode,
background locking and device transitions. Physical Apple TV playback, reboot and
iCloud acceptance remain explicit deferred work, not implied by simulator success.

## Evidence and rollback

For every trial, record its ID, exact client/backend revisions and identities,
preconditions, action, server result, receiver result, visible result and pass/fail/
unobserved disposition. Use opaque media IDs in exported logs; exclude credentials,
media paths and raw private server logs. Do not merge unrelated trial clocks.

Optional evidence capture follows [kids-client-evidence.md](../kids-client-evidence.md).
It requires both `--kids-evidence` and an owner-only plan inside the app container;
loading it does not itself play media. The current SDK cannot provide strict native
renderer/audio/decoder callbacks. Preserve `unsupported_client_callback` failures
and supplementary observations as such. Neither a growing clock/counter nor a
persisted receipt proves visible/audible success or a performance target.

Rollback must hold/stop the isolated receiver first and preserve unresolved reports,
mutations and usage. Use an explicit authenticated release/deactivation and the
backend's reviewed optional-service rollback. Never make a child unrestricted by
deleting a journal, resetting quota, restoring a stale database or silently
downgrading required-grant mode. Before broader commissioning, verify the rollback
on isolated state and record its actual result. A written command is not execution
evidence.
