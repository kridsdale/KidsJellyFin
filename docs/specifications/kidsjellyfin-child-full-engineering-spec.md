# KidsJellyFin child app — full functional engineering specification

Version 1.0 • 21 October 2026

## Purpose and scope

KidsJellyFin is an Apple TV app through which a child who cannot yet read can independently choose and watch approved television episodes and movies. A protected Parents area provides adult actions on the television. The separate Parents iPhone app manages family controls and offers an optional alternative to entering the television's Parents PIN.

This specification defines externally observable product behavior. Every numbered requirement is required unless explicitly marked optional. It defines neither implementation nor delivery status. “Ordered progress” is the child's position through a show's regular episode sequence. “Session cap” is a convenience limit on consecutive episodes; “daily allowance” and “routine” are parental restrictions. These must remain distinct.

## Setup, identity and content boundaries

- **C-001 — Restricted setup.** A parent can connect to a Jellyfin server and authenticate a restricted, non-administrator child account. Setup identifies the server and account before exposing content.
- **C-002 — Exact approved libraries.** Only the approved Kid TV and Kid Movies libraries are available. Similar library names, additional accessible libraries and administrator access do not expand this boundary.
- **C-003 — Safe initial display.** Before account, server and library identity are verified, the app shows a neutral connection or loading view, with no unverified catalog artwork or titles.
- **C-004 — Authentication loss.** Expired, revoked or rejected authentication removes access to the catalog and playback and presents parent recovery. A cached catalog does not become an offline bypass.
- **C-005 — Discovery and manual connection.** Setup supports local server discovery and a manual address. The selected server identity is verified; discovering a different address does not silently move credentials to another server.
- **C-006 — Reconnection.** Parents can recover a changed server address without losing account-scoped progress. Cancelling or failing a connection attempt preserves the existing configuration. Replacing the account or server requires an explicit parent action.
- **C-007 — Identity isolation.** Progress, settings and late connection results from another account, server or library context cannot appear in the active child's context.
- **C-008 — Media preservation.** Browsing, playback, resets and parent actions do not delete, rename, reorganize or modify source media or its metadata. The app does not import raw storage folders or expand library permissions.

## Child navigation and catalog

- **C-009 — Launch destination.** A cold launch opens Shows without starting playback. Movies is an adjacent, clearly distinguished destination.
- **C-010 — Deliberate category selection.** Moving focus over a category does not activate it; selecting it does. Returning from a title restores the category, focused card and scroll position where that content still exists.
- **C-011 — Artwork-led grid.** The catalog uses large, recognizable artwork, normally four cards per row and approximately two visible rows at television scale. It avoids text-dependent child decisions.
- **C-012 — Predictable focus.** Catalog ordering is stable for an unchanged catalog. Focus is clearly visible, respects grid edges without wrapping and moves predictably between categories, cards and actions.
- **C-013 — Missing artwork and empty catalogs.** Missing artwork has a distinct accessible placeholder. Empty or unavailable categories show a calm, truthful state without exposing another library or fabricating choices.
- **C-014 — Show title screen.** A show offers Next and Shuffle as the primary child actions, with initial focus on Next. It does not require a child to navigate season or episode lists.
- **C-015 — Movie title screen.** A movie offers one appropriate primary action: Play, Resume or Play again, and displays existing progress. Starting over is a parent action.
- **C-016 — Child interface boundary.** The child interface omits open-ended search, recommendation feeds, cast browsing, trailers, purchases, downloads, Live TV and server administration. Parents management features do not leak into this interface.

## Ordered episode playback

- **C-017 — Ordered eligibility.** Next follows regular playable episodes ordered by season and episode. Specials, extras and trailers are excluded from that sequence.
- **C-018 — Next and resume.** Next resumes an interrupted ordered episode at its retained position, or starts the next eligible episode when the previous one is completed. A new show begins with its first eligible regular episode.
- **C-019 — Progress advancement.** Natural completion or an explicit parent completion advances ordered progress. Merely opening a title, failing to start, playing once or shuffling does not advance it.
- **C-020 — Ambiguous or removed items.** Missing current media or ambiguous numbering produces a recoverable parent decision rather than silently choosing another episode or discarding the existing cursor.
- **C-021 — Catalog changes.** Added episodes do not regress retained progress. After a show's ordered finale, the child is offered Again rather than an unrelated show or movie.
- **C-022 — Persistent progress.** Pause, seek, leaving playback, backgrounding and relaunch retain the appropriate position and completion state. Unexpected termination loses no more than approximately ten seconds of recent observed progress under normal operation.

## Shuffle

- **C-023 — Scoped random choice.** Shuffle chooses only an eligible episode of the selected show, respecting parental exclusions and availability.
- **C-024 — Cycle behavior.** Eligible episodes do not repeat until the current shuffle cycle is exhausted. Across a cycle refill, an immediate repeat is avoided where more than one eligible item exists. A one-episode show remains playable.
- **C-025 — Independent progress.** Shuffle never changes the ordered cursor. Each deliberate new Shuffle selection starts the newly chosen episode at its beginning.
- **C-026 — Interrupted and failed choices.** Retrying interrupted shuffle playback resumes the same choice and position; a deliberate new Shuffle action makes a new choice. A failed start does not consume a cycle choice.
- **C-027 — Family shuffle rules.** When enabled, prefer-unwatched choices and cooldown rules use available real viewing history. Unknown history is not represented as proof an episode is unwatched. Hard availability restrictions always apply.

## Player and session behavior

- **C-028 — Real playback.** A successful start produces actual video, audible sound where the media has audio, and advancing playback time. A loading indicator, static preview or successful request alone is not playback.
- **C-029 — Remote controls.** Select reveals player controls. Standard Play/Pause changes playback state. Controls hide after inactivity without losing the current playback session.
- **C-030 — Seeking.** The paused timeline displays position and duration. Left and right seek only when the timeline has focus; other focused controls retain their own navigation behavior.
- **C-031 — Back behavior.** Back/Menu first dismisses visible player controls, then returns from playback to the title screen. Returning restores meaningful action focus and retains resume position.
- **C-032 — Duplicate input.** Rapid repeated selection does not create concurrent streams, duplicate session counts or conflicting starts.
- **C-033 — Next episode prompt.** Eligible automatic continuation displays the upcoming episode's picture and a ten-second countdown. Stop is initially focused; Stop or Back cancels continuation immediately.
- **C-034 — Continuation boundaries.** No next-episode countdown starts after a finale, session cap, parental restriction, unresolved media failure or unavailable next item. Movies never automatically start another movie.
- **C-035 — Session preference.** Parents can select one episode, two episodes or continuous playback. The default is two. Each actual episode counts once; failed starts count zero and resuming the same interrupted episode does not count it twice.
- **C-036 — Session persistence.** Interruptions and application termination do not reset a partly used session's count. Reopening the app does not automatically resume or start media.
- **C-037 — Calm session end.** A reached convenience cap ends on a calm screen with one Back to shows action and no autoplay. A child may deliberately begin a new local session later, subject to parental restrictions.
- **C-038 — Error recovery.** Network and decoding failures use a bounded retry period, approximately fifteen seconds, then offer Try again and Back. Retry targets the same item and position; it does not silently skip to another item or advance progress.
- **C-039 — Restrictions at every entry.** Next, Shuffle, Resume, Play again, parent Play once and automatic continuation all respect effective parental availability and time restrictions.

## Parents area and PIN

- **C-040 — Primary parent authentication.** A separate local Parents PIN of four to eight digits is the standard entry path whenever a protected parent action needs authentication. It is distinct from the Jellyfin password and masked during entry.
- **C-041 — PIN security and escape.** Repeated wrong PIN attempts incur a visible, bounded backoff. Back can abandon entry. Leaving the Parents area, backgrounding or parent inactivity relocks access; authentication errors do not trap focus.
- **C-042 — PIN maintenance.** Parents can establish, explicitly change or recover a PIN through the parent setup/recovery flow. Reconnecting an already authenticated account does not require re-entering an existing PIN solely to retain it; first setup and deliberate reset still require choosing a PIN.
- **C-043 — Right sidebar.** Parents content animates into a sidebar occupying the right 25 percent of the screen. The video or underlying content resizes into the remaining 75 percent and returns to full size as the sidebar closes.
- **C-044 — Playback continuity in sidebar.** Opening, navigating or closing Parents mode does not by itself pause, restart, replace or stop the current media. Media identity, position and play/pause state are preserved through the animation.
- **C-045 — Consistent sidebar navigation.** The sidebar operates consistently from browsing, normal playback and ambient playback. Focus stays within it while open. Back/Menu or its close action restores the appropriate underlying focus and relocks protected access.
- **C-046 — Choose episode.** Parents can browse approved shows, seasons and episode thumbnails, returning to the last browsed show where possible. Adult or unapproved libraries remain unavailable even after PIN authentication.
- **C-047 — Explicit progress actions.** Play once plays the chosen episode without moving ordered progress. Set Next here explicitly changes that show's ordered cursor. Parents can start a movie over and explicitly mark completion.
- **C-048 — Reset and sign-out.** Scoped or all-progress reset requires clear confirmation and leaves media untouched. Parent-only sign-out/account replacement removes access to the prior context. PIN changes and reset actions are unavailable to an unauthenticated child.
- **C-049 — Help.** Parents can inspect server identity, restricted-account status, last successful playback and sanitized diagnostics. Child errors and exported diagnostics do not reveal credentials or private access secrets.

## Optional phone route alongside the standard PIN

- **C-050 — Automatic request.** Displaying any existing Parents PIN entry UI automatically requests approval in the background from eligible Parents iPhones on the same LAN. There is no Ask parent iPhone button or additional child choice.
- **C-051 — PIN independence.** PIN entry remains available and primary while waiting. An absent, offline, locked or unreachable phone does not prevent correct PIN authentication or add a phone prerequisite.
- **C-052 — Equivalent narrow approval.** A positive phone decision unlocks only the exact currently displayed parent gate, with the same limited parent access as a correct PIN. It does not create/change a PIN, start media, change settings or expand content permissions.
- **C-053 — Denial and cancellation.** A phone denial never unlocks the gate. Closing the gate, correct PIN entry, TV backgrounding or account/context change cancels outstanding phone requests. PIN remains usable after a denial while the gate remains displayed.
- **C-054 — Expiry and replay.** Each request expires within sixty seconds. Late, duplicate, replayed, wrong-TV, wrong-child or superseded responses cannot unlock anything. The first valid terminal decision settles the request and dismisses other phones' corresponding prompts.
- **C-055 — Locality.** The approval route is limited to verified same-LAN participation. It must not disturb parents outside the building. Optional notification delivery does not weaken this boundary.

## Family control enforcement and ambient playback

- **C-056 — Explicit activation.** Pairing alone does not enable parental controls. The app distinguishes a connection, a requested control change and an acknowledged effective control state.
- **C-057 — Quiet countdown.** An enabled parent countdown allows ordinary viewing until its deadline without an intrusive child countdown overlay. It remains effective when the phone closes or disconnects.
- **C-058 — Deadline transition.** At expiry normal child playback stops and the selected approved cached bird video loops. If unavailable, a calm static fallback appears. Neither outcome powers off the television or controls other apps.
- **C-059 — Finish current.** Finish-current permission applies only to the exact current episode and has a hard stop. A replacement episode, late command or reconnect does not inherit an unrelated permission.
- **C-060 — Release and remote controls.** A cancelled pending countdown does not fire later. Releasing an ended restriction requires an explicit valid parent action. Remote Pause, Resume and Skip act on the identified current session; stale, duplicate or expired commands do not affect a replacement session.
- **C-061 — Routine and allowance.** Enabled viewing routines and household daily allowance constrain playback across participating TVs. A more permissive countdown or bonus cannot override another stricter active restriction.
- **C-062 — Honest time accounting.** Browsing, idle time and paused time do not become watched time. Actual viewing is accounted for once, concurrent viewing is retained, and uncertain contact does not fabricate remaining time or silently refund usage.
- **C-063 — Boundary recovery.** Reconnection, relaunch, midnight and daylight-saving changes preserve effective control intent and use the family's selected timezone. Unavailable authority is shown truthfully and never treated as permission to bypass an active restriction.

## Multi-TV progress, accessibility and quality

- **C-064 — Progress continuity.** TVs sharing the same iCloud account and verified child/server/library context can share ordered episode positions, movie progress/completion, shuffle consumption, interrupted session counts and playback preferences.
- **C-065 — Offline and merge behavior.** Local progress works without internet/iCloud. Independent edits to different shows or movies survive reconciliation; shuffle consumption is combined. Conflicting edits settle deterministically and a reset cannot be undone by older progress. Reconciliation never starts playback.
- **C-066 — Secrets stay local.** Sync does not transfer the PIN, login credentials, catalog permissions or media. Each TV needs explicit setup and local authentication. Cloud status distinguishes local saving from verified delivery.
- **C-067 — Accessibility.** All actions have meaningful accessible names, roles and states, predictable focus order and sufficient contrast. Reduced-motion preference is respected. Optional focus narration waits for settled focus, cancels obsolete speech and does not duplicate VoiceOver.
- **C-068 — Usability and playback target.** After one demonstration a pre-reader should independently choose and start content in at least four of five attempts. On a healthy warm LAN, representative eligible media should start successfully ten times in ten with a median first-picture time no greater than three seconds.
- **C-069 — Privacy.** The app does not send external analytics or expose account secrets, parent credentials or detailed private diagnostics through the child interface. Only deliberate, authorized parent actions change family configuration.

## Explicit boundaries

The child app does not enforce television power, device-wide restrictions or restrictions in other apps. Hardware-specific behavior and cloud behavior remain requirements where applicable, even when an individual evaluation environment cannot exercise them. An optional feature is not a prerequisite for required behavior: focus narration and same-LAN push notifications are optional; PIN entry and the automatic same-LAN foreground phone approval alternative are required behaviors.
