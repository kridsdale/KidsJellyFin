//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CryptoKit

// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation

public extension KidsEvidencePlan {
    /// This only reads an explicitly supplied, private internal configuration.
    /// It does not contact Jellyfin, select media, or validate a server binding.
    static func load(fileURL: URL) throws -> Self {
        let fd = fileURL.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw KidsEvidenceProtocolError.invalidConfiguration }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_mode & mode_t(0o077) == 0,
              before.st_size > 0, before.st_size <= 2 * 1024 * 1024
        else { throw KidsEvidenceProtocolError.invalidConfiguration }
        guard let data = try file.read(upToCount: Int(before.st_size) + 1), data.count == before.st_size else {
            throw KidsEvidenceProtocolError.invalidConfiguration
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw KidsEvidenceProtocolError.invalidConfiguration }
        var scanner = EvidenceJSONScanner(bytes: Array(data), allowMultiline: true)
        _ = try scanner.scan()
        let plan = try JSONDecoder().decode(Self.self, from: data)
        try plan.validate()
        return plan
    }
}

/// Captured before network preparation; not an authorization to play an item.
public struct KidsEvidenceAction: Sendable {
    fileprivate let clock: KidsEvidenceClock
    fileprivate let requestedNS: UInt64
    fileprivate let scopeID: UUID
    fileprivate let nonce: UUID
}

/// App-private, opt-in coordination. Only explicitly planned IDs are journaled.
/// A fresh run/clock is allocated per attempt; cross-restart timing is unsupported.
@MainActor
public final class KidsEvidenceCapture {
    public static var shared: KidsEvidenceCapture?
    public static var setupFailure: KidsEvidenceProtocolError?
    @TaskLocal
    public static var currentAttempt: KidsEvidenceAttempt?
    public let plan: KidsEvidencePlan
    private let revision: String
    private let root: URL
    private let now: @MainActor () -> UInt64
    private let scopeID = UUID()
    private var consumed = Set<String>()
    private var usedActions = Set<UUID>()
    private var attempts: [KidsEvidenceAttempt] = []
    public var attemptStatuses: [KidsEvidenceAttemptStatus] {
        attempts.map(\.status)
    }

    public init(
        plan: KidsEvidencePlan,
        implementationRevision: String,
        directory: URL,
        platform: KidsEvidenceClient.Platform,
        appBuild: String,
        osBuild: String,
        now: @escaping @MainActor () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) throws {
        try plan.validate()
        guard plan.client.platform == platform, plan.client.appBuild == appBuild, plan.client.osBuild == osBuild,
              directory.isFileURL else { throw KidsEvidenceProtocolError.invalidScope }
        guard KidsEvidenceValidation.hex(implementationRevision, count: 40) || KidsEvidenceValidation.hex(implementationRevision, count: 64)
        else { throw KidsEvidenceProtocolError.invalidRevision }
        self.plan = plan
        revision = implementationRevision
        root = directory
        self.now = now
    }

    public func beginAction(serverID: String, userID: String, monotonicNS: UInt64? = nil) -> KidsEvidenceAction? {
        guard Self.sameID(serverID, plan.serverID), Self.sameID(userID, plan.userID) else { return nil }
        let ns = monotonicNS ?? now()
        guard KidsEvidenceValidation.time(ns) else { return nil }
        return .init(clock: .init(id: UUID()), requestedNS: ns, scopeID: scopeID, nonce: UUID())
    }

    public func bind(
        action: KidsEvidenceAction?,
        itemID: String,
        serverID: String,
        userID: String,
        clientID: String,
        operation: KidsEvidenceTrial.Operation = .start
    ) -> KidsEvidenceAttempt? {
        guard let action, action.scopeID == scopeID, !usedActions.contains(action.nonce),
              Self.sameID(serverID, plan.serverID), Self.sameID(userID, plan.userID),
              Self.sameID(clientID, plan.client.clientID) else { return nil }
        guard operation == .start || operation == .seek,
              let trial = plan.trials.first(where: {
                  $0.operation == operation && Self.sameID($0.itemID, itemID) && !consumed.contains($0.id) &&
                      !FileManager.default.fileExists(atPath: attemptDirectory(for: $0).path)
              }) else { return nil }
        consumed.insert(trial.id)
        usedActions.insert(action.nonce)
        do {
            let header = try KidsEvidenceRunHeader(
                plan: plan,
                runID: UUID(),
                clock: action.clock,
                monotonicNS: action.requestedNS,
                implementationRevision: revision
            )
            let event = try KidsEvidenceActionEvent(
                event: operation == .start ? .playbackRequested : .seekRequested,
                clock: action.clock,
                monotonicNS: action.requestedNS
            )
            let record = try KidsEvidenceUnmeasuredRecord(trial: trial, clock: action.clock, event: event)
            let attempt = KidsEvidenceAttempt(
                header: header,
                clock: action.clock,
                record: record,
                directory: attemptDirectory(for: trial)
            )
            attempts.append(attempt)
            return attempt
        } catch {
            Self.setupFailure = .invalidConfiguration
            return nil
        }
    }

    public func finishInterrupted() {
        let ns = now()
        for attempt in attempts {
            attempt.finish(monotonicNS: ns, disposition: .interrupted)
        }
    }

    private func attemptDirectory(for trial: KidsEvidenceTrial) -> URL {
        root.appendingPathComponent(plan.digest, isDirectory: true).appendingPathComponent(trial.id, isDirectory: true)
    }

    private static func sameID(_ lhs: String, _ rhs: String) -> Bool {
        lhs.replacingOccurrences(of: "-", with: "").lowercased() == rhs.replacingOccurrences(of: "-", with: "")
    }
}

public enum KidsEvidenceSupplementarySource: String, Codable, Sendable { case vlc, session }
public enum KidsEvidenceAttemptStatus: Equatable, Sendable {
    case preparing
    case recording
    case exportReady
    case interrupted
    case failed(KidsEvidenceJournalError)
}

/// The worker owns all disk I/O. Passive callbacks only enqueue immutable closed
/// payloads. Queue overflow stops capture visibly; it never becomes playback success.
public final class KidsEvidenceAttempt: @unchecked Sendable {
    public let directory: URL
    public let clock: KidsEvidenceClock
    private let header: KidsEvidenceRunHeader
    private let runID: UUID
    private let queue = DispatchQueue(label: "KidsEvidence.attempt", qos: .utility)
    private let lock = NSLock()
    private var state: KidsEvidenceAttemptStatus = .preparing
    private var queued = 0
    private var ending = false
    private var strict: KidsEvidenceJournal?
    private var supplementary: KidsEvidenceJournal?
    private var lastNS: UInt64
    private var receiptData: Data?
    private var exportHashes: (strict: String, supplementary: String)?

    init(header: KidsEvidenceRunHeader, clock: KidsEvidenceClock, record: KidsEvidenceUnmeasuredRecord, directory: URL) {
        self.header = header
        self.clock = clock
        self.directory = directory
        runID = UUID(uuidString: header.runID)!
        lastNS = header.monotonicNS
        queue.async { [self] in
            do {
                try Self.prepareDirectory(directory.deletingLastPathComponent(), exclusive: false)
                try Self.prepareDirectory(directory, exclusive: true)
                strict = try .init(enabled: true, fileURL: directory.appendingPathComponent("strict.jsonl"), runID: runID)
                supplementary = try .init(
                    enabled: true,
                    fileURL: directory.appendingPathComponent("supplementary.jsonl"),
                    runID: runID,
                    streamKind: .supplementary
                )
                try strict?.append(header)
                try supplementary?.append(header)
                try strict?.appendEncoded { sequence in
                    try JSONEncoder().encode(KidsEvidenceTrialLine(sequence: sequence, runID: runID, record: record))
                }
                setState(.recording)
                if case .failed = status {
                    closeIncomplete()
                }
            } catch {
                abort((error as? KidsEvidenceJournalError) ?? .fileCreationFailed)
            }
        }
    }

    public var status: KidsEvidenceAttemptStatus {
        locked { state }
    }

    public func observe(
        source: KidsEvidenceSupplementarySource,
        monotonicNS: UInt64,
        observation: some Encodable & Sendable
    ) {
        locked {
            guard !ending else { return }
            if case .failed = state {
                return
            }
            guard queued < 128 else {
                ending = true
                state = .failed(.totalLimit)
                queue.async { [self] in closeIncomplete() }
                return
            }
            queued += 1
            // Accept and enqueue under the same lock as finish. A concurrent
            // finish cannot publish a footer ahead of an accepted observation.
            queue.async { [self] in
                defer { locked { queued -= 1 } }
                guard case .recording = status else { return }
                guard KidsEvidenceValidation.time(monotonicNS), monotonicNS >= header.monotonicNS else {
                    abort(.invalidObject)
                    return
                }
                lastNS = max(lastNS, monotonicNS)
                do {
                    let record = SupplementaryRecord(source: source, clockID: clock.id, monotonicNS: monotonicNS, observation: observation)
                    try supplementary?.appendEncoded { sequence in
                        try JSONEncoder().encode(KidsEvidenceObservationLine(sequence: sequence, runID: runID, record: record))
                    }
                } catch { abort((error as? KidsEvidenceJournalError) ?? .encodingFailed) }
            }
        }
    }

    /// Explicitly closes capture, not the player. A complete journal disposition
    /// describes journal completeness; its strict trial remains failed/unmeasured.
    public func finish(monotonicNS: UInt64, disposition: KidsEvidenceRunFooter.Disposition = .complete) {
        locked {
            guard !ending else { return }
            ending = true
            queue.async { [self] in
                guard case .recording = status, KidsEvidenceValidation.time(monotonicNS), monotonicNS >= lastNS else {
                    if case .failed = status {} else {
                        abort(.invalidObject)
                    }
                    return
                }
                do {
                    for journal in [strict, supplementary].compactMap(\.self) {
                        try journal.appendEncoded { sequence in
                            try JSONEncoder().encode(KidsEvidenceRunFooter(
                                sequence: sequence,
                                runID: runID,
                                monotonicNS: monotonicNS,
                                disposition: disposition
                            ))
                        }
                        try journal.close()
                        guard journal.status == .finished, journal.lossCount == 0 else { throw KidsEvidenceJournalError.journalFailed }
                    }
                    try writeExportReceipt(disposition: disposition)
                    setState(disposition == .complete ? .exportReady : .interrupted)
                } catch { abort((error as? KidsEvidenceJournalError) ?? .writeFailed) }
            }
        }
    }

    /// Offline coordination only; UI callbacks never call this blocking boundary.
    public func flush() {
        queue.sync {}
    }

    public struct Export: Sendable {
        public let strictJSONL: Data
        public let supplementaryJSONL: Data
        public let durabilityReceipt: Data
    }

    /// Export is an explicit local read. A readable footer/receipt alone cannot
    /// override a failed write/sync or an observation lost before submission.
    public func export() throws -> Export {
        try queue.sync {
            guard status == .exportReady || status == .interrupted,
                  let hashes = exportHashes, let receiptData,
                  strict?.status == .finished, supplementary?.status == .finished,
                  strict?.lossCount == 0, supplementary?.lossCount == 0
            else { throw KidsEvidenceJournalError.journalFailed }
            let strictData = try Self.readPrivate(directory.appendingPathComponent("strict.jsonl"))
            let supplementaryData = try Self.readPrivate(directory.appendingPathComponent("supplementary.jsonl"))
            guard Self.digest(strictData) == hashes.strict, Self.digest(supplementaryData) == hashes.supplementary
            else { throw KidsEvidenceJournalError.journalFailed }
            return .init(strictJSONL: strictData, supplementaryJSONL: supplementaryData, durabilityReceipt: receiptData)
        }
    }

    private func writeExportReceipt(disposition: KidsEvidenceRunFooter.Disposition) throws {
        // Absence of this durable receipt forbids complete export, including a
        // readable footer whose synchronization failed.
        let strictHash = try Self.digest(Self.readPrivate(directory.appendingPathComponent("strict.jsonl")))
        let supplementaryHash = try Self.digest(Self.readPrivate(directory.appendingPathComponent("supplementary.jsonl")))
        let receipt = ExportReceipt(
            runID: header.runID,
            disposition: disposition.rawValue,
            strictBytes: strict?.durableBytes ?? 0,
            supplementaryBytes: supplementary?.durableBytes ?? 0,
            strictSHA256: strictHash,
            supplementarySHA256: supplementaryHash
        )
        let data = try JSONEncoder().encode(receipt)
        let url = directory.appendingPathComponent("durable-export.json")
        let pending = directory.appendingPathComponent("pending-export.json")
        let fd = pending.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { throw KidsEvidenceJournalError.fileCreationFailed }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: data)
        try file.synchronize()
        try file.close()
        guard link(pending.path, url.path) == 0 else { throw KidsEvidenceJournalError.fileCreationFailed }
        let directoryFD = directory.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard directoryFD >= 0 else { throw KidsEvidenceJournalError.synchronizeFailed }
        defer { Darwin.close(directoryFD) }
        guard fsync(directoryFD) == 0 else {
            _ = unlink(url.path)
            throw KidsEvidenceJournalError.synchronizeFailed
        }
        receiptData = data
        exportHashes = (strictHash, supplementaryHash)
        _ = unlink(pending.path)
    }

    private struct ExportReceipt: Encodable {
        let schemaVersion = 1
        let runID: String
        let disposition: String
        let strictBytes: Int
        let supplementaryBytes: Int
        let strictSHA256: String
        let supplementarySHA256: String
    }

    private struct SupplementaryRecord<Observation: Encodable & Sendable>: Encodable, Sendable {
        let source: KidsEvidenceSupplementarySource
        let clockID: String
        let monotonicNS: UInt64
        let observation: Observation
    }

    private func setState(_ value: KidsEvidenceAttemptStatus) {
        locked {
            // Once loss is reported, preparation/completion must never erase it.
            if case .failed = state {
                return
            }
            state = value
        }
    }

    private func abort(_ error: KidsEvidenceJournalError) {
        setState(.failed(error))
        closeIncomplete()
    }

    private func closeIncomplete() {
        // Closing preserves already-durable partial lines; no success footer is
        // synthesized after loss. The explicit status remains failed.
        try? strict?.close()
        try? supplementary?.close()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func readPrivate(_ url: URL) throws -> Data {
        let fd = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw KidsEvidenceJournalError.journalFailed }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & mode_t(0o077) == 0,
              info.st_size > 0, info.st_size <= KidsEvidenceJournal.maximumBytes,
              let data = try file.read(upToCount: Int(info.st_size) + 1), data.count == info.st_size
        else { throw KidsEvidenceJournalError.journalFailed }
        return data
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func prepareDirectory(_ url: URL, exclusive: Bool) throws {
        if mkdir(url.path, 0o700) != 0 {
            guard !exclusive, errno == EEXIST else { throw KidsEvidenceJournalError.fileCreationFailed }
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_mode & mode_t(0o077) == 0
        else { throw KidsEvidenceJournalError.insecureDirectory }
    }
}
