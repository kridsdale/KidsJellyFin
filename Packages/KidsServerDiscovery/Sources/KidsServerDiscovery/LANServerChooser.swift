//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Observation
import SwiftUI

@MainActor @Observable
public final class LANDiscoveryModel {
    public private(set) var servers: [LANServer] = []
    public private(set) var scanning = false
    public private(set) var message: String?
    private var generation = UUID()
    private let client: LANDiscoveryClient

    public init(client: LANDiscoveryClient = .live) {
        self.client = client
    }

    public func scan(expectedID: String? = nil) async {
        let epoch = UUID()
        generation = epoch
        scanning = true
        servers = [] // Never offer stale results from the previous network/scan.
        message = nil
        do {
            let values = try await client.servers(expectedID: expectedID)
            guard generation == epoch, !Task.isCancelled else { return }
            servers = values
            message = values
                .isEmpty ? "No matching server found. Check Local Network access in Settings, then try again or enter an address." : nil
        } catch is CancellationError {
            guard generation == epoch else { return }
        } catch {
            guard generation == epoch, !Task.isCancelled else { return }
            message = "Could not search the home network. Allow Local Network access in Settings, or enter the server address."
        }
        if generation == epoch {
            scanning = false
        }
    }

    public func cancel() {
        generation = UUID()
        scanning = false
        servers = []
    }
}

/// Place inside a Form/Section. Scanning never logs in, sends stored credentials,
/// changes an account binding, or starts playback. The grown-up chooses a result.
public struct LANServerChooser: View {
    @State
    private var model = LANDiscoveryModel()
    @State
    private var scanID = UUID()
    private let expectedID: String?
    private let select: (LANServer) -> Void

    public init(expectedID: String? = nil, select: @escaping (LANServer) -> Void) {
        self.expectedID = expectedID
        self.select = select
    }

    public var body: some View {
        Group {
            if model.scanning {
                HStack { ProgressView()
                    Text("Finding your Jellyfin server…")
                }
                .accessibilityIdentifier("discovery.scanning")
            }
            ForEach(model.servers, id: \.url) { server in
                Button {
                    select(server)
                } label: {
                    VStack(alignment: .leading) {
                        Label(server.name, systemImage: "server.rack")
                        Text(server.url.absoluteString).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("discovery.server.\(server.id)")
            }
            if let message = model.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Button(model.scanning ? "Search again" : "Find servers on the home network", systemImage: "network") {
                scanID = UUID()
            }
            .accessibilityIdentifier("discovery.refresh")
        }
        .task(id: scanID) { await model.scan(expectedID: expectedID) }
        .onDisappear { model.cancel() }
    }
}
