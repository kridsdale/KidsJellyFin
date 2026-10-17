//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import KidsParentControl
import SwiftUI

struct ParentSettingsView: View {
    @Bindable
    var model: ParentsModel
    @State
    private var setup: ImportManagerDestination?
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
                }
                Section("YouTube import manager") {
                    TextField("Service address", text: $model.importServerText).keyboardType(.URL).textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("The existing service uses its own administrator sign-in inside the import review screen.").font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Text(model.controlStatus).font(.footnote).foregroundStyle(.secondary)
                    Button("Set up access on the server", systemImage: "person.badge.key") {
                        do {
                            // A fresh browser must sign in at the manager root.
                            // /admin/parent-control requires that separate cookie.
                            setup = try ImportManagerDestination(url: ParentServer(model.controlServerText).url, title: "Parent setup")
                        } catch { model.error = error.localizedDescription }
                    }.disabled(model.busy || model.demo)
                    Text("Sign in to the server manager, then choose Parents to create access for this phone or an Apple TV.")
                        .font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup("Advanced connection") {
                        TextField("Control service address", text: $model.controlServerText).keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Parent-control access token", text: $model.controlToken).textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Check parent-control support") { Task { await model.connectControls() } }
                            .disabled(model.busy || model.demo || model.controlToken.isEmpty)
                    }
                } header: {
                    Text("Parent controls")
                } footer: {
                    if model.capabilities == nil {
                        Text(
                            "Create access in parent setup, then connect below. Countdowns and viewing rules become available when the server and TV are ready."
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
                .sheet(item: $setup) { destination in
                    ImportManagerSheet(url: destination.url, title: destination.title)
                }
        }
    }
}
