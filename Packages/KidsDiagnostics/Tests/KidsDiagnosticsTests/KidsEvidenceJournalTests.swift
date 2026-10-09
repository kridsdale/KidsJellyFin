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

private final class EvidenceMemoryIO: KidsEvidenceJournalIO, @unchecked Sendable {
    var bytes = Data()
    var writes = 0
    var synchronizations = 0
    var closed = false
    var maximumChunk = Int.max
    var failWriteNumber: Int?
    var failSyncNumber: Int?

    func write(_ bytes: Data) throws -> Int {
        writes += 1
        if writes == failWriteNumber {
            throw KidsEvidenceJournalError.writeFailed
        }
        let count = min(bytes.count, maximumChunk)
        self.bytes.append(bytes.prefix(count))
        return count
    }

    func synchronize() throws {
        synchronizations += 1
        if synchronizations == failSyncNumber {
            throw KidsEvidenceJournalError.synchronizeFailed
        }
    }

    func close() {
        closed = true
    }
}

private func evidenceObject(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func evidenceHeader(_ run: UUID, sequence: UInt64 = 0) throws -> Data {
    try evidenceObject([
        "event": "run_started", "protocol_version": 1, "sequence": sequence,
        "run_id": run.uuidString.lowercased(), "plan_id": "fixture-plan", "plan_digest": String(repeating: "a", count: 64),
        "server_id": "fixture-server", "user_id": "fixture-user", "client": ["platform": "offline_fixture"],
        "clock_id": UUID().uuidString.lowercased(), "monotonic_ns": 1,
        "implementation_revision": String(repeating: "b", count: 40),
        "callbacks": ["video": "unavailable", "audio": "unavailable", "decoder": "unavailable"]
    ])
}

private func evidenceRecord(_ run: UUID, sequence: UInt64, event: String = "trial_record", padding: Int = 0) throws -> Data {
    try evidenceObject([
        "event": event, "sequence": sequence, "run_id": run.uuidString.lowercased(),
        "record": ["fixture": String(repeating: "x", count: padding)]
    ])
}

private func evidenceFooter(_ run: UUID, sequence: UInt64, disposition: String = "complete") throws -> Data {
    try evidenceObject([
        "event": "run_finished", "sequence": sequence, "run_id": run.uuidString.lowercased(),
        "monotonic_ns": 2, "disposition": disposition
    ])
}

private func evidencePrivateDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return directory
}

@Test
func `evidence opt out touches no path and invokes no encoder`() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let journal = try KidsEvidenceJournal(enabled: false, fileURL: directory.appendingPathComponent("run.jsonl"), runID: UUID())
    let accepted = try journal.appendEncoded { _ in
        Issue.record("Disabled journal called encoder")
        return Data()
    }
    try journal.close()
    #expect(!accepted && journal.status == .disabled && journal.fileURL == nil)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@Test
func `evidence real file is private fresh newline complete and terminal`() throws {
    let directory = try evidencePrivateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("run.jsonl")
    let run = UUID()
    let journal = try KidsEvidenceJournal(enabled: true, fileURL: file, runID: run)
    #expect(try journal.append(evidenceHeader(run)))
    #expect(try journal.append(evidenceRecord(run, sequence: 1)))
    #expect(try journal.append(evidenceFooter(run, sequence: 2)))
    #expect(journal.status == .finished && journal.nextSequence == 3 && journal.lossCount == 0)
    #expect(throws: KidsEvidenceJournalError.invalidLifecycle) { try journal.append(evidenceRecord(run, sequence: 3)) }
    try journal.close()
    let bytes = try Data(contentsOf: file)
    #expect(bytes.last == 10 && bytes.count == journal.durableBytes)
    let objects = try bytes.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
    #expect(objects.count == 3)
    #expect(objects.map { ($0["sequence"] as! NSNumber).intValue } == [0, 1, 2])
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect(try #require((attributes[.posixPermissions] as? NSNumber)?.intValue) & 0o777 == 0o600)
    #expect(throws: KidsEvidenceJournalError.fileCreationFailed) {
        try KidsEvidenceJournal(enabled: true, fileURL: file, runID: UUID())
    }
    #expect(try Data(contentsOf: file) == bytes)
}

@Test
func `evidence rejects insecure directories and directory or destination symlinks`() throws {
    let parent = try evidencePrivateDirectory()
    defer { try? FileManager.default.removeItem(at: parent) }
    let target = parent.appendingPathComponent("target", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    let file = target.appendingPathComponent("run.jsonl")
    #expect(throws: KidsEvidenceJournalError.insecureDirectory) {
        try KidsEvidenceJournal(enabled: true, fileURL: file, runID: UUID())
    }
    #expect(!FileManager.default.fileExists(atPath: file.path))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
    let alias = parent.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    #expect(throws: KidsEvidenceJournalError.insecureDirectory) {
        try KidsEvidenceJournal(enabled: true, fileURL: alias.appendingPathComponent("run.jsonl"), runID: UUID())
    }
    let preserved = target.appendingPathComponent("preserved")
    try Data([1, 2, 3]).write(to: preserved)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: preserved)
    #expect(throws: KidsEvidenceJournalError.fileCreationFailed) {
        try KidsEvidenceJournal(enabled: true, fileURL: file, runID: UUID())
    }
    #expect(try Data(contentsOf: preserved) == Data([1, 2, 3]))
}

@Test
func `evidence envelope validation forbids sequence gaps wrong runs and completion after loss`() throws {
    let run = UUID()
    let io = EvidenceMemoryIO()
    let journal = KidsEvidenceJournal(enabled: true, runID: run, io: io)
    try journal.append(evidenceHeader(run))
    #expect(throws: KidsEvidenceJournalError.invalidSequence) { try journal.append(evidenceRecord(run, sequence: 2)) }
    #expect(journal.status == .failed(.invalidSequence) && journal.nextSequence == 1 && journal.lossCount == 1)
    #expect(throws: KidsEvidenceJournalError.journalFailed) { try journal.append(evidenceFooter(run, sequence: 1)) }
    #expect(try journal.append(evidenceFooter(run, sequence: 1, disposition: "interrupted")))
    #expect(journal.status == .failed(.invalidSequence) && journal.nextSequence == 2)
    #expect(!String(decoding: io.bytes, as: UTF8.self).contains("\"complete\""))

    let wrong = KidsEvidenceJournal(enabled: true, runID: run, io: EvidenceMemoryIO())
    #expect(throws: KidsEvidenceJournalError.wrongRun) { try wrong.append(evidenceHeader(UUID())) }
    #expect(wrong.durableBytes == 0)
}

@Test
func `evidence stream kind and single object shape are enforced`() throws {
    let run = UUID()
    let strict = KidsEvidenceJournal(enabled: true, runID: run, io: EvidenceMemoryIO())
    try strict.append(evidenceHeader(run))
    #expect(throws: KidsEvidenceJournalError.invalidLifecycle) {
        try strict.append(evidenceRecord(run, sequence: 1, event: "observation_record"))
    }
    let supplementary = KidsEvidenceJournal(enabled: true, runID: run, streamKind: .supplementary, io: EvidenceMemoryIO())
    try supplementary.append(evidenceHeader(run))
    #expect(try supplementary.append(evidenceRecord(run, sequence: 1, event: "observation_record")))
    #expect(throws: KidsEvidenceJournalError.invalidLifecycle) { try supplementary.append(evidenceRecord(run, sequence: 2)) }
    for data in [Data("[]".utf8), Data("{}\n{}".utf8), Data([0xFF]), Data("{\"sequence\":true}".utf8)] {
        let isolated = KidsEvidenceJournal(enabled: true, runID: run, io: EvidenceMemoryIO())
        #expect(throws: (any Error).self) { try isolated.append(data) }
        #expect(isolated.durableBytes == 0 && isolated.lossCount == 1)
    }
}

@Test
func `evidence reserves interrupted footer space and bounds every line`() throws {
    let run = UUID()
    let io = EvidenceMemoryIO()
    let header = try evidenceHeader(run)
    let reserve = 256
    let journal = KidsEvidenceJournal(
        enabled: true,
        runID: run,
        maxBytes: header.count + 1 + reserve,
        maxLineBytes: 2048,
        footerReserveBytes: reserve,
        io: io
    )
    try journal.append(header)
    #expect(throws: KidsEvidenceJournalError.totalLimit) { try journal.append(evidenceRecord(run, sequence: 1)) }
    #expect(try journal.append(evidenceFooter(run, sequence: 1, disposition: "interrupted")))
    #expect(io.bytes.count <= header.count + 1 + reserve)
    #expect(io.bytes.last == 10 && journal.lossCount == 1)

    let bounded = KidsEvidenceJournal(enabled: true, runID: run, maxLineBytes: 1024, io: EvidenceMemoryIO())
    try bounded.append(evidenceHeader(run))
    #expect(throws: KidsEvidenceJournalError.lineLimit) {
        try bounded.append(evidenceRecord(run, sequence: 1, padding: 1024))
    }
    #expect(bounded.status == .failed(.lineLimit) && bounded.nextSequence == 1)
}

@Test
func `evidence partial writes complete before ack but write or sync failures permanently poison stream`() throws {
    let run = UUID()
    let chunked = EvidenceMemoryIO()
    chunked.maximumChunk = 7
    let journal = KidsEvidenceJournal(enabled: true, runID: run, io: chunked)
    let header = try evidenceHeader(run)
    #expect(try journal.append(header))
    #expect(chunked.bytes == header + Data([10]))
    #expect(chunked.writes > 1 && chunked.synchronizations == 1 && journal.durableBytes == header.count + 1)

    let partial = EvidenceMemoryIO()
    partial.maximumChunk = 7
    partial.failWriteNumber = 2
    let poisoned = KidsEvidenceJournal(enabled: true, runID: run, io: partial)
    #expect(throws: KidsEvidenceJournalError.writeFailed) { try poisoned.append(header) }
    #expect(partial.bytes.count == 7 && poisoned.durableBytes == 0 && poisoned.nextSequence == 0)
    #expect(throws: KidsEvidenceJournalError.journalFailed) { try poisoned.append(evidenceFooter(
        run,
        sequence: 0,
        disposition: "interrupted"
    )) }
    #expect(partial.bytes.count == 7 && poisoned.status == .failed(.writeFailed))

    let unsynced = EvidenceMemoryIO()
    unsynced.failSyncNumber = 1
    let syncPoisoned = KidsEvidenceJournal(enabled: true, runID: run, io: unsynced)
    #expect(throws: KidsEvidenceJournalError.synchronizeFailed) { try syncPoisoned.append(header) }
    #expect(syncPoisoned.nextSequence == 0 && syncPoisoned.durableBytes == 0 && unsynced.bytes.last == 10)
    #expect(throws: KidsEvidenceJournalError.journalFailed) { try syncPoisoned.append(header) }
    #expect(unsynced.synchronizations == 1 && syncPoisoned.status == .failed(.synchronizeFailed))
}

@Test
func `evidence encoder failure and closing without footer cannot claim complete`() throws {
    struct Failing: Encodable {
        func encode(to encoder: any Encoder) throws {
            throw KidsEvidenceJournalError.invalidObject
        }
    }
    let run = UUID()
    let io = EvidenceMemoryIO()
    let journal = KidsEvidenceJournal(enabled: true, runID: run, io: io)
    try journal.append(evidenceHeader(run))
    #expect(throws: KidsEvidenceJournalError.encodingFailed) { try journal.append(Failing()) }
    #expect(throws: KidsEvidenceJournalError.journalFailed) { try journal.append(evidenceFooter(run, sequence: 1)) }
    try journal.append(evidenceFooter(run, sequence: 1, disposition: "interrupted"))
    #expect(journal.status == .failed(.encodingFailed))

    let unfinished = KidsEvidenceJournal(enabled: true, runID: UUID(), io: EvidenceMemoryIO())
    try unfinished.close()
    #expect(unfinished.status == .failed(.closedWithoutFooter))
    #expect(throws: KidsEvidenceJournalError.invalidLifecycle) { try unfinished.append(Data()) }
}

@Test
func `evidence concurrent records receive contiguous durable serialized sequences`() async throws {
    let run = UUID()
    let io = EvidenceMemoryIO()
    let journal = KidsEvidenceJournal(enabled: true, runID: run, io: io)
    try journal.append(evidenceHeader(run))
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0 ..< 100 {
            group.addTask {
                try journal.appendEncoded { sequence in try evidenceRecord(run, sequence: sequence) }
            }
        }
        try await group.waitForAll()
    }
    try journal.appendEncoded { sequence in try evidenceFooter(run, sequence: sequence) }
    let sequences = try io.bytes.split(separator: 10).map {
        let object = try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
        return (object["sequence"] as! NSNumber).intValue
    }
    #expect(sequences == Array(0 ... 101))
    #expect(io.synchronizations == 102 && journal.nextSequence == 102 && journal.status == .finished)
}

@Test
func `evidence caller cannot raise protocol storage limits`() throws {
    let directory = try evidencePrivateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("run.jsonl")
    #expect(throws: KidsEvidenceJournalError.invalidLimits) {
        try KidsEvidenceJournal(enabled: true, fileURL: file, runID: UUID(), maxBytes: KidsEvidenceJournal.maximumBytes + 1)
    }
    #expect(throws: KidsEvidenceJournalError.invalidLimits) {
        try KidsEvidenceJournal(enabled: true, fileURL: file, runID: UUID(), maxLineBytes: KidsEvidenceJournal.maximumLineBytes + 1)
    }
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test
func `evidence raw input rejects duplicate keys and boolean floating or exponent sequences`() throws {
    let run = UUID()
    let header = try String(decoding: evidenceHeader(run), as: UTF8.self)
    let duplicate = header.replacingOccurrences(
        of: "\"event\":\"run_started\"",
        with: "\"event\":\"run_started\",\"event\":\"run_started\""
    )
    let escapedDuplicate = header.replacingOccurrences(
        of: "\"event\":\"run_started\"",
        with: "\"event\":\"run_started\",\"\\u0065vent\":\"run_started\""
    )
    let nestedDuplicate = header.replacingOccurrences(
        of: "\"platform\":\"offline_fixture\"",
        with: "\"platform\":\"offline_fixture\",\"platform\":\"offline_fixture\""
    )
    for content in [duplicate, escapedDuplicate, nestedDuplicate] {
        let journal = KidsEvidenceJournal(enabled: true, runID: run, io: EvidenceMemoryIO())
        #expect(throws: KidsEvidenceJournalError.invalidObject) { try journal.append(Data(content.utf8)) }
        #expect(journal.lossCount == 1 && journal.durableBytes == 0)
    }
    for token in ["true", "0.0", "0e0", "-0", "null", "\"0\""] {
        let content = header.replacingOccurrences(of: "\"sequence\":0", with: "\"sequence\":\(token)")
        let journal = KidsEvidenceJournal(enabled: true, runID: run, io: EvidenceMemoryIO())
        #expect(throws: KidsEvidenceJournalError.invalidEnvelope) { try journal.append(Data(content.utf8)) }
        #expect(journal.nextSequence == 0)
    }
}

@Test
func `evidence scanner permits plan formatting only when explicitly requested`() throws {
    let data = Data("{\n  \"plan\": {\r\n    \"id\": \"fixture\"\n  }\n}".utf8)
    var line = EvidenceJSONScanner(bytes: Array(data))
    #expect(throws: KidsEvidenceJournalError.invalidObject) { try line.scan() }
    var plan = EvidenceJSONScanner(bytes: Array(data), allowMultiline: true)
    #expect(try plan.scan() == nil)
    var duplicated = EvidenceJSONScanner(bytes: Array("{\n\"id\":1,\n\"id\":2\n}".utf8), allowMultiline: true)
    #expect(throws: KidsEvidenceJournalError.invalidObject) { try duplicated.scan() }
    var control = EvidenceJSONScanner(bytes: Array("{\"id\":\"line\nbreak\"}".utf8), allowMultiline: true)
    #expect(throws: KidsEvidenceJournalError.invalidObject) { try control.scan() }
}
