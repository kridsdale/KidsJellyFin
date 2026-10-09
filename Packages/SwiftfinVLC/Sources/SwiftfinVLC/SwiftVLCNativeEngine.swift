//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import KidsDiagnostics
import SwiftUI
import SwiftVLC

@MainActor
final class SwiftVLCNativeEngine: VLCNativeEngine {
    var requiresSurfaceMount: Bool {
        true
    }

    private let instance = VLCInstance.shared
    private let player: Player

    init() {
        player = Player(instance: instance)
    }

    private var updateTask: Task<Void, Never>?
    private(set) var nativeTimeObservation: VLCNativeTimeObservation?
    private var nativeTimeSequence: UInt64 = 0
    private var passiveObservationsEnabled = false

    func setPassiveObservationsEnabled(_ enabled: Bool) {
        passiveObservationsEnabled = enabled
        nativeTimeObservation = nil
    }

    var passiveStatistics: VLCNativeCounterSnapshot? {
        guard let statistics = player.statistics else { return nil }
        return .init(
            readBytes: statistics.readBytes, decodedVideo: statistics.decodedVideo,
            displayedPictures: statistics.displayedPictures, lostPictures: statistics.lostPictures,
            latePictures: statistics.latePictures, decodedAudio: statistics.decodedAudio,
            playedAudioBuffers: statistics.playedAudioBuffers, lostAudioBuffers: statistics.lostAudioBuffers,
            demuxCorrupted: statistics.demuxCorrupted, demuxDiscontinuity: statistics.demuxDiscontinuity
        )
    }

    var frame: VLCPlaybackFrame {
        var result = VLCPlaybackFrame()
        switch player.state {
        case .idle: result.state = .idle
        case .opening: result.state = .opening
        case .buffering: result.state = .buffering
        case .playing: result.state = .playing
        case .paused: result.state = .paused
        case .stopped: result.state = .stopped
        case .stopping: result.state = .stopping
        case .error: result.state = .error
        }
        result.time = player.currentTime
        result.seekable = player.isSeekable
        result.reachedEnd = player.didReachEnd
        result.bufferFill = player.bufferFill
        result.videoSize = player.videoSize ?? .zero
        if let stats = player.statistics {
            result.readBytes = stats.readBytes
            result.decodedVideo = stats.decodedVideo
            result.displayedPictures = stats.displayedPictures
            result.lostPictures = stats.lostPictures
            result.corruptedPictures = stats.demuxCorrupted
        }
        return result
    }

    var subtitleTracks: [VLCSubtitleTrack] {
        player.subtitleTracks.enumerated().map { .init(index: $0.offset, id: $0.element.id) }
    }

    func startupMeasurements() -> [String: Double] {
        var values = frame.startupMeasurements
        values["active_video_outputs"] = Double(player.activeVideoOutputs)
        if let statistics = player.statistics {
            values["decoded_audio"] = Double(statistics.decodedAudio)
            values["played_audio_buffers"] = Double(statistics.playedAudioBuffers)
            values["lost_audio_buffers"] = Double(statistics.lostAudioBuffers)
        }
        return values
    }

    func surface(controller: VLCPlaybackController, generation: UUID) -> AnyView {
        AnyView(NativeSurface(player: player, controller: controller, generation: generation))
    }

    func observeUpdates(_ update: @escaping @MainActor () -> Void) {
        updateTask?.cancel()
        let events = player.events(policy: .newest(64), filter: { event in
            switch event {
            case .stateChanged, .timeChanged, .voutChanged, .bufferingProgress: true
            default: false
            }
        })
        updateTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                if let self, self.passiveObservationsEnabled, case let .timeChanged(time) = event {
                    self.nativeTimeSequence += 1
                    self.nativeTimeObservation = .init(
                        sequence: self.nativeTimeSequence, monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
                        positionSeconds: time.vlcSeconds
                    )
                }
                update()
            }
        }
    }

    func cancelUpdates() {
        updateTask?.cancel()
        updateTask = nil
    }

    func open(_ request: VLCPlaybackRequest) throws {
        nativeTimeObservation = nil
        let media = try Media(url: request.url)
        for url in request.subtitleURLs {
            try media.addSlave(from: url, type: .subtitle)
        }
        media.addOption(":freetype-font=\(request.subtitleStyle.fontName)")
        if let color = request.subtitleStyle.colorRGB {
            media.addOption(":freetype-color=\(color)")
        }
        try player.play(media)
    }

    func play() throws {
        if player.state == .paused {
            player.resume()
        } else {
            try player.play()
        }
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.stop()
    }

    func seek(_ time: Duration) throws {
        nativeTimeObservation = nil
        try player.seek(to: time)
    }

    func jump(_ offset: Duration) {
        player.jump(by: offset)
    }

    func rate(_ value: Float) throws {
        try player.setPlaybackRate(PlaybackRate(value))
    }

    func audioTrack(_ index: Int?) {
        guard let index, player.audioTracks.indices.contains(index) else { player.selectedAudioTrack = nil
            return
        }
        let track = player.audioTracks[index]
        if player.selectedAudioTrack != track {
            player.selectedAudioTrack = track
        }
    }

    func subtitleTrack(_ index: Int?) {
        guard let index, player.subtitleTracks.indices.contains(index) else { player.selectedSubtitleTrack = nil
            return
        }
        let track = player.subtitleTracks[index]
        if player.selectedSubtitleTrack != track {
            player.selectedSubtitleTrack = track
        }
    }

    func aspectFill(_ value: Bool) {
        player.aspectRatio = value ? .fill : .default
    }

    func audioDelay(_ value: Duration) throws {
        try player.setAudioDelay(value)
    }

    func subtitleDelay(_ value: Duration) throws {
        try player.setSubtitleDelay(value)
    }

    func subtitleStyle(_ value: VLCSubtitleStyle) {
        player.setSubtitleScale(.init(approximatePoints: value.approximatePoints))
    }

    func shutdown() async -> Bool {
        await player.shutdown()
        return player.state == .idle
    }

    func observeDiagnostics(_ performance: KidsPerformanceSpan?) -> Task<Void, Never>? {
        guard let performance else { return nil }
        let logs = instance.logStream(minimumLevel: .warning)
        return Task {
            var seen = Set<Int>()
            for await entry in logs {
                guard !Task.isCancelled else { return }
                let reason = KidsNativeDiagnostic(message: entry.message).rawValue
                let module = KidsNativeModule(entry.module).rawValue
                let context = KidsNativeContext(message: entry.message).rawValue
                let key = (reason << 16) | (module << 12) | (context << 4) | Int(entry.level.rawValue)
                guard seen.insert(key).inserted else { continue }
                performance.mark(
                    .nativeDiagnostic,
                    values: [
                        "native_reason": Double(reason),
                        "native_severity": Double(entry.level.rawValue),
                        "native_module": Double(module),
                        "native_context": Double(context)
                    ]
                )
            }
        }
    }

    private struct NativeSurface: View {
        let player: Player
        let controller: VLCPlaybackController
        let generation: UUID
        var body: some View {
            VLCMountedVideoView(player: player, controller: controller, generation: generation)
                .onChange(of: player.currentTime) { controller.observed(.clock, generation: generation) }
                .onChange(of: player.state) { controller.observed(.state, generation: generation) }
                .onChange(of: player.bufferFill) { controller.observed(.buffer, generation: generation) }
                .onChange(of: player.isSeekable) { controller.observed(.seekable, generation: generation) }
                .onChange(of: player.didReachEnd) { controller.observed(.end, generation: generation) }
                .onChange(of: player.audioTracks) { controller.observed(.audioTracks, generation: generation) }
                .onChange(of: player.subtitleTracks) { controller.observed(.subtitleTracks, generation: generation) }
        }
    }
}
