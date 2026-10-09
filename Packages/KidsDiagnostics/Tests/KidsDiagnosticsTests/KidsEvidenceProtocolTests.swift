//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation
@testable import KidsDiagnostics
import Testing

private enum ProtocolFixture {
    static let planID = "00000000000000000000000000000001"
    static let serverID = "00000000000000000000000000000002"
    static let userID = "00000000000000000000000000000003"
    static let clientID = "00000000000000000000000000000004"
    static let itemID = "00000000000000000000000000000005"
    static let trialID = "00000000000000000000000000000007"
    static let digest = "ce6c34830e491e655fae6949af5e332f2eb534cb853c6d77271361e2b5e87e7a"
    static let revision = String(repeating: "a", count: 40)

    static func clientObject() -> [String: Any] {
        [
            "platform": "tvos_simulator",
            "client_id": clientID,
            "app_build": "synthetic-1",
            "os_build": "synthetic-1",
            "network": "unknown",
            "cache_state": "uncontrolled"
        ]
    }

    static func trialObject() -> [String: Any] {
        ["id": trialID, "item_id": itemID, "operation": "start", "load": "idle", "wan": "connected"]
    }

    static func planObject() -> [String: Any] {
        [
            "id": planID,
            "digest": digest,
            "server_id": serverID,
            "user_id": userID,
            "client": clientObject(),
            "trials": [trialObject()]
        ]
    }

    static func plan(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> KidsEvidencePlan {
        var object = planObject()
        change(&object)
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(KidsEvidencePlan.self, from: data)
    }

    static func clock() throws -> KidsEvidenceClock {
        try KidsEvidenceClock(id: "00000000000000000000000000000006")
    }
}

private func protocolObject(_ value: some Encodable) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
}

@Test
func `protocol fixture preserves exact planner identities and client scope`() throws {
    let plan = try ProtocolFixture.plan()
    try plan.validate()
    #expect(plan.id == ProtocolFixture.planID && plan.digest == ProtocolFixture.digest)
    #expect(plan.serverID == ProtocolFixture.serverID && plan.userID == ProtocolFixture.userID)
    #expect(plan.client.clientID == ProtocolFixture.clientID)
    #expect(plan.trials.first?.id == ProtocolFixture.trialID && plan.trials.first?.itemID == ProtocolFixture.itemID)
    let client = try protocolObject(plan.client)
    #expect(Set(client.keys) == Set(["platform", "client_id", "app_build", "os_build", "network", "cache_state"]))
    #expect(client["platform"] as? String == "tvos_simulator")
    #expect(client["cache_state"] as? String == "uncontrolled" && client["network"] as? String == "unknown")
    #expect(client["app_build"] as? String == "synthetic-1" && client["os_build"] as? String == "synthetic-1")

    let hyphenated = "aabbccdd-eeff-4011-8022-334455667788"
    let changed = try ProtocolFixture.plan {
        $0["id"] = hyphenated
        var client = $0["client"] as! [String: Any]
        client["client_id"] = hyphenated
        $0["client"] = client
    }
    try changed.validate()
    let header = try KidsEvidenceRunHeader(
        plan: changed,
        runID: UUID(),
        clock: ProtocolFixture.clock(),
        monotonicNS: 1,
        implementationRevision: ProtocolFixture.revision
    )
    #expect(header.planID == hyphenated && header.client.clientID == hyphenated)
    #expect(changed.client.matches(
        platform: .simulator,
        clientID: hyphenated.uppercased(),
        appBuild: "synthetic-1",
        osBuild: "synthetic-1"
    ))
    #expect(!changed.client.matches(
        platform: .physical,
        clientID: hyphenated,
        appBuild: "synthetic-1",
        osBuild: "synthetic-1"
    ))
}

@Test
func `protocol invalid planner identities digest trial lists and client fields are rejected`() throws {
    for key in ["id", "server_id", "user_id"] {
        for invalid in ["invalid", String(repeating: "g", count: 32), "AABBCCDD-EEFF-4011-8022-334455667788"] {
            let plan = try ProtocolFixture.plan { $0[key] = invalid }
            #expect(throws: KidsEvidenceProtocolError.invalidConfiguration) { try plan.validate() }
        }
    }
    for digest in ["", String(repeating: "a", count: 63), String(repeating: "A", count: 64), String(repeating: "z", count: 64)] {
        let plan = try ProtocolFixture.plan { $0["digest"] = digest }
        #expect(throws: KidsEvidenceProtocolError.invalidConfiguration) { try plan.validate() }
    }
    let empty = try ProtocolFixture.plan { $0["trials"] = [[String: Any]]() }
    #expect(throws: KidsEvidenceProtocolError.invalidConfiguration) { try empty.validate() }
    let duplicated = try ProtocolFixture.plan { $0["trials"] = [ProtocolFixture.trialObject(), ProtocolFixture.trialObject()] }
    #expect(throws: KidsEvidenceProtocolError.invalidConfiguration) { try duplicated.validate() }
    for key in ["id", "item_id"] {
        let plan = try ProtocolFixture.plan {
            var trial = ProtocolFixture.trialObject()
            trial[key] = "invalid"
            $0["trials"] = [trial]
        }
        #expect(throws: KidsEvidenceProtocolError.invalidIdentity) { try plan.validate() }
    }
    for (key, invalid) in [
        ("client_id", "invalid"), ("cache_state", "warm"), ("app_build", ""),
        ("app_build", "https://example.invalid"), ("os_build", "synthetic build"),
        ("os_build", String(repeating: "a", count: 97))
    ] {
        let plan = try ProtocolFixture.plan {
            var client = ProtocolFixture.clientObject()
            client[key] = invalid
            $0["client"] = client
        }
        #expect(throws: KidsEvidenceProtocolError.invalidScope) { try plan.validate() }
    }
    #expect(throws: KidsEvidenceProtocolError.invalidScope) {
        try KidsEvidenceClient(
            platform: .simulator,
            clientID: "invalid",
            appBuild: "synthetic-1",
            osBuild: "synthetic-1",
            network: .unknown
        )
    }
}

@Test
func `protocol header has exact contract keys unavailable callbacks and bounded revision time`() throws {
    let plan = try ProtocolFixture.plan()
    let run = UUID()
    let clock = try ProtocolFixture.clock()
    let header = try KidsEvidenceRunHeader(
        plan: plan,
        runID: run,
        clock: clock,
        monotonicNS: UInt64(Int64.max),
        implementationRevision: ProtocolFixture.revision
    )
    let object = try protocolObject(header)
    #expect(Set(object.keys) == Set([
        "event",
        "protocol_version",
        "sequence",
        "run_id",
        "plan_id",
        "plan_digest",
        "server_id",
        "user_id",
        "client",
        "clock_id",
        "monotonic_ns",
        "implementation_revision",
        "callbacks"
    ]))
    #expect(object["event"] as? String == "run_started")
    #expect((object["sequence"] as? NSNumber)?.uint64Value == 0)
    #expect((object["protocol_version"] as? NSNumber)?.intValue == 1)
    #expect(object["run_id"] as? String == run.uuidString.lowercased())
    #expect(object["clock_id"] as? String == clock.id)
    #expect(object["plan_id"] as? String == ProtocolFixture.planID && object["plan_digest"] as? String == ProtocolFixture.digest)
    let callbacks = try #require(object["callbacks"] as? [String: String])
    #expect(callbacks == ["video": "unavailable", "audio": "unavailable", "decoder": "unavailable"])
    let sha256Revision = try KidsEvidenceRunHeader(
        plan: plan,
        runID: run,
        clock: clock,
        monotonicNS: 1,
        implementationRevision: String(repeating: "b", count: 64)
    )
    #expect(sha256Revision.implementationRevision.count == 64)
    for revision in [String(repeating: "a", count: 39), String(repeating: "a", count: 63), String(repeating: "A", count: 40), "HEAD"] {
        #expect(throws: KidsEvidenceProtocolError.invalidRevision) {
            try KidsEvidenceRunHeader(plan: plan, runID: run, clock: clock, monotonicNS: 1, implementationRevision: revision)
        }
    }
    #expect(throws: KidsEvidenceProtocolError.invalidTime) {
        try KidsEvidenceRunHeader(
            plan: plan,
            runID: run,
            clock: clock,
            monotonicNS: UInt64(Int64.max) + 1,
            implementationRevision: ProtocolFixture.revision
        )
    }
    #expect(throws: KidsEvidenceProtocolError.invalidTime) {
        try KidsEvidenceActionEvent(event: .playbackRequested, clock: clock, monotonicNS: UInt64.max)
    }
    #expect(throws: KidsEvidenceProtocolError.invalidTime) {
        try KidsEvidenceRunFooter(sequence: 1, runID: run, monotonicNS: UInt64.max, disposition: .complete)
    }
}

@Test
func `protocol partial record explicitly marks absent callback decoder condition and server evidence`() throws {
    let plan = try ProtocolFixture.plan {
        var trial = ProtocolFixture.trialObject()
        trial["load"] = "ingestion_active"
        trial["wan"] = "disconnected"
        $0["trials"] = [trial]
    }
    try plan.validate()
    let trial = try #require(plan.trials.first)
    let clock = try ProtocolFixture.clock()
    let event = try KidsEvidenceActionEvent(event: .playbackRequested, clock: clock, monotonicNS: 1)
    let record = try KidsEvidenceUnmeasuredRecord(trial: trial, clock: clock, event: event)
    let object = try protocolObject(record)
    #expect(Set(object.keys) == Set([
        "trial_id",
        "item_id",
        "outcome",
        "failure_code",
        "clock",
        "events",
        "decoder_load",
        "conditions",
        "behavior",
        "server_corroboration",
        "condition_observations"
    ]))
    #expect(object["trial_id"] as? String == ProtocolFixture.trialID && object["item_id"] as? String == ProtocolFixture.itemID)
    #expect(object["outcome"] as? String == "failed" && object["failure_code"] as? String == "unsupported_client_callback")
    #expect((object["decoder_load"] as? [Any])?.isEmpty == true)
    #expect(object["behavior"] is NSNull && object["condition_observations"] is NSNull)
    let conditions = try #require(object["conditions"] as? [String: Any])
    #expect(Set(conditions.keys) == Set(["load", "wan", "observed", "artifact_sha256", "media_properties_comparable"]))
    #expect(conditions["load"] as? String == "ingestion_active" && conditions["wan"] as? String == "disconnected")
    #expect(conditions["observed"] as? Bool == false && conditions["media_properties_comparable"] as? Bool == false)
    #expect(conditions["artifact_sha256"] is NSNull)
    let corroboration = try #require(object["server_corroboration"] as? [String: Any])
    #expect(Set(corroboration.keys) == Set(["play_method", "artifact_sha256", "ingestion_trace_id"]))
    #expect(corroboration.values.allSatisfy { $0 is NSNull })
    let events = try #require(object["events"] as? [[String: Any]])
    #expect(events.count == 1)
    #expect(Set(events[0].keys) == Set(["event", "clock_id", "monotonic_ns", "source"]))
    #expect(events[0]["event"] as? String == "playback_requested" && events[0]["clock_id"] as? String == clock.id)
    #expect((events[0]["monotonic_ns"] as? NSNumber)?.uint64Value == 1)
    #expect(events[0]["source"] as? String == "instrumented_client")
    let serialized = try String(decoding: JSONEncoder().encode(record), as: UTF8.self)
    #expect(!serialized.contains("first_video_presented") && !serialized.contains("first_audio_output") && !serialized
        .contains("seek_video_presented"))
    #expect(!serialized.contains("hardware_utilization") && !serialized.contains("\"success\""))
}

@Test
func `protocol seek action trial kind and clock mismatches fail without invented outcomes`() throws {
    let plan = try ProtocolFixture.plan()
    let start = try #require(plan.trials.first)
    let clock = try ProtocolFixture.clock()
    let seekEvent = try KidsEvidenceActionEvent(event: .seekRequested, clock: clock, monotonicNS: 1)
    #expect(throws: KidsEvidenceProtocolError.invalidConfiguration) {
        try KidsEvidenceUnmeasuredRecord(trial: start, clock: clock, event: seekEvent)
    }
    let foreign = try KidsEvidenceActionEvent(event: .playbackRequested, clock: KidsEvidenceClock(id: UUID()), monotonicNS: 1)
    #expect(throws: KidsEvidenceProtocolError.clockChanged) {
        try KidsEvidenceUnmeasuredRecord(trial: start, clock: clock, event: foreign)
    }
    let seek = try KidsEvidenceTrial(
        id: ProtocolFixture.trialID,
        itemID: ProtocolFixture.itemID,
        operation: .seek,
        load: .idle,
        wan: .connected
    )
    let record = try KidsEvidenceUnmeasuredRecord(trial: seek, clock: clock, event: seekEvent)
    #expect(record.events == [seekEvent] && record.outcome == .failed)
    let cancelled = try KidsEvidenceUnmeasuredRecord(trial: start, clock: clock, event: nil, failure: .userCancelled, outcome: .cancelled)
    #expect(cancelled.events.isEmpty && cancelled.outcome == .cancelled && cancelled.failureCode == .userCancelled)
}

@Test
func `protocol typed journal round trip preserves failure and drops private unknown planner fields`() throws {
    let plan = try ProtocolFixture.plan {
        $0["media_name"] = "PRIVATE_FIXTURE_NAME"
        $0["source_path"] = "/synthetic/PRIVATE_FIXTURE_PATH"
        $0["source_url"] = "https://example.invalid/PRIVATE_FIXTURE_URL?token=PRIVATE_FIXTURE_CREDENTIAL"
        var client = ProtocolFixture.clientObject()
        client["private_planner_metadata"] = "PRIVATE_FIXTURE_CLIENT"
        $0["client"] = client
        var trial = ProtocolFixture.trialObject()
        trial["private_planner_metadata"] = "PRIVATE_FIXTURE_TRIAL"
        $0["trials"] = [trial]
    }
    try plan.validate()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("fixture.jsonl")
    let run = UUID()
    let clock = try ProtocolFixture.clock()
    let journal = try KidsEvidenceJournal(enabled: true, fileURL: file, runID: run)
    let header = try KidsEvidenceRunHeader(
        plan: plan,
        runID: run,
        clock: clock,
        monotonicNS: 1,
        implementationRevision: ProtocolFixture.revision
    )
    let action = try KidsEvidenceActionEvent(event: .playbackRequested, clock: clock, monotonicNS: 1)
    let record = try KidsEvidenceUnmeasuredRecord(trial: #require(plan.trials.first), clock: clock, event: action)
    #expect(try journal.append(header))
    #expect(try journal.appendEncoded { sequence in
        try JSONEncoder().encode(KidsEvidenceTrialLine(sequence: sequence, runID: run, record: record))
    })
    #expect(try journal.appendEncoded { sequence in
        try JSONEncoder().encode(KidsEvidenceRunFooter(sequence: sequence, runID: run, monotonicNS: 2, disposition: .complete))
    })
    try journal.close()
    #expect(journal.status == .finished && journal.lossCount == 0)
    let data = try Data(contentsOf: file)
    #expect(data.last == 10)
    let lines = data.split(separator: 10).map(Data.init)
    #expect(lines.count == 3)
    let objects = try lines.map { line -> [String: Any] in
        var scanner = EvidenceJSONScanner(bytes: Array(line))
        _ = try scanner.scan()
        return try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
    }
    #expect(objects.map { ($0["sequence"] as! NSNumber).intValue } == [0, 1, 2])
    #expect(objects.map { $0["event"] as! String } == ["run_started", "trial_record", "run_finished"])
    #expect(objects.allSatisfy { $0["run_id"] as? String == run.uuidString.lowercased() })
    #expect(Set(objects[1].keys) == Set(["event", "sequence", "run_id", "record"]))
    #expect(Set(objects[2].keys) == Set(["event", "sequence", "run_id", "monotonic_ns", "disposition"]))
    let failure = try #require(objects[1]["record"] as? [String: Any])
    #expect(failure["outcome"] as? String == "failed" && failure["failure_code"] as? String == "unsupported_client_callback")
    #expect(objects[2]["disposition"] as? String == "complete") // Completeness of the journal is separate from trial success.
    let serialized = String(decoding: data, as: UTF8.self)
    #expect(!serialized.contains("PRIVATE_FIXTURE") && !serialized.contains("example.invalid") && !serialized.contains("/synthetic/"))
}
