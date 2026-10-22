# SwiftfinPlaybackProfiles

Owns immutable codec/container/subtitle/player/resolution values, typed Jellyfin profile constructors and native/VLC compatibility profile assembly. SDK pin: Jellyfin 3.2.0. Direct local dependency: SwiftfinCollections.

PlaybackOptions owns the immutable requested source/audio/subtitle/bitrate selection transition. Selecting a source resets its track choices; other selections preserve unrelated fields and complete source payloads. Its three scenario tests cover multi-step/default/disabled/reselection behavior and checked Sendable executor transfer. The original application switch is byte-equivalent after extraction.

Assembly consumes immutable PlaybackCapabilitySnapshot and PlaybackProfileSettings values. No hardware APIs, defaults, account/session globals, network requests or player objects enter this module. App composition captures live hardware and user settings; SwiftfinStoredValues owns installed defaults serialization, and presentation adapters own localized labels and UTType conversion. DTOs are an explicit SDK interoperability API.

The test fixture was captured from 26 original production files at commit 05bb0d31 before extraction. Only hardware/settings reads were replaced with deterministic inputs. It freezes 97 complete profiles covering player, compatibility, HDR, custom add/replace and transcode policies, resolution, bitrate and subtitle burn-in. Native Defaults representations were captured in an isolated random suite. Fixture generation never reads media or installed user preferences.

Run `swift test --package-path Packages/SwiftfinPlaybackProfiles`.

## AV1 and HEVC negotiation

`PlaybackCapabilitySnapshot.supportsAV1` currently means the app's VideoToolbox
hardware-decode probe returned true. It is not a general test of software codec
availability. Both native and VLC automatic profiles use that flag to admit AV1
for direct playback and HLS output. VLC deliberately leaves software AV1 out of
its automatic profile; its source comments describe the performance reason and
point to custom profiles as the explicit override. Native HEVC is hardware gated;
VLC HEVC is advertised independently because it has a separate decoding stack.

The Kids adapter selects VLC. Its format-specific compatibility override applies
only to MPEG4 in AVI, so it does not itself force AV1 into H264. A user-selected
`mostCompatible` profile still deliberately advertises only H264/AAC/MP4.
`custom` can add or replace selected codecs, and `directPlay` is an unrestricted
profile; neither is a measurement of decoder performance.

The reported AV1-to-H264 `VideoCodecNotSupported` decision is consistent with an
automatic profile captured when the AV1 hardware flag is false. This is a source
explanation, not confirmation of the exact profile sent by the installed app.
No default capability has been broadened on the strength of that observation.
The pinned SwiftVLC source describes its dav1d decoder, but including a decoder
does not establish adequate throughput or hardware acceleration on a device.

For the next codec runtime check, capture the actual selected player,
compatibility mode, AV1/HEVC probe values and outgoing codec lists once, alongside
the same PlaybackInfo response's direct-play/direct-stream support and transcoding
reasons. Compare them with the actual media codec/container/range/bitrate. If an
explicit software-AV1 trial is useful, use a scoped custom profile after the
accounting trial, retain the ordinary fallback, and observe startup, sustained
playback, lost/corrupted pictures and server transcode state. Keep that one trial
separate from the current frozen receiver. Simulator success proves that
simulator's path; it does not prove a future Apple TV's hardware decoding.
