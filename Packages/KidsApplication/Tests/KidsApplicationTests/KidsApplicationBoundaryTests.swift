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
        func start() {}
        func beginReporting() {}
        func togglePlayPause() {}
        func pause() {
            pauses += 1
        }

        func seek(seconds: Double) {}
        func stop() async {
            await withCheckedContinuation { continuation in
                resume = continuation
                entered.continuation.yield(())
            }
        }
    }

    private func controller(_ item: KidsItem, driver: any KidsPlaybackDriver, model: KidsAppModel) -> KidsPlaybackController {
        KidsPlaybackController(item: item, title: item, mode: .movie, position: 0, episodes: [], driver: driver, delegate: model)
    }

    private actor ReceiverTransport: ParentHTTPTransport {
        var requests: [URLRequest] = []
        var policies: [String]
        var eventStatuses: [Int]
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

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let status: Int
            let data: Data
            if request.httpMethod == "POST" {
                status = eventStatuses.isEmpty ? 200 : eventStatuses.removeFirst()
                let event = try JSONDecoder().decode(ReceiverEvent.self, from: XCTUnwrap(request.httpBody))
                data = status == 409 ? Data("{\"error\":\"\(conflictCode)\"}".utf8) :
                    Data("{\"commandID\":\"\(event.eventID)\",\"status\":\"persisted\"}".utf8)
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
        runtime.events = [event]
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
        runtime.events = [event]
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
        let requests = await transport.requests
        let event = try JSONDecoder().decode(ReceiverEvent.self, from: XCTUnwrap(requests.first?.httpBody))
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
            runtime.events = [heartbeat]
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
        runtime.events = (0 ..< 119).map { _ in ReceiverEvent(
            deviceID: configuration.deviceID.uuidString,
            childUserID: "kid",
            policyRevision: 1,
            playbackSessionID: playback.id.uuidString,
            itemID: movie.id,
            kind: .progress,
            positionSeconds: 0
        ) }
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
        try await model.synchronizeViewingPolicy(runtime)
        XCTAssertEqual(accounts.receiver?.activated, false)
        XCTAssertTrue(model.activePlayback === playback)
        let stopped = try XCTUnwrap(runtime.events.first { $0.kind == .stopped })
        XCTAssertEqual(stopped.policyRevision, 2)
        XCTAssertEqual(stopped.playbackSessionID, playback.id.uuidString)
        XCTAssertEqual(runtime.events.last?.policyRevision, 3)
        XCTAssertEqual(runtime.events.last?.kind, .commandApplied)
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
