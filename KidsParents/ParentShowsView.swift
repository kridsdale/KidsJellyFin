//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import SwiftUI

struct ParentShowsView: View {
    @Bindable
    var model: ParentsModel
    @State
    private var search = ""
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose what belongs in their world.").font(.title2.bold())
                    Text("Choose what the selected child can browse and play. Turning a show off keeps its files in your library.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.listRowBackground(Color.clear)
                if let dashboard = model.dashboard {
                    Section {
                        Picker("Child profile", selection: $model.selectedChild) {
                            ForEach(dashboard.children) { Text($0.name).tag($0.id) }
                        }
                    }
                    Section("Kid TV") {
                        ForEach(dashboard.shows
                            .filter {
                                $0.childUserID == model
                                    .selectedChild && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
                            }) { show in
                                Toggle(isOn: Binding(
                                    get: { show.enabled },
                                    set: { value in Task { await model.setShow(show, enabled: value) } }
                                )) {
                                    Label(show.name, systemImage: show.enabled ? "checkmark.circle.fill" : "pause.circle")
                                }.disabled(!model.canChangeShows)
                            }
                    }
                } else {
                    Section {
                        Label("Viewing restrictions need the server extension. This catalog is read-only.", systemImage: "info.circle")
                            .font(.footnote)
                    }
                    Section("Kid TV") {
                        ForEach(model.shows.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { show in
                            Label(show.name, systemImage: "tv")
                        }
                        if model.shows.isEmpty {
                            Text("No shows loaded. Pull to refresh.").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Their shows")
            .searchable(text: $search, prompt: "Find a show")
            .refreshable { await model.refresh() }
            .toolbar {
                NavigationLink { EpisodeRulesView(model: model) } label: { Label("Episode rules", systemImage: "list.bullet") }
            }
        }
    }
}
