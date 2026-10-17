//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import SwiftUI

@main
struct KidsParentsApp: App {
    @Environment(\.scenePhase)
    private var scenePhase
    @State
    private var model = ParentsModel(demo: ProcessInfo.processInfo.arguments.contains("--parent-preview"))

    var body: some Scene {
        WindowGroup {
            Group {
                if model.locked {
                    ContentUnavailableView {
                        Label("Parent controls are locked", systemImage: "lock.shield")
                    } description: {
                        Text("Unlock to manage your family's viewing.")
                    } actions: {
                        Button("Unlock") { Task { await model.unlock() } }.buttonStyle(.borderedProminent)
                        Button("Use Jellyfin sign-in instead") { Task { await model.signOut() } }.disabled(model.busy)
                    }
                } else if model.signedIn {
                    if model.demo, let screen = ParentFeaturePreview.requestedScreen {
                        ParentFeaturePreview(model: model, screen: screen)
                    } else {
                        ParentTabs(model: model)
                    }
                } else {
                    ParentSignIn(model: model)
                }
            }
            .tint(.teal)
            .alert("Parent controls", isPresented: Binding(get: { model.error != nil }, set: {
                if !$0 {
                    model.error = nil
                }
            })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    model.lock()
                }
            }
        }
    }
}

struct ParentSignIn: View {
    @Bindable
    var model: ParentsModel
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "figure.2.and.child.holdinghands").font(.system(size: 42)).foregroundStyle(.teal)
                        Text("Their shows.\nYour say.").font(.largeTitle.bold())
                        Text("A quiet little control room for family TV.").foregroundStyle(.secondary)
                    }.padding(.vertical, 16)
                }.listRowBackground(Color.clear)
                Section("Your Jellyfin server") {
                    TextField("Server address", text: $model.serverText).keyboardType(.URL).textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Administrator username", text: $model.username).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $model.password).textContentType(.password)
                    Button {
                        Task { await model.signIn() }
                    } label: {
                        HStack { Text("Connect as parent")
                            Spacer()
                            if model.busy {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.right")
                            }
                        }
                    }.disabled(model.busy || model.username.isEmpty || model.password.isEmpty)
                }
                Section {
                    Label("Use an adult administrator account", systemImage: "person.badge.key")
                    Text("Your sign-in stays in this iPhone's Keychain. Passwords aren't saved. Connect over your home network.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("KidsJellyFin Parents").navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct ParentTabs: View {
    @Bindable
    var model: ParentsModel
    var body: some View {
        VStack(spacing: 0) {
            if model.demo {
                Text("DESIGN PREVIEW · Sample data · Controls inactive")
                    .font(.caption2.bold()).frame(maxWidth: .infinity).padding(8).background(.yellow.opacity(0.22))
            }
            TabView {
                TonightView(model: model).tabItem { Label("Tonight", systemImage: "moon.stars") }
                ParentShowsView(model: model).tabItem { Label("Shows", systemImage: "rectangle.stack") }
                ParentYouTubeView(model: model).tabItem { Label("YouTube", systemImage: "play.rectangle") }
                ParentSettingsView(model: model).tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .task(id: model.selectedChild) { await model.loadProfile() }
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    await model.pollControls()
                }
            }
        }
    }
}
