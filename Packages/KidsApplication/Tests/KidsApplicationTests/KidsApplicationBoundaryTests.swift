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
import KidsAccounts
@testable import KidsApplication
import KidsCatalog
import KidsDiagnostics
import KidsDomain
import KidsParentControl
import KidsPlaybackSession
import XCTest

@MainActor
final class KidsApplicationBoundaryTests: XCTestCase {
    private final class Accounts: KidsAccountHost {
        let changes = CurrentValueSubject<KidsAccountIdentity?, Never>(nil)
        var currentIdentity: KidsAccountIdentity? {
            changes.value
        }

        var identityChanges: AnyPublisher<KidsAccountIdentity?, Never> {
            changes.eraseToAnyPublisher()
        }

        struct StorageFailure: Error {}
        var savedPIN: String?
        var pinReadFails = false
        var parentPIN: String? {
            get throws {
                if pinReadFails {
                    throw StorageFailure()
                }
                return savedPIN
            }
        }

        var writes = 0
        var authentications = 0
        var signOuts = 0
        var receiver: KidsReceiverConfiguration?
        var receiverReadsFail = false
        var receiverWritesFail = false
        var receiverWrites = 0
        var receiverConfiguration: KidsReceiverConfiguration? {
            get throws {
                if receiverReadsFail {
                    throw StorageFailure()
                }
                return receiver
            }
        }

        func storeReceiverConfiguration(_ configuration: KidsReceiverConfiguration?) throws {
            receiverWrites += 1
            if receiverWritesFail {
                throw StorageFailure()
            }
            receiver = configuration
        }

        func storeParentPIN(_ pin: String) throws {
            writes += 1
            savedPIN = pin
        }

        func authenticate(
            url: URL,
            serverID: String,
            serverName: String,
            username: String,
            password: String
        ) async throws -> KidsAuthenticatedAccount {
            authentications += 1
            throw KidsContractError.denied
        }

        func signOut(validate: @escaping KidsAccountCheckpoint) async throws {
            try validate()
            signOuts += 1
            changes.send(nil)
        }
    }

    private final class PlaybackFactory: KidsPlaybackSessionFactory {
        var preparations = 0
        func prepare(
            item: KidsItem,
            title: KidsItem,
            mode: KidsPlaybackMode,
            position: Double,
            episodes: [KidsItem],
            delegate: any KidsPlaybackSessionDelegate,
            performance: KidsPerformanceSpan?,
            simulateStreamFailure: Bool
        ) async throws -> KidsPlaybackController {
            preparations += 1
            throw KidsContractError.denied
        }
    }

    private final class SuspendedDriver: KidsPlaybackDriver {
        var frame = KidsPlaybackFrame()
        let subject = PassthroughSubject<KidsPlaybackDriverEvent, Never>()
        var events: AnyPublisher<KidsPlaybackDriverEvent, Never> {
            subject.eraseToAnyPublisher()
        }

        let entered = AsyncStream<Void>.makeStream()
        var resume: CheckedContinuation<Void, Never>?
        var pauses = 0
        var stopsImmediately = false
        func start() {}
        func beginReporting() {}
        func togglePlayPause() {}
        func pause() {
            pauses += 1
        }

        func seek(seconds: Double) {}
        func stop() async {
            if stopsImmediately {
                entered.continuation.yield(())
                return
            }
            await withCheckedContinuation { continuation in
                resume = continuation
                entered.continuation.yield(())
            }
        }
    }

    private final class AdvancingClockDriver: KidsPlaybackDriver {
        var current = KidsPlaybackFrame()
        var next: KidsPlaybackFrame?
        var frame: KidsPlaybackFrame {
            let observed = current
            if let next {
                current = next
                self.next = nil
            }
            return observed
        }

        let subject = PassthroughSubject<KidsPlaybackDriverEvent, Never>()
        var events: AnyPublisher<KidsPlaybackDriverEvent, Never> {
            subject.eraseToAnyPublisher()
        }

        func start() {}
        func beginReporting() {}
        func togglePlayPause() {}
        func pause() {}
        func seek(seconds: Double) {}
        func stop() async {}
    }

    private func controller(_ item: KidsItem, driver: any KidsPlaybackDriver, model: KidsAppModel) -> KidsPlaybackController {
        KidsPlaybackController(item: item, title: item, mode: .movie, position: 0, episodes: [], driver: driver, delegate: model)
    }

    private actor ReceiverTransport: ParentHTTPTransport {
        var requests: [URLRequest] = []
        var policies: [String]
        var eventStatuses: [Int]
        var unconfirmedSessions: [UUID: String] = [:]
        var quarantinedDispositions: [UUID: UUID] = [:]
        let holdPolicy: Bool
        let conflictCode: String
        let policyEntered = AsyncStream<Void>.makeStream()
        var policyContinuation: CheckedContinuation<Void, Never>?

        init(policies: [String], eventStatuses: [Int] = [], holdPolicy: Bool = false, conflictCode: String = "lease_mismatch") {
            self.policies = policies
            self.eventStatuses = eventStatuses
            self.holdPolicy = holdPolicy
            self.conflictCode = conflictCode
        }

        func releasePolicy() {
            policyContinuation?.resume()
            policyContinuation = nil
        }

        func markUnconfirmed(_ event: ReceiverEvent, sessionID: String? = nil) {
            unconfirmedSessions[event.eventID] = sessionID ?? event.playbackSessionID
        }

        func markQuarantined(_ event: ReceiverEvent, dispositionID: UUID = UUID()) {
            quarantinedDispositions[event.eventID] = dispositionID
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let status: Int
            let data: Data
            if request.httpMethod == "POST" {
                status = eventStatuses.isEmpty ? 200 : eventStatuses.removeFirst()
                let event = try JSONDecoder().decode(ReceiverEvent.self, from: XCTUnwrap(request.httpBody))
                if status == 409 {
                    data = Data("{\"error\":\"\(conflictCode)\"}".utf8)
                } else {
                    var receipt: [String: Any] = ["commandID": event.eventID.uuidString, "status": "persisted"]
                    if let session = unconfirmedSessions[event.eventID] {
                        receipt["evidenceDisposition"] = "unconfirmed"
                        receipt["unconfirmedPlaybackSessionID"] = session
                    }
                    if let disposition = quarantinedDispositions[event.eventID] {
                        receipt["evidenceDisposition"] = "quarantined"
                        receipt["unconfirmedPlaybackSessionID"] = event.playbackSessionID
                        receipt["dispositionID"] = disposition.uuidString
                        receipt["usageCredited"] = false
                        receipt["unknownUsagePreserved"] = true
                    }
                    data = try JSONSerialization.data(withJSONObject: receipt)
                }
            } else {
                status = 200
                guard let json = policies.first else { throw ParentControlError.malformedResponse }
                if policies.count > 1 {
                    policies.removeFirst()
                }
                if holdPolicy {
                    await withCheckedContinuation { continuation in
                        policyContinuation = continuation
                        policyEntered.continuation.yield(())
                    }
                }
                data = Data(json.utf8)
            }
            return try (
                data,
                XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil))
            )
        }
    }

    /// Canned policy/receipt transport. It contains no quota/accounting engine;
    /// those semantics are separately replayed from the real backend fixture.
    private actor AdmissionTransport: ParentHTTPTransport {
        var requests: [URLRequest] = []
        var base: [String: Any]
        var prepared: [String: Any]?
        var bound = false
        var revision = 1
        var boundReplies = 0
        var loseIntentOnce: Bool
        var holdGrant: Bool
        var buildVerified = true
        var intentConflict: String?
        var eventConflict: String?
        let grantEntered = AsyncStream<Void>.makeStream()
        var grantContinuation: CheckedContinuation<Void, Never>?

        init(base: String, loseIntentOnce: Bool = false, holdGrant: Bool = false) throws {
            self.base = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(base.utf8)) as? [String: Any])
            self.loseIntentOnce = loseIntentOnce
            self.holdGrant = holdGrant
        }

        func releaseGrant() {
            holdGrant = false
            grantContinuation?.resume()
            grantContinuation = nil
        }

        func setResumeCommand(_ id: UUID, sessionID: String, expired: Bool = false) {
            base["commands"] = [[
                "commandID": id.uuidString,
                "action": "resume",
                "playbackSessionID": sessionID,
                "expiresAt": expired ? "2026-10-17T11:59:59.000Z" : "2026-10-17T12:00:30.000Z"
            ]]
        }

        func suspendNextGrant() {
            holdGrant = true
        }

        func setBuildVerified(_ verified: Bool) {
            buildVerified = verified
        }

        func setConflict(_ code: String?, events: Bool = false) {
            if events {
                eventConflict = code
            } else {
                intentConflict = code
            }
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let path = try XCTUnwrap(request.url?.lastPathComponent)
            if let code = path == "events" ? eventConflict : (path == "playback-intents" ? intentConflict : nil) {
                return try (
                    JSONSerialization.data(withJSONObject: ["error": code]),
                    XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 409, httpVersion: nil, headerFields: nil))
                )
            }
            if path == "playback-intents", !buildVerified {
                return try (
                    Data(#"{"error":"receiver_build_unverified","message":"Operator verification required"}"#.utf8),
                    XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 501, httpVersion: nil, headerFields: nil))
                )
            }
            var status = 200
            let object: [String: Any]
            if request.httpMethod == "GET" {
                if prepared != nil, !bound {
                    if holdGrant {
                        await withCheckedContinuation { continuation in
                            grantContinuation = continuation
                            grantEntered.continuation.yield(())
                        }
                    }
                    bound = true
                    revision += 1
                }
                var policy = base
                policy["revision"] = revision
                policy["policyControl"] = NSNull()
                policy["playbackIntentRequired"] = true
                policy["playbackIntentAvailable"] = !bound
                policy["viewingAllowed"] = bound
                policy["validUntil"] = bound ? "2026-10-17T12:00:30.000Z" : policy["serverTime"]
                policy["playbackIntentID"] = bound ? prepared?["commandID"] : NSNull()
                policy["leasePlaybackSessionID"] = bound ? prepared?["playbackSessionID"] : NSNull()
                policy["leaseItemID"] = bound ? prepared?["itemID"] : NSNull()
                if bound {
                    boundReplies += 1
                }
                object = policy
            } else {
                let data = try XCTUnwrap(request.httpBody)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                if path == "events" {
                    object = try ["commandID": XCTUnwrap(body["eventID"]), "status": "persisted"]
                } else {
                    let commandID = try XCTUnwrap(body["commandID"] as? String)
                    if path == "playback-intents" {
                        if prepared?["commandID"] as? String != commandID {
                            prepared = body
                            bound = false
                        }
                        if loseIntentOnce {
                            loseIntentOnce = false
                            status = 503
                        }
                    } else if path == "playback-surrenders" {
                        if body["playbackIntentID"] as? String == prepared?["commandID"] as? String {
                            prepared = nil
                            bound = false
                            revision += 1
                        }
                    } else {
                        throw ParentControlError.malformedResponse
                    }
                    object = ["commandID": commandID, "status": "persisted"]
                }
            }
            return try (JSONSerialization.data(withJSONObject: object), XCTUnwrap(HTTPURLResponse(
                url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil
            )))
        }
    }

    private final class AdmissionDriver: KidsPlaybackDriver {
        var frame = KidsPlaybackFrame()
        let subject = PassthroughSubject<KidsPlaybackDriverEvent, Never>()
        var events: AnyPublisher<KidsPlaybackDriverEvent, Never> {
            subject.eraseToAnyPublisher()
        }

        var starts = 0, stops = 0, toggles = 0
        func start() {
            starts += 1
        }

        func beginReporting() {}
        func seek(seconds: Double) {}
        func pause() {
            guard !frame.paused else { return }
            frame.paused = true
            frame.playing = false
            subject.send(.transport(paused: true, seconds: frame.seconds, terminal: frame.terminal))
        }

        func togglePlayPause() {
            toggles += 1
            frame.paused.toggle()
            frame.playing = !frame.paused
            subject.send(.transport(paused: frame.paused, seconds: frame.seconds, terminal: frame.terminal))
            subject.send(.updated)
        }

        func stop() async {
            stops += 1
            frame.playing = false
            frame.terminal = true
        }

        func advance(_ seconds: Double) {
            frame.seconds = seconds
            frame.displayedPictures += 1
            frame.playing = true
            frame.paused = false
            subject.send(.updated)
        }
    }

    private func grantHarness(
        loseIntentOnce: Bool = false,
        holdGrant: Bool = false
    ) async throws -> (KidsAppModel, KidsViewingRuntime, AdmissionTransport, URL) {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let transport = try AdmissionTransport(
            base: policyJSON(model, enabled: true, revision: 1, commandID: UUID()),
            loseIntentOnce: loseIntentOnce,
            holdGrant: holdGrant
        )
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        return (model, runtime, transport, directory)
    }

    private func policyJSON(_ model: KidsAppModel, enabled: Bool, revision: Int, commandID: UUID) -> String {
        // Same shape as the separately hash-verified backend enforcement fixture,
        // scoped here to this synthetic host and simulator installation.
        """
        {"serverID":"server","childUserID":"kid","deviceID":"\(model.receiverInstallationID)",
        "revision":\(revision),"enforcementEnabled":\(enabled),"serverTime":"2026-10-17T12:00:00.000Z",
        "validUntil":"2026-10-17T12:00:\(enabled ? "30" : "00").000Z","viewingAllowed":\(enabled),
        "blockedShowIDs":[],"blockedEpisodeIDs":[],"deadline":null,"finishPlaybackSessionID":null,"birdItemID":null,
        "policyControl":{"commandID":"\(commandID)","kind":"release"},
        "shuffle":{"preferUnwatched":false,"repeatCooldownDays":0,"preferredShowIDs":[]},"commands":[]}
        """
    }

    private func receiverHarness(activated: Bool = false) throws -> (KidsAppModel, Accounts, KidsReceiverConfiguration, URL) {
        let accounts = Accounts()
        accounts.changes.send(identity())
        let model = KidsAppModel(accounts: accounts, playbackFactory: PlaybackFactory())
        model.state = KidsState(binding: KidsBinding(serverID: "server", userID: "kid", showsID: "shows", moviesID: "movies"))
        let configuration = try KidsReceiverConfiguration(
            serviceURL: XCTUnwrap(URL(string: "http://127.0.0.1:9")), serverID: "server", childUserID: "kid",
            deviceID: XCTUnwrap(UUID(uuidString: model.receiverInstallationID)), token: "synthetic", activated: activated
        )
        accounts.receiver = configuration
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReceiverTests-\(UUID())", isDirectory: true)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        return (model, accounts, configuration, directory)
    }

    func testRecoveringAmbientRetiresOnceAndExhaustedAttemptsStayQuiet() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let controlID = UUID()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(
            policyJSON(model, enabled: true, revision: 1, commandID: controlID).utf8
        )) as? [String: Any])
        object["birdItemID"] = "bird"
        object["deadline"] = object["serverTime"]
        object["viewingAllowed"] = false
        object["policyControl"] = ["commandID": controlID.uuidString, "kind": "countdown"]
        let policyData = try JSONSerialization.data(withJSONObject: object)
        let policy = try XCTUnwrap(String(data: policyData, encoding: .utf8))
        let transport = ReceiverTransport(policies: [policy])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        model.ambientMode = true
        model.viewingHeld = true
        runtime.ambientControlID = controlID
        runtime.ambientAttempts = 3
        let bird = KidsItem(id: "bird", name: "Birds", kind: .movie, libraryID: "movies")
        let driver = AdmissionDriver()
        let ambient = controller(bird, driver: driver, model: model)
        ambient.allowsCheckpoints = false
        ambient.recovery = true
        runtime.ambientSessionID = ambient.id
        model.activePlayback = ambient
        model.state?.movies["normal-movie"] = KidsProgress(itemID: "normal-movie", seconds: 42)
        model.state?.session = KidsSession(showID: "normal-show", mode: .ordered, limit: 2)
        let originalState = model.state
        let requestsBefore = await transport.requests.count

        await model.tickViewingAmbient(runtime, at: DispatchTime.now().uptimeNanoseconds)
        await model.tickViewingAmbient(runtime, at: DispatchTime.now().uptimeNanoseconds)

        XCTAssertNil(model.activePlayback)
        XCTAssertEqual(driver.stops, 1)
        XCTAssertEqual(runtime.events.filter { $0.kind == .ambientFailed }.count, 1)
        XCTAssertEqual(runtime.events.last?.commandID, controlID)
        XCTAssertEqual(runtime.ambientAttempts, 3)
        XCTAssertFalse(runtime.ambientStarting)
        XCTAssertNil(runtime.ambientTask)
        XCTAssertTrue(model.ambientMode)
        XCTAssertTrue(model.viewingHeld)
        XCTAssertEqual(model.state, originalState)
        let requestsAfter = await transport.requests.count
        XCTAssertEqual(requestsAfter, requestsBefore)

        // A replacement normal controller cannot inherit the failed ambient ID.
        let replacementDriver = AdmissionDriver()
        let replacement = controller(bird, driver: replacementDriver, model: model)
        replacement.recovery = true
        model.activePlayback = replacement
        await model.tickViewingAmbient(runtime, at: DispatchTime.now().uptimeNanoseconds)
        XCTAssertTrue(model.activePlayback === replacement)
        XCTAssertEqual(replacementDriver.stops, 0)
        XCTAssertEqual(runtime.events.filter { $0.kind == .ambientFailed }.count, 1)
        model.activePlayback = nil
    }

    func testPolicyRefreshRetainsPermittedEpisodeMetadataAndAppliesCurrentBlocks() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let allowed = KidsItem(
            id: "allowed", name: "Allowed", kind: .episode, libraryID: "shows",
            seriesID: "show", season: 1, episode: 1
        )
        let blocked = KidsItem(
            id: "blocked", name: "Blocked", kind: .episode, libraryID: "shows",
            seriesID: "show", season: 1, episode: 2
        )
        model.episodeCache["show"] = [allowed, blocked]
        let policy = policyJSON(model, enabled: true, revision: 1, commandID: UUID())
            .replacingOccurrences(of: "\"blockedEpisodeIDs\":[]", with: "\"blockedEpisodeIDs\":[\"blocked\"]")
        let transport = ReceiverTransport(policies: [policy])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime

        try await model.synchronizeViewingPolicy(runtime)

        XCTAssertEqual(model.episodeCache["show"], [allowed])
        let binding = try XCTUnwrap(model.binding)
        XCTAssertTrue(model.permitsViewing(allowed, binding: binding))
        XCTAssertFalse(model.permitsViewing(blocked, binding: binding))
    }

    func testGrantAdmissionBrowsesWithoutIntentAndRequiresBoundPolicyBeforeStart() async throws {
        let (model, runtime, transport, _) = try await grantHarness()
        let driver = AdmissionDriver()
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        let binding = try XCTUnwrap(model.binding)
        try await model.acquireViewingLease()
        XCTAssertTrue(model.permitsViewing(playback.item, binding: binding))
        XCTAssertFalse(model.permitsViewingPlayback(playback, binding: binding))
        var requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.url?.lastPathComponent == "playback-intents" })
        try await model.admitViewingPlayback(playback, binding: binding)
        XCTAssertEqual(driver.starts, 0)
        XCTAssertTrue(model.permitsViewingPlayback(playback, binding: binding))
        requests = await transport.requests
        let index = try XCTUnwrap(requests.firstIndex { $0.url?.lastPathComponent == "playback-intents" })
        XCTAssertEqual(requests[index + 1].httpMethod, "GET")
        model.activePlayback = playback
        playback.start()
        driver.advance(0.25)
        XCTAssertEqual(runtime.events.first?.kind, .started)
        try await model.synchronizeViewingPolicy(runtime)
        await model.stopPlayback(endSession: false)
        try await model.synchronizeViewingPolicy(runtime)
        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(driver.stops, 1)
        XCTAssertNil(runtime.admission.intent)
        XCTAssertNil(runtime.admittedIntentID)
    }

    func testGrantPauseSurrendersBeforeSameControllerResumeAndNewObservedStart() async throws {
        let (model, runtime, transport, _) = try await grantHarness()
        let driver = AdmissionDriver()
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        try await model.admitViewingPlayback(playback, binding: XCTUnwrap(model.binding))
        let originalIntent = try XCTUnwrap(runtime.admittedIntentID)
        model.activePlayback = playback
        playback.start()
        driver.advance(0.25)
        try await model.synchronizeViewingPolicy(runtime)
        playback.toggle()
        try await model.synchronizeViewingPolicy(runtime)
        XCTAssertTrue(driver.frame.paused)
        XCTAssertEqual(runtime.heldSessionID, playback.id)
        XCTAssertNil(runtime.admission.intent)
        XCTAssertNil(runtime.announcedSessionID)
        let resume = try XCTUnwrap(model.requestViewingResume(playback, automatic: false))
        let resumed = await resume.value
        XCTAssertTrue(resumed)
        XCTAssertTrue(model.activePlayback === playback)
        XCTAssertEqual(driver.starts, 1)
        XCTAssertEqual(driver.toggles, 2)
        XCTAssertNotEqual(runtime.admittedIntentID, originalIntent)
        XCTAssertNil(runtime.announcedSessionID)
        driver.advance(1.25)
        await model.tickViewingAdmission(runtime, at: DispatchTime.now().uptimeNanoseconds)
        let started = try XCTUnwrap(runtime.events.first { $0.kind == .started })
        XCTAssertEqual(started.playbackSessionID, playback.id.uuidString)
        XCTAssertEqual(started.policyRevision, runtime.lease.policy?.revision)
        let requests = await transport.requests
        let paths = requests.compactMap { $0.url?.lastPathComponent }
        let firstSurrender = try XCTUnwrap(paths.firstIndex(of: "playback-surrenders"))
        let intents = paths.indices.filter { paths[$0] == "playback-intents" }
        XCTAssertEqual(intents.count, 2)
        XCTAssertLessThan(firstSurrender, intents[1])
        await model.stopPlayback(endSession: false)
        try await model.synchronizeViewingPolicy(runtime)
    }

    func testUnknownPreparedPostReplaysThenSurrendersBeforeRestartPolicyGet() async throws {
        let (model, runtime, transport, directory) = try await grantHarness(loseIntentOnce: true)
        let driver = AdmissionDriver()
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        do { try await model.admitViewingPlayback(playback, binding: XCTUnwrap(model.binding))
            XCTFail("Lost receipt must hold")
        } catch { XCTAssertEqual(error as? ParentControlError, .http(503)) }
        let captured = try XCTUnwrap(runtime.admission.intent)
        XCTAssertFalse(captured.persisted)
        await model.abandonPreparedViewing(playback)
        let before = await transport.requests
        let original = try XCTUnwrap(before.first { $0.url?.lastPathComponent == "playback-intents" })
        let recovered = try KidsViewingRuntime(configuration: runtime.configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = recovered
        try await model.synchronizeViewingPolicy(recovered)
        let after = await transport.requests
        let recovery = Array(after.dropFirst(before.count))
        let retry = try XCTUnwrap(recovery.firstIndex { $0.url?.lastPathComponent == "playback-intents" })
        let surrender = try XCTUnwrap(recovery.firstIndex { $0.url?.lastPathComponent == "playback-surrenders" })
        let get = try XCTUnwrap(recovery.firstIndex { $0.httpMethod == "GET" })
        XCTAssertEqual(recovery[retry].httpBody, original.httpBody)
        XCTAssertLessThan(retry, surrender)
        XCTAssertLessThan(surrender, get)
        XCTAssertNil(recovered.admission.intent)
        XCTAssertNil(recovered.admittedIntentID)
        XCTAssertEqual(driver.starts, 0)
        let boundReplies = await transport.boundReplies
        XCTAssertEqual(boundReplies, 0)
    }

    func testUnverifiedBuildRetainsOriginalRequestAcrossRestartUntilSafeRetirement() async throws {
        let (model, runtime, transport, directory) = try await grantHarness()
        await transport.setBuildVerified(false)
        let driver = AdmissionDriver()
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        do {
            try await model.admitViewingPlayback(playback, binding: XCTUnwrap(model.binding))
            XCTFail("An unverified build cannot acquire viewing authority")
        } catch { XCTAssertEqual(error as? ParentControlError, .unsupported) }
        let originalIntent = try XCTUnwrap(runtime.admission.intent)
        XCTAssertFalse(originalIntent.persisted)
        XCTAssertNil(runtime.admittedIntentID)
        XCTAssertEqual(driver.starts, 0)
        await model.abandonPreparedViewing(playback)
        let recovered = try KidsViewingRuntime(configuration: runtime.configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = recovered
        do {
            try await model.synchronizeViewingPolicy(recovered)
            XCTFail("Restart must preserve the refused request while verification is unavailable")
        } catch { XCTAssertEqual(error as? ParentControlError, .unsupported) }
        XCTAssertEqual(recovered.admission.intent?.commandID, originalIntent.commandID)
        XCTAssertEqual(recovered.admission.intent?.persisted, false)
        XCTAssertEqual(recovered.admission.intent?.abandoned, true)
        // Change only the injected test transport's gate. No real operator
        // record, credential or service is created by this synthetic test.
        await transport.setBuildVerified(true)
        try await model.synchronizeViewingPolicy(recovered)
        let requests = await transport.requests
        let attempts = requests.filter { $0.url?.lastPathComponent == "playback-intents" }
        XCTAssertEqual(attempts.count, 3)
        for request in attempts.dropFirst() {
            XCTAssertEqual(request.httpBody, attempts[0].httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), attempts[0].value(forHTTPHeaderField: "Idempotency-Key"))
        }
        let lastIntent = try XCTUnwrap(requests.lastIndex { $0.url?.lastPathComponent == "playback-intents" })
        XCTAssertEqual(requests[lastIntent + 1].url?.lastPathComponent, "playback-surrenders")
        XCTAssertEqual(requests[lastIntent + 2].httpMethod, "GET")
        XCTAssertNil(recovered.admission.intent)
        XCTAssertNil(recovered.admittedIntentID)
        let boundReplies = await transport.boundReplies
        XCTAssertEqual(boundReplies, 0)
        XCTAssertEqual(driver.starts, 0)
    }

    func testBackgroundWhileFreshGrantIsPendingCannotStartPreparedController() async throws {
        let (model, runtime, transport, _) = try await grantHarness(holdGrant: true)
        let driver = AdmissionDriver()
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        let binding = try XCTUnwrap(model.binding)
        let task = Task { try await model.admitViewingPlayback(playback, binding: binding) }
        for await _ in transport.grantEntered.stream {
            break
        }
        model.background()
        await transport.releaseGrant()
        do { try await task.value
            XCTFail("Late grant cannot undo background hold")
        } catch {}
        await model.abandonPreparedViewing(playback)
        XCTAssertEqual(driver.starts, 0)
        XCTAssertFalse(model.permitsViewingPlayback(playback, binding: binding))
        XCTAssertEqual(runtime.admission.intent?.abandoned, true)
        model.foregroundViewingControls()
        try await model.synchronizeViewingPolicy(runtime)
        XCTAssertNil(runtime.admission.intent)
    }

    func testBufferRecoveryRequiresNewReadySignalWhileHeld() async throws {
        let (model, runtime, _, _) = try await grantHarness()
        let driver = AdmissionDriver()
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        try await model.admitViewingPlayback(playback, binding: XCTUnwrap(model.binding))
        model.activePlayback = playback
        playback.start()
        driver.advance(0.25)
        try await model.synchronizeViewingPolicy(runtime)
        driver.frame.buffering = true
        driver.subject.send(.updated)
        try await model.synchronizeViewingPolicy(runtime)
        XCTAssertEqual(runtime.admissionHold, .buffering)
        XCTAssertTrue(driver.frame.paused)
        driver.frame.buffering = false
        driver.subject.send(.updated)
        XCTAssertNil(runtime.admissionFlight)
        XCTAssertEqual(driver.toggles, 0)
        driver.frame.bufferReadySequence = 1
        driver.subject.send(.updated)
        let recovery = try XCTUnwrap(runtime.admissionFlight?.task)
        let recovered = await recovery.value
        XCTAssertTrue(recovered)
        XCTAssertEqual(driver.toggles, 1)
        XCTAssertEqual(driver.starts, 1)
        XCTAssertTrue(model.activePlayback === playback)
        await model.stopPlayback(endSession: false)
        try await model.synchronizeViewingPolicy(runtime)
    }

    func testAdmissionJournalSurvivesUnknownPostWithoutCredentialsOrAuthority() throws {
        let (_, _, configuration, directory) = try receiverHarness(activated: true)
        let journal = try KidsAdmissionJournal(configuration: configuration, directory: directory)
        let id = UUID()
        try journal.stage(.init(commandID: id, expectedRevision: 2, sessionID: UUID().uuidString, itemID: "movie"))
        let restarted = try KidsAdmissionJournal(configuration: configuration, directory: directory)
        XCTAssertEqual(restarted.intent?.commandID, id)
        XCTAssertEqual(restarted.intent?.expectedRevision, 2)
        XCTAssertEqual(restarted.intent?.persisted, false)
        XCTAssertEqual(restarted.intent?.abandoned, true)
        let surrenderID = try XCTUnwrap(restarted.surrender?.commandID)
        let restartedAgain = try KidsAdmissionJournal(configuration: configuration, directory: directory)
        XCTAssertEqual(restartedAgain.surrender?.commandID, surrenderID)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "json" {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains(configuration.token))
            XCTAssertFalse(text.contains("validUntil"))
            XCTAssertFalse(text.contains("viewingAllowed"))
        }
    }

    func testRemoteResumeRequestsFreshIntentWithoutDeadlockAndAcknowledgesDeliveryRevision() async throws {
        let (model, runtime, transport, _) = try await grantHarness()
        let driver = AdmissionDriver()
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        try await model.admitViewingPlayback(playback, binding: XCTUnwrap(model.binding))
        model.activePlayback = playback
        playback.start()
        driver.advance(0.25)
        try await model.synchronizeViewingPolicy(runtime)
        playback.toggle()
        try await model.synchronizeViewingPolicy(runtime)
        let deliveryRevision = try XCTUnwrap(runtime.lease.policy?.revision)
        let commandID = UUID()
        await transport.setResumeCommand(commandID, sessionID: playback.id.uuidString)
        try await model.synchronizeViewingPolicy(runtime)
        // The refresh returns before admission's separate policy flight. An
        // inline wait here would deadlock on that very refresh.
        for _ in 0 ..< 1000 {
            if runtime.events.contains(where: { $0.commandID == commandID }) {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        let acknowledgement = try XCTUnwrap(runtime.events.first { $0.commandID == commandID })
        XCTAssertEqual(acknowledgement.kind, .commandApplied)
        XCTAssertEqual(acknowledgement.policyRevision, deliveryRevision)
        XCTAssertGreaterThan(try XCTUnwrap(runtime.lease.policy?.revision), deliveryRevision)
        XCTAssertFalse(driver.frame.paused)
        XCTAssertEqual(driver.starts, 1)
        await model.stopPlayback(endSession: false)
        try await model.synchronizeViewingPolicy(runtime)
    }

    func testRemoteResumeRechecksExpiredControlAfterFreshGrantWait() async throws {
        let (model, runtime, transport, _) = try await grantHarness()
        let driver = AdmissionDriver()
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        try await model.admitViewingPlayback(playback, binding: XCTUnwrap(model.binding))
        model.activePlayback = playback
        playback.start()
        driver.advance(0.25)
        try await model.synchronizeViewingPolicy(runtime)
        playback.toggle()
        try await model.synchronizeViewingPolicy(runtime)
        let commandID = UUID()
        await transport.setResumeCommand(commandID, sessionID: playback.id.uuidString)
        await transport.suspendNextGrant()
        try await model.synchronizeViewingPolicy(runtime)
        for await _ in transport.grantEntered.stream {
            break
        }
        // Simulate expiration on the fresh server-clock response while the
        // network was suspended, without a thirty-second wall-clock test.
        await transport.setResumeCommand(commandID, sessionID: playback.id.uuidString, expired: true)
        await transport.releaseGrant()
        for _ in 0 ..< 1000 {
            if runtime.events.contains(where: { $0.commandID == commandID }) {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        let acknowledgement = try XCTUnwrap(runtime.events.first { $0.commandID == commandID })
        XCTAssertEqual(acknowledgement.kind, .commandFailed)
        XCTAssertTrue(driver.frame.paused)
        XCTAssertEqual(driver.toggles, 1) // Only the original explicit pause.
        XCTAssertEqual(runtime.admission.intent?.abandoned, true)
        await model.stopPlayback(endSession: false)
        try await model.synchronizeViewingPolicy(runtime)
    }

    func testAdmissionJournalRejectsCorruptOrForeignScopeWithoutReplacingBytes() throws {
        let (_, _, configuration, directory) = try receiverHarness(activated: true)
        let journal = try KidsAdmissionJournal(configuration: configuration, directory: directory)
        try journal.stage(.init(commandID: UUID(), expectedRevision: 2, sessionID: "controller", itemID: "movie"))
        let files = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        let url = try XCTUnwrap(files.allObjects.compactMap { $0 as? URL }.first { $0.pathExtension == "json" })
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var scope = try XCTUnwrap(state["scope"] as? [String: Any])
        scope["child"] = "another-child"
        state["scope"] = scope
        let foreign = try JSONSerialization.data(withJSONObject: state)
        try foreign.write(to: url)
        XCTAssertThrowsError(try KidsAdmissionJournal(configuration: configuration, directory: directory))
        XCTAssertEqual(try Data(contentsOf: url), foreign)
        let corrupt = Data("{incomplete".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try KidsAdmissionJournal(configuration: configuration, directory: directory))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    private func admissionFile(in directory: URL) throws -> URL {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        return try XCTUnwrap(files.allObjects.compactMap { $0 as? URL }.first {
            $0.pathExtension == "json" && $0.path.contains("/Admissions/") && !$0.lastPathComponent.hasPrefix("epoch-recovery-")
        })
    }

    func testUnknownUsageReceiptReplaysExactFIFOAfterRuntimeRestart() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let transport = ReceiverTransport(
            policies: [policyJSON(model, enabled: true, revision: 4, commandID: UUID())],
            eventStatuses: [500, 200, 200]
        )
        let original = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = original
        let session = UUID().uuidString
        let reports = [
            ReceiverEvent(
                deviceID: configuration.deviceID.uuidString,
                childUserID: configuration.childUserID,
                policyRevision: 2,
                playbackSessionID: session,
                itemID: "movie",
                kind: .progress,
                positionSeconds: 7.195,
                elapsedPlayingSeconds: 0.01200000000000001
            ),
            ReceiverEvent(
                deviceID: configuration.deviceID.uuidString,
                childUserID: configuration.childUserID,
                policyRevision: 2,
                playbackSessionID: session,
                itemID: "movie",
                kind: .stopped,
                positionSeconds: 7.213
            )
        ]
        for event in reports {
            try original.admission.appendEvent(event)
        }
        do { try await model.synchronizeViewingPolicy(original)
            XCTFail("Unknown receipt must retain exact evidence")
        } catch { XCTAssertEqual(error as? ParentControlError, .http(500)) }
        let restarted = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        XCTAssertEqual(restarted.events, reports)
        XCTAssertNil(restarted.lease.policy)
        XCTAssertNil(restarted.admittedIntentID)
        model.viewingRuntime = restarted
        try await model.synchronizeViewingPolicy(restarted)
        let requests = await transport.requests
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Idempotency-Key"), requests[1].value(forHTTPHeaderField: "Idempotency-Key"))
        let replayed = try requests.prefix(3).map { try JSONDecoder().decode(ReceiverEvent.self, from: XCTUnwrap($0.httpBody)) }
        XCTAssertEqual(replayed, [reports[0], reports[0], reports[1]])
        XCTAssertEqual(requests[3].httpMethod, "GET")
        XCTAssertFalse(restarted.events.contains { reports.map(\.eventID).contains($0.eventID) })
        let file = try admissionFile(in: directory)
        XCTAssertEqual(try (FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(try String(decoding: Data(contentsOf: file), as: UTF8.self).contains(configuration.token))
    }

    func testUsageFIFORejectsOutOfOrderAckAndSurvivesAcknowledgementWriteFailure() throws {
        let (_, _, configuration, directory) = try receiverHarness(activated: true)
        let journal = try KidsAdmissionJournal(configuration: configuration, directory: directory)
        let events = (0 ..< 2).map { _ in ReceiverEvent(
            deviceID: configuration.deviceID.uuidString,
            childUserID: configuration.childUserID,
            policyRevision: 2,
            kind: .heartbeat
        ) }
        for event in events {
            try journal.appendEvent(event)
        }
        let file = try admissionFile(in: directory), before = try Data(contentsOf: file)
        XCTAssertThrowsError(try journal.acknowledgeEvent(events[1].eventID))
        XCTAssertEqual(try Data(contentsOf: file), before)
        let folder = file.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        XCTAssertThrowsError(try journal.acknowledgeEvent(events[0].eventID))
        XCTAssertEqual(journal.events, events)
        XCTAssertEqual(try Data(contentsOf: file), before)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let restarted = try KidsAdmissionJournal(configuration: configuration, directory: directory)
        XCTAssertEqual(restarted.events, events)
        try restarted.acknowledgeEvent(events[0].eventID)
        XCTAssertEqual(try KidsAdmissionJournal(configuration: configuration, directory: directory).events, [events[1]])
    }

    func testUsageFIFOEnforcesCapacityIdentityScopeAndStoredSchema() throws {
        let (_, _, configuration, directory) = try receiverHarness(activated: true)
        let journal = try KidsAdmissionJournal(configuration: configuration, directory: directory)
        let event = ReceiverEvent(
            deviceID: configuration.deviceID.uuidString,
            childUserID: configuration.childUserID,
            policyRevision: 2,
            kind: .heartbeat
        )
        try journal.appendEvent(event)
        XCTAssertThrowsError(try journal.appendEvent(event))
        let foreign = ReceiverEvent(
            deviceID: configuration.deviceID.uuidString,
            childUserID: "another-child",
            policyRevision: 2,
            kind: .heartbeat
        )
        XCTAssertThrowsError(try journal.appendEvent(foreign))
        for _ in 1 ..< 128 {
            try journal.appendEvent(ReceiverEvent(
                deviceID: configuration.deviceID.uuidString,
                childUserID: configuration.childUserID,
                policyRevision: 2,
                kind: .heartbeat
            ))
        }
        let file = try admissionFile(in: directory), full = try Data(contentsOf: file)
        XCTAssertThrowsError(try journal.appendEvent(ReceiverEvent(
            deviceID: configuration.deviceID.uuidString,
            childUserID: configuration.childUserID,
            policyRevision: 2,
            kind: .heartbeat
        )))
        XCTAssertEqual(try Data(contentsOf: file), full)
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: full) as? [String: Any])
        state.removeValue(forKey: "events")
        let missing = try JSONSerialization.data(withJSONObject: state)
        try missing.write(to: file)
        XCTAssertThrowsError(try KidsAdmissionJournal(configuration: configuration, directory: directory))
        XCTAssertEqual(try Data(contentsOf: file), missing)
        state["events"] = try [JSONSerialization.jsonObject(with: JSONEncoder().encode(foreign))]
        let wrong = try JSONSerialization.data(withJSONObject: state)
        try wrong.write(to: file)
        XCTAssertThrowsError(try KidsAdmissionJournal(configuration: configuration, directory: directory))
        XCTAssertEqual(try Data(contentsOf: file), wrong)
    }

    func testV1AdmissionMigrationRetainsUnknownIntentWithoutInventingReports() throws {
        let (_, _, configuration, directory) = try receiverHarness(activated: true)
        let journal = try KidsAdmissionJournal(configuration: configuration, directory: directory)
        let command = UUID()
        try journal.stage(.init(commandID: command, expectedRevision: 2, sessionID: "controller", itemID: "movie"))
        let file = try admissionFile(in: directory)
        var v1 = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        v1["version"] = 1
        v1.removeValue(forKey: "events")
        try JSONSerialization.data(withJSONObject: v1).write(to: file)
        let migrated = try KidsAdmissionJournal(configuration: configuration, directory: directory)
        XCTAssertEqual(migrated.intent?.commandID, command)
        XCTAssertTrue(migrated.intent?.abandoned == true)
        XCTAssertEqual(migrated.surrender?.intentID, command)
        XCTAssertTrue(migrated.events.isEmpty)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(state["version"] as? Int, 2)
        XCTAssertEqual((state["events"] as? [Any])?.count, 0)
    }

    func testEventPersistenceFailureHoldsPlaybackAndRetainsEarlierEvidence() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let driver = SuspendedDriver()
        driver.stopsImmediately = true
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        model.activePlayback = playback
        let transport = ReceiverTransport(policies: [policyJSON(model, enabled: true, revision: 2, commandID: UUID())])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        let previous = runtime.events
        let folder = try admissionFile(in: directory).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        playback.start()
        driver.frame.playing = true
        driver.frame.preparing = false
        driver.frame.buffering = false
        driver.frame.seconds = 0.202
        driver.frame.displayedPictures = 1
        driver.subject.send(.updated)
        XCTAssertTrue(runtime.reportingFault)
        XCTAssertEqual(runtime.events, previous)
        XCTAssertNil(runtime.announcedSessionID)
        await model.tickViewingAdmission(runtime, at: DispatchTime.now().uptimeNanoseconds)
        XCTAssertTrue(model.viewingHeld)
        XCTAssertNil(model.activePlayback)
        XCTAssertEqual(runtime.events, previous)
    }

    func testEpochArchivePreservesPendingActionsAndEvidenceBeforeClearingRetrySlots() throws {
        let (_, _, configuration, directory) = try receiverHarness(activated: true)
        let journal = try KidsAdmissionJournal(configuration: configuration, directory: directory)
        let id = UUID(), session = UUID().uuidString
        try journal.stage(.init(commandID: id, expectedRevision: 2, sessionID: session, itemID: "movie"))
        try journal.abandon(id)
        let surrender = try XCTUnwrap(journal.surrender)
        let report = ReceiverEvent(
            deviceID: configuration.deviceID.uuidString,
            childUserID: configuration.childUserID,
            policyRevision: 2,
            playbackSessionID: session,
            itemID: "movie",
            kind: .progress,
            positionSeconds: 4,
            elapsedPlayingSeconds: 1
        )
        try journal.appendEvent(report)
        let archive = try journal.archiveForEpochRecovery()
        let data = try Data(contentsOf: archive)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["reason"] as? String, "command_epoch_changed")
        let saved = try XCTUnwrap(object["journal"] as? [String: Any])
        let intent = try XCTUnwrap(saved["intent"] as? [String: Any])
        XCTAssertEqual(intent["commandID"] as? String, id.uuidString)
        let savedSurrender = try XCTUnwrap(saved["surrender"] as? [String: Any])
        XCTAssertEqual(savedSurrender["commandID"] as? String, surrender.commandID.uuidString)
        let events = try JSONSerialization.data(withJSONObject: XCTUnwrap(object["events"]))
        XCTAssertEqual(try JSONDecoder().decode([ReceiverEvent].self, from: events), [report])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains(configuration.token))
        XCTAssertFalse(text.contains("validUntil"))
        XCTAssertFalse(text.contains("viewingAllowed"))
        let permissions = try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertNil(journal.intent)
        XCTAssertTrue(journal.events.isEmpty)
        let restarted = try KidsAdmissionJournal(configuration: configuration, directory: directory)
        XCTAssertNil(restarted.intent)
        XCTAssertNil(restarted.surrender)
    }

    func testFailedEpochArchiveLeavesOriginalPendingActionIntact() throws {
        let (_, _, configuration, directory) = try receiverHarness(activated: true)
        let journal = try KidsAdmissionJournal(configuration: configuration, directory: directory)
        let id = UUID()
        try journal.stage(.init(commandID: id, expectedRevision: 2, sessionID: "controller", itemID: "movie"))
        let files = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        let file = try XCTUnwrap(files.allObjects.compactMap { $0 as? URL }.first { $0.pathExtension == "json" })
        let folder = file.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        XCTAssertThrowsError(try journal.archiveForEpochRecovery())
        XCTAssertEqual(journal.intent?.commandID, id)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let restarted = try KidsAdmissionJournal(configuration: configuration, directory: directory)
        XCTAssertEqual(restarted.intent?.commandID, id)
    }

    func testEpochMutationRecoveryRequiresParentUnlockAndPreservesEnforcementConfiguration() async throws {
        let (model, runtime, transport, directory) = try await grantHarness()
        await transport.setConflict("command_epoch_changed")
        let driver = AdmissionDriver()
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        do {
            try await model.admitViewingPlayback(playback, binding: XCTUnwrap(model.binding))
            XCTFail("An old epoch cannot acquire authority")
        } catch { XCTAssertEqual(error as? ReceiverMutationConflict, ReceiverMutationConflict(code: "command_epoch_changed")) }
        XCTAssertTrue(runtime.epochRecoveryRequired)
        let oldID = try XCTUnwrap(runtime.admission.intent?.commandID)
        do { try await model.archiveViewingRecovery()
            XCTFail("A parent unlock is required")
        } catch {}
        XCTAssertEqual(runtime.admission.intent?.commandID, oldID)
        let configuration = runtime.configuration
        XCTAssertTrue(configuration.activated && configuration.requiresPlaybackGrants)
        XCTAssertTrue(model.gate.attempt(correct: true, now: .now))
        XCTAssertTrue(model.canArchiveViewingRecovery)
        try await model.archiveViewingRecovery()
        XCTAssertFalse(model.viewingRuntime === runtime)
        XCTAssertEqual(model.viewingRuntime?.configuration, configuration)
        XCTAssertEqual(runtime.configuration, configuration)
        XCTAssertNil(runtime.admission.intent)
        XCTAssertTrue(runtime.events.isEmpty)
        XCTAssertTrue(model.viewingHeld)
        XCTAssertNil(runtime.lease.policy)
        XCTAssertNil(runtime.admittedIntentID)
        XCTAssertFalse(model.canArchiveViewingRecovery)
        XCTAssertEqual(driver.starts, 0)
        XCTAssertEqual(driver.stops, 1)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        XCTAssertEqual(files.allObjects.compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasPrefix("epoch-recovery-") }.count, 1)
    }

    func testEpochEventRecoveryArchivesOriginalReportWithoutAcknowledgingIt() async throws {
        let (model, runtime, transport, directory) = try await grantHarness()
        let event = ReceiverEvent(
            deviceID: runtime.configuration.deviceID.uuidString,
            childUserID: runtime.configuration.childUserID,
            policyRevision: 1,
            playbackSessionID: "old-controller",
            itemID: "movie",
            kind: .progress,
            positionSeconds: 5,
            elapsedPlayingSeconds: 2
        )
        try runtime.admission.appendEvent(event)
        await transport.setConflict("command_epoch_changed", events: true)
        do { try await model.synchronizeViewingPolicy(runtime)
            XCTFail("Old evidence remains unacknowledged")
        } catch { XCTAssertEqual(error as? ReceiverEventConflict, ReceiverEventConflict(code: "command_epoch_changed")) }
        XCTAssertEqual(runtime.events, [event])
        XCTAssertTrue(model.gate.attempt(correct: true, now: .now))
        try await model.archiveViewingRecovery()
        let files = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        let archive = try XCTUnwrap(files.allObjects.compactMap { $0 as? URL }.first { $0.lastPathComponent.hasPrefix("epoch-recovery-") })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: archive)) as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: XCTUnwrap(object["events"]))
        XCTAssertEqual(try JSONDecoder().decode([ReceiverEvent].self, from: data), [event])
        XCTAssertTrue(runtime.events.isEmpty && model.viewingHeld)
    }

    func testOtherIntegrityFaultsCannotEnableEpochArchival() async throws {
        let (model, runtime, transport, _) = try await grantHarness()
        await transport.setConflict("idempotency_conflict")
        let playback = controller(
            KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"),
            driver: AdmissionDriver(),
            model: model
        )
        do { try await model.admitViewingPlayback(playback, binding: XCTUnwrap(model.binding))
            XCTFail("Integrity conflict must hold")
        } catch {}
        let id = try XCTUnwrap(runtime.admission.intent?.commandID)
        XCTAssertTrue(model.gate.attempt(correct: true, now: .now))
        XCTAssertFalse(model.canArchiveViewingRecovery)
        do { try await model.archiveViewingRecovery()
            XCTFail("Only a structured epoch fault permits this recovery")
        } catch {}
        XCTAssertEqual(runtime.admission.intent?.commandID, id)
        await model.abandonPreparedViewing(playback)
    }

    func testAdmissionDrainRetiresCompletedSharedFlightBeforeSendingStagedIntent() async throws {
        let (model, runtime, _, _) = try await grantHarness()
        let driver = AdmissionDriver()
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        runtime.admissionController = playback
        try runtime.admission.stage(.init(
            commandID: UUID(),
            expectedRevision: 1,
            sessionID: playback.id.uuidString,
            itemID: playback.item.id
        ))
        let finished = Task<Void, Error> {}
        try await finished.value
        runtime.policyFlight = (UUID(), finished)
        try await model.drainViewingAdmission(runtime)
        XCTAssertEqual(runtime.admission.intent?.persisted, true)
        XCTAssertEqual(runtime.lease.policy?.playbackIntentID, runtime.admission.intent?.commandID)
        XCTAssertNil(runtime.policyFlight)
        await model.abandonPreparedViewing(playback)
        try await model.synchronizeViewingPolicy(runtime)
    }

    func testResumedGrantWithoutNewPlaybackCannotRelabelOldTerminalEvidence() async throws {
        let (model, runtime, transport, _) = try await grantHarness()
        let driver = AdmissionDriver()
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        let binding = try XCTUnwrap(model.binding)
        try await model.admitViewingPlayback(playback, binding: binding)
        model.activePlayback = playback
        playback.start()
        driver.advance(0.25)
        try await model.synchronizeViewingPolicy(runtime)
        let observedRevision = try XCTUnwrap(runtime.normalGrant?.revision)
        driver.frame.buffering = true
        driver.subject.send(.updated)
        try await model.synchronizeViewingPolicy(runtime)
        XCTAssertNil(runtime.announcedSessionID)
        await transport.suspendNextGrant()
        driver.frame.buffering = false
        driver.frame.bufferReadySequence = 1
        driver.subject.send(.updated)
        let recovery = try XCTUnwrap(runtime.admissionFlight?.task)
        for await _ in transport.grantEntered.stream {
            break
        }
        // Readiness can disappear during an admission round trip. The grant
        // exists, but the final automatic-resume check must hold transport.
        driver.frame.preparing = true
        await transport.releaseGrant()
        let resumed = await recovery.value
        XCTAssertFalse(resumed)
        XCTAssertGreaterThan(try XCTUnwrap(runtime.lease.policy?.revision), observedRevision)
        XCTAssertEqual(runtime.normalGrant?.revision, observedRevision)
        XCTAssertTrue(driver.frame.paused)
        await model.stopPlayback(endSession: false)
        let stop = try XCTUnwrap(runtime.events.first { $0.kind == .stopped })
        XCTAssertEqual(stop.policyRevision, observedRevision)
        XCTAssertFalse(runtime.events.contains { $0.kind == .started })
        try await model.synchronizeViewingPolicy(runtime)
    }

    func testReceiverActivationAndExplicitReleaseUseDurableHostState() async throws {
        let (model, accounts, configuration, directory) = try receiverHarness()
        let enableID = UUID(), disableID = UUID()
        let transport = ReceiverTransport(policies: [
            policyJSON(model, enabled: true, revision: 2, commandID: enableID),
            policyJSON(model, enabled: false, revision: 3, commandID: disableID)
        ])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        XCTAssertTrue(runtime.configuration.activated)
        XCTAssertEqual(accounts.receiver?.activated, true)
        XCTAssertFalse(model.viewingHeld)
        XCTAssertEqual(runtime.events.first?.commandID, enableID)
        try await model.synchronizeViewingPolicy(runtime)
        XCTAssertFalse(runtime.configuration.activated)
        XCTAssertEqual(accounts.receiver?.activated, false)
        XCTAssertEqual(accounts.receiverWrites, 2)
        XCTAssertFalse(model.viewingHeld)
        XCTAssertEqual(runtime.events.first?.commandID, disableID)
    }

    func testReceiverCannotGrantPlaybackWhenActivationPersistenceFails() async throws {
        let (model, accounts, configuration, directory) = try receiverHarness()
        accounts.receiverWritesFail = true
        let transport = ReceiverTransport(policies: [policyJSON(model, enabled: true, revision: 2, commandID: UUID())])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        do { try await model.synchronizeViewingPolicy(runtime)
            XCTFail("Activation must be durable before playback")
        } catch { XCTAssertTrue(error is Accounts.StorageFailure) }
        XCTAssertFalse(runtime.configuration.activated)
        XCTAssertEqual(accounts.receiver?.activated, false)
        XCTAssertTrue(model.viewingHeld)
        let binding = try XCTUnwrap(model.binding)
        XCTAssertFalse(model.permitsViewing(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), binding: binding))
    }

    func testRequiredGrantModePersistsAndRejectsMissingFieldsOnLaterPolicy() async throws {
        let (model, accounts, configuration, directory) = try receiverHarness(activated: true)
        let json = policyJSON(model, enabled: true, revision: 2, commandID: UUID())
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8))
        var fields = try XCTUnwrap(decoded as? [String: Any])
        fields["playbackIntentRequired"] = true
        fields["playbackIntentAvailable"] = true
        fields["playbackIntentID"] = NSNull()
        fields["leasePlaybackSessionID"] = NSNull()
        fields["leaseItemID"] = NSNull()
        fields["viewingAllowed"] = false
        fields["validUntil"] = fields["serverTime"]
        let idle = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: fields), encoding: .utf8))
        let transport = ReceiverTransport(policies: [idle, policyJSON(model, enabled: true, revision: 3, commandID: UUID())])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        XCTAssertTrue(runtime.configuration.requiresPlaybackGrants)
        XCTAssertEqual(accounts.receiver?.requiresPlaybackGrants, true)
        XCTAssertFalse(model.viewingHeld)
        let movie = KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies")
        XCTAssertTrue(try model.permitsViewing(movie, binding: XCTUnwrap(model.binding)))
        XCTAssertFalse(try model.permitsViewingPlayback(
            controller(movie, driver: SuspendedDriver(), model: model),
            binding: XCTUnwrap(model.binding)
        ))
        do { try await model.synchronizeViewingPolicy(runtime)
            XCTFail("A learned grant requirement cannot downgrade on missing fields")
        } catch { XCTAssertEqual(error as? ParentControlError, .malformedResponse) }
        XCTAssertTrue(runtime.reportingFault)
        XCTAssertTrue(runtime.configuration.requiresPlaybackGrants)
        XCTAssertEqual(runtime.lease.policy?.revision, 2)
    }

    func testBoundPolicyCannotAuthorizeUnrequestedIntentOrDifferentController() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let movie = KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies")
        let prepared = controller(movie, driver: SuspendedDriver(), model: model)
        let intentID = UUID()
        let decoded = try JSONSerialization.jsonObject(with: Data(policyJSON(model, enabled: true, revision: 2, commandID: UUID()).utf8))
        var fields = try XCTUnwrap(decoded as? [String: Any])
        fields["playbackIntentRequired"] = true
        fields["playbackIntentAvailable"] = false
        fields["playbackIntentID"] = intentID.uuidString
        fields["leasePlaybackSessionID"] = prepared.id.uuidString
        fields["leaseItemID"] = movie.id
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: fields), encoding: .utf8))
        let runtime = try KidsViewingRuntime(
            configuration: configuration,
            transport: ReceiverTransport(policies: [json]),
            ledgerDirectory: directory
        )
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        let binding = try XCTUnwrap(model.binding)
        XCTAssertFalse(model.permitsViewingPlayback(prepared, binding: binding))
        // Inject the result of a future verified admission flow; the current
        // scaffold does not issue intents or set this state by itself.
        runtime.admittedIntentID = intentID
        XCTAssertTrue(model.permitsViewingPlayback(prepared, binding: binding))
        runtime.reportingFault = true
        XCTAssertFalse(model.permitsViewingPlayback(prepared, binding: binding))
        runtime.reportingFault = false
        let other = controller(movie, driver: SuspendedDriver(), model: model)
        XCTAssertFalse(model.permitsViewingPlayback(other, binding: binding))
        runtime.admittedIntentID = UUID()
        XCTAssertFalse(model.permitsViewingPlayback(prepared, binding: binding))
        XCTAssertFalse(prepared.hasBegunPlayback)
    }

    func testBootstrapHeartbeatConflictCanRecoverWithoutDiscardingUsage() async throws {
        let (model, _, configuration, directory) = try receiverHarness()
        let transport = ReceiverTransport(
            policies: [policyJSON(model, enabled: true, revision: 2, commandID: UUID())],
            eventStatuses: [409]
        )
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        XCTAssertTrue(runtime.configuration.activated)
        let requests = await transport.requests
        let heartbeat = try JSONDecoder().decode(ReceiverEvent.self, from: XCTUnwrap(requests.first?.httpBody))
        XCTAssertEqual(heartbeat.kind, .heartbeat)
        XCTAssertEqual(heartbeat.policyRevision, 0)
        XCTAssertNil(heartbeat.playbackSessionID)
        XCTAssertNil(heartbeat.positionSeconds)
        XCTAssertEqual(heartbeat.elapsedPlayingSeconds, 0)
        XCTAssertEqual(requests.filter { $0.httpMethod == "GET" }.count, 1)
    }

    func testFailedUsageReceiptRetriesExactEventBeforeFetchingPolicy() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let transport = ReceiverTransport(
            policies: [policyJSON(model, enabled: true, revision: 4, commandID: UUID())],
            eventStatuses: [500, 200]
        )
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        let event = ReceiverEvent(
            deviceID: configuration.deviceID.uuidString,
            childUserID: "kid",
            policyRevision: 2,
            playbackSessionID: UUID().uuidString,
            itemID: "movie",
            kind: .progress,
            positionSeconds: 7,
            elapsedPlayingSeconds: 3
        )
        try runtime.admission.appendEvent(event)
        do { try await model.synchronizeViewingPolicy(runtime)
            XCTFail("Lost receipt must remain queued")
        } catch { XCTAssertEqual(error as? ParentControlError, .http(500)) }
        XCTAssertEqual(runtime.events, [event])
        let failedRequests = await transport.requests
        XCTAssertEqual(failedRequests.count, 1)
        try await model.synchronizeViewingPolicy(runtime)
        let requests = await transport.requests
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Idempotency-Key"), requests[1].value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(requests[2].httpMethod, "GET")
        XCTAssertFalse(runtime.events.contains(where: { $0.eventID == event.eventID }))
    }

    func testConcurrentReceiverRefreshesShareOnePolicyRequest() async throws {
        let (model, _, configuration, directory) = try receiverHarness()
        let transport = ReceiverTransport(policies: [policyJSON(model, enabled: true, revision: 2, commandID: UUID())], holdPolicy: true)
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        let first = Task { try await model.synchronizeViewingPolicy(runtime) }
        let entered = await transport.policyEntered.stream
        for await _ in entered {
            break
        }
        let joining = AsyncStream<Void>.makeStream()
        let second = Task {
            joining.continuation.yield(())
            try await model.synchronizeViewingPolicy(runtime)
        }
        for await _ in joining.stream {
            break
        }
        await transport.releasePolicy()
        try await first.value
        try await second.value
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "GET" }.count, 1)
        XCTAssertTrue(runtime.configuration.activated)
    }

    func testUsageConflictNeverDiscardsAnUnacknowledgedPlaybackReport() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let transport = ReceiverTransport(
            policies: [policyJSON(model, enabled: true, revision: 4, commandID: UUID())],
            eventStatuses: [409]
        )
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        let event = ReceiverEvent(
            deviceID: configuration.deviceID.uuidString,
            childUserID: "kid",
            policyRevision: 2,
            playbackSessionID: UUID().uuidString,
            itemID: "movie",
            kind: .progress,
            positionSeconds: 7,
            elapsedPlayingSeconds: 3
        )
        try runtime.admission.appendEvent(event)
        do { try await model.synchronizeViewingPolicy(runtime)
            XCTFail("A conflict cannot discard usage")
        } catch { XCTAssertEqual(error as? ReceiverEventConflict, ReceiverEventConflict(code: "lease_mismatch")) }
        XCTAssertEqual(runtime.events, [event])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "POST")
        XCTAssertTrue(runtime.reportingFault)
    }

    func testPlayingHeartbeatBindsControllerWithoutChargingElapsedTime() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let transport = ReceiverTransport(policies: [policyJSON(model, enabled: true, revision: 2, commandID: UUID())])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        let movie = KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies")
        let playback = controller(movie, driver: SuspendedDriver(), model: model)
        model.activePlayback = playback
        try await model.synchronizeViewingPolicy(runtime)
        model.playbackBegan(playback)
        try await model.synchronizeViewingPolicy(runtime)
        try await model.synchronizeViewingPolicy(runtime)
        let requests = await transport.requests
        let events = try requests.compactMap { request in
            try request.httpBody.map { try JSONDecoder().decode(ReceiverEvent.self, from: $0) }
        }
        let event = try XCTUnwrap(events.last { $0.kind == .heartbeat })
        XCTAssertEqual(event.playbackSessionID, playback.id.uuidString)
        XCTAssertEqual(event.itemID, movie.id)
        XCTAssertNotNil(event.positionSeconds)
        XCTAssertEqual(event.elapsedPlayingSeconds, 0)
        XCTAssertNil(event.commandID)
    }

    func testStaleNoUsageHeartbeatRecoversButIntegrityConflictsRemainQueued() async throws {
        let stale = ["lease_mismatch", "lease_expired_or_mismatched", "policy_revision_mismatch", "heartbeat_session_mismatch"]
        let integrity = [
            "idempotency_mismatch",
            "idempotency_conflict",
            "key_mismatch",
            "clock_rollback",
            "restore_review_required",
            "unknown_error"
        ]
        for code in stale + integrity {
            let (model, _, configuration, directory) = try receiverHarness(activated: true)
            let transport = ReceiverTransport(
                policies: [policyJSON(model, enabled: true, revision: 4, commandID: UUID())],
                eventStatuses: [409],
                conflictCode: code
            )
            let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
            model.viewingRuntime = runtime
            let heartbeat = ReceiverEvent(
                deviceID: configuration.deviceID.uuidString,
                childUserID: "kid",
                policyRevision: 2,
                playbackSessionID: UUID().uuidString,
                itemID: "movie",
                kind: .heartbeat,
                positionSeconds: 7
            )
            try runtime.admission.appendEvent(heartbeat)
            if stale.contains(code) {
                try await model.synchronizeViewingPolicy(runtime)
                XCTAssertFalse(runtime.events.contains(where: { $0.eventID == heartbeat.eventID }))
            } else {
                do { try await model.synchronizeViewingPolicy(runtime)
                    XCTFail("Integrity conflict was swallowed: \(code)")
                } catch { XCTAssertEqual(error as? ReceiverEventConflict, ReceiverEventConflict(code: code)) }
                XCTAssertEqual(runtime.events, [heartbeat])
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.filter { $0.httpMethod == "GET" }.count, stale.contains(code) ? 1 : 0)
            XCTAssertEqual(runtime.reportingFault, !stale.contains(code))
        }
    }

    func testCommandBurstStopsBeforeAcknowledgementsOverflow() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let driver = SuspendedDriver()
        let movie = KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies")
        let playback = controller(movie, driver: driver, model: model)
        model.activePlayback = playback
        let json = policyJSON(model, enabled: true, revision: 2, commandID: UUID())
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8))
        var object = try XCTUnwrap(decoded as? [String: Any])
        object["commands"] = (0 ..< 64).map { _ in [
            "commandID": UUID().uuidString, "action": "pause", "playbackSessionID": playback.id.uuidString,
            "expiresAt": "2026-10-17T12:00:30.000Z"
        ] }
        let policy = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
        let transport = ReceiverTransport(policies: [policy])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        let queued = (0 ..< 119).map { _ in ReceiverEvent(
            deviceID: configuration.deviceID.uuidString,
            childUserID: "kid",
            policyRevision: 1,
            playbackSessionID: playback.id.uuidString,
            itemID: movie.id,
            kind: .progress,
            positionSeconds: 0
        ) }
        for event in queued {
            try runtime.admission.appendEvent(event)
        }
        try await model.synchronizeViewingPolicy(runtime)
        let acknowledgements = runtime.events.filter { $0.kind == .commandApplied && $0.playbackSessionID == playback.id.uuidString }
        // One acknowledgement belongs to policy release; every executed remote
        // action must have its own retained acknowledgement as well.
        XCTAssertGreaterThan(driver.pauses, 0)
        XCTAssertLessThan(driver.pauses, 64)
        XCTAssertEqual(acknowledgements.count, driver.pauses + 1)
        XCTAssertLessThanOrEqual(runtime.events.count, 120)
        XCTAssertTrue(runtime.reportingFault)
    }

    func testDeniedSnapshotCannotRelabelOldControllerUsageBeforeRelease() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let driver = SuspendedDriver()
        let movie = KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies")
        let playback = controller(movie, driver: driver, model: model)
        model.activePlayback = playback
        let deniedValue = try JSONSerialization
            .jsonObject(with: Data(policyJSON(model, enabled: true, revision: 3, commandID: UUID()).utf8))
        var denied = try XCTUnwrap(deniedValue as? [String: Any])
        denied["viewingAllowed"] = false
        denied["validUntil"] = denied["serverTime"]
        denied["policyControl"] = ["commandID": UUID().uuidString, "kind": "countdown"]
        let deniedJSON = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: denied), encoding: .utf8))
        let transport = ReceiverTransport(policies: [
            policyJSON(model, enabled: true, revision: 2, commandID: UUID()), deniedJSON,
            policyJSON(model, enabled: true, revision: 4, commandID: UUID())
        ])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        model.playbackBegan(playback)
        try await model.synchronizeViewingPolicy(runtime)
        XCTAssertEqual(runtime.lease.policy?.revision, 3)
        XCTAssertEqual(runtime.normalGrant?.revision, 2)
        XCTAssertTrue(model.viewingHeld)
        model.queueViewingEvent(.progress, controller: playback, elapsed: 3)
        let stopping = Task { await model.stopPlayback(endSession: false) }
        for await _ in driver.entered.stream {
            break
        }
        driver.resume?.resume()
        await stopping.value
        let finalReports = runtime.events.filter { $0.kind == .progress || $0.kind == .stopped }
        XCTAssertTrue(finalReports.contains { $0.kind == .progress && $0.elapsedPlayingSeconds == 3 })
        XCTAssertEqual(finalReports.last?.kind, .stopped)
        XCTAssertTrue(finalReports.allSatisfy { $0.policyRevision == 2 && $0.playbackSessionID == playback.id.uuidString })
        let immutableIDs = Set(finalReports.map(\.eventID))
        try await model.synchronizeViewingPolicy(runtime)
        XCTAssertFalse(model.viewingHeld)
        XCTAssertEqual(runtime.lease.policy?.revision, 4)
        let requests = await transport.requests
        let sent = try requests.compactMap { request -> ReceiverEvent? in
            guard let body = request.httpBody else { return nil }
            return try JSONDecoder().decode(ReceiverEvent.self, from: body)
        }.filter { immutableIDs.contains($0.eventID) }
        XCTAssertEqual(sent, finalReports)
    }

    func testExplicitDeactivationEndsAccountingWithTheLastGrantedRevision() async throws {
        let (model, accounts, configuration, directory) = try receiverHarness(activated: true)
        let playback = controller(
            KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"),
            driver: SuspendedDriver(),
            model: model
        )
        model.activePlayback = playback
        let transport = ReceiverTransport(policies: [
            policyJSON(model, enabled: true, revision: 2, commandID: UUID()),
            policyJSON(model, enabled: false, revision: 3, commandID: UUID())
        ])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        model.playbackBegan(playback)
        try await model.synchronizeViewingPolicy(runtime)
        XCTAssertEqual(accounts.receiver?.activated, false)
        XCTAssertTrue(model.activePlayback === playback)
        let stopped = try XCTUnwrap(runtime.events.first { $0.kind == .stopped })
        XCTAssertEqual(stopped.policyRevision, 2)
        XCTAssertEqual(stopped.playbackSessionID, playback.id.uuidString)
        XCTAssertEqual(runtime.events.last?.policyRevision, 3)
        XCTAssertEqual(runtime.events.last?.kind, .commandApplied)
    }

    func testPreparingControllerCannotAnnounceUsageOrBoundHeartbeat() async throws {
        let (model, _, configuration, directory) = try receiverHarness()
        let driver = SuspendedDriver()
        driver.stopsImmediately = true
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        model.activePlayback = playback
        let transport = ReceiverTransport(policies: [policyJSON(model, enabled: true, revision: 2, commandID: UUID())])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        playback.start()
        try await model.synchronizeViewingPolicy(runtime)
        model.sampleViewingProgress(runtime, at: DispatchTime.now().uptimeNanoseconds)
        XCTAssertFalse(playback.hasBegunPlayback)
        XCTAssertNil(runtime.announcedSessionID)
        XCTAssertFalse(runtime.events.contains { [.started, .progress, .paused, .buffering].contains($0.kind) })
        try await model.synchronizeViewingPolicy(runtime)
        try await model.synchronizeViewingPolicy(runtime)
        await model.stopPlayback(endSession: false)
        XCTAssertFalse(runtime.events.contains { $0.kind == .stopped })
        let requests = await transport.requests
        let events = try requests.compactMap { request in
            try request.httpBody.map { try JSONDecoder().decode(ReceiverEvent.self, from: $0) }
        }
        let heartbeats = events.filter { $0.kind == .heartbeat }
        XCTAssertEqual(heartbeats.count, 2)
        XCTAssertTrue(heartbeats
            .allSatisfy { $0.playbackSessionID == nil && $0.itemID == nil && $0.positionSeconds == nil && $0.elapsedPlayingSeconds == 0 })
    }

    func testActualStartPrecedesPlayingIntervalsAndTransportTransitions() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let driver = SuspendedDriver()
        driver.stopsImmediately = true
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        model.activePlayback = playback
        let transport = ReceiverTransport(policies: [policyJSON(model, enabled: true, revision: 2, commandID: UUID())])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        playback.start()
        driver.frame.playing = true
        driver.frame.preparing = false
        driver.frame.buffering = false
        driver.frame.seconds = 0.25
        driver.frame.displayedPictures = 1
        driver.subject.send(.updated)
        XCTAssertTrue(playback.hasBegunPlayback)
        XCTAssertEqual(runtime.announcedSessionID, playback.id)
        let base = DispatchTime.now().uptimeNanoseconds
        model.sampleViewingProgress(runtime, at: base)
        driver.frame.seconds = 1.25
        model.sampleViewingProgress(runtime, at: base + 1_000_000_000)
        driver.frame.paused = true
        driver.frame.playing = false
        model.sampleViewingProgress(runtime, at: base + 2_000_000_000)
        model.sampleViewingProgress(runtime, at: base + 3_000_000_000)
        driver.frame.buffering = true
        model.sampleViewingProgress(runtime, at: base + 4_000_000_000)
        let usage = runtime.events.filter { [.started, .progress, .paused, .buffering].contains($0.kind) }
        XCTAssertEqual(usage.map(\.kind), [.started, .progress, .paused, .buffering])
        XCTAssertEqual(usage.map(\.elapsedPlayingSeconds), [0, 1, 0, 0])
        XCTAssertEqual(usage.first { $0.kind == .progress }?.positionSeconds, 1.25)
        XCTAssertTrue(usage.allSatisfy { $0.policyRevision == 2 })
        await model.stopPlayback(endSession: false)
    }

    func testDelayedFirstProgressSampleRetainsTheObservedStartBaseline() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let driver = SuspendedDriver()
        driver.stopsImmediately = true
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        model.activePlayback = playback
        let transport = ReceiverTransport(policies: [policyJSON(model, enabled: true, revision: 2, commandID: UUID())])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        playback.start()
        driver.frame.playing = true
        driver.frame.preparing = false
        driver.frame.buffering = false
        driver.frame.seconds = 0.202
        driver.frame.displayedPictures = 1
        driver.subject.send(.updated)
        let started = try XCTUnwrap(runtime.events.first { $0.kind == .started })
        let base = DispatchTime.now().uptimeNanoseconds

        // The first periodic sample can arrive a second after the real start,
        // followed by an immediate policy-flush sample. This was observed in
        // the finite simulator trial: dropping the first interval caused the
        // server to reject the subsequent positive interval as a position jump.
        driver.frame.seconds = 1.183
        model.sampleViewingProgress(runtime, at: base + 1_000_000_000)
        driver.frame.seconds = 1.195
        model.sampleViewingProgress(runtime, at: base + 1_012_000_000)
        driver.frame.paused = true
        driver.frame.playing = false
        model.sampleViewingProgress(runtime, at: base + 1_020_000_000)

        let reports = runtime.events.filter { $0.kind == .progress }
        XCTAssertFalse(reports.isEmpty)
        let reported = reports.reduce(0) { $0 + $1.elapsedPlayingSeconds }
        XCTAssertEqual(reported, 0.993, accuracy: 0.02)
        XCTAssertLessThanOrEqual(reported, 1.02)
        var previous = try XCTUnwrap(started.positionSeconds)
        for report in reports {
            let position = try XCTUnwrap(report.positionSeconds)
            if report.elapsedPlayingSeconds > 0 {
                XCTAssertLessThanOrEqual(abs(position - previous - report.elapsedPlayingSeconds), 0.5)
            }
            previous = position
        }
        XCTAssertEqual(runtime.events.filter { $0.kind == .started }.count, 1)
        await model.stopPlayback(endSession: false)
    }

    func testProgressCadenceOvershootDoesNotClipAnObservedIntervalToFiveSeconds() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let driver = SuspendedDriver()
        driver.stopsImmediately = true
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        model.activePlayback = playback
        let transport = ReceiverTransport(policies: [policyJSON(model, enabled: true, revision: 2, commandID: UUID())])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        playback.start()
        driver.frame.playing = true
        driver.frame.preparing = false
        driver.frame.buffering = false
        driver.frame.seconds = 0.803
        driver.frame.displayedPictures = 1
        driver.subject.send(.updated)
        let started = try XCTUnwrap(runtime.events.first { $0.kind == .started })
        let base = DispatchTime.now().uptimeNanoseconds
        // Normal timer jitter can make the nominal five-second report become
        // due on the sixth tick. The observed interval must survive intact;
        // clipping it to five seconds makes the server correctly reject it.
        for second in 1 ... 7 {
            driver.frame.seconds = 0.803 + Double(second)
            model.sampleViewingProgress(runtime, at: base + UInt64(second) * 999_000_000)
        }
        let reports = runtime.events.filter { $0.kind == .progress }
        XCTAssertGreaterThanOrEqual(reports.count, 2)
        XCTAssertGreaterThan(try XCTUnwrap(reports.last).elapsedPlayingSeconds, 5.5)
        var previous = try XCTUnwrap(started.positionSeconds)
        for report in reports {
            let position = try XCTUnwrap(report.positionSeconds)
            XCTAssertLessThanOrEqual(abs(position - previous - report.elapsedPlayingSeconds), 0.5)
            XCTAssertLessThanOrEqual(report.elapsedPlayingSeconds, 30)
            previous = position
        }
        XCTAssertEqual(reports.reduce(0) { $0 + $1.elapsedPlayingSeconds }, 6.993, accuracy: 0.02)
        await model.stopPlayback(endSession: false)
    }

    func testRepeatedVLCClockRetainsWallIntervalUntilPositionAdvances() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let driver = SuspendedDriver()
        driver.stopsImmediately = true
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        model.activePlayback = playback
        let transport = ReceiverTransport(policies: [policyJSON(model, enabled: true, revision: 2, commandID: UUID())])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        playback.start()
        driver.frame.playing = true
        driver.frame.preparing = false
        driver.frame.buffering = false
        driver.frame.seconds = 0.335
        driver.frame.displayedPictures = 1
        driver.subject.send(.updated)
        let started = try XCTUnwrap(runtime.events.first { $0.kind == .started })
        let base = try XCTUnwrap(runtime.lastFrame).uptime
        model.sampleViewingProgress(runtime, at: base)
        // VLC's media clock and our timer need not update on the same tick.
        // A repeated position followed by a two-second advance is not a seek.
        let positions = [1.345, 1.345, 3.345, 4.345, 5.345, 6.345]
        for (index, position) in positions.enumerated() {
            driver.frame.seconds = position
            model.sampleViewingProgress(runtime, at: base + 976_128_292 + UInt64(index) * 1_000_000_000)
        }
        let report = try XCTUnwrap(runtime.events.last { $0.kind == .progress })
        XCTAssertEqual(report.elapsedPlayingSeconds, 5.976128292, accuracy: 0.00001)
        XCTAssertLessThanOrEqual(
            try abs(XCTUnwrap(report.positionSeconds) - XCTUnwrap(started.positionSeconds) - report.elapsedPlayingSeconds),
            0.5
        )
        await model.stopPlayback(endSession: false)
    }

    func testStaleSampleCannotReplaceNewerStartPositionAndClock() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let driver = SuspendedDriver()
        driver.stopsImmediately = true
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        model.activePlayback = playback
        let transport = ReceiverTransport(policies: [policyJSON(model, enabled: true, revision: 2, commandID: UUID())])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        playback.start()
        driver.frame.playing = true
        driver.frame.preparing = false
        driver.frame.buffering = false
        driver.frame.seconds = 0.335
        driver.frame.displayedPictures = 1
        driver.subject.send(.updated)
        let baseline = try XCTUnwrap(runtime.lastFrame)
        driver.frame.seconds = 1.345
        model.sampleViewingProgress(runtime, at: baseline.uptime - 1)
        XCTAssertEqual(runtime.lastFrame?.position, baseline.position)
        XCTAssertEqual(runtime.lastFrame?.uptime, baseline.uptime)
        XCTAssertEqual(runtime.accumulatedPlaying, 0)
        XCTAssertEqual(runtime.progressSamples.last?.ignoredStaleTimestamp, true)
        model.sampleViewingProgress(runtime, at: baseline.uptime + 1_010_000_000)
        XCTAssertEqual(runtime.events.last { $0.kind == .progress }?.elapsedPlayingSeconds ?? -1, 1.01, accuracy: 0.00001)
        for second in 2 ... 150 {
            driver.frame.seconds = 0.335 + Double(second)
            model.sampleViewingProgress(runtime, at: baseline.uptime + UInt64(second) * 1_010_000_000)
        }
        XCTAssertEqual(runtime.progressSamples.count, 128)
        XCTAssertEqual(runtime.progressSamples.first?.ignoredStaleTimestamp, true)
        XCTAssertEqual(runtime.progressSamples.last?.position, 150.335)
        await model.stopPlayback(endSession: false)
    }

    func testQuantizedClockTracePreservesIntervalsWithinObservedWallTime() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let driver = SuspendedDriver()
        driver.stopsImmediately = true
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        model.activePlayback = playback
        let transport = ReceiverTransport(policies: [policyJSON(model, enabled: true, revision: 2, commandID: UUID())])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        playback.start()
        driver.frame.playing = true
        driver.frame.preparing = false
        driver.frame.buffering = false
        driver.frame.seconds = 0.894
        driver.frame.displayedPictures = 1
        driver.subject.send(.updated)
        let started = try XCTUnwrap(runtime.events.first { $0.kind == .started })
        let base = try XCTUnwrap(runtime.lastFrame).uptime
        // Anonymous timing/position observations from an unperturbed real run.
        // Policy flushes sample between periodic ticks, and VLC's clock can
        // advance in a burst or regress slightly without a user seek.
        let samples: [(UInt64, Double)] = [
            (101_546_208, 0.894),
            (119_474_333, 0.894),
            (1_133_931_208, 1.9180000000000001),
            (2_135_085_667, 2.9050000000000002),
            (3_140_359_750, 3.909),
            (4_152_757_000, 4.9030000000000005),
            (5_171_455_458, 5.916),
            (6_208_328_625, 6.91),
            (7_254_598_167, 7.927),
            (7_474_061_167, 7.934),
            (8_310_027_917, 8.911),
            (9_371_633_583, 9.894),
            (10_387_490_833, 10.92),
            (11_408_559_667, 11.902),
            (12_414_327_250, 12.931000000000001),
            (13_423_747_708, 13.897),
            (13_973_039_000, 14.931000000000001),
            (14_476_807_708, 14.926),
            (15_508_710_750, 15.917),
            (16_571_409_500, 16.936),
            (17_571_868_167, 17.92),
            (18_584_819_542, 18.944),
            (19_608_434_000, 19.92),
            (19_610_612_458, 19.92),
        ]
        for (index, sample) in samples.enumerated() {
            driver.frame.seconds = sample.1
            model.sampleViewingProgress(runtime, at: base + sample.0)
            if [9, 12, 16, 22].contains(index) {
                model.flushViewingProgress(playback, at: base + sample.0)
            }
        }
        let reports = runtime.events.filter { $0.kind == .progress && $0.elapsedPlayingSeconds > 0 }
        var previous = try XCTUnwrap(started.positionSeconds)
        for report in reports {
            let position = try XCTUnwrap(report.positionSeconds)
            XCTAssertLessThanOrEqual(abs(position - previous - report.elapsedPlayingSeconds), 0.5)
            previous = position
        }
        let total = reports.reduce(0) { $0 + $1.elapsedPlayingSeconds }
        XCTAssertGreaterThan(total, 18.9)
        XCTAssertLessThanOrEqual(total, try Double(XCTUnwrap(samples.last).0) / 1_000_000_000)
        XCTAssertFalse(runtime.reportingFault)
        await model.stopPlayback(endSession: false)
    }

    func testProgressFlushReportsTheSameNativeFrameUsedToMeasureElapsedTime() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let driver = AdvancingClockDriver()
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        model.activePlayback = playback
        let transport = ReceiverTransport(policies: [policyJSON(model, enabled: true, revision: 2, commandID: UUID())])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        playback.start()
        driver.current.playing = true
        driver.current.preparing = false
        driver.current.buffering = false
        driver.current.seconds = 10
        driver.current.displayedPictures = 1
        driver.subject.send(.updated)
        let started = try XCTUnwrap(runtime.events.first { $0.kind == .started })
        let base = try XCTUnwrap(runtime.lastFrame).uptime
        model.sampleViewingProgress(runtime, at: base)
        driver.current.seconds = 11
        var next = driver.current
        next.seconds = 12
        driver.next = next
        // The native engine can update independently between two getter calls.
        // The report must use the observation that supplied its elapsed time.
        model.flushViewingProgress(playback, at: base + 1_000_000_000)
        let report = try XCTUnwrap(runtime.events.last { $0.kind == .progress })
        XCTAssertEqual(report.positionSeconds, 11)
        XCTAssertEqual(report.elapsedPlayingSeconds, 1, accuracy: 0.000001)
        XCTAssertLessThanOrEqual(
            try abs(XCTUnwrap(report.positionSeconds) - XCTUnwrap(started.positionSeconds) - report.elapsedPlayingSeconds),
            0.5
        )
        await model.stopPlayback(endSession: false)
        let stopped = try XCTUnwrap(runtime.events.last { $0.kind == .stopped })
        XCTAssertEqual(stopped.positionSeconds, 11)
    }

    func testNativeTerminalClockResetCannotRewindTheFinalUsageReport() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let driver = AdvancingClockDriver()
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        model.activePlayback = playback
        let transport = ReceiverTransport(policies: [policyJSON(model, enabled: true, revision: 2, commandID: UUID())])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        playback.start()
        driver.current.playing = true
        driver.current.preparing = false
        driver.current.seconds = 10
        driver.current.displayedPictures = 1
        driver.subject.send(.updated)
        let base = try XCTUnwrap(runtime.lastFrame).uptime
        model.sampleViewingProgress(runtime, at: base)
        driver.current.seconds = 11
        model.flushViewingProgress(playback, at: base + 1_000_000_000)
        driver.current.seconds = 0
        driver.current.playing = false
        driver.current.terminal = true
        model.flushViewingProgress(playback, at: base + 2_000_000_000)
        await model.stopPlayback(endSession: false)
        let progress = try XCTUnwrap(runtime.events.last { $0.kind == .progress })
        let stopped = try XCTUnwrap(runtime.events.last { $0.kind == .stopped })
        XCTAssertEqual(progress.positionSeconds, 11)
        XCTAssertEqual(progress.elapsedPlayingSeconds, 1, accuracy: 0.000001)
        XCTAssertEqual(stopped.positionSeconds, progress.positionSeconds)
        XCTAssertEqual(stopped.elapsedPlayingSeconds, 0)
        XCTAssertFalse(runtime.reportingFault)
    }

    func testPolicyFlushClockBurstRetainsObservedPlayingTime() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let driver = SuspendedDriver()
        driver.stopsImmediately = true
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        model.activePlayback = playback
        let transport = ReceiverTransport(policies: [policyJSON(model, enabled: true, revision: 2, commandID: UUID())])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        playback.start()
        driver.frame.playing = true
        driver.frame.preparing = false
        driver.frame.buffering = false
        driver.frame.seconds = 0.888
        driver.frame.displayedPictures = 1
        driver.subject.send(.updated)
        let started = try XCTUnwrap(runtime.events.first { $0.kind == .started })
        let base = try XCTUnwrap(runtime.lastFrame).uptime
        // Anonymous timing/position observations from an unperturbed real run.
        // Policy flushes sample between periodic ticks, and VLC's clock can
        // advance in a burst or regress slightly without a user seek.
        let samples: [(UInt64, Double)] = [
            (432_315_208, 0.894),
            (685_691_291, 0.894),
            (1_452_103_416, 1.911),
            (2_456_122_458, 2.904),
            (3_493_728_375, 3.88),
            (4_523_701_250, 4.908),
            (5_549_490_750, 5.872),
            (6_593_779_916, 6.904),
            (7_652_238_750, 7.892),
            (8_227_281_000, 8.879),
            (8_693_786_666, 8.873),
            (9_694_521_750, 9.896),
            (10_712_428_041, 10.914),
            (11_766_670_791, 11.9),
            (12_793_706_250, 12.883000000000001),
            (13_853_583_375, 13.906),
            (14_769_940_750, 14.888),
            (14_885_542_333, 15.917),
            (15_893_823_750, 16.894),
        ]
        for (index, sample) in samples.enumerated() {
            driver.frame.seconds = sample.1
            model.sampleViewingProgress(runtime, at: base + sample.0)
            if [0, 5, 9, 16, 18].contains(index) {
                model.flushViewingProgress(playback, at: base + sample.0)
            }
        }
        let reports = runtime.events.filter { $0.kind == .progress && $0.elapsedPlayingSeconds > 0 }
        var previous = try XCTUnwrap(started.positionSeconds)
        for report in reports {
            let position = try XCTUnwrap(report.positionSeconds)
            XCTAssertLessThanOrEqual(abs(position - previous - report.elapsedPlayingSeconds), 0.5)
            previous = position
        }
        let total = reports.reduce(0) { $0 + $1.elapsedPlayingSeconds }
        XCTAssertGreaterThan(total, 15.5)
        XCTAssertLessThanOrEqual(total, try Double(XCTUnwrap(samples.last).0) / 1_000_000_000)
        XCTAssertFalse(runtime.reportingFault)
        await model.stopPlayback(endSession: false)
    }

    func testOversizedObservedIntervalHoldsInsteadOfClampingToTheWireLimit() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let driver = SuspendedDriver()
        driver.stopsImmediately = true
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        model.activePlayback = playback
        let transport = ReceiverTransport(policies: [policyJSON(model, enabled: true, revision: 2, commandID: UUID())])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        playback.start()
        driver.frame.playing = true
        driver.frame.preparing = false
        driver.frame.buffering = false
        driver.frame.seconds = 31
        driver.frame.displayedPictures = 1
        driver.subject.send(.updated)
        let original = runtime.events
        runtime.accumulatedPlaying = 30.1
        runtime.lastFrame = (playback.id, 31, DispatchTime.now().uptimeNanoseconds, true)
        model.flushViewingProgress(playback)
        XCTAssertTrue(runtime.reportingFault)
        XCTAssertEqual(runtime.events, original)
        await model.tickViewingAdmission(runtime, at: DispatchTime.now().uptimeNanoseconds)
        XCTAssertTrue(model.viewingHeld)
        XCTAssertNil(model.activePlayback)
        XCTAssertFalse(runtime.events.contains { $0.kind == .progress })
    }

    func testPauseBetweenTicksRetainsPastPlayingTimeWithoutChargingPausedSeek() async throws {
        try await assertPastPlayingIntervalSurvivesTransportHold(buffering: false)
    }

    func testBufferingBetweenTicksRetainsPastPlayingTimeWithoutChargingHeldSeek() async throws {
        try await assertPastPlayingIntervalSurvivesTransportHold(buffering: true)
    }

    private func assertPastPlayingIntervalSurvivesTransportHold(buffering: Bool) async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let driver = SuspendedDriver()
        driver.stopsImmediately = true
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        model.activePlayback = playback
        let transport = ReceiverTransport(policies: [policyJSON(model, enabled: true, revision: 2, commandID: UUID())])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        playback.start()
        driver.frame.playing = true
        driver.frame.preparing = false
        driver.frame.buffering = false
        driver.frame.seconds = 0.803
        driver.frame.displayedPictures = 1
        driver.subject.send(.updated)
        let started = try XCTUnwrap(runtime.events.first { $0.kind == .started })
        let base = DispatchTime.now().uptimeNanoseconds
        driver.frame.seconds = 1.803
        model.sampleViewingProgress(runtime, at: base + 1_000_000_000)
        driver.frame.seconds = 2.803
        model.sampleViewingProgress(runtime, at: base + 2_000_000_000)
        // Playback advances for another fraction before the transport hold.
        driver.frame.seconds = 3.553
        driver.frame.playing = false
        driver.frame.paused = !buffering
        driver.frame.buffering = buffering
        model.sampleViewingProgress(runtime, at: base + 3_000_000_000)
        let reports = runtime.events.filter { $0.kind == .progress }
        XCTAssertEqual(reports.reduce(0) { $0 + $1.elapsedPlayingSeconds }, 2.75, accuracy: 0.02)
        var previous = try XCTUnwrap(started.positionSeconds)
        for report in reports {
            let position = try XCTUnwrap(report.positionSeconds)
            XCTAssertLessThanOrEqual(abs(position - previous - report.elapsedPlayingSeconds), 0.5)
            previous = position
        }
        let held = try XCTUnwrap(runtime.events.last)
        XCTAssertEqual(held.kind, buffering ? .buffering : .paused)
        XCTAssertEqual(held.elapsedPlayingSeconds, 0)
        model.sampleViewingProgress(runtime, at: base + 4_000_000_000)
        driver.frame.seconds += 15
        model.sampleViewingProgress(runtime, at: base + 5_000_000_000)
        XCTAssertEqual(runtime.events.filter { $0.kind == .progress }, reports)
        await model.stopPlayback(endSession: false)
    }

    func testRenewalFlushesAccruedIntervalUnderOriginalGrant() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let driver = SuspendedDriver()
        driver.stopsImmediately = true
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        model.activePlayback = playback
        let transport = ReceiverTransport(policies: [
            policyJSON(model, enabled: true, revision: 2, commandID: UUID()),
            policyJSON(model, enabled: true, revision: 3, commandID: UUID())
        ])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        model.playbackBegan(playback)
        runtime.accumulatedPlaying = 1.25
        driver.frame.seconds = 9.25
        driver.frame.paused = true
        runtime.lastFrame = (playback.id, 9.25, DispatchTime.now().uptimeNanoseconds, false)
        try await model.synchronizeViewingPolicy(runtime)
        let progress = try XCTUnwrap(runtime.events.first { $0.kind == .progress })
        XCTAssertEqual(progress.elapsedPlayingSeconds, 1.25)
        XCTAssertEqual(progress.positionSeconds, 9.25)
        XCTAssertEqual(progress.policyRevision, 2)
        XCTAssertEqual(runtime.normalGrant?.revision, 3)
        let saved = runtime.events
        try await model.synchronizeViewingPolicy(runtime)
        let requests = await transport.requests
        let sent = try requests.compactMap { request in
            try request.httpBody.map { try JSONDecoder().decode(ReceiverEvent.self, from: $0) }
        }
        XCTAssertTrue(saved.allSatisfy { sent.contains($0) })
        await model.stopPlayback(endSession: false)
    }

    func testFailedActivationStopsLegacyControllerWithoutInventingUsage() async throws {
        let (model, accounts, configuration, directory) = try receiverHarness()
        accounts.receiverWritesFail = true
        let driver = SuspendedDriver()
        driver.stopsImmediately = true
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        model.activePlayback = playback
        let transport = ReceiverTransport(policies: [policyJSON(model, enabled: true, revision: 2, commandID: UUID())])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        do { try await model.synchronizeViewingPolicy(runtime)
            XCTFail("Storage failure must not admit activation")
        } catch { XCTAssertTrue(error is Accounts.StorageFailure) }
        for await _ in driver.entered.stream {
            break
        }
        // The stop task is scheduled by the failed persistence path.
        for _ in 0 ..< 10 where model.activePlayback != nil {
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(driver.pauses, 1)
        XCTAssertNil(model.activePlayback)
        XCTAssertTrue(model.viewingHeld)
        XCTAssertTrue(runtime.reportingFault)
        XCTAssertFalse(runtime.configuration.activated)
        XCTAssertFalse(runtime.events.contains { [.started, .progress, .stopped].contains($0.kind) })
    }

    func testOutageRetainsOldAcknowledgementUntilPersistenceThenFetchesFreshRelease() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let oldControlID = UUID(), releaseID = UUID()
        let transport = ReceiverTransport(
            policies: [policyJSON(model, enabled: true, revision: 5, commandID: releaseID)],
            eventStatuses: [503, 200, 200]
        )
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        model.viewingHeld = true
        let oldAcknowledgement = ReceiverEvent(
            deviceID: configuration.deviceID.uuidString, childUserID: "kid", policyRevision: 3,
            playbackSessionID: UUID().uuidString, itemID: "movie", kind: .commandApplied,
            positionSeconds: 0, commandID: oldControlID
        )
        try runtime.admission.appendEvent(oldAcknowledgement)
        do { try await model.synchronizeViewingPolicy(runtime)
            XCTFail("Transport outage must retain the original evidence")
        } catch { /* Retry the same immutable event after recovery. */ }
        XCTAssertEqual(runtime.events, [oldAcknowledgement])
        XCTAssertTrue(model.viewingHeld)
        var requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST"])
        try await model.synchronizeViewingPolicy(runtime)
        XCTAssertFalse(runtime.events.contains { $0.eventID == oldAcknowledgement.eventID })
        XCTAssertEqual(runtime.lease.policy?.revision, 5)
        XCTAssertFalse(model.viewingHeld)
        let releaseAcknowledgement = try XCTUnwrap(runtime.events.first)
        XCTAssertEqual(releaseAcknowledgement.kind, .commandApplied)
        XCTAssertEqual(releaseAcknowledgement.commandID, releaseID)
        XCTAssertNil(releaseAcknowledgement.playbackSessionID)
        try await model.synchronizeViewingPolicy(runtime)
        requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST", "GET", "POST", "GET"])
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Idempotency-Key"), requests[1].value(forHTTPHeaderField: "Idempotency-Key"))
        let final = try JSONDecoder().decode(ReceiverEvent.self, from: XCTUnwrap(requests[3].httpBody))
        XCTAssertEqual(final, releaseAcknowledgement)
        XCTAssertTrue(runtime.events.isEmpty)
    }

    func testUnconfirmedStartRetiresMatchingControllerDrainsEvidenceThenFetchesPermission() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let driver = SuspendedDriver()
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        model.activePlayback = playback
        let transport = ReceiverTransport(policies: [
            policyJSON(model, enabled: true, revision: 2, commandID: UUID()),
            policyJSON(model, enabled: true, revision: 4, commandID: UUID())
        ])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        model.playbackBegan(playback)
        model.queueViewingEvent(.progress, controller: playback, elapsed: 2)
        let originalReports = runtime.events.filter { $0.kind == .started || $0.kind == .progress }
        let started = try XCTUnwrap(originalReports.first { $0.kind == .started })
        await transport.markUnconfirmed(started)
        let recovering = Task { try await model.synchronizeViewingPolicy(runtime) }
        for await _ in driver.entered.stream {
            break
        }
        XCTAssertTrue(model.viewingHeld)
        XCTAssertEqual(runtime.lease.policy?.revision, 2)
        XCTAssertTrue(model.activePlayback === playback)
        let duringStop = await transport.requests
        XCTAssertEqual(duringStop.filter { $0.httpMethod == "GET" }.count, 1)
        driver.resume?.resume()
        try await recovering.value
        XCTAssertNil(model.activePlayback)
        XCTAssertFalse(model.viewingHeld)
        XCTAssertEqual(runtime.lease.policy?.revision, 4)
        let requests = await transport.requests
        let sent = try requests.compactMap { request in
            try request.httpBody.map { try JSONDecoder().decode(ReceiverEvent.self, from: $0) }
        }
        XCTAssertTrue(originalReports.allSatisfy { sent.contains($0) })
        let usage = sent.filter { [.started, .progress, .stopped].contains($0.kind) }
        XCTAssertEqual(usage.map(\.kind), [.started, .progress, .stopped])
        XCTAssertTrue(usage.allSatisfy { $0.policyRevision == 2 && $0.playbackSessionID == playback.id.uuidString })
        XCTAssertEqual(requests.last?.httpMethod, "GET")
        XCTAssertFalse(runtime.events.contains { $0.kind == .started })
    }

    func testQuarantinedAuditStopsOriginalControllerBeforeDrainingAndFreshPolicy() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let driver = SuspendedDriver()
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        model.activePlayback = playback
        let transport = ReceiverTransport(policies: [
            policyJSON(model, enabled: true, revision: 2, commandID: UUID()),
            policyJSON(model, enabled: true, revision: 4, commandID: UUID())
        ])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        model.playbackBegan(playback)
        model.queueViewingEvent(.progress, controller: playback, elapsed: 2)
        let originalReports = runtime.events.filter { $0.kind == .started || $0.kind == .progress }
        for report in originalReports {
            await transport.markQuarantined(report)
        }
        let recovering = Task { try await model.synchronizeViewingPolicy(runtime) }
        for await _ in driver.entered.stream {
            break
        }
        XCTAssertTrue(model.viewingHeld)
        XCTAssertEqual(runtime.lease.policy?.revision, 2)
        XCTAssertTrue(model.activePlayback === playback)
        let duringStop = await transport.requests
        XCTAssertEqual(duringStop.filter { $0.httpMethod == "GET" }.count, 1)
        driver.resume?.resume()
        try await recovering.value
        XCTAssertNil(model.activePlayback)
        XCTAssertFalse(model.viewingHeld)
        XCTAssertEqual(runtime.lease.policy?.revision, 4)
        let requests = await transport.requests
        let sent = try requests.compactMap { request in
            try request.httpBody.map { try JSONDecoder().decode(ReceiverEvent.self, from: $0) }
        }
        XCTAssertTrue(originalReports.allSatisfy { sent.contains($0) })
        let usage = sent.filter { [.started, .progress, .stopped].contains($0.kind) }
        XCTAssertEqual(usage.map(\.kind), [.started, .progress, .stopped])
        XCTAssertTrue(usage.allSatisfy { $0.policyRevision == 2 && $0.playbackSessionID == playback.id.uuidString })
        XCTAssertEqual(requests.last?.httpMethod, "GET")
        XCTAssertFalse(runtime.events.contains { $0.kind == .started })
        XCTAssertEqual(try KidsAdmissionJournal(configuration: configuration, directory: directory).events, runtime.events)
    }

    func testQuarantinedDurablePrefixAfterRestartDrainsOriginalBodiesBeforePolicyWithoutAutoplay() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let reports = [ReceiverEvent.Kind.progress, .progress, .stopped].enumerated().map { index, kind in
            ReceiverEvent(
                deviceID: configuration.deviceID.uuidString,
                childUserID: configuration.childUserID,
                policyRevision: 2,
                playbackSessionID: "retired-controller",
                itemID: "movie",
                kind: kind,
                positionSeconds: Double(index + 6),
                elapsedPlayingSeconds: index == 0 ? 5 : 0
            )
        }
        let original = try KidsAdmissionJournal(configuration: configuration, directory: directory)
        for report in reports {
            try original.appendEvent(report)
        }
        let transport = ReceiverTransport(policies: [policyJSON(model, enabled: false, revision: 4, commandID: UUID())])
        for report in reports {
            await transport.markQuarantined(report)
        }
        let restarted = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = restarted
        XCTAssertEqual(restarted.events, reports)
        XCTAssertNil(restarted.lease.policy)
        try await model.synchronizeViewingPolicy(restarted)
        XCTAssertNil(model.activePlayback)
        XCTAssertNil(restarted.admittedIntentID)
        let requests = await transport.requests
        XCTAssertEqual(requests.prefix(3).map { $0.url?.path }, Array(repeating: "/api/kids/v1/events", count: 3))
        let sent = try requests.prefix(3).map { try JSONDecoder().decode(ReceiverEvent.self, from: XCTUnwrap($0.httpBody)) }
        XCTAssertEqual(sent, reports)
        XCTAssertEqual(requests[3].httpMethod, "GET")
        XCTAssertFalse(restarted.events.contains { reports.map(\.eventID).contains($0.eventID) })
        XCTAssertEqual(try KidsAdmissionJournal(configuration: configuration, directory: directory).events, restarted.events)
    }

    func testUnconfirmedBacklogDrainsAcrossBatchesBeforeFreshPolicy() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let driver = SuspendedDriver()
        driver.stopsImmediately = true
        let playback = controller(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), driver: driver, model: model)
        model.activePlayback = playback
        let transport = ReceiverTransport(policies: [
            policyJSON(model, enabled: true, revision: 2, commandID: UUID()),
            policyJSON(model, enabled: true, revision: 4, commandID: UUID())
        ])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        model.playbackBegan(playback)
        for _ in 0 ..< 31 {
            model.queueViewingEvent(.progress, controller: playback, elapsed: 1)
        }
        let original = runtime.events.filter { $0.kind == .started || $0.kind == .progress }
        for event in original {
            await transport.markUnconfirmed(event)
        }
        for _ in 0 ..< 2 {
            try await model.synchronizeViewingPolicy(runtime)
            XCTAssertTrue(runtime.drainingUnconfirmedEvidence)
            XCTAssertTrue(model.viewingHeld)
            XCTAssertNil(model.activePlayback)
            XCTAssertFalse(runtime.events.isEmpty)
            XCTAssertEqual(runtime.lease.policy?.revision, 2)
            let requests = await transport.requests
            XCTAssertEqual(requests.filter { $0.httpMethod == "GET" }.count, 1)
        }
        try await model.synchronizeViewingPolicy(runtime)
        XCTAssertFalse(runtime.drainingUnconfirmedEvidence)
        XCTAssertFalse(model.viewingHeld)
        XCTAssertNil(model.activePlayback)
        XCTAssertEqual(runtime.lease.policy?.revision, 4)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "GET" }.count, 2)
        let sent = try requests.compactMap { request in
            try request.httpBody.map { try JSONDecoder().decode(ReceiverEvent.self, from: $0) }
        }
        let originalIDs = Set(original.map(\.eventID))
        XCTAssertEqual(sent.filter { originalIDs.contains($0.eventID) }, original)
        XCTAssertEqual(sent.last?.kind, .stopped)
        XCTAssertEqual(sent.last?.policyRevision, 2)
        XCTAssertEqual(requests.last?.httpMethod, "GET")
    }

    func testUnconfirmedOldControllerReceiptCannotStopItsReplacement() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let first = controller(
            KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"),
            driver: SuspendedDriver(),
            model: model
        )
        model.activePlayback = first
        let transport = ReceiverTransport(policies: [
            policyJSON(model, enabled: true, revision: 2, commandID: UUID()),
            policyJSON(model, enabled: true, revision: 4, commandID: UUID())
        ])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        try await model.synchronizeViewingPolicy(runtime)
        model.playbackBegan(first)
        let started = try XCTUnwrap(runtime.events.first { $0.kind == .started })
        await transport.markUnconfirmed(started)
        let replacementDriver = SuspendedDriver()
        let replacement = controller(first.item, driver: replacementDriver, model: model)
        model.activePlayback = replacement
        try await model.synchronizeViewingPolicy(runtime)
        XCTAssertTrue(model.activePlayback === replacement)
        XCTAssertEqual(replacementDriver.pauses, 0)
        XCTAssertFalse(replacement.hasEndedPlayback)
        XCTAssertFalse(model.viewingHeld)
        XCTAssertFalse(runtime.events.contains { $0.kind == .started || $0.kind == .stopped })
    }

    func testMismatchedRecoveryReceiptKeepsEvidenceAndFaultsBeforePolicyRefresh() async throws {
        let (model, _, configuration, directory) = try receiverHarness(activated: true)
        let transport = ReceiverTransport(policies: [policyJSON(model, enabled: true, revision: 2, commandID: UUID())])
        let runtime = try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: directory)
        model.viewingRuntime = runtime
        let event = ReceiverEvent(
            deviceID: configuration.deviceID.uuidString,
            childUserID: "kid",
            policyRevision: 2,
            playbackSessionID: UUID().uuidString,
            itemID: "movie",
            kind: .started,
            positionSeconds: 1
        )
        try runtime.admission.appendEvent(event)
        await transport.markUnconfirmed(event, sessionID: "other-controller")
        do { try await model.synchronizeViewingPolicy(runtime)
            XCTFail("Malformed recovery metadata cannot acknowledge an event")
        } catch { XCTAssertEqual(error as? ParentControlError, .malformedResponse) }
        XCTAssertEqual(runtime.events, [event])
        XCTAssertTrue(runtime.reportingFault)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST"])
        XCTAssertNil(runtime.lease.policy)
    }

    func testActivatedReceiverRequiresFreshPermissionBeforeAnyPlaybackPreparation() throws {
        let accounts = Accounts(), factory = PlaybackFactory()
        let model = KidsAppModel(accounts: accounts, playbackFactory: factory)
        let device = try XCTUnwrap(UUID(uuidString: model.receiverInstallationID))
        accounts.receiver = try KidsReceiverConfiguration(
            serviceURL: XCTUnwrap(URL(string: "http://127.0.0.1:9")),
            serverID: "server",
            childUserID: "kid",
            deviceID: device,
            token: "synthetic",
            activated: true
        )
        accounts.changes.send(identity())
        let binding = KidsBinding(serverID: "server", userID: "kid", showsID: "shows", moviesID: "movies")
        model.state = KidsState(binding: binding)
        try model.prepareViewingControls(binding: binding)
        let movie = KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies")
        XCTAssertTrue(model.viewingHeld)
        XCTAssertFalse(model.permitsViewing(movie, binding: binding))
        model.play(movie, mode: .movie)
        XCTAssertEqual(factory.preparations, 0)
    }

    func testPairingAlonePreservesExistingEligibility() throws {
        let accounts = Accounts(), model = KidsAppModel(accounts: accounts, playbackFactory: PlaybackFactory())
        accounts.receiver = try KidsReceiverConfiguration(
            serviceURL: XCTUnwrap(URL(string: "http://127.0.0.1:9")),
            serverID: "server",
            childUserID: "kid",
            deviceID: XCTUnwrap(UUID(uuidString: model.receiverInstallationID)),
            token: "synthetic"
        )
        let binding = KidsBinding(serverID: "server", userID: "kid", showsID: "shows", moviesID: "movies")
        try model.prepareViewingControls(binding: binding)
        XCTAssertFalse(model.viewingHeld)
        XCTAssertTrue(model.permitsViewing(KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies"), binding: binding))
        XCTAssertEqual(accounts.receiverWrites, 0)
    }

    func testForeignReceiverConfigurationFailsClosed() throws {
        let accounts = Accounts(), model = KidsAppModel(accounts: accounts, playbackFactory: PlaybackFactory())
        accounts.receiver = try KidsReceiverConfiguration(
            serviceURL: XCTUnwrap(URL(string: "http://127.0.0.1:9")),
            serverID: "other-server",
            childUserID: "kid",
            deviceID: XCTUnwrap(UUID(uuidString: model.receiverInstallationID)),
            token: "synthetic"
        )
        XCTAssertThrowsError(try model.prepareViewingControls(binding: KidsBinding(
            serverID: "server",
            userID: "kid",
            showsID: "shows",
            moviesID: "movies"
        )))
        XCTAssertTrue(model.viewingHeld)
    }

    func testUnreadableReceiverCredentialsCannotSilentlyUnpair() {
        let accounts = Accounts(), model = KidsAppModel(accounts: accounts, playbackFactory: PlaybackFactory())
        accounts.receiverReadsFail = true
        XCTAssertThrowsError(try model.prepareViewingControls(binding: KidsBinding(
            serverID: "server",
            userID: "kid",
            showsID: "shows",
            moviesID: "movies"
        )))
        XCTAssertTrue(model.viewingHeld)
        XCTAssertEqual(accounts.receiverWrites, 0)
    }

    func testLockedParentCannotPairOrUnpairReceiver() async {
        let accounts = Accounts(), model = KidsAppModel(accounts: accounts, playbackFactory: PlaybackFactory())
        XCTAssertThrowsError(try model.pairViewingControls(serviceURL: "invalid-before-auth", token: "synthetic"))
        do { try await model.unpairViewingControls()
            XCTFail("Locked parent must not remove a receiver credential")
        } catch { XCTAssertEqual(accounts.receiverWrites, 0) }
    }

    func testPreviewCannotStoreReceiverCredentialsEvenAfterUnlock() {
        let model = KidsAppModel.preview("shows")
        XCTAssertTrue(model.unlock("4242"))
        XCTAssertThrowsError(try model.pairViewingControls(serviceURL: "invalid-before-auth", token: "synthetic"))
    }

    func testLateStopCannotClearReplacementPlayback() async {
        let accounts = Accounts(), model = KidsAppModel(accounts: accounts, playbackFactory: PlaybackFactory())
        accounts.changes.send(identity())
        let movie = KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies")
        let oldDriver = SuspendedDriver()
        model.activePlayback = controller(movie, driver: oldDriver, model: model)
        let stopping = Task { await model.stopPlayback() }
        for await _ in oldDriver.entered.stream {
            break
        }
        let replacement = controller(movie, driver: SuspendedDriver(), model: model)
        model.activePlayback = replacement
        oldDriver.resume?.resume()
        await stopping.value
        XCTAssertTrue(model.activePlayback === replacement)
    }

    func testLateStopAndOldCallbacksCannotChangeReplacementAccountProgress() async {
        let accounts = Accounts(), model = KidsAppModel(accounts: accounts, playbackFactory: PlaybackFactory())
        accounts.changes.send(identity())
        let binding = KidsBinding(serverID: "server", userID: "kid", showsID: "shows", moviesID: "movies")
        model.state = KidsState(binding: binding)
        let movie = KidsItem(id: "movie", name: "Fixture", kind: .movie, libraryID: "movies")
        let driver = SuspendedDriver(), old = controller(movie, driver: driver, model: model)
        model.activePlayback = old
        let stopping = Task { await model.stopPlayback() }
        for await _ in driver.entered.stream {
            break
        }
        accounts.changes.send(identity(token: "replacement"))
        model.state?.movies[movie.id] = KidsProgress(itemID: movie.id, seconds: 42)
        model.playbackCheckpoint(old, seconds: 99)
        driver.resume?.resume()
        await stopping.value
        XCTAssertEqual(model.state?.movies[movie.id]?.seconds, 42)
        XCTAssertNil(model.activePlayback)
    }

    func testStaleBackRequestCannotStopReplacementController() async throws {
        let model = KidsAppModel.preview("controls")
        let old = try XCTUnwrap(model.activePlayback)
        let title = try XCTUnwrap(model.catalog[.shows]?.first)
        let episodes = try await model.episodes(for: title)
        let replacement = KidsPlaybackController.preview(
            item: episodes[1],
            title: title,
            mode: .ordered,
            episodes: episodes,
            delegate: model,
            scenario: "controls"
        )
        model.activePlayback = replacement
        await model.stopPlaybackFromSession(old)
        XCTAssertTrue(model.activePlayback === replacement)
        await model.stopPlaybackFromSession(replacement)
        XCTAssertNil(model.activePlayback)
    }

    private func identity(
        url: String = "http://localhost:9",
        server: String = "server",
        user: String = "kid",
        token: String = "fixture",
        name: String = "Fixture"
    ) -> KidsAccountIdentity {
        .init(serverURL: URL(string: url)!, serverID: server, serverName: name, userID: user, accessToken: token)
    }

    private func drainIdentityDelivery() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testAccountRevisionTracksFullAuthorizationIdentityOnly() async {
        let accounts = Accounts(), factory = PlaybackFactory()
        let model = KidsAppModel(accounts: accounts, playbackFactory: factory)
        var revision = model.accountRevision
        await drainIdentityDelivery()
        XCTAssertEqual(model.accountRevision, revision)
        for candidate in [
            identity(),
            identity(token: "replacement"),
            identity(url: "http://localhost:8"),
            identity(server: "replacement-server"),
            identity(user: "replacement-kid")
        ] {
            accounts.changes.send(candidate)
            await drainIdentityDelivery()
            XCTAssertNotEqual(model.accountRevision, revision)
            revision = model.accountRevision
            accounts.changes.send(candidate)
            await drainIdentityDelivery()
            XCTAssertEqual(model.accountRevision, revision)
        }
        accounts.changes.send(identity(user: "replacement-kid", name: "Renamed"))
        await drainIdentityDelivery()
        XCTAssertEqual(model.accountRevision, revision)
        XCTAssertEqual(model.serverName, "Renamed")
        accounts.changes.send(nil)
        await drainIdentityDelivery()
        XCTAssertNotEqual(model.accountRevision, revision)
        XCTAssertEqual(factory.preparations, 0)
        XCTAssertEqual(accounts.writes, 0)
        XCTAssertEqual(accounts.authentications, 0)
    }

    func testExistingParentUnlockReusesPINWithoutChangingIt() async {
        let accounts = Accounts(), factory = PlaybackFactory()
        accounts.savedPIN = "1234"
        let model = KidsAppModel(accounts: accounts, playbackFactory: factory)
        model.lockParents()
        XCTAssertTrue(model.unlock("1234"))
        do {
            try await model.signIn(urlText: "not-a-server", username: "fixture", password: "fixture", parentPIN: "")
            XCTFail("Invalid server address was accepted")
        } catch { XCTAssertTrue(error is KidsAPIError, "An existing unlocked gate must not demand another PIN") }
        XCTAssertEqual(accounts.savedPIN, "1234")
        XCTAssertEqual(accounts.writes, 0)
        model.lockParents()
        do {
            try await model.signIn(urlText: "not-a-server", username: "fixture", password: "fixture", parentPIN: "")
            XCTFail("A locked gate reused parent access")
        } catch { XCTAssertEqual(error as? KidsContractError, .denied) }
        XCTAssertEqual(accounts.authentications, 0)
        XCTAssertEqual(accounts.savedPIN, "1234")
    }

    func testPreviewRejectsCredentialsBeforeNetworkOrHostMutation() async {
        let accounts = Accounts(), factory = PlaybackFactory()
        let model = KidsAppModel(accounts: accounts, playbackFactory: factory, preview: true)
        XCTAssertTrue(model.unlock("4242"))
        do {
            try await model.signIn(urlText: "http://127.0.0.1:9", username: "fixture", password: "fixture", parentPIN: "1234")
            XCTFail("Synthetic preview activated an account")
        } catch { XCTAssertEqual(error as? KidsContractError, .denied) }
        XCTAssertThrowsError(try model.setPIN("1234"))
        await model.signOut()
        XCTAssertEqual(accounts.writes, 0)
        XCTAssertEqual(accounts.authentications, 0)
        XCTAssertEqual(accounts.signOuts, 0)
        XCTAssertEqual(factory.preparations, 0)
    }

    func testParentsMustUnlockBeforePreferencesAndRelockRevokesEdits() {
        let model = KidsAppModel.preview("shows")
        let original = model.state?.preferences
        model.savePreferences(limit: 1, spoken: true)
        XCTAssertEqual(model.state?.preferences, original)
        XCTAssertFalse(model.unlock("0000"))
        XCTAssertTrue(model.unlock("4242"))
        model.savePreferences(limit: 1, spoken: true)
        XCTAssertEqual(model.state?.preferences.episodeLimit, 1)
        XCTAssertEqual(model.state?.preferences.spokenNavigation, true)
        model.lockParents()
        model.savePreferences(limit: 2, spoken: false)
        XCTAssertEqual(model.state?.preferences.episodeLimit, 1)
        XCTAssertEqual(model.state?.preferences.spokenNavigation, true)
    }

    func testSetNextChangesOnlyItsApprovedShow() async throws {
        let model = KidsAppModel.preview("again")
        let show = try XCTUnwrap(model.catalog[.shows]?.first)
        let episodes = try await model.episodes(for: show)
        let episode = try XCTUnwrap(episodes.first)
        let other = model.state?.ordered["show-2"]
        XCTAssertTrue(model.unlock("4242"))
        model.chooseNext(episode)
        XCTAssertEqual(model.state?.ordered[show.id]?.itemID, episode.id)
        XCTAssertEqual(model.state?.ordered[show.id]?.seconds, 0)
        XCTAssertEqual(model.state?.ordered["show-2"], other)
    }

    func testAuthorizationDenialClearsVisibleStateAndStopsPlayer() async {
        let model = KidsAppModel.preview("controls")
        XCTAssertNotNil(model.activePlayback)
        XCTAssertFalse(model.catalog.isEmpty)
        model.show(KidsAPIError.authentication)
        await drainIdentityDelivery()
        XCTAssertTrue(model.requiresParent)
        XCTAssertTrue(model.catalog.isEmpty)
        XCTAssertNil(model.selectedShow)
        XCTAssertNil(model.selectedMovie)
        XCTAssertNil(model.state)
        XCTAssertNil(model.activePlayback)
    }

    func testStalePresentationDismissalCannotStopReplacementSession() async throws {
        let model = KidsAppModel.preview("controls")
        let old = try XCTUnwrap(model.activePlayback)
        let title = try XCTUnwrap(model.catalog[.shows]?.first)
        let episodes = try await model.episodes(for: title)
        let replacement = KidsPlaybackController.preview(
            item: episodes[1],
            title: title,
            mode: .ordered,
            episodes: episodes,
            delegate: model,
            scenario: "controls"
        )
        model.activePlayback = replacement
        await model.dismissPlayback(old)
        XCTAssertTrue(model.activePlayback === replacement)
        await model.dismissPlayback(replacement)
        XCTAssertNil(model.activePlayback)
    }

    func testUnavailablePINLocksParentsWithoutCountingWrongPINOrWriting() {
        let accounts = Accounts(), factory = PlaybackFactory()
        accounts.savedPIN = "1234"
        accounts.pinReadFails = true
        let model = KidsAppModel(accounts: accounts, playbackFactory: factory)
        XCTAssertTrue(model.hasParentPIN)
        XCTAssertTrue(model.gate.attempt(correct: true, now: .now))
        XCTAssertFalse(model.unlock("1234"))
        XCTAssertFalse(model.unlocked)
        XCTAssertNotNil(model.parentPINProblem)
        XCTAssertEqual(model.gate.failures, 0)
        XCTAssertThrowsError(try model.setPIN("5678")) {
            XCTAssertEqual($0 as? KidsParentPINError, .unavailable)
        }
        XCTAssertEqual(accounts.writes, 0)
        XCTAssertEqual(accounts.savedPIN, "1234")
    }

    func testUnreadablePINBlocksSignInBeforeURLParsingOrHostAuthentication() async {
        let accounts = Accounts(), factory = PlaybackFactory()
        accounts.pinReadFails = true
        let model = KidsAppModel(accounts: accounts, playbackFactory: factory)
        for recovering in [false, true] {
            do {
                try await model.signIn(
                    urlText: "invalid URL",
                    username: "fixture",
                    password: "fixture",
                    parentPIN: "1234",
                    recovering: recovering
                )
                XCTFail("Unreadable credentials permitted sign-in")
            } catch { XCTAssertEqual(error as? KidsParentPINError, .unavailable) }
        }
        XCTAssertEqual(accounts.writes, 0)
        XCTAssertEqual(accounts.authentications, 0)
        XCTAssertEqual(factory.preparations, 0)
    }
}
