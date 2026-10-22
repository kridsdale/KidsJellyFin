# Paired simulator observation

`Scripts/Kids/observe_simulator_pair.py` saves private evidence from the actual
Kids tvOS and Parents iOS simulator apps. It does not launch either app, press a
control, call the backend, start video, or authorize a trial. Run it only during
an already authorized integration trial, after the operator has verified its
current server scope and installed the separate local TV stop guard.

Use a current private guard plan and the exact installed executable hashes:

```sh
python3 Scripts/Kids/observe_simulator_pair.py \
  --tv-guard-plan /private/tmp/CURRENT-GUARD-PLAN.json \
  --tv-executable-sha256 TV_EXECUTABLE_SHA256 \
  --phone-udid PHONE_SIMULATOR_UUID \
  --phone-executable-sha256 PHONE_EXECUTABLE_SHA256 \
  --axe /private/tmp/kids-axe-v1.8.0/axe \
  --output-directory /private/tmp/NEW-UNIQUE-OBSERVATION \
  --phase after-pause \
  --run-approved-observation
```

Replace every uppercase placeholder. The output directory must be new and
directly under `/private/tmp`. Existing evidence is never overwritten. The
helper checks each bundle identity, executable hash and code signature; it
also compares the TV's embedded source revision to the guard plan. Reading a
plan does not establish that its guard process is running: check the actual
stop-guard process and receipt separately before any playback action.

Both apps must be foreground on their respective simulators, without visible
text-entry controls or web views. The helper validates both accessibility trees
before saving either screenshot. It omits accessibility values and refuses
credential-entry screens. The observations and images are instantaneous,
serial captures; UI may change between accessibility inspection and capture.
Use them only after leaving all credential/setup screens. Their timestamps
are not a claim that the two screens were captured simultaneously.

Each new output directory is mode 0700; PNGs and `observation.json` are mode
0600. The manifest records each simulator, build, observation/capture time,
image hash and accessibility labels. Treat these files as private because
screens may include library titles or household information. If capture fails
partway, the partial directory is retained without a success manifest; use a
new directory for a later attempt.

`baseline`, `after-pause`, `after-resume`, `after-skip` and `after-stop` are
operator annotations. They do not establish that a command was sent or applied.
For each control test, separately retain the actual phone action, matched server
acknowledgment/state, visible TV response, elapsed propagation time and a
pass/fail/unobserved assessment. Still images cannot prove continuous rendering
or audio. Unit-test hosts label their output synthetic; they cannot supply
runtime acceptance evidence.

Run the isolated helper checks with:

```sh
python3 -m unittest discover -s Scripts/Kids/tests \
  -p test_observe_simulator_pair.py -v
```

The helper is preparation for Bead `kids-1t9.38`; passing its tests does not
complete paired-device control acceptance.

## Timed core acceptance handoff

Prepare the next core attempt before starting its clock. The Oct 20 idle-only
attempt exhausted the required 150-second reserve during proof handoffs; its
passing idle evidence remains reusable and is not playback acceptance. The
existing guard already supports a 600-second maximum. Use one new guard on the
next eligible Los Angeles calendar day; never extend or retry the spent attempt.

1. **Finish preparation first.** Assign the client operator, server enable/GO
   owner, and cleanup owner. Agree the exact approved scope and separate GO
   action, prepare the capture/proof commands and stop/reconciliation steps, and
   settle all other server gates. Reuse passing build, idle and policy evidence.
   The phone stays untouched. Use proven native HID, `simctl` captures and
   existing local proof commands; the AX/codesign pair helper above is unnecessary
   in this timed core. Do not add LLDB or a host-unlock gate.
2. **Check readiness before consuming the attempt.** Confirm fresh service and
   token headroom covers the planned guard and cleanup. Confirm the installed
   source/executable identity, expected journal scope and pending counts, and
   absence of a player. Atomically claim the unused Pacific-date daily marker for
   this same logical core check across both agents. If it is already consumed,
   keep preparing independent work for the next eligible day.
3. **Launch once, then send one complete initial handoff.** Compute the new plan's
   expiry at the actual launch boundary, with a maximum of 600 seconds and within
   service/token authority. The first message to the server owner includes the
   actual prelaunch check time, source/executable hashes, scope-match booleans and
   pending counts, daily marker date/key, actual client/guard liveness checks,
   guard start/deadline, proof assembly time and seconds remaining. Include the
   local guard receipt hash. A prepared plan alone is not a running guard.
4. **Bundle title proof instead of adding another round trip.** After reaching
   the approved title without starting it, send the real observation time and
   screenshot capture time/hash together with current client/guard liveness,
   deadline/remaining time, installed source/executable hashes, journal-scope
   match/pending counts and no-player/no-Next/phone-untouched booleans. The operator
   must actually inspect the screen and explicitly confirm the approved title;
   screenshot and source hashes cannot establish that semantic claim. Share the
   safe summary only, excluding raw logs/journals, credentials, private UUIDs and
   media paths.
5. **Keep the playback gate explicit.** No Next action until the server owner's
   separate GO and at least 150 seconds of actual guard reserve remain. If either
   condition fails, stop this attempt without playback and retain its evidence;
   do not extend its deadline or immediately mint a replacement. At completion or
   deadline, perform the prepared stop/reconciliation, preserving pending reports
   and recording actual stopped state. Core completion still requires the planned
   real playback and server accounting observations.

The initial handoff uses the existing private proof command and these agreed
fields; collect them once and send them together:

| Group | Fields |
| --- | --- |
| Time and live owner | `checkedUnix`, `uiObservationUnix`, active client and guard PIDs |
| Guard bounds | `guardStartedUnix`, `stopRequestUnix`, `expiresUnix`, `maximumSeconds` |
| Installed identity | `sourceRevision`, `executableSHA256`, `signatureVerified` from the existing prelaunch check |
| Action state | `idle`, `nextActions`, `playbackActions`, `newPlaybackIntents` |
| Durable state | `journalSHA256`, `eventCount`, `intentAbsent`, `surrenderAbsent` |
| Prelaunch baseline | Its `checkedUnix`, prior client/guard PIDs, `processAbsent`, `guardAbsent`, `historicalTerminationAccepted` |
| Proof identity | `receiptSHA`, `screenshotSHA`, `safeObservationSHA` |

Keep full server, child, device, endpoint, core-item and ambient-item identities
local. Send separate existing-root-scope match booleans for those six scopes;
the backend owner already has their values. Do not attach the raw journal.
Record the actual screenshot capture time separately from the operator's visual
review time. `uiObservationUnix` is the real UI observation time, not a copied
receipt timestamp. The operator's approved-title confirmation is an annotation
of that visual review; PID, hash and signature fields are machine observations.
Reuse the single capture and prelaunch signature result instead of repeating them
for successive messages.
