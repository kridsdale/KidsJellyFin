//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import CoreFoundation
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Fixed diagnostic categories deliberately exclude paths, operating-system messages, and payloads.
public enum KidsEvidenceJournalError: String, Error, Codable, Sendable {
    case invalidLimits
    case insecureDirectory
    case fileCreationFailed
    case invalidObject
    case invalidEnvelope
    case invalidSequence
    case wrongRun
    case invalidLifecycle
    case encodingFailed
    case lineLimit
    case totalLimit
    case writeFailed
    case synchronizeFailed
    case closeFailed
    case journalFailed
    case closedWithoutFooter
}

public enum KidsEvidenceJournalStream: Equatable, Sendable {
    case strict
    case supplementary
}

public enum KidsEvidenceJournalStatus: Equatable, Sendable {
    case disabled
    case open
    case finished
    case failed(KidsEvidenceJournalError)
}

/// Injectable only inside the module: failure tests must exercise partial writes and failed syncs.
protocol KidsEvidenceJournalIO: AnyObject, Sendable {
    func write(_ bytes: Data) throws -> Int
    func synchronize() throws
    func close() throws
}

private final class KidsEvidencePOSIXFile: KidsEvidenceJournalIO, @unchecked Sendable {
    private var descriptor: Int32

    init(fileURL: URL) throws {
        guard fileURL.isFileURL, !fileURL.lastPathComponent.isEmpty,
              fileURL.lastPathComponent != ".", fileURL.lastPathComponent != ".."
        else { throw KidsEvidenceJournalError.fileCreationFailed }
        let directory = fileURL.deletingLastPathComponent()
        let directoryFD = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryFD >= 0 else { throw KidsEvidenceJournalError.insecureDirectory }
        defer { _ = systemClose(directoryFD) }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0,
              directoryInfo.st_uid == geteuid(),
              (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (directoryInfo.st_mode & mode_t(0o077)) == 0
        else { throw KidsEvidenceJournalError.insecureDirectory }
        let newFD = fileURL.lastPathComponent.withCString {
            openat(directoryFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard newFD >= 0 else { throw KidsEvidenceJournalError.fileCreationFailed }
        var info = stat()
        guard fstat(newFD, &info) == 0,
              info.st_uid == geteuid(), info.st_nlink == 1,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              fchmod(newFD, mode_t(0o600)) == 0
        else {
            _ = systemClose(newFD)
            throw KidsEvidenceJournalError.fileCreationFailed
        }
        // Persist the new directory entry as well as subsequent file contents.
        guard fsync(directoryFD) == 0 else {
            _ = systemClose(newFD)
            throw KidsEvidenceJournalError.synchronizeFailed
        }
        descriptor = newFD
    }

    func write(_ bytes: Data) throws -> Int {
        guard descriptor >= 0 else { throw KidsEvidenceJournalError.writeFailed }
        return try bytes.withUnsafeBytes { raw in
            while true {
                let count = systemWrite(descriptor, raw.baseAddress, raw.count)
                if count >= 0 {
                    return count
                }
                if errno != EINTR {
                    throw KidsEvidenceJournalError.writeFailed
                }
            }
        }
    }

    func synchronize() throws {
        guard descriptor >= 0 else { throw KidsEvidenceJournalError.synchronizeFailed }
        while fsync(descriptor) != 0 {
            if errno != EINTR {
                throw KidsEvidenceJournalError.synchronizeFailed
            }
        }
    }

    func close() throws {
        guard descriptor >= 0 else { return }
        let value = descriptor
        descriptor = -1
        guard systemClose(value) == 0 else { throw KidsEvidenceJournalError.closeFailed }
    }

    deinit { try? close() }
}

private func systemClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(fd)
    #else
    Glibc.close(fd)
    #endif
}

private func systemWrite(_ fd: Int32, _ bytes: UnsafeRawPointer?, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.write(fd, bytes, count)
    #else
    Glibc.write(fd, bytes, count)
    #endif
}

/// A bounded synchronous journal. An acknowledgement means the entire newline-terminated
/// object was written and synced. This class validates the envelope; protocol models own
/// the nested schema and privacy policy. A run is never reopened or appended after its footer.
public final class KidsEvidenceJournal: @unchecked Sendable {
    public static let maximumBytes = 32 * 1024 * 1024
    public static let maximumLineBytes = 2 * 1024 * 1024

    public let runID: UUID
    public let fileURL: URL?
    private let streamKind: KidsEvidenceJournalStream
    private let lock = NSLock()
    private let io: (any KidsEvidenceJournalIO)?
    private let maxBytes: Int
    private let maxLineBytes: Int
    private let footerReserveBytes: Int
    private var state: KidsEvidenceJournalStatus
    private var sequence: UInt64 = 0
    private var bytes = 0
    private var losses: UInt64 = 0
    private var started = false
    private var terminal = false
    private var closed = false
    private var unsafeToWrite = false

    public convenience init(
        enabled: Bool,
        fileURL: URL,
        runID: UUID,
        streamKind: KidsEvidenceJournalStream = .strict,
        maxBytes: Int = KidsEvidenceJournal.maximumBytes,
        maxLineBytes: Int = KidsEvidenceJournal.maximumLineBytes,
        footerReserveBytes: Int = 1024
    ) throws {
        // Opt-out never checks, creates, opens, or otherwise touches the supplied path.
        if !enabled {
            self.init(
                enabled: false,
                fileURL: nil,
                runID: runID,
                streamKind: streamKind,
                maxBytes: maxBytes,
                maxLineBytes: maxLineBytes,
                footerReserveBytes: footerReserveBytes,
                io: nil
            )
            return
        }
        try Self.validateLimits(maxBytes: maxBytes, maxLineBytes: maxLineBytes, reserve: footerReserveBytes)
        let file = try KidsEvidencePOSIXFile(fileURL: fileURL)
        self.init(
            enabled: true,
            fileURL: fileURL,
            runID: runID,
            streamKind: streamKind,
            maxBytes: maxBytes,
            maxLineBytes: maxLineBytes,
            footerReserveBytes: footerReserveBytes,
            io: file
        )
    }

    init(
        enabled: Bool,
        fileURL: URL? = nil,
        runID: UUID,
        streamKind: KidsEvidenceJournalStream = .strict,
        maxBytes: Int = KidsEvidenceJournal.maximumBytes,
        maxLineBytes: Int = KidsEvidenceJournal.maximumLineBytes,
        footerReserveBytes: Int = 1024,
        io: (any KidsEvidenceJournalIO)?
    ) {
        self.runID = runID
        self.fileURL = enabled ? fileURL : nil
        self.streamKind = streamKind
        self.maxBytes = maxBytes
        self.maxLineBytes = maxLineBytes
        self.footerReserveBytes = footerReserveBytes
        self.io = enabled ? io : nil
        state = enabled ? .open : .disabled
    }

    public var status: KidsEvidenceJournalStatus {
        locked { state }
    }

    public var nextSequence: UInt64 {
        locked { sequence }
    }

    public var durableBytes: Int {
        locked { bytes }
    }

    public var lossCount: UInt64 {
        locked { losses }
    }

    @discardableResult
    public func append(_ encodedObject: Data) throws -> Bool {
        try appendEncoded { _ in encodedObject }
    }

    @discardableResult
    public func append(_ record: some Encodable) throws -> Bool {
        try appendEncoded { _ in try JSONEncoder().encode(record) }
    }

    /// The closure runs under the journal lock. It must not call back into this journal.
    /// Use its sequence to encode concurrent records without allocating sequence numbers
    /// outside the serialized durable append. Caller payloads must be privacy-safe models.
    @discardableResult
    public func appendEncoded(_ encode: (UInt64) throws -> Data) throws -> Bool {
        try locked {
            guard state != .disabled else { return false }
            guard !closed, !terminal else { throw KidsEvidenceJournalError.invalidLifecycle }
            guard !unsafeToWrite else { throw KidsEvidenceJournalError.journalFailed }
            let data: Data
            do { data = try encode(sequence) }
            catch {
                fail(.encodingFailed)
                throw KidsEvidenceJournalError.encodingFailed
            }
            guard data.count < maxLineBytes else {
                fail(.lineLimit)
                throw KidsEvidenceJournalError.lineLimit
            }
            let envelope: Envelope
            do { envelope = try validate(data) }
            catch let error as KidsEvidenceJournalError {
                fail(error)
                throw error
            } catch {
                fail(.invalidObject)
                throw KidsEvidenceJournalError.invalidObject
            }
            if losses > 0, !(envelope.event == "run_finished" && envelope.disposition == "interrupted") {
                throw KidsEvidenceJournalError.journalFailed
            }
            var line = data
            line.append(0x0A)
            guard line.count <= maxLineBytes else {
                fail(.lineLimit)
                throw KidsEvidenceJournalError.lineLimit
            }
            let remaining = maxBytes - bytes
            let reserve = envelope.event == "run_finished" ? 0 : footerReserveBytes
            guard remaining >= reserve, line.count <= remaining - reserve else {
                fail(.totalLimit)
                throw KidsEvidenceJournalError.totalLimit
            }
            guard let io else {
                fail(.writeFailed, poison: true)
                throw KidsEvidenceJournalError.writeFailed
            }
            var offset = 0
            do {
                while offset < line.count {
                    let written = try io.write(Data(line[offset...]))
                    guard written > 0, written <= line.count - offset else {
                        throw KidsEvidenceJournalError.writeFailed
                    }
                    offset += written
                }
            } catch {
                fail(.writeFailed, poison: true)
                throw KidsEvidenceJournalError.writeFailed
            }
            do { try io.synchronize() }
            catch {
                fail(.synchronizeFailed, poison: true)
                throw KidsEvidenceJournalError.synchronizeFailed
            }
            bytes += line.count
            sequence += 1
            started = true
            if envelope.event == "run_finished" {
                terminal = true
                if losses == 0 {
                    state = .finished
                }
            }
            return true
        }
    }

    /// Closing without a durable footer is incomplete, even when all preceding lines synced.
    public func close() throws {
        try locked {
            guard state != .disabled, !closed else { return }
            closed = true
            if !terminal {
                fail(.closedWithoutFooter)
            }
            do { try io?.close() }
            catch {
                fail(.closeFailed, poison: true)
                throw KidsEvidenceJournalError.closeFailed
            }
        }
    }

    private struct Envelope {
        let event: String
        let disposition: String?
    }

    private func validate(_ data: Data) throws -> Envelope {
        var scanner = EvidenceJSONScanner(bytes: Array(data))
        let lexicalSequence = try scanner.scan()
        guard !data.isEmpty, !data.contains(0x0A), !data.contains(0x0D),
              String(data: data, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw KidsEvidenceJournalError.invalidObject }
        guard let event = object["event"] as? String,
              let sequenceToken = lexicalSequence,
              sequenceToken.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              let candidateSequence = UInt64(sequenceToken)
        else { throw KidsEvidenceJournalError.invalidEnvelope }
        guard candidateSequence == sequence else { throw KidsEvidenceJournalError.invalidSequence }
        guard let candidateRun = object["run_id"] as? String,
              candidateRun == runID.uuidString.lowercased()
        else { throw KidsEvidenceJournalError.wrongRun }
        let keys = Set(object.keys)
        let disposition: String?
        switch event {
        case "run_started":
            guard !started, sequence == 0,
                  keys == Set([
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
                  ]),
                  unsignedInteger(object["protocol_version"]) == 1
            else { throw KidsEvidenceJournalError.invalidLifecycle }
            disposition = nil
        case "trial_record", "observation_record":
            let accepted = streamKind == .strict ? "trial_record" : "observation_record"
            guard started, event == accepted,
                  keys == Set(["event", "sequence", "run_id", "record"]),
                  object["record"] is [String: Any]
            else { throw KidsEvidenceJournalError.invalidLifecycle }
            disposition = nil
        case "run_finished":
            guard started,
                  keys == Set(["event", "sequence", "run_id", "monotonic_ns", "disposition"]),
                  unsignedInteger(object["monotonic_ns"]) != nil,
                  let value = object["disposition"] as? String,
                  value == "complete" || value == "interrupted"
            else { throw KidsEvidenceJournalError.invalidLifecycle }
            disposition = value
        default:
            throw KidsEvidenceJournalError.invalidEnvelope
        }
        return Envelope(event: event, disposition: disposition)
    }

    private func unsignedInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let string = number.stringValue
        guard !string.isEmpty, string.utf8.allSatisfy({ (48 ... 57).contains($0) }) else { return nil }
        return UInt64(string)
    }

    private func fail(_ error: KidsEvidenceJournalError, poison: Bool = false) {
        losses += 1
        if case .failed = state {} else {
            state = .failed(error)
        }
        unsafeToWrite = unsafeToWrite || poison
    }

    private static func validateLimits(maxBytes: Int, maxLineBytes: Int, reserve: Int) throws {
        guard maxBytes > 0, maxBytes <= maximumBytes,
              maxLineBytes > 0, maxLineBytes <= maximumLineBytes,
              reserve >= 256, reserve <= maxLineBytes, reserve < maxBytes
        else { throw KidsEvidenceJournalError.invalidLimits }
    }

    private func locked<T>(_ action: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try action()
    }

    deinit { try? io?.close() }
}

/// Foundation collapses duplicate object keys and normalizes `1.0` to `1`.
/// Preserve sequence token spelling and reject duplicate keys at every nesting level
/// before Foundation performs the remaining JSON and UTF-8 validation.
struct EvidenceJSONScanner {
    let bytes: [UInt8]
    private let allowMultiline: Bool
    private var index = 0
    private var sequenceToken: String?

    init(bytes: [UInt8], allowMultiline: Bool = false) {
        self.bytes = bytes
        self.allowMultiline = allowMultiline
    }

    mutating func scan() throws -> String? {
        skipWhitespace()
        guard peek == 123 else { throw KidsEvidenceJournalError.invalidObject }
        try object(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw KidsEvidenceJournalError.invalidObject }
        return sequenceToken
    }

    private var peek: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func skipWhitespace() {
        while peek == 32 || peek == 9 || (allowMultiline && (peek == 10 || peek == 13)) {
            index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) throws {
        guard peek == byte else { throw KidsEvidenceJournalError.invalidObject }
        index += 1
        skipWhitespace()
    }

    private mutating func string() throws -> String {
        guard peek == 34 else { throw KidsEvidenceJournalError.invalidObject }
        let start = index
        index += 1
        while let current = peek {
            if current == 34 {
                index += 1
                guard let decoded = try? JSONDecoder().decode(String.self, from: Data(bytes[start ..< index]))
                else { throw KidsEvidenceJournalError.invalidObject }
                skipWhitespace()
                return decoded
            }
            guard current >= 32 else { throw KidsEvidenceJournalError.invalidObject }
            if current == 92 {
                index += 1
                guard peek != nil else { throw KidsEvidenceJournalError.invalidObject }
            }
            index += 1
        }
        throw KidsEvidenceJournalError.invalidObject
    }

    private mutating func object(depth: Int) throws {
        guard depth < 128 else { throw KidsEvidenceJournalError.invalidObject }
        try consume(123)
        if peek == 125 {
            try consume(125)
            return
        }
        var keys = Set<String>()
        while true {
            let key = try string()
            guard keys.insert(key).inserted else { throw KidsEvidenceJournalError.invalidObject }
            try consume(58)
            let token = try value(depth: depth + 1)
            if depth == 0, key == "sequence" {
                sequenceToken = token
            }
            if peek == 125 {
                try consume(125)
                return
            }
            try consume(44)
        }
    }

    private mutating func value(depth: Int) throws -> String? {
        guard depth < 128, let current = peek else { throw KidsEvidenceJournalError.invalidObject }
        switch current {
        case 123:
            try object(depth: depth)
            return nil
        case 91:
            try consume(91)
            if peek == 93 {
                try consume(93)
                return nil
            }
            while true {
                _ = try value(depth: depth + 1)
                if peek == 93 {
                    try consume(93)
                    return nil
                }
                try consume(44)
            }
        case 34:
            _ = try string()
            return nil
        case 116, 102, 110:
            let literal: [UInt8] = current == 116 ? Array("true".utf8) : current == 102 ? Array("false".utf8) : Array("null".utf8)
            guard bytes.count - index >= literal.count,
                  Array(bytes[index ..< index + literal.count]) == literal
            else { throw KidsEvidenceJournalError.invalidObject }
            index += literal.count
            skipWhitespace()
            return nil
        case 45, 48 ... 57:
            let start = index
            while let character = peek,
                  character == 45 || character == 43 || character == 46 || character == 101 || character == 69 || (48 ... 57)
                      .contains(character)
            {
                index += 1
            }
            let token = String(decoding: bytes[start ..< index], as: UTF8.self)
            skipWhitespace()
            return token
        default:
            throw KidsEvidenceJournalError.invalidObject
        }
    }
}
