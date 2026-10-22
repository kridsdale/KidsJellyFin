# KidsJellyFin Parents iPhone app — full functional engineering specification

Version 1.0 • 21 October 2026

## Purpose and scope

The Parents iPhone app lets an adult connect to the family Jellyfin service, manage children's approved content and viewing rules, inspect activity and service health, and control a participating KidsJellyFin television. It also provides an optional alternative to entering a PIN on the television. The television's PIN remains the standard parent authentication path.

This specification defines features and observable behavior, without implementation design or delivery status. Numbered requirements are required except an explicitly optional notification enhancement. “Acknowledged” means the target's effective result is known, not merely that a request was sent. Family countdowns, daily time allowance and acquisition/download activity are separate concepts.

## Adult access and connection

- **P-001 — Adult sign-in.** The app connects to a selected Jellyfin server and admits a verified administrator account. A regular or child account is rejected without exposing parent data or controls.
- **P-002 — Server discovery.** Parents can discover local servers and enter a manual address. Results identify the server and avoid duplicate or misleading choices. Discovery alone does not select a server or change saved authentication.
- **P-003 — Changed address.** An adult can recover a changed server address after verifying the same intended server. Cancellation, failure or a mismatched identity preserves the prior connection and does not forward credentials to the new origin.
- **P-004 — Saved access.** A validated adult account can be restored across launches. Sign-in errors are truthful and recoverable; a failed attempt does not become a saved authenticated session.
- **P-005 — App lock.** Backgrounding locks parent access. An eligible adult can unlock using Face ID/device authentication or the saved adult account's Jellyfin sign-in fallback.
- **P-006 — Late results and sign-out.** Responses arriving after backgrounding, sign-out, account replacement or cancellation cannot reopen the app or restore stale authority. Sign-out clears active access to that account's family data and controls.
- **P-007 — Credential separation.** The native adult account, television child account/PIN, parent-control access and embedded management session remain distinct. A login in one context does not silently grant another context's authority.
- **P-008 — Parent-control connection.** An authorized adult can set up and connect the family control service, restore its scoped saved connection after unlocking, and recover rejected or expired access. Unsupported capabilities are unavailable or explicitly read-only.
- **P-009 — Privacy.** Passwords are not retained as reusable plaintext, displayed in diagnostics or passed to unrelated origins. Embedded pages cannot obtain native credentials. Clipboard writes occur only after an explicit copy action.

## Navigation, selection and trustworthy state

- **P-010 — Main destinations.** The app has Tonight, Shows, YouTube and Settings destinations, with clear selected destination and accessible navigation.
- **P-011 — Child and TV identity.** Family actions clearly identify their selected child and, where applicable, television. Changing either selection clears or replaces prior selection-specific data and pending actions.
- **P-012 — Request versus effect.** Saved settings, submitted commands, target acknowledgement and observed effective state are distinguishable. The app does not label an unconfirmed request as a completed action.
- **P-013 — Failure and conflicts.** Network errors, unavailable features and concurrent parent edits produce actionable truthful states. Conflicts require refresh/review; a write whose outcome is unknown is not blindly repeated or claimed successful.
- **P-014 — Revocation.** Losing authentication, pairing or a capability disables the affected controls and clears stale authority. Old responses cannot re-enable them or cross into another child's context.
- **P-015 — Accessibility.** Controls, choices, errors, loading and confirmations have meaningful accessible names, values and focus order. Text remains usable with larger type and adequate contrast; disabled actions communicate why where helpful.

## Tonight and television controls

- **P-016 — TV selection.** Tonight lists participating family televisions and their online/offline or unknown readiness, identifies the selected device and displays relevant current playback and enforcement state when available.
- **P-017 — Explicit enablement.** Parents explicitly enable or disable television parental controls. Pairing does not activate them. The UI reflects target acknowledgement and does not invent readiness from a successful connection alone.
- **P-018 — Ambient selection.** Parents select an approved bird video for the post-countdown experience. Selection is visible and scoped to the intended TV/child; unsupported or unavailable media is explained.
- **P-019 — Quiet countdown choices.** Parents can start a quiet viewing countdown of five, ten, fifteen, twenty, thirty, forty-five or sixty minutes for the selected TV. Selecting a duration alone does not start it.
- **P-020 — Persistent countdown.** Once accepted, a countdown continues if the phone closes, restarts or loses the network. The phone accurately distinguishes a running countdown, elapsed deadline and unknown target state.
- **P-021 — Deadline outcome.** At expiry, ordinary child playback stops and an approved cached bird video loops; a calm static fallback handles unavailable ambient media. The control does not promise to power off the television or restrict other applications.
- **P-022 — Cancellation and release.** A pending countdown can be cancelled. An elapsed restriction requires explicit valid release, and the phone waits for effective acknowledgement before claiming normal viewing is restored.
- **P-023 — Finish current.** Parents can permit the exact current episode to finish before birds, subject to a hard stop. Another episode/session does not inherit this permission. Unsupported or stale current-session state prevents the action.
- **P-024 — Add countdown time.** Add ten minutes extends the appropriate active countdown only when valid. It is distinct from a daily allowance bonus and cannot silently reopen a settled restriction.
- **P-025 — Remote playback.** Pause, Resume and Skip target the selected TV's current session. Skip uses that session's eligible progression mode. Pausing or resuming does not bypass time/content restrictions.
- **P-026 — Safe command validity.** Offline, stale, expired and superseded controls are unavailable or rejected. Duplicate delivery and reconnect do not repeat an action or apply a previous command to a new session.
- **P-027 — Restriction precedence.** A permissive countdown, finish-current action or bonus cannot override stricter effective show availability, routine or allowance rules. Failures explain the restriction rather than falsely claiming success.

## Shows and episode availability

- **P-028 — Approved catalog.** Parents can browse the approved child shows and identify the selected child's catalog. Unsupported write capability leaves a clearly read-only catalog rather than simulated controls.
- **P-029 — Show enablement.** An adult can enable or disable each show for the selected child, inspect the saved effective state and recover a conflict. Changing availability does not delete or modify media.
- **P-030 — Episode rules.** Parents can inspect a show's seasons and episodes with readable identity and artwork where available, and include/exclude individual episodes without changing unrelated items.
- **P-031 — Pagination and selection.** Long catalogs and episode lists support continued loading without missing or duplicate entries. Switching child/show discards obsolete pages and writes; returning preserves meaningful navigation context.
- **P-032 — Effective exclusions.** Disabled shows and excluded episodes are unavailable through Next, Shuffle, Resume, parent Play once and automatic continuation when the restriction applies. Restricting the current item is reflected in effective television enforcement.

## Weekly routines, daily allowance and shuffle preferences

- **P-033 — Weekly routines.** Parents can inspect, add, name, enable/disable, edit and remove up to thirty-two weekly routines for a child, specifying one to seven weekdays, start/end time and timezone.
- **P-034 — Routine validity.** A same-day routine ends after it starts. An overnight allowance uses two explicit windows. Invalid or incomplete inputs produce clear validation before saving; removal is deliberate and confirmed where destructive.
- **P-035 — Routine semantics.** Enabled windows permit their union of scheduled time, subject to other stricter restrictions. Chosen timezone, local-day boundaries and daylight-saving changes determine the schedule consistently across TVs.
- **P-036 — Daily allowance.** An adult can enable/disable a household viewing allowance for a child and set zero through 1,440 minutes, with five-minute selection increments in the phone UI. Zero is a real zero allowance, not an unlimited sentinel.
- **P-037 — Shared accounting.** The allowance applies across participating TVs. Actual viewing counts; browsing, idle and paused time do not. Concurrent actual viewing is accounted for without losing usage or counting one reported interval twice.
- **P-038 — Honest remaining time.** Watched, held or unconfirmed usage is distinguishable where supplied. Missing contact does not invent a refund or certain remaining balance. A refresh reconciles real authoritative usage.
- **P-039 — Daily reset and bonus.** Allowance resets at the child's selected local-day boundary while preserving history. A deliberate ten-minute daily bonus is separate from extending a TV countdown and does not override another restriction.
- **P-040 — Shuffle preferences.** Parents can configure prefer-unwatched selection, a cooldown from zero to thirty days and preferred eligible shows where supported, up to one hundred selections. Unsupported preferences remain unavailable.
- **P-041 — Shuffle truthfulness.** Preferences use real available viewing history, preserve uncertainty and never fabricate unwatched status. They do not override excluded shows/episodes or time limits.
- **P-042 — Save/readback.** Routine, allowance and shuffle changes display acknowledged saved state after readback. Failed or conflicting saves retain a recoverable form without silently overwriting another parent's changes.

## Viewing activity and health

- **P-043 — Viewing history.** Parents can inspect the selected child's last thirty days of viewing, including date, title, television, mode and duration when available. App-observed, Jellyfin-observed and incomplete records are labeled honestly.
- **P-044 — History paging.** Earlier history can be loaded without duplicates or mixing another child's records. Empty history is shown as empty, not replaced by sample events.
- **P-045 — Health fields.** Health presents Jellyfin availability, acquisition worker health, free storage, queued/failed jobs, TV contact and relevant issues when real observations exist.
- **P-046 — Unknown and stale health.** Missing metrics display Unknown, not zero or Healthy. Old observations are marked stale and lose current-state certainty; after approximately sixty seconds without a fresh observation, affected status is visibly stale/unknown.
- **P-047 — Refresh.** Parents can refresh connection/health observations and see when they were last obtained. Success reflects fresh real data; an unsuccessful refresh does not make old observations current.
- **P-048 — Empty versus unavailable.** A genuine zero queue or empty history/inbox is distinct from data not fetched, unsupported capability or failed access. Status panels do not manufacture metrics or operational certainty.

## YouTube intake, management and review

- **P-049 — Playlist intake.** Parents can enter and validate a supported YouTube playlist link and review its normalized destination. Typing or validating a link does not automatically import, approve or download anything.
- **P-050 — Explicit handoff.** Copy link is deliberate and reports the copied destination. Opening management is deliberate, uses the intended management origin and provides a recoverable error if unavailable.
- **P-051 — Separate manager authentication.** The embedded management workflow requires its own appropriate authentication. Closing it returns to the native app without transferring native account credentials or treating page navigation as successful approval.
- **P-052 — Immutable review.** Before approval, the adult sees the exact existing review snapshot, selected video identities/count, channels, effective languages and presentation choices, and the excluded entries. Selection changes remain visible and deliberate.
- **P-053 — Exact selection.** Approval preserves exactly the selection the adult reviewed. Default selection and Select all cannot silently replace a prior explicit selection, include excluded entries or misstate the selection count.
- **P-054 — Explicit approval and results.** Approval/import requires a deliberate adult action on the reviewed snapshot. A legitimate approval records its actual revision/history and resulting work. Queued work is not described as completed acquisition or playable media.
- **P-055 — Stale and duplicate submission.** A stale snapshot is rejected without new work, media mutation or false approval history. Duplicate delivery of one accepted action does not create unintended duplicate jobs. New deliberate approval is distinguished from replaying an old action.
- **P-056 — New-video inbox.** The native inbox displays real pending review entries and available candidate/approval information, with truthful empty/loading/error states and paging for longer lists. It never invents entries to fill the screen.
- **P-057 — Exact inbox handoff.** Opening a pending review carries its exact existing snapshot into management so the adult can review and approve that same set. A disappeared or stale entry requires refresh, not approval of a substitute.
- **P-058 — Acquisition status.** Parents can inspect actual collection/download status and supported pause/resume acquisition actions. Their effect is separate from pausing television playback; failed work and pending work remain distinct from success.
- **P-059 — Ambient intake.** Selecting a standalone ambient video follows the same explicit authorized review route. A standalone video is not presented as a fabricated playlist or automatically approved from a pasted address.
- **P-060 — Content boundaries.** Management never expands the television's approved libraries merely because a parent can access broader content. No action deletes or reorganizes existing RAID media or rewrites its metadata as a side effect of approval.

## Automatic television PIN approval alternative

- **P-061 — Automatic participation.** Whenever a participating TV displays an existing Parents PIN entry UI, eligible same-LAN Parents iPhones receive its approval request automatically. The TV has no Ask iPhone button and correct PIN entry continues independently.
- **P-062 — Foreground takeover.** A signed-in, unlocked, connected Parents app in the foreground displays a full-screen approval view identifying the requesting TV/context and offering clear Yes and No decisions. It replaces the current app interaction until settled or dismissed by cancellation/expiry.
- **P-063 — Deliberate response.** Yes authorizes only that live parent gate; No does not unlock it. Merely receiving, displaying, opening or dismissing a prompt never grants approval. The phone does not promise a decision succeeded before it is accepted.
- **P-064 — Single settlement.** The first valid terminal response settles the request. Other participating phones dismiss the corresponding prompt. Duplicate, stale, wrong-child, wrong-TV or replayed responses cannot unlock another gate.
- **P-065 — Expiry and cancellation.** Requests expire within sixty seconds. TV gate closure, correct PIN entry, TV backgrounding or identity change cancels the matching request and removes its prompt. A disconnected or late phone cannot revive it.
- **P-066 — Narrow authorization.** Approval provides the same short parent access as entering the TV PIN. It does not change/create a PIN, approve content, start playback, modify settings or grant unrelated capabilities.
- **P-067 — Lock and locality.** Locked, signed-out and ineligible phones do not expose a usable approval decision. Participation requires verified same-LAN presence, and parents outside the building are not disturbed by remote requests.
- **P-068 — Optional local notification.** As an optional enhancement, a notification may alert an eligible same-LAN phone when permitted by the operating system and adult. It must not alert an outside-LAN or cellular-only phone. Missing notification permission never blocks PIN entry or foreground approval.
- **P-069 — Return to prior work.** Resolving or cancelling a takeover returns to the prior native destination without submitting unfinished forms, losing unrelated edits or executing a stale control action.

## Settings and preservation

- **P-070 — Settings visibility.** Settings identifies the connected server and adult account, last refresh, connection health, management destination and family-control connection. Refresh, reconnect, setup/connect and sign-out are clearly distinguished actions.
- **P-071 — Account-scoped preservation.** Restart and supported reconnect preserve valid selected family context and saved settings without automatically activating controls, approving intake or replaying prior commands. Switching accounts does not expose the prior account's data.
- **P-072 — Authority boundaries.** The phone cannot silently reset or extend an expired authority window, expand library permissions, replace a TV PIN or assume an unconfirmed control is active. Revocation and expiry are visible, recoverable conditions.
- **P-073 — Data preservation.** Testing, ordinary use and error recovery retain existing history, jobs, approval revisions and media unless an explicit authorized product action requires its narrowly stated change. Progress reset and content approval are not interchangeable.
- **P-074 — Honest scope.** The app communicates that it controls participating KidsJellyFin viewing, not TV power or other applications. Cloud availability, push permission and external management outages are not represented as successful device control.
