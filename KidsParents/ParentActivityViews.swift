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

struct ParentHistoryView: View {
    @Bindable
    var model: ParentsModel
    var body: some View {
        List {
            if let dashboard = model.dashboard {
                Section { Picker("Child", selection: $model.selectedChild) {
                    ForEach(dashboard.children) { Text($0.name).tag($0.id) }
                }.disabled(model.busy) }
            }
            if model.supports("viewing-history-v1") || model.demo {
                Section {
                    ForEach(model.historyEntries) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.title).font(.headline)
                            Text("\(entry.watchedSeconds / 60) minutes · \(entry.deviceName)").foregroundStyle(.secondary)
                            Text(entry.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            Label(
                                evidence(entry.evidence),
                                systemImage: entry.evidence == "incomplete" ? "exclamationmark.circle" : "info.circle"
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                    if model.historyEntries.isEmpty {
                        Text("No viewing history loaded.").foregroundStyle(.secondary)
                    }
                    if model
                        .historyCursor !=
                        nil
                    {
                        Button("Load earlier viewing") { Task { await model.loadHistory(more: true) } }.disabled(model.busy)
                    }
                } footer: { Text("Shows up to 30 days of playback reports. Missing reports can leave gaps in the history.") }
            } else {
                FeatureUnavailableView(name: "Viewing history")
            }
        }.navigationTitle("Viewing history")
            .refreshable { await model.loadHistory() }
            .task(id: model.selectedChild) { await model.loadHistory() }
    }

    private func evidence(_ value: String) -> String {
        switch value {
        case "clientReported": "Reported by the kids app"
        case "jellyfinReported": "Reported by Jellyfin"
        case "incomplete": "Incomplete report"
        default: "Report quality unknown"
        }
    }
}

struct ParentHealthView: View {
    @Bindable
    var model: ParentsModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            healthContent(at: context.date)
        }
        .navigationTitle("Server health")
        .refreshable { await model.loadHealth() }
        .task { await model.loadHealth() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.loadHealth() } }
                    .disabled(model.busy || model.demo || !model.supports("health-v1"))
                    .accessibilityIdentifier("parents.health.refresh")
            }
        }
    }

    private func healthContent(at now: Date) -> some View {
        List {
            if let health = model.serverHealth {
                let current = model.healthIsCurrent(at: now)
                if !current {
                    Section {
                        Label("This observation is out of date. Pull to refresh.", systemImage: "clock.badge.questionmark")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Server") {
                    LabeledContent("Jellyfin", value: current ? health.jellyfin.capitalized : "Unknown")
                    LabeledContent("Download worker", value: current ? health.worker.capitalized : "Unknown")
                    LabeledContent(
                        "Available storage",
                        value: current ?
                            (health.storageFreeBytes.map { ByteCountFormatter.string(
                                fromByteCount: $0,
                                countStyle: .file
                            ) } ?? "Unknown") : "Unknown"
                    )
                    LabeledContent("Queued downloads", value: current ? (health.pendingJobs.map(String.init) ?? "Unknown") : "Unknown")
                    LabeledContent("Failed downloads", value: current ? (health.failedJobs.map(String.init) ?? "Unknown") : "Unknown")
                    LabeledContent("Observed") {
                        Text(health.observedAt.formatted(date: .abbreviated, time: .shortened)).font(.footnote)
                    }
                }
                Section("Apple TVs") {
                    ForEach(health.televisions) { tv in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(tv.name, systemImage: current ? (tv.online ? "tv.badge.wifi" : "wifi.slash") : "questionmark.circle")
                            Text(current ? (tv.online ? "Online" : "Offline") : "Unknown").foregroundStyle(.secondary)
                            if let seen = tv
                                .lastSeen
                            {
                                Text("Last seen \(seen.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !health.issues
                    .isEmpty
                {
                    Section(current ? "Needs attention" : "Last reported issues") { ForEach(
                        Array(health.issues.enumerated()),
                        id: \.offset
                    ) { _, issue in Label(
                        issue,
                        systemImage: "exclamationmark.triangle"
                    ) } }
                }
            } else if model.supports("health-v1") {
                ContentUnavailableView {
                    Label("No health observation loaded", systemImage: "server.rack")
                } description: {
                    Text("Refresh to read the server's latest status. Unknown values stay unknown until the server reports them.")
                } actions: {
                    if model.busy {
                        ProgressView("Loading server status")
                    } else {
                        Button("Refresh server health") { Task { await model.loadHealth() } }
                            .accessibilityIdentifier("parents.health.load")
                    }
                }
            } else {
                FeatureUnavailableView(name: "Server health")
            }
        }
    }
}

struct ParentReviewInboxView: View {
    @Bindable
    var model: ParentsModel
    @State
    private var manager: ImportManagerDestination?
    var body: some View {
        List {
            Section {
                Text(
                    "New playlist videos wait here for your review. Open a snapshot, inspect the selection, then approve only the videos you want."
                )
                .font(.subheadline).foregroundStyle(.secondary)
            }
            if model.supports("review-inbox-v1") || model.demo {
                ForEach(model.reviewEntries) { entry in
                    Section {
                        Text(entry.title).font(.headline)
                        LabeledContent("New videos", value: String(entry.newVideoCount))
                        LabeledContent("Status", value: entry.status == "needsReview" ? "Needs review" : entry.status)
                        Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        Button("Review in import manager", systemImage: "checklist") {
                            do {
                                manager = try ImportManagerDestination.review(
                                    url: ParentServer(model.importServerText).url,
                                    entry: entry
                                )
                            } catch { model.error = error.localizedDescription }
                        }.disabled(model.demo || model.busy)
                            .accessibilityIdentifier("parents.review.open.\(entry.id)")
                    }
                }
                if model.reviewEntries.isEmpty {
                    Text("No reviews loaded. Pull to refresh.").foregroundStyle(.secondary)
                }
                if model
                    .reviewCursor != nil
                {
                    Button("Load more reviews") { Task { await model.loadInbox(more: true) } }.disabled(model.busy)
                        .accessibilityIdentifier("parents.review.more")
                }
            } else {
                FeatureUnavailableView(name: "New-video inbox")
            }
        }.navigationTitle("Review inbox").refreshable { await model.loadInbox() }.task { await model.loadInbox() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.loadInbox() } }
                        .disabled(model.busy || model.demo || !model.supports("review-inbox-v1"))
                        .accessibilityIdentifier("parents.review.refresh")
                }
            }
            .sheet(item: $manager) { ImportManagerSheet(url: $0.url, title: $0.title, reviewEntry: $0.reviewEntry) }
    }
}

struct EpisodeRulesView: View {
    @Bindable
    var model: ParentsModel
    @State
    private var showID = ""
    var body: some View {
        List {
            Section {
                Picker("Show", selection: $showID) {
                    Text("Choose a show").tag("")
                    ForEach(model.dashboard?.shows.filter { $0.childUserID == model.selectedChild } ?? []) { Text($0.name).tag($0.id) }
                }.disabled(model.busy)
                if let show = model.dashboard?.shows.first(where: { $0.id == showID }), !show.enabled {
                    Text("This show is turned off. Making an episode available will not enable its show.").font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if model.supports("episode-exclusions-v1") {
                ForEach(model.episodes) { episode in
                    Toggle(isOn: Binding(
                        get: { !episode.excluded },
                        set: { available in Task { await model.excludeEpisode(episode, excluded: !available) } }
                    )) {
                        VStack(alignment: .leading) {
                            Text(episode.name)
                            if let season = episode.season,
                               let number = episode
                                   .episode
                            {
                                Text("Season \(season), episode \(number)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.disabled(!model.canUse("episode-exclusions-v1") || model.profile?.childUserID != model.selectedChild)
                }
                if model
                    .episodeCursor !=
                    nil
                {
                    Button("Load more episodes") { Task { await model.loadEpisodes(showID: showID, more: true) } }.disabled(model.busy)
                }
            } else {
                FeatureUnavailableView(name: "Episode rules")
            }
        }.navigationTitle("Individual episodes")
            .task(id: showID) {
                if !showID.isEmpty {
                    await model.loadEpisodes(showID: showID)
                }
            }
            .onChange(of: model.selectedChild) { _, _ in showID = "" }
            .refreshable {
                if !showID.isEmpty {
                    await model.loadEpisodes(showID: showID)
                }
            }
    }
}

struct FeatureUnavailableView: View {
    let name: String
    var body: some View {
        ContentUnavailableView(
            "\(name) needs server support",
            systemImage: "server.rack",
            description: Text("Connect the parent service in Settings. This feature becomes available when the server supports it.")
        )
    }
}
