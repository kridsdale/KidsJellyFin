# KidsJellyFin

The enforceable engineering process is defined in [source control](engineering/source-control-policy.md), [QA](engineering/qa-policy.md), and [release and rollback](engineering/release-policy.md). This guide describes product scope and operational use; the policies define release gates and records.

This tvOS fork opens on Shows and exposes only Kid TV and Kid Movies. A title offers Next and Shuffle; a movie offers one Play, Resume, or Play again action. The existing Swiftfin VLC playback foundation remains responsible for formats and streaming.

RC1 is ready for simulator evaluation. See [the evidence record](kids-validation.md) and [requirement coverage](kids-requirements.md) for the passed checks and their limits. The approved [full product brief](kids-product-brief.pdf) defines the scope; the seven-page memo is a review aid.

## Build and test

Use Xcode 27, the `KidsJellyFin tvOS` scheme, and a tvOS simulator. App targets now compile in Swift 6 with explicit main-actor ownership; dependencies retain their declared language modes. Run `sh Scripts/Kids/test_runtime.sh` alongside package tests to exercise the actual settings, timer and bitrate utilities. Debug and Release default to Kevin Ridsdale's paid team (`Z3LBQE3J8T`) with automatic signing; `XcodeConfig/DevelopmentTeam.xcconfig` remains an ignored optional override. The current project deployment target is tvOS 26.1. Choose a device UUID with `xcrun simctl list devices available`.

```sh
swift test --package-path KidsCore
xcodebuild -project KidsJellyFin.xcodeproj -scheme 'KidsJellyFin tvOS' \
  -configuration Debug -destination 'platform=tvOS Simulator,id=DEVICE_UUID' \
  -derivedDataPath build/DerivedData -skipMacroValidation \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
xcodebuild -project KidsJellyFin.xcodeproj -scheme KidsValidation \
  -configuration Debug -destination 'platform=tvOS Simulator,id=DEVICE_UUID' \
  -derivedDataPath build/DerivedData -skipMacroValidation \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -parallel-testing-enabled NO \
  -collect-test-diagnostics never -resultBundlePath build/validation/Kids-Run.xcresult test
```

Use a new result-bundle path for each invocation. Ad-hoc simulator signing is necessary for Keychain persistence. `KidsValidation` drives the actual Apple TV simulator with XCTest remote events; it does not require a visible Simulator window. Its launch environment clears inherited DYLD paths so embedded frameworks load from the app, rather than protected host Documents paths. Verbose automatic sysdiagnose collection is disabled because it can stall after a test failure; assertions, logs, screenshots, and xcresults remain available.

The `KidsCore` package exercises authorization, HTTP pagination and ancestry, ordered progress, shuffle bags, interruption budgets, legacy atomic storage, and native SwiftData migration/merge/recovery. See [iCloud setup and verification](kids-icloud.md) for the active store and signing requirements. SwiftUI Previews and Debug-only `--kids-preview=SCENARIO` launches render the real views with synthetic data and no server access or state writes. Scenarios include shows, movies, empty, again, resume, one-episode, movie-complete, paused, controls, hidden-player, reconnecting, countdown, session-end, denied, offline, loading, and movie-paused. The fixture PIN 4242 is only for the synthetic preview model and never initializes a real account or production PIN. Release builds exclude fixtures.

## Opt-in real playback tests

Live playback methods require explicit opt-in; skipped methods are not evidence of working streams. The exact approved AVI movie check is `testRealApprovedLegacyMoviePlayback`; it uses an existing verified Kid Movies item and exercises actual rendered output, pause/resume and clock progress. After the actual restricted account is configured in the simulator, enable the basic episode/movie/Shuffle checks using Xcode's runner environment prefix:

```sh
TEST_RUNNER_KIDS_RUN_LIVE=1 xcodebuild -project KidsJellyFin.xcodeproj \
  -scheme KidsValidation -configuration Debug \
  -destination 'platform=tvOS Simulator,id=DEVICE_UUID' \
  -derivedDataPath build/DerivedData -skipMacroValidation \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -parallel-testing-enabled NO \
  -collect-test-diagnostics never \
  -only-testing:KidsUITests/KidsLivePlaybackTests/testRealEpisodePauseSeekAndResumeAfterRelaunch \
  -only-testing:KidsUITests/KidsLivePlaybackTests/testRealMoviePauseSeekAndResume \
  -only-testing:KidsUITests/KidsLivePlaybackTests/testRealShufflePlaysEpisode \
  -resultBundlePath build/validation/Kids-Live-Run.xcresult test
```

No password or token goes in this command, test environment, or source. The tests use the already configured Keychain session and fail if the real kids browser cannot load; they never substitute fixtures. They select the first approved show/movie, play, pause, seek forward 15 seconds, observe real time progression, verify ordered resume after relaunch, and exercise Shuffle. Use an unfinished representative title with sufficient duration. Review retained frames and server evidence. `testRealShufflePlaysEpisode` can also run alone with `-configuration Release` to verify the actual candidate.

`testRealRecoveryClearsCatalogAndPreservesSavedAccount` requires Debug. It uses opt-in `--kids-validation=` arguments to exercise genuine invalid-token HTTP denial, expected-binding mismatch and loopback connection refusal without altering the valid saved account or the household server. `testRealStreamFailureRetriesExactItem` additionally needs `TEST_RUNNER_KIDS_RECOVERY_ITEM_ID` set to the current real ordered item and `TEST_RUNNER_KIDS_RECOVERY_MIN_SECONDS` set to its local checkpoint. It replaces one approved item's stream URL with a refused loopback URL once, then verifies deliberate Retry uses the exact real item and saved position. These hooks are excluded from Release.

Natural-end tests require verified regular-episode metadata and a valid near-end checkpoint. Use `Scripts/Kids/simulator_resume.py` only against the simulator. `seed --device DEVICE_UUID --backup build/validation/UNIQUE_BACKUP.json --show-id SHOW_ID --item-id FIRST_ID --season SEASON --episode EPISODE --runtime RUNTIME_SECONDS --completed 0` terminates the app, requires a new internal backup, and sets local resume time 25 seconds before EOF. Run only `testRealNaturalEpisodeTransition` with `TEST_RUNNER_KIDS_RUN_LIVE=1`, `TEST_RUNNER_KIDS_RUN_NATURAL=1`, `TEST_RUNNER_KIDS_NATURAL_FIRST_ID=FIRST_ID` and `TEST_RUNNER_KIDS_NATURAL_NEXT_ID=NEXT_ID`. Seed the next verified item with `--completed 1` using the same backup; the helper refuses unless the genuine first completion budget and exact next item already persisted. Run only `testRealSessionCapAtNaturalEnd`, then always `restore --device DEVICE_UUID --backup build/validation/UNIQUE_BACKUP.json`. These tests observe actual VLC EOF; they never call a synthetic completion function, bypass authorization, or alter media files. Retain the backup. The first show in the test must match the verified show ID. See the evidence record for the completed local run.

A Release compile for physical Apple TV can be checked before device signing:

```sh
xcodebuild -project KidsJellyFin.xcodeproj -scheme 'KidsJellyFin tvOS' \
  -configuration Release -destination 'generic/platform=tvOS' \
  -derivedDataPath build/DeviceDerivedData -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO build
```

An unsigned device compile does not install or validate playback on an Apple TV.

To request a signed hardware build using the account in Xcode > Settings > Accounts:

```sh
xcodebuild -project KidsJellyFin.xcodeproj -scheme 'KidsJellyFin tvOS' \
  -configuration Release -destination 'generic/platform=tvOS' \
  -derivedDataPath build/DeviceDerivedData -skipMacroValidation \
  -allowProvisioningUpdates build
```

Automatic signing may create/download signing assets. The latest attempt selected the correct paid team but failed with `No Accounts`; resolve the Xcode login before treating a hardware build or iCloud provisioning as verified. See [the current iCloud status](kids-icloud.md).

## Initial setup

1. Have the server administrator provision a dedicated non-admin Jellyfin account restricted to the existing, audited Kid TV and Kid Movies library IDs. Disable all-libraries access and content deletion. Do not repurpose an unrestricted development account as a child account.
2. On this LAN, use `http://1531server.local:8096` or `http://192.168.10.100:8096`. Open Parents, enter the restricted account credentials, and choose a separate 4-8 digit parent PIN. Credentials are entered privately and stored through the platform Keychain, never in source control.
3. The app verifies server identity, account policy, both library identities, and each item's ancestry before artwork/browsing. A failed check leaves a neutral parent-required screen. Account setup is the deliberate point at which library names are resolved to immutable IDs.
4. Play one approved episode and movie. Verify frames/time, pause/resume, seeking, relaunch, and a natural episode-to-next transition with server corroboration before approving the candidate.

## Watching and parent controls

Next uses a SwiftData ordered cursor independent of Jellyfin watched flags, synchronized through private CloudKit when the app is properly provisioned. See [the iCloud guide](kids-icloud.md). Shuffle stays within the selected show, excludes specials/extras, and consumes a randomized bag only when playback actually starts. It does not move Next. Leaving ends the session; a crash or temporary interruption retains the current shuffle item and its checkpoint. Natural completion counts toward the parent-selected cap (default two, or one/continuous); failed starts do not.

Select reveals the player HUD, then its central button toggles play/pause. The paused timeline seeks in 15-second steps only while focused. Back first hides ordinary controls, then stops playback and returns to the title. Autoplay shows the next picture and a 10-second countdown with Stop focused. Back cancels it. Ordered mode stops at the finale; movies never start another movie.

Parents requires the separate PIN and relocks on dismissal, backgrounding, or inactivity. It offers a restricted show/season/episode picker, Play once (leaves Next unchanged), Set Next here, confirmed per-show or all-synced-state reset, movie Start over, session count, optional spoken navigation, available audio/caption tracks during playback, and connection diagnostics. Wrong PIN attempts have persisted backoff.

## Recovery

A network or stream failure retains the item and position and offers Try again/Back after a bounded wait. A denied/expired credential hides old content and requires Parents. Sign back into the same verified binding to retain ordered progress, movie positions, shuffle bags, preferences, and session budget in SwiftData. A different binding starts isolated local state.

For damaged local state, unlock Parents and explicitly confirm Reset synced progress and playback settings. The account and both approved IDs must validate again before the reset is written. This reset changes only internal app data.

For a forgotten parent PIN, use Recover parent setup. Authenticate the previously bound restricted Jellyfin account, then choose and confirm a new parent PIN. Recovery validates the same server, user, and two library IDs and resets synced playback setup for the same binding. It cannot authenticate an administrator, broaden library access, or edit media. If that account no longer exists, the server administrator must restore it or a parent can reinstall the app and repeat restricted setup; reinstall can lose unexported local progress; a provisioned installation can restore synchronized progress after the same restricted setup and cloud import.

## Update smoke test and client rollback

Before accepting a client or server update, rerun the core/remote suites and the approved-library playback/recovery checks in the requirement matrix. Preserve the last accepted signed app/archive and its source commit on internal storage. Install a prior client build using the same bundle identifier without uninstalling to preserve compatible local state and Keychain identity. Never copy a broad catalog or modify media as a fallback. If a prior build cannot decode state, require an explicit parent reset; do not silently discard progress.

Physical Apple TV signing, audio/HDR/format coverage, sleep/wake, TestFlight distribution, the child's usability observation, and the household pilot are evaluation activities after the simulator candidate. Server unattended startup and Plex retirement are separate workstreams.

## Storage and privacy boundary

The app uses only the curated Jellyfin API catalog. It never scans or mounts the RAID, creates sidecars, renames/deletes files, changes permissions, or broadens the Plex-indexed media set. Catalog authorization and ephemeral artwork are tied to server/user/library scope. Local state and diagnostics stay in internal app storage; HTTP payload/token logging is disabled for tvOS. No external analytics is added. Playback state can synchronize through the private Apple CloudKit container when provisioned; media, artwork, credentials, and the parent PIN are excluded.
