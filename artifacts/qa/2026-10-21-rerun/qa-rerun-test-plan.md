# Independent client QA rerun test plan

Prepared before rerun execution: 2026-10-22T04:06:45.201579+00:00.

## Scope and verdict rules

The original21October version1.0 child and Parents specifications and original QA report remain immutable. This is a fresh independent rerun after root-owned prerequisite changes. QA changes no source, build, deployment, backend service, credentials or authority. Phone-only read operations begin now; TV and paired commands remain exclusively root-owned until explicit GO.

Results are recorded as individual functional assertions within each scenario. Every assertion has PASS or FAIL, expected/actual and current evidence. A passing sub-assertion never becomes a full-requirement PASS when edge clauses remain untested. FAIL distinguishes observed behavior from unable-to-verify. Optional notification absence alone is not a required-feature defect. The final traceability matrix covers all143 original requirement IDs, describing fully or partially established runtime coverage and residual conditions.

Reboot the iOS simulator between automation scenarios, not between individual observations of the same screen. This is one consolidated functional rerun, not repeated reliability attempts. No fabricated inbox entries, metrics, histories or media. A503 causes a timestamp/category handoff, not a repair or blind write retry. No policy/content/control writes before paired GO.

## Scenario plan

| Scenario | Requirement areas | Steps | Expected |
|---|---|---|---|
|PH-01: Saved adult unlock, tabs and Tonight|P-004,P-005,P-010,P-011,P-012,P-016,P-017,P-018,P-019,P-026,P-074|Reboot; verify locked launch; privately unlock saved adult; inspect Tonight selected child/TV, disabled/offline state, approved ambient selector; open duration choices without selecting/start; visit all four tabs.|Saved adult restores; four destinations; exact selected identities and truthful controls; seven duration choices; no activation from selection.|
|PH-02: Shows and episode rules, read only|P-028,P-029,P-030,P-031|Reboot/unlock; Shows; inspect real catalog and current show values; open episode rules and genuine show/season; inspect existing inclusion/exclusion and paging without toggling.|Real approved shows and selected-child scope; readable identity/artwork; current availability, no duplicated or mixed list pages.|
|PH-03: Settings and family rules, read only|P-002,P-008,P-033,P-034,P-036,P-040,P-070,P-071,P-072|Reboot/unlock; read Settings identity/setup/connection; inspect discovered candidate unselected; open Routines/allowance/shuffle, inspect genuine saved rules/bounds, open an unsaved Add form and validation if safe, cancel.|Distinct connections/actions, saved context; truthful capability; valid labels and bounds, no implicit changes from opening/cancelling.|
|PH-04: Viewing history|P-043,P-044,P-048|Reboot/unlock; open Viewing history; capture selected child, real last30days/history source labels; if real earlier pages exist open once and compare unique identity/count.|Genuine dated history or explicit loaded-empty/unavailable state; no fabricated default rows or duplicates.|
|PH-05: Health, refresh and natural stale|P-045,P-046,P-047,P-048|Reboot/unlock; open health; capture actual fields/observation timestamp; explicitly refresh once; observe current actual state and missing fields; wait natural>60sec with no refresh, capture stale change.|Fresh real metric values or Unknown with honest source; genuine zero distinct from failed load; stale banner/uncertainty appears as expected, no refresh from failed request.|
|PH-06: Intake validation and real inbox|P-049,P-050,P-051,P-056,P-057,P-058,P-059|Reboot/unlock; inspect intake; enter clearly invalid non-playlist input and observe validation/no enabled import; clear transient form; open actual review inbox and load once; inspect genuine entry or loaded-empty; open collections/status or manager read-only when available, no sign-in/approval mutations.|No import on typing/copy; accurate validation; canonical loaded data distinguished from unloaded; exact real pending entry if present; status does not claim queued=downloaded.|
|PH-07: Background re-lock|P-005,P-006,P-069|Reboot/unlock; capture unlocked tab; Home then physically reopen installed app; capture lock; existing fallback may unlock once; no sign-out/account replacement.|Background locks; no exposed family controls; saved adult fallback works and no unfinished form auto-submits.|
|TV-PAIRED: Child and paired functional acceptance after root GO|C-001..C-069,P-017..P-027,P-029..P-042,P-061..P-069|Await root exact source/scope/remote helper ownership GO. Then test actual installed child UI, real media/player/progress and paired control cases within authorized finite scope. Read before changing settings and restore exactly; preserve real history.|Observe product behavior directly; no helper XCTest success substituted; no authority reset/extension. Record unexercised edge/hardware/cloud conditions explicitly.|

## Planned assertion granularity

- Adult: locked cold launch; successful saved-adult fallback; saved identity; no503 during restoration; background lock; no auto-submit. Negative nonadmin, stale-response and account-switch cases remain distinct when not safely executable.
- Navigation/Tonight: each destination; actual child identity; actual TV identity; connection versus effective controls; offline safeguards; selected ambient media; all seven duration choices; no start from inspection.
- Catalog: actual approved library; selected child; show availability display; genuine show/season/episode identity; inclusion state; continued pages without duplicates. Writes and cross-entry enforcement require paired authorization.
- Rules: real current routines, allowance, shuffle; field labels, visible input bounds and cancel behavior. Saving, timezone/DST/overlap/max-count/conflicts are distinct assertions, not inferred from form presence.
- History: actual loaded state, date/title/source/time/device fields when present, honest empty and next-page behavior.
- Health: each field separately; real value vs missing Unknown; one explicit refresh; last-observed time; natural stale transition.
- Intake: invalid link behavior, no automatic action, real loaded inbox, exact pending handoff when genuine entry exists, separate manager gate/status. Approval/stale/duplicate effects require real authorized mutation.
- Child/paired afterGO: setup/library scope, grid and focus, title choices, ordered/resume/shuffle, real audio/video/time, HUD/seek/back, progress/session/autoplay, ParentsPIN/sidebar and exact phone flow, controls/countdown/ambient. Each observed feature separated from untested full-cycle/cloud/hardware/usability clauses.

Reference original full per-requirement basis: [original test plan](../2026-10-21/qa-test-plan.md).
