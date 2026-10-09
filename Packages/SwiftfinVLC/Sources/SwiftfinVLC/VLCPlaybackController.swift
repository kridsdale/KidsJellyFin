//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Foundation
import KidsDiagnostics
import SwiftUI

@MainActor
protocol VLCNativeEngine: AnyObject {
    var requiresSurfaceMount: Bool { get }
    var frame: VLCPlaybackFrame { get }
    var subtitleTracks: [VLCSubtitleTrack] { get }
    var passiveStatistics: VLCNativeCounterSnapshot? { get }
    var nativeTimeObservation: VLCNativeTimeObservation? { get }
    func setPassiveObservationsEnabled(_ enabled: Bool)
    func startupMeasurements() -> [String: Double]
    func surface(controller: VLCPlaybackController, generation: UUID) -> AnyView
    func observeUpdates(_ update: @escaping @MainActor () -> Void)
    func cancelUpdates()
    func open(_ request: VLCPlaybackRequest) throws
    func play() throws
    func pause()
    func stop()
    func seek(_ time: Duration) throws
    func jump(_ offset: Duration)
    func rate(_ value: Float) throws
    func audioTrack(_ index: Int?)
    func subtitleTrack(_ index: Int?)
    func aspectFill(_ value: Bool)
    func audioDelay(_ value: Duration) throws
    func subtitleDelay(_ value: Duration) throws
    func subtitleStyle(_ value: VLCSubtitleStyle)
    func shutdown() async -> Bool
}

extension VLCNativeEngine {
    // Synthetic engines have no platform drawable. Production explicitly opts in.
    var requiresSurfaceMount: Bool {
        false
    }

    var passiveStatistics: VLCNativeCounterSnapshot? {
        nil
    }

    var nativeTimeObservation: VLCNativeTimeObservation? {
        nil
    }

    func setPassiveObservationsEnabled(_ enabled: Bool) {}

    func startupMeasurements() -> [String: Double] {
        frame.startupMeasurements
    }
}

extension VLCPlaybackFrame {
    var startupMeasurements: [String: Double] {
        // Fixed diagnostic codes; neither native prose nor stream identity escapes.
        let stateCode: Double = switch state {
        case .idle: 0
        case .opening: 1
        case .buffering: 2
        case .playing: 3
        case .paused: 4
        case .stopped: 5
        case .stopping: 6
        case .error: 7
        }
        return [
            "read_bytes": Double(readBytes), "decoded_video": Double(decodedVideo),
            "displayed_pictures": Double(displayedPictures), "lost_pictures": Double(lostPictures),
            "seconds": time.vlcSeconds, "buffer_fraction": Double(bufferFill), "native_state": stateCode
        ]
    }
}

enum VLCObservation { case clock, state, buffer, seekable, end, audioTracks, subtitleTracks }

/// Owns the SDK, renderer and native lifecycle; no SDK object escapes this module.
@MainActor
public final class VLCPlaybackController {
    private let engine: any VLCNativeEngine
    private let updateSubject = PassthroughSubject<Void, Never>()
    private var generation: UUID?
    private var operationID: UUID?
    private var request: VLCPlaybackRequest?
    private var pendingNativeOpen = false
    private var surfaceGeneration: UUID?
    private var surfaceID: UUID?
    private var surfaceMounted = false
    private var surfaceSize = CGSize.zero
    private var retiredSurfaceIDs = Set<UUID>()
    private var retiredSurfaceGenerations = Set<UUID>()
    private var pendingStart: Duration?
    private var buffering = false
    private var ended = false
    private var terminalPosition: Duration = .zero
    private var performance: KidsPerformanceSpan?
    private var performanceSampler: Task<Void, Never>?
    private var nativeDiagnostics: Task<Void, Never>?
    private var passiveSampler: Task<Void, Never>?
    private var passiveTracker: VLCPassiveObservationTracker?
    private var passiveReceipt = UUID()
    private var passiveTerminal = false
    private let observationNow: @MainActor () -> UInt64
    public var onEvent: (@MainActor (VLCPlaybackEvent) -> Void)?

    /// Opt-in supplementary observations; nil cancels all passive counter sampling.
    /// Consume promptly without operating the player. Strict renderer/audio callbacks
    /// and hardware utilization are unavailable; no replacement AV callbacks are installed.
    public var onPassiveObservation: (@MainActor (VLCPassiveObservation) -> Void)? {
        didSet {
            cancelPassiveObservations()
            if onPassiveObservation != nil, let generation, !pendingNativeOpen, !ended, !passiveTerminal {
                startPassiveObservations(generation: generation)
            }
        }
    }

    public convenience init() {
        self.init(engine: SwiftVLCNativeEngine())
    }

    init(engine: any VLCNativeEngine, observationNow: @escaping @MainActor () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.engine = engine
        self.observationNow = observationNow
        engine.observeUpdates { [weak self] in
            guard let self, self.generation != nil else { return }
            self.updateSubject.send(())
        }
    }

    isolated deinit {
        performanceSampler?.cancel()
        nativeDiagnostics?.cancel()
        passiveSampler?.cancel()
        engine.cancelUpdates()
    }

    public var updates: AnyPublisher<Void, Never> {
        updateSubject.eraseToAnyPublisher()
    }

    public var frame: VLCPlaybackFrame {
        // A replacement waiting for its own drawable cannot expose decoded
        // output or an advancing clock retained by the predecessor.
        var result = pendingNativeOpen ? VLCPlaybackFrame() : engine.frame
        result.buffering = buffering
        result.applyingStartPosition = pendingStart != nil || pendingNativeOpen
        return result
    }

    public func surface(generation: UUID) -> AnyView {
        // An obsolete SwiftUI body must not reset the successor's mount receipt
        // or create an SDK view that can take its native drawable ownership.
        guard !retiredSurfaceGenerations.contains(generation) else { return AnyView(Color.clear) }
        expectSurface(generation: generation)
        return engine.surface(controller: self, generation: generation)
    }

    private func expectSurface(generation: UUID) {
        guard surfaceGeneration != generation else { return }
        if let surfaceGeneration {
            retiredSurfaceGenerations.insert(surfaceGeneration)
        }
        if let surfaceID {
            retiredSurfaceIDs.insert(surfaceID)
        }
        surfaceGeneration = generation
        surfaceID = nil
        surfaceMounted = false
        surfaceSize = .zero
    }

    func surfaceAttached(generation: UUID, id: UUID) {
        guard surfaceGeneration == generation, !retiredSurfaceIDs.contains(id) else { return }
        guard surfaceID != id else { return }
        if let surfaceID {
            retiredSurfaceIDs.insert(surfaceID)
        }
        surfaceID = id
        surfaceMounted = false
        surfaceSize = .zero
    }

    func surfaceLaidOut(generation: UUID, id: UUID, size: CGSize) {
        guard surfaceGeneration == generation, surfaceID == id, !retiredSurfaceIDs.contains(id),
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        surfaceMounted = true
        surfaceSize = size
        guard self.generation == generation, pendingNativeOpen, let operation = operationID else { return }
        beginNativeOpen(operation: operation, generation: generation)
    }

    func surfaceUnavailable(generation: UUID, id: UUID) {
        guard surfaceGeneration == generation, surfaceID == id else { return }
        surfaceMounted = false
        surfaceSize = .zero
    }

    func surfaceDetached(generation: UUID, id: UUID) {
        guard surfaceGeneration == generation, surfaceID == id else { return }
        retiredSurfaceIDs.insert(id)
        surfaceID = nil
        surfaceMounted = false
        surfaceSize = .zero
        guard self.generation == generation, pendingNativeOpen else { return }
        let terminal = endPassiveObservations(reason: .surfaceUnavailable)
        pendingNativeOpen = false
        request = nil
        pendingStart = nil
        self.generation = nil
        operationID = nil
        if let terminal {
            onPassiveObservation?(terminal)
        }
        onEvent?(.playbackFailed)
    }

    public func open(_ request: VLCPlaybackRequest, generation: UUID, performance: KidsPerformanceSpan? = nil) {
        guard !retiredSurfaceGenerations.contains(generation) else { return }
        let previousTerminal = endPassiveObservations(reason: .replaced)
        let operation = UUID()
        if let current = self.generation, current != generation {
            retiredSurfaceGenerations.insert(current)
        }
        operationID = operation
        self.generation = generation
        expectSurface(generation: generation)
        self.request = request
        pendingNativeOpen = true
        self.performance = performance
        self.pendingStart = !request.live && request.start > .zero ? request.start : nil
        self.ended = false
        passiveTerminal = false
        self.terminalPosition = .zero
        performanceSampler?.cancel()
        nativeDiagnostics?.cancel()
        if let previousTerminal {
            onPassiveObservation?(previousTerminal)
        }
        guard operationID == operation else { return }
        guard !engine.requiresSurfaceMount || surfaceMounted else { return }
        beginNativeOpen(operation: operation, generation: generation)
    }

    private func beginNativeOpen(operation: UUID, generation: UUID) {
        guard operationID == operation, self.generation == generation, pendingNativeOpen, let request else { return }
        pendingNativeOpen = false
        startPassiveObservations(generation: generation)
        guard operationID == operation else { return }
        do {
            nativeDiagnostics = (engine as? SwiftVLCNativeEngine)?.observeDiagnostics(performance)
            var measurements = startupMeasurements()
            measurements["resume_seconds"] = request.start.vlcSeconds
            if engine.requiresSurfaceMount {
                performance?.mark(.rendererMounted, values: measurements)
            }
            performance?.mark(.vlcOpen, values: measurements)
            try engine.open(request)
            guard operationID == operation else { return }
            performance?.mark(.vlcOpenReturned)
            observeStartup(generation: generation)
            engine.subtitleStyle(request.subtitleStyle)
        } catch {
            guard operationID == operation else { return }
            pendingStart = nil
            let terminal = endPassiveObservations(reason: .openRejected)
            if let terminal {
                onPassiveObservation?(terminal)
            }
            guard operationID == operation else { return }
            onEvent?(.playbackFailed)
        }
    }

    public func play() {
        guard generation != nil, !pendingNativeOpen else { return }
        perform(.play) { try engine.play() }
    }

    public func pause() {
        guard generation != nil else { return }
        engine.pause()
    }

    public func stop() {
        let terminal = endPassiveObservations(reason: .requestedStop)
        if let generation {
            retiredSurfaceGenerations.insert(generation)
        }
        if let surfaceGeneration {
            retiredSurfaceGenerations.insert(surfaceGeneration)
        }
        generation = nil
        operationID = nil
        pendingNativeOpen = false
        request = nil
        if let surfaceID {
            retiredSurfaceIDs.insert(surfaceID)
        }
        surfaceGeneration = nil
        surfaceID = nil
        surfaceMounted = false
        surfaceSize = .zero
        pendingStart = nil
        buffering = false
        performanceSampler?.cancel()
        nativeDiagnostics?.cancel()
        performanceSampler = nil
        nativeDiagnostics = nil
        engine.stop()
        if let terminal {
            onPassiveObservation?(terminal)
        }
    }

    public func jump(_ offset: Duration) {
        guard generation != nil else { return }
        terminalPosition = .zero
        engine.jump(offset)
    }

    public func setRate(_ value: Float) {
        guard generation != nil else { return }
        perform(.rate) { try engine.rate(value) }
    }

    public func seek(_ value: Duration) {
        guard let operation = operationID, engine.frame.seekable, operationID == operation else { return }
        pendingStart = nil
        observeSeekRequest(value)
        guard operationID == operation else { return }
        perform(.seek) {
            try engine.seek(value)
            guard operationID == operation else { return }
            terminalPosition = max(.zero, value)
        }
    }

    public func setAudioTrack(_ index: Int?) {
        engine.audioTrack(index)
    }

    public func setSubtitleTrack(_ index: Int?) {
        engine.subtitleTrack(index)
    }

    public func setAspectFill(_ value: Bool) {
        engine.aspectFill(value)
    }

    public func setAudioDelay(_ value: Duration) {
        perform(.audioDelay) { try engine.audioDelay(value) }
    }

    public func setSubtitleDelay(_ value: Duration) {
        perform(.subtitleDelay) { try engine.subtitleDelay(value) }
    }

    public func setSubtitleStyle(_ value: VLCSubtitleStyle) {
        engine.subtitleStyle(value)
    }

    public func shutdown() async -> Bool {
        stop()
        engine.cancelUpdates()
        return await engine.shutdown()
    }

    private func perform(_ operation: VLCPlaybackOperation, _ action: () throws -> Void) {
        let receipt = operationID
        do { try action() } catch {
            guard operationID == receipt else { return }
            if operation == .seek {
                observeSeekRejection()
            }
            guard operationID == receipt else { return }
            onEvent?(.operationRejected(operation))
        }
    }

    @discardableResult
    private func applyPendingStart() -> Bool {
        guard let operation = operationID, let pendingStart, engine.frame.seekable, operationID == operation else { return false }
        self.pendingStart = nil
        performance?.once(.resumeSeek, values: ["seconds": pendingStart.vlcSeconds])
        observeSeekRequest(pendingStart)
        guard operationID == operation else { return true }
        do {
            try engine.seek(pendingStart)
            guard operationID == operation else { return true }
            observeSeekRejection()
            guard operationID == operation else { return true }
            terminalPosition = pendingStart
            onEvent?(.resumePosition(pendingStart))
        } catch {
            guard operationID == operation else { return true }
            onEvent?(.operationRejected(.seek))
        }
        return true
    }

    func observed(_ kind: VLCObservation, generation: UUID) {
        guard self.generation == generation, !pendingNativeOpen, let operation = operationID else { return }
        let native = engine.frame
        guard operationID == operation else { return }
        switch kind {
        case .clock:
            guard native.state == .playing || native.state == .paused, !applyPendingStart() else { return }
            terminalPosition = max(.zero, native.time)
            if native.time.vlcSeconds > (request?.start.vlcSeconds ?? 0) + 0.1 {
                performance?.once(.firstClock, values: ["seconds": native.time.vlcSeconds])
            }
            if native.state == .playing {
                buffering = false
            }
            onEvent?(.clock(frame))
        case .state:
            switch native.state {
            case .opening: performance?.once(.vlcOpening)
                buffering = true
            case .buffering: performance?.once(.vlcBuffering)
                buffering = true
            case .playing: performance?.once(.vlcPlaying)
                applyPendingStart()
                // A resume event can synchronously stop or replace this open.
                guard operationID == operation else { return }
                buffering = false
            case .paused: buffering = false
            case .error: performance?.once(.playerError)
                performance?.finish(.failure)
                buffering = false
            case .idle, .stopped, .stopping: break
            }
            if native.state == .error {
                let terminal = endPassiveObservations(reason: .nativeError)
                if let terminal {
                    onPassiveObservation?(terminal)
                }
                guard operationID == operation else { return }
            }
            onEvent?(.state(frame))
        case .buffer:
            guard native.state == .playing else { return }
            if native.bufferFill < 0.9 {
                buffering = true
            } else if native.bufferFill >= 1 {
                buffering = false
            }
            onEvent?(.buffer(frame))
        case .seekable: applyPendingStart()
        case .end:
            guard native.reachedEnd, request?.live == false, !ended else { return }
            ended = true
            buffering = false
            // SwiftVLC resets its clock when stopping. Keep the latest clock/accepted
            // seek, but do not turn an early stream termination into watched progress.
            let position = max(native.time, terminalPosition)
            if let runtime = request?.runtime, runtime > .zero,
               position < max(.zero, runtime - .seconds(5))
            {
                performance?.once(.playerError, values: ["seconds": position.vlcSeconds, "runtime_seconds": runtime.vlcSeconds])
                performance?.finish(.failure)
                let terminal = endPassiveObservations(reason: .prematureEnd)
                if let terminal {
                    onPassiveObservation?(terminal)
                }
                guard operationID == operation else { return }
                onEvent?(.playbackFailed)
            } else {
                let terminal = endPassiveObservations(reason: .naturalEnd)
                if let terminal {
                    onPassiveObservation?(terminal)
                }
                guard operationID == operation else { return }
                onEvent?(.naturalEnd(request?.runtime))
            }
        case .audioTracks: onEvent?(.audioTracksChanged)
        case .subtitleTracks: onEvent?(.subtitleTracksChanged(engine.subtitleTracks))
        }
    }

    private func cancelPassiveObservations() {
        engine.setPassiveObservationsEnabled(false)
        passiveReceipt = UUID()
        passiveSampler?.cancel()
        passiveSampler = nil
        passiveTracker = nil
    }

    private func startPassiveObservations(generation: UUID) {
        guard onPassiveObservation != nil, self.generation == generation, !pendingNativeOpen else { return }
        cancelPassiveObservations()
        engine.setPassiveObservationsEnabled(true)
        let receipt = passiveReceipt
        let tracker = VLCPassiveObservationTracker(generation: generation)
        passiveTracker = tracker
        deliverPassive([tracker.started(frame: frame, now: observationNow())], generation: generation, receipt: receipt)
        guard self.generation == generation, passiveReceipt == receipt, onPassiveObservation != nil else { return }
        passiveSampler = Task { [weak self] in
            while !Task.isCancelled {
                guard self?.generation == generation, self?.passiveReceipt == receipt else { return }
                self?.samplePassiveObservations(generation: generation, receipt: receipt)
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }

    // Internal for deterministic synthetic tests; production is driven by the bounded-cadence task.
    func samplePassiveObservations(generation: UUID, receipt: UUID? = nil) {
        let receipt = receipt ?? passiveReceipt
        guard self.generation == generation, passiveReceipt == receipt, !pendingNativeOpen,
              onPassiveObservation != nil, var tracker = passiveTracker else { return }
        let observations = tracker.sample(
            frame: frame, statistics: engine.passiveStatistics,
            nativeTime: engine.nativeTimeObservation, now: observationNow()
        )
        passiveTracker = tracker
        deliverPassive(observations, generation: generation, receipt: receipt)
    }

    private func deliverPassive(_ observations: [VLCPassiveObservation], generation: UUID, receipt: UUID) {
        for observation in observations {
            guard self.generation == generation, passiveReceipt == receipt, let observer = onPassiveObservation else { return }
            observer(observation)
        }
    }

    private func observeSeekRequest(_ target: Duration) {
        guard let generation, onPassiveObservation != nil, var tracker = passiveTracker else { return }
        let receipt = passiveReceipt
        let observations = tracker.requestedSeek(
            id: UUID(), target: target, frame: frame, statistics: engine.passiveStatistics,
            nativeTime: engine.nativeTimeObservation, now: observationNow()
        )
        passiveTracker = tracker
        deliverPassive(observations, generation: generation, receipt: receipt)
    }

    private func observeSeekRejection() {
        guard let generation, onPassiveObservation != nil, var tracker = passiveTracker else { return }
        let observation = tracker.rejectedSeek(frame: frame, now: observationNow())
        passiveTracker = tracker
        if let observation {
            deliverPassive([observation], generation: generation, receipt: passiveReceipt)
        }
    }

    private func endPassiveObservations(reason: VLCPassiveTerminalReason) -> VLCPassiveObservation? {
        let observation = passiveTracker?.ended(
            reason: reason, frame: frame, now: observationNow(), statistics: engine.passiveStatistics,
            nativeTime: engine.nativeTimeObservation
        )
        cancelPassiveObservations()
        passiveTerminal = true
        return observation
    }

    private func observeStartup(generation: UUID) {
        guard let performance else { return }
        performanceSampler = Task { [weak self] in
            for _ in 0 ..< 400 {
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                let sample = self.engine.frame
                let values: [String: Double] = [
                    "read_bytes": Double(sample.readBytes), "decoded_video": Double(sample.decodedVideo),
                    "displayed_pictures": Double(sample.displayedPictures), "lost_pictures": Double(sample.lostPictures),
                    "resume_pending": self.pendingStart == nil ? 0 : 1
                ]
                if sample.readBytes > 0 {
                    performance.once(.firstInput, values: values)
                }
                if sample.decodedVideo > 0 {
                    performance.once(.firstDecode, values: values)
                }
                if sample.displayedPictures > 0 {
                    performance.once(.firstVideoOutput, values: values)
                    performance.finish()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            performance.once(.observationTimeout, values: self.startupMeasurements())
        }
    }

    private func startupMeasurements() -> [String: Double] {
        var values = engine.startupMeasurements()
        values["resume_pending"] = pendingStart == nil ? 0 : 1
        values["surface_mounted"] = surfaceMounted ? 1 : 0
        values["surface_width_points"] = Double(surfaceSize.width)
        values["surface_height_points"] = Double(surfaceSize.height)
        return values
    }
}
