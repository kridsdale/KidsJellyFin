//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation
import Observation
import SwiftUI

public struct LANParentService: Identifiable, Equatable, Sendable {
    public var id: String {
        url.absoluteString
    }

    public let name: String
    public let serverID: String
    public let url: URL

    /// TXT is an untrusted selector. Only exact Jellyfin identity, API version,
    /// local host and valid port become a proposal; no bearer is sent here.
    public init(name: String, host: String, port: Int, txt: [String: Data], expectedServerID: String) throws {
        func value(_ key: String) -> String? {
            txt[key].flatMap { String(data: $0, encoding: .utf8) }
        }
        guard value("jellyfinServerId") == expectedServerID, !expectedServerID.isEmpty,
              value("apiVersion") == "1", (1 ... 65535).contains(port),
              !host.contains("/"), !host.contains("@"),
              value("scheme").map({ ["http", "https"].contains($0) }) ?? true
        else { throw LANDiscoveryError.identityMismatch }
        var parts = URLComponents()
        parts.scheme = value("scheme") ?? "http"
        parts.host = host.hasSuffix(".") ? String(host.dropLast()) : host
        parts.port = port
        guard let url = parts.url else { throw LANDiscoveryError.invalidAddress }
        self.url = try LANDiscoveryPolicy.validatedURL(url)
        self.name = String(name.prefix(256))
        serverID = expectedServerID
    }
}

/// DNS-SD contract: _kidsparents._tcp.local, TXT jellyfinServerId and
/// apiVersion=1, optional scheme=http|https. Browsing does not pair or send tokens.
/// After resolution we confirm Jellyfin's public ID at that host before offering
/// the Parents endpoint. Authentication itself still verifies capabilities.serverID.
@MainActor @Observable
public final class LANParentServiceDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    public private(set) var services: [LANParentService] = []
    public private(set) var scanning = false
    public private(set) var message: String?
    private var browser: NetServiceBrowser?
    private var pending: [NetService] = []
    private var verificationTasks: [Task<Void, Never>] = []
    private var generation = UUID()
    private var jellyfin: LANServer?

    override public init() {
        super.init()
    }

    public func scan(jellyfin: LANServer) async {
        cancel()
        let epoch = generation
        self.jellyfin = jellyfin
        scanning = true
        message = nil
        let browser = NetServiceBrowser()
        self.browser = browser
        browser.delegate = self
        browser.searchForServices(ofType: "_kidsparents._tcp.", inDomain: "local.")
        do { try await Task.sleep(for: .seconds(6)) } catch {
            if generation == epoch {
                cancel()
            }
            return
        }
        guard generation == epoch else { return }
        stopBrowsing()
        for task in verificationTasks {
            await task.value
        }
        guard generation == epoch else { return }
        scanning = false
        if services.isEmpty {
            message = "No matching parent service found. Check Local Network access or use the advanced address."
        }
    }

    public func cancel() {
        generation = UUID()
        stopBrowsing()
        for task in verificationTasks {
            task.cancel()
        }
        verificationTasks = []
        services = []
        scanning = false
    }

    private func stopBrowsing() {
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        for service in pending {
            service.stop()
            service.delegate = nil
        }
        pending = []
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard self.browser === browser, pending.count < 16 else { return }
        pending.append(service)
        service.delegate = self
        service.resolve(withTimeout: 3)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard self.browser === browser else { return }
        message = "Network discovery is unavailable. Check Local Network access in Settings."
    }

    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard pending.contains(where: { $0 === sender }), let jellyfin,
              let host = sender.hostName, let data = sender.txtRecordData(),
              let candidate = try? LANParentService(
                  name: sender.name,
                  host: host,
                  port: sender.port,
                  txt: NetService.dictionary(fromTXTRecord: data),
                  expectedServerID: jellyfin.id
              )
        else { return }
        let epoch = generation
        // Verify that the advertising machine also serves this Jellyfin ID.
        // This is a public, credential-free request; do not probe a guessed
        // control port or transfer the existing parent/receiver token.
        var parts = URLComponents(url: jellyfin.url, resolvingAgainstBaseURL: false)!
        parts.host = candidate.url.host
        guard let identityURL = parts.url else { return }
        let identity = LANServer(id: jellyfin.id, name: jellyfin.name, url: identityURL)
        verificationTasks.append(Task {
            guard await (try? LANDiscoveryClient.verifyPublicServer(identity, expectedID: jellyfin.id)) != nil,
                  !Task.isCancelled, generation == epoch else { return }
            if !services.contains(where: { $0.url == candidate.url }) {
                services.append(candidate)
                services.sort { $0.name < $1.name }
            }
        })
    }
}

public struct LANParentServiceChooser: View {
    private let jellyfin: LANServer
    private let select: (LANParentService) -> Void
    @State
    private var model = LANParentServiceDiscovery()
    @State
    private var scanID = UUID()

    public init(jellyfin: LANServer, select: @escaping (LANParentService) -> Void) {
        self.jellyfin = jellyfin
        self.select = select
    }

    public var body: some View {
        Group {
            if model.scanning {
                HStack { ProgressView()
                    Text("Finding parent controls…")
                }
            }
            ForEach(model.services) { service in
                Button { select(service) } label: {
                    VStack(alignment: .leading) {
                        Label(service.name, systemImage: "figure.2.and.child.holdinghands")
                        Text(service.url.absoluteString).font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("discovery.parentService")
            }
            if let message = model.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Button("Find parent controls", systemImage: "network") { scanID = UUID() }
                .accessibilityIdentifier("discovery.parentRefresh")
        }
        .task(id: scanID) { await model.scan(jellyfin: jellyfin) }
        .onDisappear { model.cancel() }
    }
}
