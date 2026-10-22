//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Darwin
import Foundation
import KidsAccounts
import KidsDomain
import KidsParentControl

/// Captured mutations and exact pending evidence. No token, permission, or media is stored.
@MainActor
final class KidsAdmissionJournal {
    struct Intent: Codable, Equatable {
        let commandID: UUID
        let expectedRevision: Int
        let sessionID: String
        let itemID: String
        var persisted = false
        var abandoned = false
    }

    struct Surrender: Codable, Equatable {
        let commandID: UUID
        let intentID: UUID
        let sessionID: String
        let itemID: String
    }

    private struct Scope: Codable, Equatable {
        let service: URL
        let server: String
        let child: String
        let device: UUID
    }

    private struct State: Codable {
        var version: Int
        let scope: Scope
        var intent: Intent?
        var surrender: Surrender?
        var events: [ReceiverEvent]

        enum CodingKeys: String, CodingKey { case version, scope, intent, surrender, events }

        init(scope: Scope) {
            version = 2
            self.scope = scope
            events = []
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            scope = try values.decode(Scope.self, forKey: .scope)
            intent = try values.decodeIfPresent(Intent.self, forKey: .intent)
            surrender = try values.decodeIfPresent(Surrender.self, forKey: .surrender)
            if version == 1 {
                guard !values.contains(.events) else { throw KidsContractError.denied }
                events = []
            } else {
                events = try values.decode([ReceiverEvent].self, forKey: .events)
            }
        }
    }

    private var state: State
    private let url: URL
    var intent: Intent? {
        state.intent
    }

    var surrender: Surrender? {
        state.surrender
    }

    var events: [ReceiverEvent] {
        state.events
    }

    init(configuration: KidsReceiverConfiguration, directory: URL) throws {
        let scope = Scope(
            service: configuration.serviceURL,
            server: configuration.serverID,
            child: configuration.childUserID,
            device: configuration.deviceID
        )
        var folder = directory.appendingPathComponent("Admissions", isDirectory: true)
        for value in [scope.service.absoluteString, scope.server, scope.child] {
            guard !value.isEmpty, value.utf8.count <= 512 else { throw KidsContractError.denied }
            let encoded = Array(Data(value.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-"))
            for start in stride(from: 0, to: encoded.count, by: 100) {
                folder.appendPathComponent(String(encoded[start ..< min(start + 100, encoded.count)]), isDirectory: true)
            }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        url = folder.appendingPathComponent("\(scope.device.uuidString).json")
        if FileManager.default.fileExists(atPath: url.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 262_144 else { throw KidsContractError.denied }
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
            guard (1 ... 2).contains(state.version), state.scope == scope else { throw KidsContractError.denied }
            try validateEvents(state.events)
            state.version = 2
            if let intent = state.intent, let surrender = state.surrender {
                guard intent.commandID == surrender.intentID, intent.sessionID == surrender.sessionID,
                      intent.itemID == surrender.itemID else { throw KidsContractError.denied }
            }
        } else {
            state = State(scope: scope)
        }
        // A new runtime has no surviving operational controller. Resolve an
        // unknown POST, then retire that exact intent BEFORE the first policy GET.
        if let intent = state.intent {
            try abandon(intent.commandID)
        }
    }

    func appendEvent(_ event: ReceiverEvent) throws {
        guard state.events.count < 128,
              !state.events.contains(where: { $0.eventID == event.eventID }) else { throw KidsContractError.denied }
        try validateEvents([event])
        try update { $0.events.append(event) }
    }

    func acknowledgeEvent(_ id: UUID) throws {
        guard state.events.first?.eventID == id else { throw KidsContractError.denied }
        try update { $0.events.removeFirst() }
    }

    private func validateEvents(_ events: [ReceiverEvent]) throws {
        guard events.count <= 128, Set(events.map(\.eventID)).count == events.count,
              events.allSatisfy({ event in
                  event.deviceID == state.scope.device.uuidString && event.childUserID == state.scope.child &&
                      event.policyRevision >= 0 && event.elapsedPlayingSeconds.isFinite &&
                      (0 ... 30).contains(event.elapsedPlayingSeconds) &&
                      (event.positionSeconds.map { $0.isFinite && $0 >= 0 } ?? true) &&
                      [event.playbackSessionID, event.itemID].allSatisfy { value in
                          value.map { !$0.isEmpty && $0.utf8.count <= 512 } ?? true
                      }
              }) else { throw KidsContractError.denied }
    }

    func stage(_ intent: Intent) throws {
        guard state.intent == nil, state.surrender == nil, intent.expectedRevision >= 0,
              !intent.sessionID.isEmpty, !intent.itemID.isEmpty else { throw KidsContractError.denied }
        try update { $0.intent = intent }
    }

    func acknowledgeIntent(_ id: UUID) throws {
        guard state.intent?.commandID == id else { throw KidsContractError.denied }
        try update { $0.intent?.persisted = true }
    }

    func abandon(_ id: UUID) throws {
        guard let intent = state.intent, intent.commandID == id else { throw KidsContractError.denied }
        try update {
            $0.intent?.abandoned = true
            if $0.surrender == nil {
                $0.surrender = Surrender(commandID: UUID(), intentID: id, sessionID: intent.sessionID, itemID: intent.itemID)
            }
        }
    }

    func stageSurrender(intentID: UUID, sessionID: String, itemID: String) throws {
        guard !sessionID.isEmpty, !itemID.isEmpty else { throw KidsContractError.denied }
        if let existing = state.surrender {
            guard existing.intentID == intentID, existing.sessionID == sessionID,
                  existing.itemID == itemID else { throw KidsContractError.denied }
            return
        }
        try update { $0.surrender = Surrender(commandID: UUID(), intentID: intentID, sessionID: sessionID, itemID: itemID) }
    }

    func rejectUncommittedIntent(_ id: UUID) throws {
        guard state.intent?.commandID == id else { throw KidsContractError.denied }
        try update {
            $0.intent = nil
            if $0.surrender?.intentID == id {
                $0.surrender = nil
            }
        }
    }

    func acknowledgeSurrender(_ id: UUID) throws {
        guard let surrender = state.surrender, surrender.commandID == id else { throw KidsContractError.denied }
        try update {
            if $0.intent?.commandID == surrender.intentID {
                $0.intent = nil
            }
            $0.surrender = nil
        }
    }

    /// Explicit parent recovery only. Preserve the complete old outbox before
    /// clearing local retry slots; the archive is never loaded as authority.
    func archiveForEpochRecovery() throws -> URL {
        let events = state.events
        struct Archive: Encodable {
            let reason: String
            let journal: State
            let events: [ReceiverEvent]
        }
        guard events.count <= 128 else { throw KidsContractError.denied }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Archive(reason: "command_epoch_changed", journal: state, events: events))
        guard data.count <= 524_288 else { throw KidsContractError.denied }
        let archive = url.deletingLastPathComponent().appendingPathComponent("epoch-recovery-\(UUID().uuidString).json")
        try data.write(to: archive, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        let handle = try FileHandle(forWritingTo: archive)
        try handle.synchronize()
        try handle.close()
        let descriptor: Int32 = archive.deletingLastPathComponent().withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw KidsContractError.denied }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw KidsContractError.denied }
        // A failed archive or synchronization never reaches this state change.
        try update { $0.intent = nil
            $0.surrender = nil
            $0.events = []
        }
        return archive
    }

    private func update(_ change: (inout State) -> Void) throws {
        var next = state
        change(&next)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        guard data.count <= 262_144 else { throw KidsContractError.denied }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
        let descriptor: Int32 = url.deletingLastPathComponent().withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw KidsContractError.denied }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw KidsContractError.denied }
        state = next
    }
}
