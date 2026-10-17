//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Combine
import Foundation
import KidsDiagnostics
import KidsDomain
import KidsPlayback

@MainActor
public final class KidsPlaybackController: ObservableObject, Identifiable {
    public let id = UUID()
    public let item: KidsItem
    public let title: KidsItem
    public let mode: KidsPlaybackMode
    public let episodes: [KidsItem]
    public let driver: any KidsPlaybackDriver
    public var performance: KidsPerformanceSpan?
    /// Opt-in supplementary observations. This does not certify native output or a successful trial.
    public var onPassiveObservation: (@MainActor (KidsSessionObservation) -> Void)?
    /// Optional host admission for paused-to-playing requests. The host must
    /// revalidate this controller/account after any suspension before resuming.
    /// Merely requesting admission never changes native transport state.
    public var onResumeRequested: (@MainActor (KidsPlaybackController) -> Void)?
    @Published
    public var controlsVisible = false
    @Published
    public var paused = false
    @Published
    public var seconds = 0.0
    @Published
    public var buffering = true
    @Published
    public var recovery = false
    @Published
    public var showCountdown = false
    @Published
    public var countdown = 10
    @Published
    public var nextEpisode: KidsItem?
    @Published
    public var failed = false
    private weak var model: (any KidsPlaybackSessionDelegate)?
    private var began = false
    private var finished = false
    public var allowsCheckpoints = true
    private var stopped = false
    private var started = false
    /// Operational controller callbacks only, not certification of native output.
    public var hasBegunPlayback: Bool {
        began
    }

    public var hasEndedPlayback: Bool {
        finished || stopped
    }

    private var tickTask: Task<Void, Never>?
    private var eventSubscription: AnyCancellable?
    private var requestedStartPosition = 0.0
    private var waitingSince: Date?
    private var lastCheckpoint = Date.distantPast
    private var lastControl = Date.now
    private let now: @MainActor () -> Date
    private let monotonicNow: @MainActor () -> UInt64
    private var lastObservedPaused: Bool?
    private var lastDelegatePaused: Bool?
    private var lastBufferReadySequence: UInt64 = 0
    private var lastObservedBuffering: Bool?
    private var observedNativeEnd = false

    public init(
        item: KidsItem,
        title: KidsItem,
        mode: KidsPlaybackMode,
        position: Double,
        episodes: [KidsItem],
        driver: any KidsPlaybackDriver,
        delegate: any KidsPlaybackSessionDelegate,
        performance: KidsPerformanceSpan? = nil,
        now: @escaping @MainActor () -> Date = { .now },
        monotonicNow: @escaping @MainActor () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.item = item
        self.title = title
        self.mode = mode
        self.episodes = episodes
        self.driver = driver
        self.model = delegate
        self.performance = performance
        self.now = now
        self.monotonicNow = monotonicNow
        let start = max(0, position)
        seconds = start
        requestedStartPosition = start
        lastControl = now()
    }

    private func observe(
        _ kind: KidsSessionObservation.Kind,
        position: Double? = nil,
        seekTarget: Double? = nil,
        failure: KidsSessionObservation.Failure? = nil,
        cancellationRequested: Bool = false
    ) {
        guard let onPassiveObservation else { return }
        onPassiveObservation(KidsSessionObservation(
            sessionID: id,
            kind: kind,
            monotonicNS: monotonicNow(),
            positionSeconds: position,
            requestedSeekTargetSeconds: seekTarget,
            failure: failure,
            cancellationRequested: cancellationRequested
        ))
    }

    private func observeTransport(paused: Bool, position: Double) {
        guard onPassiveObservation != nil, lastObservedPaused != paused else { return }
        lastObservedPaused = paused
        observe(paused ? .transportPausedObserved : .transportResumedObserved, position: position)
    }

    private func observeBuffering(_ buffering: Bool, position: Double) {
        guard onPassiveObservation != nil, lastObservedBuffering != buffering else { return }
        lastObservedBuffering = buffering
        observe(buffering ? .bufferingStartedObserved : .bufferingEndedObserved, position: position)
    }

    private func receive(_ event: KidsPlaybackDriverEvent) {
        guard !stopped else { return }
        switch event {
        case .updated:
            if driver.frame.failed, !failed {
                if onPassiveObservation != nil {
                    observe(.failureObserved, position: driver.frame.seconds, failure: .nativeFrame)
                    if !recovery {
                        observe(.recoveryEntered, position: driver.frame.seconds)
                    }
                }
                failed = true
                recovery = true
                driver.pause()
            }
            updatePlaybackState()
        case let .transport(paused, clock, terminal):
            if !terminal {
                observeTransport(paused: paused, position: clock)
            }
            guard began else { return }
            let newlyPaused = paused && lastDelegatePaused != true
            lastDelegatePaused = paused
            reveal()
            if paused {
                if clock.isFinite && !terminal {
                    seconds = max(0, clock)
                }
                model?.playbackCheckpoint(self, seconds: seconds)
                if newlyPaused {
                    model?.playbackPaused(self)
                }
            }
        case let .failure(error):
            if onPassiveObservation != nil {
                let classification: KidsSessionObservation.Failure = switch error {
                case .authentication: .authentication
                case .stream: .stream
                }
                observe(.failureObserved, position: driver.frame.seconds, failure: classification)
            }
            model?.playbackFailed(self, error: error)
        case .naturalEnd:
            if onPassiveObservation != nil, !observedNativeEnd {
                observedNativeEnd = true
                observe(.nativeEndObserved, position: driver.frame.seconds)
            }
            guard began, !finished else { return }
            finished = true
            Task { await self.model?.completed(self) }
        }
    }

    #if DEBUG
    public static func preview(
        item: KidsItem,
        title: KidsItem,
        mode: KidsPlaybackMode,
        episodes: [KidsItem],
        delegate: any KidsPlaybackSessionDelegate,
        scenario: String
    ) -> KidsPlaybackController {
        let movie = scenario == "movie-paused"
        let controller = KidsPlaybackController(
            item: item,
            title: title,
            mode: mode,
            position: 0,
            episodes: episodes,
            driver: PreviewDriver(),
            delegate: delegate
        )
        controller.buffering = false
        controller.paused = scenario == "paused" || movie
        controller.seconds = movie ? 1200 : 120
        controller.began = movie // Exercise the real stop checkpoint before a parent-authorized restart.
        controller.controlsVisible = scenario == "paused" || scenario == "controls" || movie
        controller.recovery = scenario == "reconnecting"
        controller.showCountdown = scenario == "countdown"
        controller.nextEpisode = movie ? nil : episodes[1]
        return controller
    }
    #endif

    #if DEBUG
    @MainActor
    private final class PreviewDriver: KidsPlaybackDriver {
        let frame = KidsPlaybackFrame()
        var events: AnyPublisher<KidsPlaybackDriverEvent, Never> {
            Empty().eraseToAnyPublisher()
        }

        func start() {}
        func beginReporting() {}
        func togglePlayPause() {}
        func pause() {}
        func seek(seconds: Double) {}
        func stop() async {}
    }
    #endif

    public func start() {
        guard !started, !stopped else { return }
        started = true
        performance?.mark(.managerStart)
        eventSubscription = driver.events.sink { [weak self] event in self?.receive(event) }
        observe(.sessionStart)
        driver.start()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                await self.tick()
            }
        }
    }

    func tick() async {
        if showCountdown {
            countdown -= 1
            if countdown <= 0 {
                tickTask?.cancel()
                await model?.continuePlayback(self)
            }
            return
        }
        guard !stopped else { return }
        updatePlaybackState() // Recovery fallback if event delivery was interrupted.
        if began && !finished && now().timeIntervalSince(lastCheckpoint) >= 10 {
            model?.playbackCheckpoint(self, seconds: seconds)
            lastCheckpoint = now()
        }
        if buffering {
            if waitingSince == nil {
                waitingSince = now()
            }
            if now().timeIntervalSince(waitingSince!) >= 15 {
                if onPassiveObservation != nil, !recovery {
                    observe(.recoveryEntered, position: driver.frame.seconds)
                }
                recovery = true
                driver.pause()
            }
        } else {
            waitingSince = nil
        }
        if !paused && !recovery && now().timeIntervalSince(lastControl) > 5 {
            controlsVisible = false
        }
    }

    private func updatePlaybackState() {
        guard !stopped, model?.isPreview != true else { return }
        let frame = driver.frame
        let terminal = frame.terminal
        let time = frame.seconds
        // Do not publish a stale pre-seek clock or overwrite a durable checkpoint
        // when VLC resets its clock after a stop.
        if time.isFinite, !frame.applyingStartPosition, !(terminal && began),
           began || time >= requestedStartPosition
        {
            let currentSeconds = max(0, time)
            if seconds != currentSeconds {
                seconds = currentSeconds
            }
        }
        let currentlyPaused = frame.paused
        if paused != currentlyPaused {
            paused = currentlyPaused
        }
        if !terminal, frame.playing || frame.paused {
            observeTransport(paused: currentlyPaused, position: time)
        }
        if !began, KidsPlaybackReadiness.permitsPresentation(
            playingOrPaused: frame.playing || paused,
            buffering: frame.buffering,
            preparing: frame.preparing,
            resumePending: frame.applyingStartPosition,
            failedOrRecovering: failed || recovery || frame.failed,
            requestedPosition: requestedStartPosition,
            clock: time,
            displayedPictures: frame.displayedPictures
        ) {
            performance?.once(.firstClock, values: ["seconds": time])
            performance?.mark(.playbackBegan)
            began = true
            observe(.readinessObserved, position: time)
            driver.beginReporting()
            model?.playbackBegan(self)
        }
        let currentlyBuffering = frame.buffering || frame.preparing || (!began && !recovery) ||
            (terminal && began && !finished && !frame.reachedEnd)
        let bufferReadyAdvanced = frame.bufferReadySequence > lastBufferReadySequence
        lastBufferReadySequence = frame.bufferReadySequence
        if buffering != currentlyBuffering {
            buffering = currentlyBuffering
            model?.playbackBufferingChanged(self, buffering: currentlyBuffering)
        } else if bufferReadyAdvanced {
            model?.playbackBufferingChanged(self, buffering: currentlyBuffering)
        }
        observeBuffering(currentlyBuffering, position: time)
    }

    public func toggle() {
        guard !stopped else { return }
        if model?.isPreview == true {
            paused.toggle()
        } else if driver.frame.paused, let onResumeRequested {
            onResumeRequested(self)
        } else {
            driver.togglePlayPause()
        }
        controlsVisible = true
        lastControl = now()
        model?.playbackCheckpoint(self, seconds: seconds)
    }

    public func reveal() {
        controlsVisible = true
        lastControl = now()
    }

    public func seek(_ delta: Double) {
        guard !stopped, paused, delta.isFinite else { return }
        guard model?.isPreview == true || driver.frame.seekable else { return }
        let runtime = item.runtime ?? 0
        let target = max(0, min(runtime > 0 ? runtime : .greatestFiniteMagnitude, seconds + delta))
        if model?.isPreview != true {
            if onPassiveObservation != nil {
                observe(.seekRequested, position: driver.frame.seconds, seekTarget: target)
            }
            driver.seek(seconds: target)
        }
        seconds = target
        reveal()
        model?.playbackCheckpoint(self, seconds: target)
    }

    public func retry() async {
        guard let model else { return }
        let saved = began ? seconds : requestedStartPosition
        model.playbackCheckpoint(self, seconds: saved)
        await stop()
        model.retryPlayback(self, position: saved)
    }

    private var stopFlight: Task<Void, Never>?

    public func stop() async {
        var completedStop = false
        if let stopFlight {
            await stopFlight.value
        } else if !stopped {
            stopped = true
            model?.playbackWillStop(self)
            if onPassiveObservation != nil {
                observe(.stopRequested, position: driver.frame.seconds, cancellationRequested: Task.isCancelled)
            }
            if began && !finished {
                model?.playbackCheckpoint(self, seconds: seconds)
            }
            eventSubscription?.cancel()
            eventSubscription = nil
            if model?.isPreview != true {
                driver.pause()
                let driver = driver
                let flight = Task { await driver.stop() }
                stopFlight = flight
                await flight.value
                observe(.driverDrained, cancellationRequested: Task.isCancelled)
            }
            completedStop = true
        }
        if !showCountdown {
            tickTask?.cancel()
        }
        if completedStop {
            model?.playbackDidStop(self)
            observe(.stopCompleted, cancellationRequested: Task.isCancelled)
        }
    }

    public func pauseOnBackground() {
        guard !stopped else { return }
        if model?.isPreview == true {
            paused = true
        } else {
            driver.pause()
        }
        model?.playbackCheckpoint(self, seconds: seconds)
    }

    public func handleBack() async {
        if controlsVisible && !recovery && !showCountdown {
            controlsVisible = false
        } else {
            await model?.stopPlaybackFromSession(self)
        }
    }

    deinit {
        tickTask?.cancel()
    }
}
