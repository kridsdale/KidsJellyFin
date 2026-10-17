//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import KidsAccounts
import KidsDomain

/// Captured mutation identity only. No token, cached permission, or media is stored.
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
    }

    private var state: State
    private let url: URL
    var intent: Intent? {
        state.intent
    }

    var surrender: Surrender? {
        state.surrender
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
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 16384 else { throw KidsContractError.denied }
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
            guard state.version == 1, state.scope == scope else { throw KidsContractError.denied }
            if let intent = state.intent, let surrender = state.surrender {
                guard intent.commandID == surrender.intentID, intent.sessionID == surrender.sessionID,
                      intent.itemID == surrender.itemID else { throw KidsContractError.denied }
            }
        } else {
            state = State(version: 1, scope: scope)
        }
        // A new runtime has no surviving operational controller. Resolve an
        // unknown POST, then retire that exact intent BEFORE the first policy GET.
        if let intent = state.intent {
            try abandon(intent.commandID)
        }
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

    private func update(_ change: (inout State) -> Void) throws {
        var next = state
        change(&next)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        guard data.count <= 16384 else { throw KidsContractError.denied }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
        state = next
    }
}
