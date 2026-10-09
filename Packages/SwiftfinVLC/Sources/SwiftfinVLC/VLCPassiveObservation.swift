//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// Cumulative native counters, not renderer/audio callbacks or hardware utilization.
/// A missing snapshot or field means unavailable, never measured zero.
public struct VLCNativeCounterSnapshot: Sendable, Equatable, Codable {
    public let readBytes: UInt64?
    public let decodedVideo: UInt64?
    public let displayedPictures: UInt64?
    public let lostPictures: UInt64?
    public let latePictures: UInt64?
    public let decodedAudio: UInt64?
    public let playedAudioBuffers: UInt64?
    public let lostAudioBuffers: UInt64?
    public let demuxCorrupted: UInt64?
    public let demuxDiscontinuity: UInt64?

    public init(
        readBytes: UInt64? = nil, decodedVideo: UInt64? = nil, displayedPictures: UInt64? = nil,
        lostPictures: UInt64? = nil, latePictures: UInt64? = nil, decodedAudio: UInt64? = nil,
        playedAudioBuffers: UInt64? = nil, lostAudioBuffers: UInt64? = nil,
        demuxCorrupted: UInt64? = nil, demuxDiscontinuity: UInt64? = nil
    ) {
        self.readBytes = readBytes
        self.decodedVideo = decodedVideo
        self.displayedPictures = displayedPictures
        self.lostPictures = lostPictures
        self.latePictures = latePictures
        self.decodedAudio = decodedAudio
        self.playedAudioBuffers = playedAudioBuffers
        self.lostAudioBuffers = lostAudioBuffers
        self.demuxCorrupted = demuxCorrupted
        self.demuxDiscontinuity = demuxDiscontinuity
    }

    private static var counters: [KeyPath<Self, UInt64?>] {
        [
            \.readBytes, \.decodedVideo, \.displayedPictures, \.lostPictures, \.latePictures,
            \.decodedAudio, \.playedAudioBuffers, \.lostAudioBuffers, \.demuxCorrupted, \.demuxDiscontinuity
        ]
    }

    func hasReset(since previous: Self) -> Bool {
        Self.counters.contains { key in
            guard let current = self[keyPath: key], let old = previous[keyPath: key] else { return false }
            return current < old
        }
    }

    func hasUnavailableCounter(since previous: Self) -> Bool {
        Self.counters.contains { key in
            previous[keyPath: key] != nil && self[keyPath: key] == nil
        }
    }

    func difference(from previous: Self) -> Self {
        func delta(_ key: KeyPath<Self, UInt64?>) -> UInt64? {
            guard let current = self[keyPath: key], let old = previous[keyPath: key], current >= old else { return nil }
            return current - old
        }
        return .init(
            readBytes: delta(\.readBytes), decodedVideo: delta(\.decodedVideo),
            displayedPictures: delta(\.displayedPictures), lostPictures: delta(\.lostPictures),
            latePictures: delta(\.latePictures), decodedAudio: delta(\.decodedAudio),
            playedAudioBuffers: delta(\.playedAudioBuffers), lostAudioBuffers: delta(\.lostAudioBuffers),
            demuxCorrupted: delta(\.demuxCorrupted), demuxDiscontinuity: delta(\.demuxDiscontinuity)
        )
    }
}

public enum VLCPassiveObservationKind: String, Sendable, Equatable, Codable {
    case observationStarted
    case stateChanged
    case bufferingChanged
    case nativeCounterSample
    case countersReset
    case counterContinuityLost
    case firstDisplayedPictureCounterObserved
    case firstPlayedAudioBufferCounterObserved
    case seekRequested
    case seekRejected
    case seekSuperseded
    case seekSettledSupplementary
    case seekObservationTimedOut
    case terminal
}

public enum VLCPassiveTerminalReason: String, Sendable, Equatable, Codable {
    case requestedStop
    case replaced
    case naturalEnd
    case prematureEnd
    case nativeError
    case openRejected
    case surfaceUnavailable
}

/// Privacy-safe, immutable supplementary observation. No media identity or native prose escapes.
/// Counter milestones are observed increments, not physical presentation/audio output receipts.
public struct VLCPassiveObservation: Sendable, Equatable, Codable {
    public let generation: UUID
    public let monotonicNanoseconds: UInt64
    public let kind: VLCPassiveObservationKind
    public let state: VLCPlaybackState
    public let buffering: Bool
    /// Last native timeChanged payload, if available; never the optimistic seek/UI clock.
    public let positionSeconds: Double?
    public let nativeTime: VLCNativeTimeObservation?
    public let statistics: VLCNativeCounterSnapshot?
    public let counterDelta: VLCNativeCounterSnapshot?
    public let counterEpoch: UInt64
    public let seekID: UUID?
    public let seekTargetSeconds: Double?
    public let terminalReason: VLCPassiveTerminalReason?
}

/// Receipt of a native timeChanged payload, separate from SwiftVLC's optimistic UI clock.
public struct VLCNativeTimeObservation: Sendable, Equatable, Codable {
    public let sequence: UInt64
    /// Main-actor receipt time from the existing bounded SDK event stream, not native callback time.
    public let monotonicNanoseconds: UInt64
    public let positionSeconds: Double

    public init(sequence: UInt64, monotonicNanoseconds: UInt64, positionSeconds: Double) {
        self.sequence = sequence
        self.monotonicNanoseconds = monotonicNanoseconds
        self.positionSeconds = positionSeconds
    }
}

/// Pure state machine. It never operates the player or treats a counter as a strict callback.
struct VLCPassiveObservationTracker {
    let generation: UUID
    private(set) var counterEpoch: UInt64 = 0
    private var previousStatistics: VLCNativeCounterSnapshot?
    private var previousState: VLCPlaybackState?
    private var previousBuffering: Bool?
    private var observedVideoIncrement = false
    private var observedAudioIncrement = false
    private var pendingSeek: PendingSeek?

    private struct PendingSeek {
        let id: UUID
        let requestedAt: UInt64
        let targetSeconds: Double
        let displayedBaseline: UInt64?
        let counterEpoch: UInt64
        let clockSequence: UInt64?
    }

    init(generation: UUID) {
        self.generation = generation
    }

    private func observation(
        _ kind: VLCPassiveObservationKind, frame: VLCPlaybackFrame, now: UInt64,
        statistics: VLCNativeCounterSnapshot? = nil, delta: VLCNativeCounterSnapshot? = nil,
        nativeTime: VLCNativeTimeObservation? = nil,
        seek: PendingSeek? = nil, terminalReason: VLCPassiveTerminalReason? = nil
    ) -> VLCPassiveObservation {
        let nativeTime = nativeTime?.positionSeconds.isFinite == true ? nativeTime : nil
        return .init(
            generation: generation, monotonicNanoseconds: now, kind: kind, state: frame.state,
            buffering: frame.buffering || frame.state == .buffering,
            positionSeconds: nativeTime?.positionSeconds, nativeTime: nativeTime,
            statistics: statistics, counterDelta: delta, counterEpoch: counterEpoch,
            seekID: seek?.id, seekTargetSeconds: seek?.targetSeconds, terminalReason: terminalReason
        )
    }

    func started(frame: VLCPlaybackFrame, now: UInt64) -> VLCPassiveObservation {
        observation(.observationStarted, frame: frame, now: now)
    }

    mutating func sample(
        frame: VLCPlaybackFrame, statistics: VLCNativeCounterSnapshot?,
        nativeTime: VLCNativeTimeObservation?, now: UInt64
    ) -> [VLCPassiveObservation] {
        var result: [VLCPassiveObservation] = []
        if previousState != frame.state {
            result.append(observation(.stateChanged, frame: frame, now: now, nativeTime: nativeTime))
            previousState = frame.state
        }
        let buffering = frame.buffering || frame.state == .buffering
        if previousBuffering != buffering {
            result.append(observation(.bufferingChanged, frame: frame, now: now, nativeTime: nativeTime))
            previousBuffering = buffering
        }
        var delta: VLCNativeCounterSnapshot?
        if previousStatistics != nil, statistics == nil {
            counterEpoch += 1
            result.append(observation(.counterContinuityLost, frame: frame, now: now, nativeTime: nativeTime))
        }
        if let statistics, let previousStatistics {
            if statistics.hasUnavailableCounter(since: previousStatistics) {
                counterEpoch += 1
                result.append(observation(.counterContinuityLost, frame: frame, now: now, statistics: statistics, nativeTime: nativeTime))
            } else if statistics.hasReset(since: previousStatistics) {
                counterEpoch += 1
                result.append(observation(.countersReset, frame: frame, now: now, statistics: statistics, nativeTime: nativeTime))
            } else {
                delta = statistics.difference(from: previousStatistics)
            }
        }
        result.append(observation(
            .nativeCounterSample,
            frame: frame,
            now: now,
            statistics: statistics,
            delta: delta,
            nativeTime: nativeTime
        ))
        if !observedVideoIncrement, let increment = delta?.displayedPictures, increment > 0 {
            observedVideoIncrement = true
            result.append(observation(
                .firstDisplayedPictureCounterObserved,
                frame: frame,
                now: now,
                statistics: statistics,
                delta: delta,
                nativeTime: nativeTime
            ))
        }
        if !observedAudioIncrement, let increment = delta?.playedAudioBuffers, increment > 0 {
            observedAudioIncrement = true
            result.append(observation(
                .firstPlayedAudioBufferCounterObserved,
                frame: frame,
                now: now,
                statistics: statistics,
                delta: delta,
                nativeTime: nativeTime
            ))
        }
        previousStatistics = statistics

        if let seek = pendingSeek, now >= seek.requestedAt {
            let elapsed = Double(now - seek.requestedAt) / 1_000_000_000
            // Supplementary settlement requires a native time payload received after the
            // command, convergence within one second of target + elapsed playback, AND
            // a displayed-counter increment in the same uninterrupted counter epoch.
            // It does not identify which picture was displayed or prove renderer completion.
            if elapsed >= 10 {
                pendingSeek = nil
                result.append(observation(
                    .seekObservationTimedOut,
                    frame: frame,
                    now: now,
                    statistics: statistics,
                    nativeTime: nativeTime,
                    seek: seek
                ))
            } else if let baseline = seek.displayedBaseline, let displayed = statistics?.displayedPictures,
                      counterEpoch == seek.counterEpoch, displayed > baseline,
                      let nativeTime, nativeTime.monotonicNanoseconds > seek.requestedAt,
                      nativeTime.monotonicNanoseconds <= now,
                      nativeTime.sequence > (seek.clockSequence ?? 0), nativeTime.positionSeconds.isFinite,
                      nativeTime.positionSeconds >= seek.targetSeconds - 1,
                      nativeTime.positionSeconds <= seek.targetSeconds + elapsed + 1
            {
                pendingSeek = nil
                result.append(observation(
                    .seekSettledSupplementary,
                    frame: frame,
                    now: now,
                    statistics: statistics,
                    nativeTime: nativeTime,
                    seek: seek
                ))
            }
        }
        return result
    }

    mutating func requestedSeek(
        id: UUID, target: Duration, frame: VLCPlaybackFrame, statistics: VLCNativeCounterSnapshot?,
        nativeTime: VLCNativeTimeObservation?, now: UInt64
    ) -> [VLCPassiveObservation] {
        var result: [VLCPassiveObservation] = []
        if let pendingSeek {
            result.append(observation(.seekSuperseded, frame: frame, now: now, nativeTime: nativeTime, seek: pendingSeek))
        }
        let seconds = target.vlcSeconds
        let seek = PendingSeek(
            id: id, requestedAt: now, targetSeconds: seconds,
            displayedBaseline: statistics?.displayedPictures, counterEpoch: counterEpoch,
            clockSequence: nativeTime?.sequence
        )
        pendingSeek = seconds.isFinite ? seek : nil
        result.append(observation(
            .seekRequested,
            frame: frame,
            now: now,
            statistics: statistics,
            nativeTime: nativeTime,
            seek: seconds.isFinite ? seek : nil
        ))
        return result
    }

    mutating func rejectedSeek(frame: VLCPlaybackFrame, now: UInt64) -> VLCPassiveObservation? {
        guard let pendingSeek else { return nil }
        self.pendingSeek = nil
        return observation(.seekRejected, frame: frame, now: now, seek: pendingSeek)
    }

    mutating func ended(
        reason: VLCPassiveTerminalReason, frame: VLCPlaybackFrame, now: UInt64,
        statistics: VLCNativeCounterSnapshot? = nil, nativeTime: VLCNativeTimeObservation? = nil
    ) -> VLCPassiveObservation {
        let seek = pendingSeek
        pendingSeek = nil
        return observation(
            .terminal,
            frame: frame,
            now: now,
            statistics: statistics,
            nativeTime: nativeTime,
            seek: seek,
            terminalReason: reason
        )
    }
}
