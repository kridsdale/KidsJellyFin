//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation
@preconcurrency import Network

private let parentAuthorizationService = "_kids-auth._tcp"

private func parentAuthorizationParameters() -> NWParameters {
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = false
    parameters.prohibitedInterfaceTypes = [.cellular]
    return parameters
}

private func isParentAuthorizationLAN(_ connection: NWConnection) -> Bool {
    guard let path = connection.currentPath, path.status == .satisfied else { return false }
    return !path.usesInterfaceType(.cellular) &&
        (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
}

/// A LAN announcement is only a hint. Approval always comes from the configured
/// authenticated service; peers never receive adult/receiver credentials or PINs.
@MainActor
public final class LANParentAuthorizationAdvertiser {
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var generation = UUID()

    public init() {}

    public func start(notice: LANParentAuthorizationNotice) throws {
        stop()
        guard notice.isValid else { throw ParentControlError.invalidSelection }
        let listener = try NWListener(using: parentAuthorizationParameters())
        let data = try JSONEncoder().encode(notice) + Data([10])
        let epoch = generation
        listener.service = NWListener.Service(
            name: "Parents-\(notice.requestID.uuidString.lowercased())",
            type: parentAuthorizationService,
            domain: "local."
        )
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.generation == epoch, self.connections.count < 8 else {
                    connection.cancel()
                    return
                }
                let key = ObjectIdentifier(connection)
                self.connections[key] = connection
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self, self.generation == epoch else { connection.cancel()
                            return
                        }
                        switch state {
                        case .ready:
                            guard isParentAuthorizationLAN(connection) else {
                                self.finish(connection)
                                return
                            }
                            connection.send(
                                content: data,
                                contentContext: .finalMessage,
                                isComplete: true,
                                completion: .contentProcessed { [weak self] _ in
                                    Task { @MainActor in self?.finish(connection) }
                                }
                            )
                        case .failed, .cancelled: self.finish(connection)
                        default: break
                        }
                    }
                }
                connection.start(queue: .main)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.finish(connection)
                }
            }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    private func finish(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    public func stop() {
        generation = UUID()
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connections.removeAll()
    }
}

/// Bonjour is constrained to local-domain infrastructure LAN paths. A foreign
/// service can supply only an untrusted nonce; the parent API verifies its scope.
@MainActor
public final class LANParentAuthorizationBrowser {
    private var browser: NWBrowser?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var seen: Set<NWEndpoint> = []
    private var generation = UUID()
    public init() {}

    public func start(serverID: String, onNotice: @escaping @MainActor (LANParentAuthorizationNotice) -> Void) {
        stop()
        guard !serverID.isEmpty else { return }
        let epoch = generation
        let browser = NWBrowser(
            for: .bonjour(type: parentAuthorizationService, domain: "local."),
            using: parentAuthorizationParameters()
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.generation == epoch else { return }
                let endpoints = Set(results.map(\.endpoint))
                self.seen.formIntersection(endpoints)
                for endpoint in endpoints where !self.seen.contains(endpoint) {
                    guard self.connections.count < 8, self.seen.count < 64 else { break }
                    guard case let .service(_, type, domain, _) = endpoint,
                          type == parentAuthorizationService, domain == "local." else { continue }
                    self.seen.insert(endpoint)
                    let connection = NWConnection(to: endpoint, using: parentAuthorizationParameters())
                    self.connections[ObjectIdentifier(connection)] = connection
                    connection.stateUpdateHandler = { [weak self] state in
                        Task { @MainActor in
                            guard let self, self.generation == epoch else { connection.cancel()
                                return
                            }
                            switch state {
                            case .ready:
                                guard isParentAuthorizationLAN(connection) else { self.finish(connection)
                                    return
                                }
                                self.receive(connection, data: Data(), serverID: serverID, epoch: epoch, onNotice: onNotice)
                            case .failed, .cancelled: self.finish(connection)
                            default: break
                            }
                        }
                    }
                    connection.start(queue: .main)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finish(connection) }
                }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    private func receive(
        _ connection: NWConnection,
        data: Data,
        serverID: String,
        epoch: UUID,
        onNotice: @escaping @MainActor (LANParentAuthorizationNotice) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [weak self] bytes, _, complete, error in
            Task { @MainActor in
                guard let self, self.generation == epoch,
                      self.connections[ObjectIdentifier(connection)] != nil
                else { connection.cancel()
                    return
                }
                let accumulated = data + (bytes ?? Data())
                guard error == nil, accumulated.count <= 2048 else { self.finish(connection)
                    return
                }
                if let newline = accumulated.firstIndex(of: 10) {
                    let payload = accumulated.prefix(upTo: newline)
                    self.finish(connection)
                    if let notice = try? JSONDecoder().decode(LANParentAuthorizationNotice.self, from: payload),
                       notice.isValid, notice.serverID == serverID
                    {
                        onNotice(notice)
                    }
                } else if !complete {
                    self.receive(connection, data: accumulated, serverID: serverID, epoch: epoch, onNotice: onNotice)
                } else {
                    self.finish(connection)
                }
            }
        }
    }

    private func finish(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    public func stop() {
        generation = UUID()
        browser?.cancel()
        browser = nil
        for connection in connections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connections.removeAll()
        seen.removeAll()
    }
}
