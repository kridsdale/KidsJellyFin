//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation
@testable import KidsDiagnostics
import Testing

private enum CaptureFixture {
    static let server = "00000000000000000000000000000002"
    static let user = "00000000000000000000000000000003"
    static let client = "00000000000000000000000000000004"
    static let item = "00000000000000000000000000000005"
    static let trial = "00000000000000000000000000000007"
    static let nextTrial = "00000000000000000000000000000008"
    static let digest = "ce6c34830e491e655fae6949af5e332f2eb534cb853c6d77271361e2b5e87e7a"
    static let revision = String(repeating: "a", count: 40)

    static func object(twoTrials: Bool = false) -> [String: Any] {
        var trials: [[String: Any]] = [["id": trial, "item_id": item, "operation": "start", "load": "idle", "wan": "connected"]]
        if twoTrials {
            trials.append(["id": nextTrial, "item_id": item, "operation": "start", "load": "idle", "wan": "connected"])
        }
        return [
            "id": "00000000000000000000000000000001",
            "digest": digest,
            "server_id": server,
            "user_id": user,
            "client": [
                "platform": "tvos_simulator",
                "client_id": client,
                "app_build": "synthetic-1",
                "os_build": "synthetic-1",
                "network": "unknown",
                "cache_state": "uncontrolled"
            ],
            "trials": trials
        ]
    }

    static func data(twoTrials: Bool = false, formatted: Bool = false) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object(twoTrials: twoTrials),
            options: formatted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        )
    }

    static func plan(twoTrials: Bool = false) throws -> KidsEvidencePlan {
        try JSONDecoder().decode(KidsEvidencePlan.self, from: data(twoTrials: twoTrials))
    }

    static func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return result
    }

    @MainActor
    static func capture(
        directory: URL,
        twoTrials: Bool = false,
        now: @escaping @MainActor () -> UInt64 = { 1 }
    ) throws -> KidsEvidenceCapture {
        try KidsEvidenceCapture(
            plan: plan(twoTrials: twoTrials),
            implementationRevision: revision,
            directory: directory,
            platform: .simulator,
            appBuild: "synthetic-1",
            osBuild: "synthetic-1",
            now: now
        )
    }

    @MainActor
    static func bind(_ capture: KidsEvidenceCapture) throws -> KidsEvidenceAttempt {
        let action = try #require(capture.beginAction(serverID: server, userID: user))
        return try #require(capture.bind(action: action, itemID: item, serverID: server, userID: user, clientID: client))
    }

    static func objects(_ data: Data) throws -> [[String: Any]] {
        try data.split(separator: 10).map {
            try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CaptureCounter: Encodable, Sendable { let value: Double }
private struct CaptureEncodingFailure: Encodable, Sendable {
    func encode(to encoder: any Encoder) throws {
        throw KidsEvidenceJournalError.encodingFailed
    }
}

@MainActor
private final class CaptureFixtureTime { var value: UInt64 = 1 }

@Test @MainActor
func `capture mismatched identities unplanned media and foreign actions create no artifacts`() throws {
    let directory = try CaptureFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let capture = try CaptureFixture.capture(directory: directory)
    let foreign = try CaptureFixture.capture(directory: directory)
    let action = try #require(capture.beginAction(serverID: CaptureFixture.server, userID: CaptureFixture.user))
    let foreignAction = try #require(foreign.beginAction(serverID: CaptureFixture.server, userID: CaptureFixture.user))
    #expect(capture.beginAction(serverID: "invalid", userID: CaptureFixture.user) == nil)
    #expect(capture.beginAction(serverID: CaptureFixture.server, userID: "invalid") == nil)
    #expect(capture.bind(
        action: action,
        itemID: CaptureFixture.item,
        serverID: "invalid",
        userID: CaptureFixture.user,
        clientID: CaptureFixture.client
    ) == nil)
    #expect(capture.bind(
        action: action,
        itemID: CaptureFixture.item,
        serverID: CaptureFixture.server,
        userID: "invalid",
        clientID: CaptureFixture.client
    ) == nil)
    #expect(capture.bind(
        action: action,
        itemID: CaptureFixture.item,
        serverID: CaptureFixture.server,
        userID: CaptureFixture.user,
        clientID: "invalid"
    ) == nil)
    #expect(capture.bind(
        action: action,
        itemID: UUID().uuidString,
        serverID: CaptureFixture.server,
        userID: CaptureFixture.user,
        clientID: CaptureFixture.client
    ) == nil)
    #expect(capture.bind(
        action: foreignAction,
        itemID: CaptureFixture.item,
        serverID: CaptureFixture.server,
        userID: CaptureFixture.user,
        clientID: CaptureFixture.client
    ) == nil)
    #expect(capture.bind(
        action: nil,
        itemID: CaptureFixture.item,
        serverID: CaptureFixture.server,
        userID: CaptureFixture.user,
        clientID: CaptureFixture.client
    ) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
}

@Test @MainActor
func `capture scoped bind journals failed strict trial and passive observations before durable export`() throws {
    let directory = try CaptureFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let capture = try CaptureFixture.capture(directory: directory)
    let attempt = try CaptureFixture.bind(capture)
    attempt.flush()
    #expect(attempt.status == .recording)
    #expect(throws: KidsEvidenceJournalError.journalFailed) { try attempt.export() }
    attempt.observe(source: .vlc, monotonicNS: 2, observation: CaptureCounter(value: 3))
    attempt.finish(monotonicNS: 3)
    attempt.flush()
    #expect(attempt.status == .exportReady)
    let export = try attempt.export()
    #expect(export.strictJSONL.last == 10 && export.supplementaryJSONL.last == 10)
    let strict = try CaptureFixture.objects(export.strictJSONL)
    let supplementary = try CaptureFixture.objects(export.supplementaryJSONL)
    #expect(strict.map { $0["event"] as! String } == ["run_started", "trial_record", "run_finished"])
    #expect(supplementary.map { $0["event"] as! String } == ["run_started", "observation_record", "run_finished"])
    let partial = try #require(strict[1]["record"] as? [String: Any])
    #expect(partial["outcome"] as? String == "failed" && partial["failure_code"] as? String == "unsupported_client_callback")
    #expect(partial["behavior"] is NSNull && partial["condition_observations"] is NSNull)
    #expect((partial["decoder_load"] as? [Any])?.isEmpty == true)
    let native = try #require(supplementary[1]["record"] as? [String: Any])
    #expect(native["source"] as? String == "vlc")
    let counter = try #require(native["observation"] as? [String: Any])
    #expect(counter["value"] as? Double == 3)
    let receipt = try #require(JSONSerialization.jsonObject(with: export.durabilityReceipt) as? [String: Any])
    #expect(receipt["strictSHA256"] as? String == CaptureFixture.hash(export.strictJSONL))
    #expect(receipt["supplementarySHA256"] as? String == CaptureFixture.hash(export.supplementaryJSONL))
    #expect((receipt["strictBytes"] as? NSNumber)?.intValue == export.strictJSONL.count)
    #expect((receipt["supplementaryBytes"] as? NSNumber)?.intValue == export.supplementaryJSONL.count)
    #expect(receipt["disposition"] as? String == "complete")
    #expect(!FileManager.default.fileExists(atPath: attempt.directory.appendingPathComponent("pending-export.json").path))
    #expect(try Data(contentsOf: attempt.directory.appendingPathComponent("durable-export.json")) == export.durabilityReceipt)
    attempt.observe(source: .session, monotonicNS: 4, observation: CaptureCounter(value: 5))
    attempt.finish(monotonicNS: 5)
    attempt.flush()
    #expect(try attempt.export().strictJSONL == export.strictJSONL)
    #expect(try attempt.export().supplementaryJSONL == export.supplementaryJSONL)
}

@Test @MainActor
func `capture trial directories forbid replay across captures and require next fresh trial identity`() throws {
    let directory = try CaptureFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstCapture = try CaptureFixture.capture(directory: directory, twoTrials: true)
    let first = try CaptureFixture.bind(firstCapture)
    first.finish(monotonicNS: 2)
    first.flush()
    let original = try first.export()
    #expect(first.directory.lastPathComponent == CaptureFixture.trial)
    let restarted = try CaptureFixture.capture(directory: directory, twoTrials: true)
    let second = try CaptureFixture.bind(restarted)
    second.finish(monotonicNS: 2)
    second.flush()
    #expect(second.directory.lastPathComponent == CaptureFixture.nextTrial && second.clock.id != first.clock.id)
    let fresh = try second.export()
    let firstHeader = try #require(CaptureFixture.objects(original.strictJSONL).first)
    let secondHeader = try #require(CaptureFixture.objects(fresh.strictJSONL).first)
    #expect(firstHeader["run_id"] as? String != secondHeader["run_id"] as? String)
    #expect(try first.export().strictJSONL == original.strictJSONL)
    let exhausted = try CaptureFixture.capture(directory: directory, twoTrials: true)
    let action = try #require(exhausted.beginAction(serverID: CaptureFixture.server, userID: CaptureFixture.user))
    #expect(exhausted.bind(
        action: action,
        itemID: CaptureFixture.item,
        serverID: CaptureFixture.server,
        userID: CaptureFixture.user,
        clientID: CaptureFixture.client
    ) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent(CaptureFixture.digest).path).sorted()
        == [CaptureFixture.trial, CaptureFixture.nextTrial])
}

@Test @MainActor
func `capture encoding loss or nonfinite observations permanently block complete export`() throws {
    for nonfinite in [false, true] {
        let directory = try CaptureFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = try CaptureFixture.capture(directory: directory)
        let attempt = try CaptureFixture.bind(capture)
        attempt.flush()
        if nonfinite {
            attempt.observe(source: .vlc, monotonicNS: 2, observation: CaptureCounter(value: .nan))
        } else {
            attempt.observe(source: .session, monotonicNS: 2, observation: CaptureEncodingFailure())
        }
        attempt.finish(monotonicNS: 3)
        attempt.flush()
        #expect(attempt.status == .failed(.encodingFailed))
        #expect(throws: KidsEvidenceJournalError.journalFailed) { try attempt.export() }
        #expect(!FileManager.default.fileExists(atPath: attempt.directory.appendingPathComponent("durable-export.json").path))
        for filename in ["strict.jsonl", "supplementary.jsonl"] {
            let data = try Data(contentsOf: attempt.directory.appendingPathComponent(filename))
            #expect(!String(decoding: data, as: UTF8.self).contains("run_finished"))
        }
    }
}

@Test @MainActor
func `capture requested clock timestamp precedes bind and out of range timestamps create nothing`() throws {
    let directory = try CaptureFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let time = CaptureFixtureTime()
    time.value = 10
    let capture = try CaptureFixture.capture(directory: directory, now: { time.value })
    let action = try #require(capture.beginAction(serverID: CaptureFixture.server, userID: CaptureFixture.user))
    time.value = 100
    let attempt = try #require(capture.bind(
        action: action,
        itemID: CaptureFixture.item,
        serverID: CaptureFixture.server,
        userID: CaptureFixture.user,
        clientID: CaptureFixture.client
    ))
    attempt.finish(monotonicNS: 101)
    attempt.flush()
    let lines = try CaptureFixture.objects(attempt.export().strictJSONL)
    #expect((lines[0]["monotonic_ns"] as? NSNumber)?.uint64Value == 10)
    let record = try #require(lines[1]["record"] as? [String: Any])
    let events = try #require(record["events"] as? [[String: Any]])
    #expect((events.first?["monotonic_ns"] as? NSNumber)?.uint64Value == 10)
    #expect(events.first?["clock_id"] as? String == lines[0]["clock_id"] as? String)

    let boundedDirectory = try CaptureFixture.directory()
    defer { try? FileManager.default.removeItem(at: boundedDirectory) }
    let bounded = try CaptureFixture.capture(directory: boundedDirectory, now: { UInt64(Int64.max) + 1 })
    #expect(bounded.beginAction(serverID: CaptureFixture.server, userID: CaptureFixture.user) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: boundedDirectory.path).isEmpty)
}

@Test
func `capture private plan loader accepts formatted fixtures but rejects symlinks duplicates and insecure files`() throws {
    let directory = try CaptureFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("plan.json")
    try CaptureFixture.data(formatted: true).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let plan = try KidsEvidencePlan.load(fileURL: file)
    #expect(plan.id == "00000000000000000000000000000001" && plan.digest == CaptureFixture.digest)
    let alias = directory.appendingPathComponent("alias.json")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
    #expect(throws: KidsEvidenceProtocolError.invalidConfiguration) { try KidsEvidencePlan.load(fileURL: alias) }
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    #expect(throws: KidsEvidenceProtocolError.invalidConfiguration) { try KidsEvidencePlan.load(fileURL: file) }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let compact = try String(decoding: CaptureFixture.data(), as: UTF8.self)
    let duplicates = [
        compact.replacingOccurrences(
            of: "\"id\":\"00000000000000000000000000000001\"",
            with: "\"id\":\"00000000000000000000000000000001\",\"id\":\"00000000000000000000000000000001\""
        ),
        compact.replacingOccurrences(
            of: "\"client_id\":\"\(CaptureFixture.client)\"",
            with: "\"client_id\":\"\(CaptureFixture.client)\",\"client_id\":\"\(CaptureFixture.client)\""
        )
    ]
    for content in duplicates {
        try Data(content.utf8).write(to: file)
        #expect(throws: KidsEvidenceJournalError.invalidObject) { try KidsEvidencePlan.load(fileURL: file) }
    }
}

@Test @MainActor
func `capture concurrent observations accepted before finish stay ahead of footer`() async throws {
    let directory = try CaptureFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let capture = try CaptureFixture.capture(directory: directory)
    let attempt = try CaptureFixture.bind(capture)
    attempt.flush()
    await withTaskGroup(of: Void.self) { group in
        for index in 0 ..< 64 {
            group.addTask { attempt.observe(source: .vlc, monotonicNS: 2, observation: CaptureCounter(value: Double(index))) }
        }
        await group.waitForAll()
    }
    // All accepted calls returned before completion was requested. Their disk work
    // may remain queued, and finish must still drain it before the durable footer.
    attempt.finish(monotonicNS: 3)
    attempt.flush()
    let export = try attempt.export()
    let records = try CaptureFixture.objects(export.supplementaryJSONL)
    #expect(records.count == 66)
    #expect(records.map { ($0["sequence"] as! NSNumber).intValue } == Array(0 ... 65))
    #expect(records.last?["event"] as? String == "run_finished")
    let values = try records.dropFirst().dropLast().map { envelope in
        let record = try #require(envelope["record"] as? [String: Any])
        let observation = try #require(record["observation"] as? [String: Any])
        return try #require(observation["value"] as? Double)
    }
    #expect(values.sorted() == (0 ..< 64).map(Double.init))
}

@Test @MainActor
func `capture changed journal cannot override live export hashes`() throws {
    let directory = try CaptureFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let capture = try CaptureFixture.capture(directory: directory)
    let attempt = try CaptureFixture.bind(capture)
    attempt.finish(monotonicNS: 2)
    attempt.flush()
    #expect(attempt.status == .exportReady)
    _ = try attempt.export()
    let file = attempt.directory.appendingPathComponent("supplementary.jsonl")
    var changed = try Data(contentsOf: file)
    changed.append(Data(" ".utf8))
    try changed.write(to: file)
    #expect(throws: KidsEvidenceJournalError.journalFailed) { try attempt.export() }
}

@Test @MainActor
func `capture action nonce cannot bind another planned trial and retries need new action clock`() throws {
    let directory = try CaptureFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let capture = try CaptureFixture.capture(directory: directory, twoTrials: true)
    let action = try #require(capture.beginAction(serverID: CaptureFixture.server, userID: CaptureFixture.user))
    let first = try #require(capture.bind(
        action: action,
        itemID: CaptureFixture.item,
        serverID: CaptureFixture.server,
        userID: CaptureFixture.user,
        clientID: CaptureFixture.client
    ))
    #expect(capture.bind(
        action: action,
        itemID: CaptureFixture.item,
        serverID: CaptureFixture.server,
        userID: CaptureFixture.user,
        clientID: CaptureFixture.client
    ) == nil)
    let newAction = try #require(capture.beginAction(serverID: CaptureFixture.server, userID: CaptureFixture.user))
    let second = try #require(capture.bind(
        action: newAction,
        itemID: CaptureFixture.item,
        serverID: CaptureFixture.server,
        userID: CaptureFixture.user,
        clientID: CaptureFixture.client
    ))
    #expect(first.clock.id != second.clock.id)
    first.finish(monotonicNS: 2)
    second.finish(monotonicNS: 2)
    first.flush()
    second.flush()
    #expect(first.status == .exportReady && second.status == .exportReady)
    #expect(first.directory.lastPathComponent == CaptureFixture.trial && second.directory.lastPathComponent == CaptureFixture.nextTrial)
}

@Test @MainActor
func `capture explicit planned seek remains failed unsupported and interrupted export retains disposition`() throws {
    let directory = try CaptureFixture.directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var object = CaptureFixture.object()
    object["trials"] = [[
        "id": CaptureFixture.trial,
        "item_id": CaptureFixture.item,
        "operation": "seek",
        "load": "idle",
        "wan": "connected"
    ]]
    let plan = try JSONDecoder().decode(KidsEvidencePlan.self, from: JSONSerialization.data(withJSONObject: object))
    let capture = try KidsEvidenceCapture(
        plan: plan,
        implementationRevision: CaptureFixture.revision,
        directory: directory,
        platform: .simulator,
        appBuild: "synthetic-1",
        osBuild: "synthetic-1",
        now: { 1 }
    )
    let action = try #require(capture.beginAction(serverID: CaptureFixture.server, userID: CaptureFixture.user))
    #expect(capture.bind(
        action: action,
        itemID: CaptureFixture.item,
        serverID: CaptureFixture.server,
        userID: CaptureFixture.user,
        clientID: CaptureFixture.client
    ) == nil)
    let attempt = try #require(capture.bind(
        action: action,
        itemID: CaptureFixture.item,
        serverID: CaptureFixture.server,
        userID: CaptureFixture.user,
        clientID: CaptureFixture.client,
        operation: .seek
    ))
    attempt.finish(monotonicNS: 2, disposition: .interrupted)
    attempt.flush()
    #expect(attempt.status == .interrupted)
    let export = try attempt.export()
    let strict = try CaptureFixture.objects(export.strictJSONL)
    let partial = try #require(strict[1]["record"] as? [String: Any])
    #expect(partial["outcome"] as? String == "failed" && partial["failure_code"] as? String == "unsupported_client_callback")
    let events = try #require(partial["events"] as? [[String: Any]])
    #expect(events.count == 1 && events[0]["event"] as? String == "seek_requested")
    #expect(strict.last?["disposition"] as? String == "interrupted")
    let receipt = try #require(JSONSerialization.jsonObject(with: export.durabilityReceipt) as? [String: Any])
    #expect(receipt["disposition"] as? String == "interrupted")
    #expect(!String(decoding: export.strictJSONL, as: UTF8.self).contains("seek_video_presented"))
}
