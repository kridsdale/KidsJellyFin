//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Foundation
@testable import SwiftfinVLC
import SwiftUI
import XCTest
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class VLCPlaybackOwnershipTests: XCTestCase {
    private final class Engine: VLCNativeEngine {
        var requiresSurfaceMount = false
        var frame = VLCPlaybackFrame()
        var subtitleTracks: [VLCSubtitleTrack] = []
        var seeks: [Duration] = []
        var opens = 0
        var plays = 0
        var openedRequests: [VLCPlaybackRequest] = []
        var stops = 0
        var shutdowns = 0
        var rejectSeek = false
        var afterOpen: (@MainActor () throws -> Void)?
        var afterSeek: (@MainActor () -> Void)?
        var update: (@MainActor () -> Void)?
        func surface(controller: VLCPlaybackController, generation: UUID) -> AnyView {
            AnyView(Color.clear)
        }

        func observeUpdates(_ update: @escaping @MainActor () -> Void) {
            self.update = update
        }

        func cancelUpdates() {
            update = nil
        }

        func open(_ request: VLCPlaybackRequest) throws {
            opens += 1
            openedRequests.append(request)
            try afterOpen?()
        }

        func play() throws {
            plays += 1
        }

        func pause() {}
        func stop() {
            stops += 1
        }

        func seek(_ time: Duration) throws {
            if rejectSeek {
                throw NSError(domain: "fixture", code: 1)
            }
            seeks.append(time)
            afterSeek?()
        }

        func jump(_ offset: Duration) {}
        func rate(_ value: Float) throws {}
        func audioTrack(_ index: Int?) {}
        func subtitleTrack(_ index: Int?) {}
        func aspectFill(_ value: Bool) {}
        func audioDelay(_ value: Duration) throws {}
        func subtitleDelay(_ value: Duration) throws {}
        func subtitleStyle(_ value: VLCSubtitleStyle) {}
        func shutdown() async -> Bool {
            shutdowns += 1
            return true
        }
    }

    private func request(start: Duration = .seconds(120), live: Bool = false) -> VLCPlaybackRequest {
        .init(
            url: URL(string: "https://localhost.invalid/video?api_key=private-fixture")!,
            start: start,
            runtime: .seconds(900),
            live: live,
            subtitleURLs: [],
            subtitleStyle: .init(fontName: "fixture", colorRGB: nil, approximatePoints: 16)
        )
    }

    func testPendingOpenRequiresCurrentMountedSurfaceAndOpensOnlyOnce() {
        let engine = Engine(), player = VLCPlaybackController(engine: engine)
        engine.requiresSurfaceMount = true
        let generation = UUID(), surface = UUID()
        player.open(request(), generation: generation)
        XCTAssertEqual(engine.opens, 0)
        player.surfaceAttached(generation: generation, id: surface)
        XCTAssertEqual(engine.opens, 0, "An allocated but unmounted surface cannot start playback")
        player.surfaceLaidOut(generation: generation, id: surface, size: CGSize(width: 320, height: 180))
        player.surfaceLaidOut(generation: generation, id: surface, size: CGSize(width: 320, height: 180))
        XCTAssertEqual(engine.opens, 1)
        XCTAssertEqual(engine.openedRequests.first?.start, .seconds(120))
    }

    func testMountedSurfaceCanPrecedeApprovedRequestButUnmountRevokesReadiness() {
        let engine = Engine(), player = VLCPlaybackController(engine: engine)
        engine.requiresSurfaceMount = true
        let generation = UUID(), surface = UUID()
        _ = player.surface(generation: generation)
        player.surfaceAttached(generation: generation, id: surface)
        player.surfaceLaidOut(generation: generation, id: surface, size: CGSize(width: 320, height: 180))
        XCTAssertEqual(engine.opens, 0)
        player.surfaceUnavailable(generation: generation, id: surface)
        player.open(request(), generation: generation)
        XCTAssertEqual(engine.opens, 0)
        player.surfaceLaidOut(generation: generation, id: surface, size: CGSize(width: 320, height: 180))
        XCTAssertEqual(engine.opens, 1)
    }

    func testReplacementRetainsOnlyNewestPendingRequestAndRejectsOldMount() {
        let engine = Engine(), player = VLCPlaybackController(engine: engine)
        engine.requiresSurfaceMount = true
        let old = UUID(), current = UUID(), oldSurface = UUID(), currentSurface = UUID()
        player.open(request(start: .seconds(120)), generation: old)
        player.surfaceAttached(generation: old, id: oldSurface)
        engine.frame.state = .playing
        engine.frame.time = .seconds(500)
        engine.frame.displayedPictures = 100
        player.open(request(start: .seconds(240)), generation: current)
        XCTAssertEqual(player.frame.state, .idle)
        XCTAssertEqual(player.frame.time, .zero)
        XCTAssertEqual(player.frame.displayedPictures, 0)
        XCTAssertTrue(player.frame.applyingStartPosition)
        player.surfaceAttached(generation: current, id: currentSurface)
        player.surfaceAttached(generation: old, id: oldSurface)
        player.surfaceLaidOut(generation: old, id: oldSurface, size: CGSize(width: 320, height: 180))
        player.surfaceDetached(generation: old, id: oldSurface)
        XCTAssertEqual(engine.opens, 0)
        player.surfaceLaidOut(generation: current, id: currentSurface, size: CGSize(width: 320, height: 180))
        XCTAssertEqual(engine.opens, 1)
        XCTAssertEqual(engine.openedRequests.first?.start, .seconds(240))
    }

    func testSameGenerationReplacementRejectsRetiredHostAndItsDismantle() {
        let engine = Engine(), player = VLCPlaybackController(engine: engine)
        engine.requiresSurfaceMount = true
        let generation = UUID(), oldSurface = UUID(), currentSurface = UUID()
        player.open(request(), generation: generation)
        player.surfaceAttached(generation: generation, id: oldSurface)
        player.surfaceAttached(generation: generation, id: currentSurface)
        player.surfaceAttached(generation: generation, id: oldSurface)
        player.surfaceLaidOut(generation: generation, id: oldSurface, size: CGSize(width: 320, height: 180))
        player.surfaceDetached(generation: generation, id: oldSurface)
        XCTAssertEqual(engine.opens, 0)
        player.surfaceLaidOut(generation: generation, id: currentSurface, size: CGSize(width: 320, height: 180))
        XCTAssertEqual(engine.opens, 1)
    }

    func testObsoletePublicSurfaceCannotReplacePendingCurrentMount() {
        for surfacePrecedesOpen in [false, true] {
            let engine = Engine(), player = VLCPlaybackController(engine: engine)
            engine.requiresSurfaceMount = true
            let old = UUID(), current = UUID(), oldSurface = UUID(), currentSurface = UUID()
            player.open(request(start: .seconds(120)), generation: old)
            player.surfaceAttached(generation: old, id: oldSurface)
            if surfacePrecedesOpen {
                _ = player.surface(generation: current)
                player.surfaceAttached(generation: current, id: currentSurface)
            }
            player.open(request(start: .seconds(240)), generation: current)
            if !surfacePrecedesOpen {
                _ = player.surface(generation: current)
                player.surfaceAttached(generation: current, id: currentSurface)
            }
            // A discarded SwiftUI body can be evaluated after replacement.
            _ = player.surface(generation: old)
            player.surfaceLaidOut(generation: old, id: oldSurface, size: CGSize(width: 320, height: 180))
            player.surfaceDetached(generation: old, id: oldSurface)
            XCTAssertEqual(engine.opens, 0)
            player.surfaceLaidOut(generation: current, id: currentSurface, size: CGSize(width: 320, height: 180))
            XCTAssertEqual(engine.opens, 1)
            XCTAssertEqual(engine.openedRequests.first?.start, .seconds(240))
        }
    }

    func testStopAndCurrentDismantleCancelPendingOpenAndRetiredCallbacks() {
        for stops in [false, true] {
            let engine = Engine(), player = VLCPlaybackController(engine: engine)
            engine.requiresSurfaceMount = true
            let generation = UUID(), surface = UUID()
            var events: [VLCPlaybackEvent] = []
            player.onEvent = { events.append($0) }
            player.open(request(), generation: generation)
            player.surfaceAttached(generation: generation, id: surface)
            if stops {
                player.stop()
            } else {
                player.surfaceDetached(generation: generation, id: surface)
            }
            player.surfaceAttached(generation: generation, id: surface)
            player.surfaceLaidOut(generation: generation, id: surface, size: CGSize(width: 320, height: 180))
            player.play()
            XCTAssertEqual(engine.opens, 0)
            XCTAssertEqual(engine.plays, 0)
            XCTAssertFalse(player.frame.applyingStartPosition)
            XCTAssertEqual(events, stops ? [] : [.playbackFailed])
        }
    }

    func testUnmountedPendingPlayerCannotBypassGateThroughPlayCommand() {
        let engine = Engine(), player = VLCPlaybackController(engine: engine)
        engine.requiresSurfaceMount = true
        let generation = UUID()
        player.open(request(), generation: generation)
        player.play()
        XCTAssertEqual(engine.opens, 0)
        XCTAssertEqual(engine.plays, 0)
        XCTAssertTrue(player.frame.applyingStartPosition)
    }

    func testPendingOpenRequiresFinitePositiveLayout() {
        let engine = Engine(), player = VLCPlaybackController(engine: engine)
        engine.requiresSurfaceMount = true
        let generation = UUID(), surface = UUID()
        player.open(request(), generation: generation)
        player.surfaceAttached(generation: generation, id: surface)
        for size in [
            CGSize.zero,
            CGSize(width: 320, height: 0),
            CGSize(width: -1, height: 180),
            CGSize(width: CGFloat.infinity, height: 180)
        ] {
            player.surfaceLaidOut(generation: generation, id: surface, size: size)
            XCTAssertEqual(engine.opens, 0)
        }
        player.surfaceLaidOut(generation: generation, id: surface, size: CGSize(width: 320, height: 180))
        XCTAssertEqual(engine.opens, 1)
    }

    func testActualSDKViewMountsAndLaysOutBeforeInjectedNativeOpen() async throws {
        let engine = Engine(), player = VLCPlaybackController(engine: engine)
        defer { engine.afterOpen = nil }
        engine.requiresSurfaceMount = true
        let native = SwiftVLCNativeEngine(), generation = UUID()
        player.open(request(), generation: generation)
        let surface = native.surface(controller: player, generation: generation)
        #if canImport(UIKit)
        let host = UIHostingController(rootView: surface)
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        host.view.layoutIfNeeded()
        await Task.yield()
        XCTAssertEqual(engine.opens, 0, "Positive bounds without a window must not start playback")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 180)

        @MainActor
        func nativeMounts(in controller: UIViewController) -> [VLCVideoMountController] {
            let current = (controller as? VLCVideoMountController).map { [$0] } ?? []
            return current + controller.children.flatMap { nativeMounts(in: $0) }
        }

        @MainActor
        func layoutAttachedHierarchy(_ controller: UIViewController) {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            for child in controller.children {
                layoutAttachedHierarchy(child)
            }
        }

        engine.afterOpen = {
            let mount = try XCTUnwrap(nativeMounts(in: host).first)
            XCTAssertTrue(mount.view.window === window)
            XCTAssertGreaterThan(mount.view.bounds.width, 0)
            XCTAssertGreaterThan(mount.view.bounds.height, 0)
            let sdkHost = try XCTUnwrap(mount.children.first)
            XCTAssertTrue(sdkHost.view.window === window)
            XCTAssertGreaterThan(sdkHost.view.bounds.width, 0)
            XCTAssertGreaterThan(sdkHost.view.bounds.height, 0)
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true
            window.rootViewController = nil
        }
        #elseif canImport(AppKit)
        _ = NSApplication.shared
        let host = NSHostingView(rootView: surface)
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        XCTAssertEqual(engine.opens, 0, "Positive bounds without a window must not start playback")
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        engine.afterOpen = { XCTAssertNotNil(host.window)
            XCTAssertGreaterThan(host.bounds.width, 0)
            XCTAssertGreaterThan(host.bounds.height, 0)
        }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        #endif
        for _ in 0 ..< 100 {
            #if canImport(UIKit)
            // Attachment invalidates the layout done before the window existed.
            // Drive real UIKit layout rather than manufacturing a mount receipt.
            window.setNeedsLayout()
            window.layoutIfNeeded()
            layoutAttachedHierarchy(host)
            #endif
            if engine.opens == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #if canImport(UIKit)
        XCTAssertEqual(nativeMounts(in: host).count, 1, "The real SwiftUI surface must create exactly one native SDK mount")
        #endif
        XCTAssertEqual(engine.opens, 1)
        let shutDown = await native.shutdown()
        XCTAssertTrue(shutDown)
    }

    func testAbsoluteResumeWaitsForSeekableTimelineAndAppliesOnce() {
        let engine = Engine()
        let player = VLCPlaybackController(engine: engine), generation = UUID()
        var events: [VLCPlaybackEvent] = []
        player.onEvent = { events.append($0) }
        player.open(request(), generation: generation)
        engine.frame.state = .playing
        player.observed(.state, generation: generation)
        XCTAssertTrue(player.frame.applyingStartPosition)
        XCTAssertEqual(engine.seeks, [])
        engine.frame.seekable = true
        player.observed(.seekable, generation: generation)
        player.observed(.state, generation: generation)
        XCTAssertEqual(engine.seeks, [.seconds(120)])
        XCTAssertFalse(player.frame.applyingStartPosition)
        XCTAssertEqual(events.filter { $0 == .resumePosition(.seconds(120)) }.count, 1)
    }

    func testUserSeekSupersedesPendingResumeAndFailedSeekIsClassified() {
        let engine = Engine()
        let controller = VLCPlaybackController(engine: engine), generation = UUID()
        var events: [VLCPlaybackEvent] = []
        controller.onEvent = { events.append($0) }
        controller.open(request(), generation: generation)
        engine.frame.seekable = true
        controller.seek(.seconds(300))
        controller.observed(.seekable, generation: generation)
        XCTAssertEqual(engine.seeks, [.seconds(300)])
        engine.rejectSeek = true
        controller.seek(.seconds(301))
        XCTAssertEqual(events.last, .operationRejected(.seek))
    }

    func testOldSurfaceCallbacksCannotMutateReplacementOrStoppedSession() {
        let engine = Engine(), player = VLCPlaybackController(engine: engine)
        let old = UUID(), current = UUID()
        var events: [VLCPlaybackEvent] = []
        player.onEvent = { events.append($0) }
        player.open(request(), generation: old)
        player.open(request(start: .seconds(200)), generation: current)
        engine.frame.state = .playing
        engine.frame.seekable = true
        player.observed(.state, generation: old)
        XCTAssertEqual(engine.seeks, [])
        XCTAssertTrue(events.isEmpty)
        player.observed(.state, generation: current)
        XCTAssertEqual(engine.seeks, [.seconds(200)])
        events.removeAll()
        player.stop()
        player.observed(.state, generation: current)
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(player.frame.applyingStartPosition)
    }

    func testPrematureNativeEndAfterSeekCannotAdvancePlayback() {
        let engine = Engine(), player = VLCPlaybackController(engine: engine), generation = UUID()
        var events: [VLCPlaybackEvent] = []
        player.onEvent = { events.append($0) }
        player.open(request(start: .seconds(113)), generation: generation)
        engine.frame.state = .paused
        engine.frame.seekable = true
        engine.frame.time = .seconds(118)
        player.seek(.seconds(133))
        engine.frame.time = .seconds(133)
        engine.frame.reachedEnd = true
        player.observed(.end, generation: generation)
        player.observed(.end, generation: generation)
        XCTAssertEqual(events, [.playbackFailed])
        XCTAssertFalse(events.contains(.naturalEnd(.seconds(900))))
    }

    func testNaturalEndRetainsLastClockWhenNativeStopResetsTime() {
        let engine = Engine(), player = VLCPlaybackController(engine: engine), generation = UUID()
        var events: [VLCPlaybackEvent] = []
        player.onEvent = { events.append($0) }
        player.open(request(start: .zero), generation: generation)
        engine.frame.state = .playing
        engine.frame.time = .seconds(899)
        player.observed(.clock, generation: generation)
        events.removeAll()
        engine.frame.state = .stopped
        engine.frame.time = .zero
        engine.frame.reachedEnd = true
        player.observed(.end, generation: generation)
        XCTAssertEqual(events, [.naturalEnd(.seconds(900))])
    }

    func testBackwardSeekCannotReuseAnEarlierNearEndClock() {
        let engine = Engine(), player = VLCPlaybackController(engine: engine), generation = UUID()
        var events: [VLCPlaybackEvent] = []
        player.onEvent = { events.append($0) }
        player.open(request(start: .zero), generation: generation)
        engine.frame.state = .playing
        engine.frame.seekable = true
        engine.frame.time = .seconds(899)
        player.observed(.clock, generation: generation)
        player.seek(.seconds(120))
        events.removeAll()
        engine.frame.state = .stopped
        engine.frame.time = .zero
        engine.frame.reachedEnd = true
        player.observed(.end, generation: generation)
        XCTAssertEqual(events, [.playbackFailed])
    }

    func testNaturalEndReportsTimelineOnceAndLiveStreamCannotAdvance() {
        let engine = Engine(), player = VLCPlaybackController(engine: engine), generation = UUID()
        var events: [VLCPlaybackEvent] = []
        player.onEvent = { events.append($0) }
        player.open(request(start: .zero), generation: generation)
        engine.frame.time = .seconds(900)
        engine.frame.reachedEnd = true
        player.observed(.end, generation: generation)
        player.observed(.end, generation: generation)
        XCTAssertEqual(events, [.naturalEnd(.seconds(900))])
        events.removeAll()
        let live = UUID()
        player.open(request(live: true), generation: live)
        player.observed(.end, generation: live)
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(player.frame.applyingStartPosition)
    }

    func testBufferReadinessWhilePausedDoesNotResumeTransportAndMetricsStayNumeric() {
        let engine = Engine(), player = VLCPlaybackController(engine: engine), generation = UUID()
        player.open(request(start: .zero), generation: generation)
        engine.frame.state = .playing
        engine.frame.bufferFill = 0.5
        engine.frame.displayedPictures = 2
        engine.frame.videoSize = CGSize(width: 720, height: 400)
        player.observed(.buffer, generation: generation)
        XCTAssertTrue(player.frame.buffering)
        engine.frame.state = .paused
        player.observed(.state, generation: generation)
        XCTAssertFalse(player.frame.buffering)
        player.observed(.buffer, generation: generation)
        XCTAssertTrue(player.frame.buffering)
        XCTAssertEqual(player.frame.state, .paused)
        engine.frame.bufferFill = 1
        player.observed(.buffer, generation: generation)
        XCTAssertFalse(player.frame.buffering)
        XCTAssertEqual(player.frame.state, .paused)
        XCTAssertEqual(player.frame.displayedPictures, 2)
        XCTAssertEqual(player.frame.videoSize.width, 720)
        XCTAssertFalse(String(describing: request()).contains("private-fixture"))
        XCTAssertFalse(String(reflecting: request()).contains("api_key"))
    }

    func testResumeCallbackCannotPublishStateFromRetiredPlayback() {
        for replaces in [false, true] {
            let engine = Engine(), player = VLCPlaybackController(engine: engine)
            let old = UUID(), new = UUID()
            var events: [VLCPlaybackEvent] = []
            player.onEvent = { event in
                events.append(event)
                if case .resumePosition = event {
                    if replaces {
                        player.open(self.request(start: .seconds(200)), generation: new)
                    } else {
                        player.stop()
                    }
                }
            }
            player.open(request(), generation: old)
            engine.frame.state = .playing
            engine.frame.seekable = true
            player.observed(.state, generation: old)
            XCTAssertEqual(events, [.resumePosition(.seconds(120))])
            XCTAssertEqual(player.frame.applyingStartPosition, replaces)
            player.onEvent = nil
        }
    }

    func testRetiredOpenFailureCannotClearReplacementResumeOrPublishFailure() {
        let engine = Engine(), player = VLCPlaybackController(engine: engine), id = UUID()
        var events: [VLCPlaybackEvent] = []
        player.onEvent = { events.append($0) }
        engine.afterOpen = {
            engine.afterOpen = nil
            player.open(self.request(start: .seconds(200)), generation: id)
            throw NSError(domain: "synthetic", code: 1)
        }
        player.open(request(), generation: id)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(player.frame.applyingStartPosition)
        engine.frame.seekable = true
        player.observed(.seekable, generation: id)
        XCTAssertEqual(engine.seeks, [.seconds(200)])
        player.onEvent = nil
    }

    func testRetiredSeekCannotMarkReplacementAsNaturallyComplete() {
        let engine = Engine(), player = VLCPlaybackController(engine: engine)
        let old = UUID(), new = UUID()
        var events: [VLCPlaybackEvent] = []
        player.onEvent = { events.append($0) }
        player.open(request(start: .zero), generation: old)
        engine.frame.seekable = true
        engine.afterSeek = {
            engine.afterSeek = nil
            player.open(self.request(start: .zero), generation: new)
        }
        player.seek(.seconds(899))
        engine.frame.time = .zero
        engine.frame.reachedEnd = true
        player.observed(.end, generation: new)
        XCTAssertEqual(events, [.playbackFailed])
        player.onEvent = nil
    }

    func testShutdownCancelsNativeUpdatesBeforeReleasingOutput() async {
        let engine = Engine(), player = VLCPlaybackController(engine: engine), generation = UUID()
        var updates = 0
        let subscription = player.updates.sink { updates += 1 }
        player.open(request(), generation: generation)
        engine.update?()
        XCTAssertEqual(updates, 1)
        player.stop()
        engine.update?()
        XCTAssertEqual(updates, 1)
        let released = await player.shutdown()
        XCTAssertTrue(released)
        XCTAssertEqual(engine.shutdowns, 1)
        XCTAssertNil(engine.update)
        withExtendedLifetime(subscription) {}
    }
}
