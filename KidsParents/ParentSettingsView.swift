//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import KidsParentControl
import KidsServerDiscovery
import SwiftUI

struct ParentSettingsView: View {
    @Bindable
    var model: ParentsModel
    @State
    private var setup: ImportManagerDestination?
    @State
    private var reconnecting = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Jellyfin") {
                    LabeledContent("Server", value: model.serverText)
                    LabeledContent("Parent", value: model.credential?.name ?? "Design preview")
                    if let date = model.lastRefresh {
                        LabeledContent(
                            "Last refreshed",
                            value: date.formatted(date: .omitted, time: .shortened)
                        )
                    }
                    Button("Refresh connection") { Task { await model.refresh() } }.disabled(model.busy || model.demo)
                    Button("Find this server again", systemImage: "network") { reconnecting = true }
                        .disabled(model.busy || model.demo)
                }
                Section("Server manager") {
                    TextField("Service address", text: $model.importServerText).keyboardType(.URL).textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("The existing service uses its own administrator sign-in inside the import review screen.").font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Text(model.controlStatus).font(.footnote).foregroundStyle(.secondary)
                    if let credential = model.credential, !model.demo {
                        LANParentServiceChooser(jellyfin: LANServer(
                            id: credential.serverID,
                            name: "Family Jellyfin",
                            url: credential.server.url
                        )) { service in
                            model.controlServerText = service.url.absoluteString
                            model.controlToken = ""
                            model.notice = "Parent service selected. Create or enter access for this phone to connect."
                        }
                    }
                    Button("Set up access on the server", systemImage: "person.badge.key") {
                        do {
                            // A fresh browser must sign in at the manager root.
                            // /admin/parent-control requires that separate cookie.
                            setup = try ImportManagerDestination(url: ParentServer(model.importServerText).url, title: "Parent setup")
                        } catch { model.error = error.localizedDescription }
                    }.disabled(model.busy || model.demo)
                    Text("Sign in to the server manager, then choose Parents to create access for this phone or an Apple TV.")
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField("Parent service address from setup", text: $model.controlServerText).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("parents.connection.address")
                    SecureField("Access token for this iPhone", text: $model.controlToken).textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("parents.connection.token")
                    Button("Connect parent access") { Task { await model.connectControls() } }
                        .disabled(model.busy || model.demo || model.controlServerText.isEmpty || model.controlToken.isEmpty)
                        .accessibilityIdentifier("parents.connection.connect")
                    Text(
                        "Use the parent service address and phone token shown in setup. The manager's web address can be different. Saved access reconnects after you unlock; only paste a token to replace or add access."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("Parent controls")
                } footer: {
                    if model.capabilities == nil {
                        Text(
                            "Create access in parent setup, copy the service address and iPhone token here, then connect. Pair the Apple TV in the same setup screen to see it in Tonight."
                        )
                    }
                }
                Section("Access") {
                    Label("Locks when this app goes into the background", systemImage: "faceid")
                    Text("Unlock with Face ID or the iPhone passcode. Parent credentials stay separate from the kids app.").font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Sign out", role: .destructive) { Task { await model.signOut() } }.disabled(model.busy || model.demo)
                }
                Section("Family tools") {
                    NavigationLink("Routines, allowance and shuffle") { FamilyRulesView(model: model) }
                    NavigationLink("Viewing history") { ParentHistoryView(model: model) }
                    NavigationLink("Server and download health") { ParentHealthView(model: model) }
                }
            }.navigationTitle("Settings")
                .sheet(isPresented: $reconnecting, onDismiss: {
                    if let credential = model.credential {
                        model.serverText = credential.server.url.absoluteString
                    }
                }) {
                    ParentSignIn(model: model, onConnected: { reconnecting = false })
                }
                .sheet(item: $setup) { destination in
                    ImportManagerSheet(url: destination.url, title: destination.title)
                }
        }
    }
}
