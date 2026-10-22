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

struct TonightView: View {
    @Bindable
    var model: ParentsModel
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("A softer landing", systemImage: "moon.stars.fill").font(.headline).foregroundStyle(.teal)
                        Text("A little more TV.\nThen, just birds.").font(.title.bold()).fixedSize(horizontal: false, vertical: true)
                        Text(
                            "Set the limit quietly from your phone. When time is up, the TV switches to the approved bird video and keeps it looping."
                        )
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 12)
                }.listRowBackground(Color.clear)

                Section {
                    if let dashboard = model.dashboard, !dashboard.televisions.isEmpty {
                        Picker("Apple TV", selection: $model.selectedTV) {
                            ForEach(dashboard.televisions) { Text($0.name).tag($0.id) }
                        }
                        if let tv = model.chosenTV {
                            Label(
                                model
                                    .needsRefresh ? "TV status needs refresh" :
                                    (tv.online ? "TV online at last refresh" : "TV offline at last refresh"),
                                systemImage: model.needsRefresh ? "arrow.clockwise" : (tv.online ? "wifi" : "wifi.slash")
                            )
                            .foregroundStyle(tv.online && !model.needsRefresh ? .secondary : Color.orange)
                            if let child = dashboard.children.first(where: { $0.id == tv.childUserID }) {
                                LabeledContent("Child profile", value: child.name)
                            }
                            if let enforcementEnabled = tv.enforcementEnabled {
                                if model.supports("receiver-enforcement-v1") {
                                    LabeledContent("Parental controls", value: enforcementEnabled ? "Enabled" : "Disabled")
                                    Button(enforcementEnabled ? "Disable parental controls" : "Enable parental controls") {
                                        Task { await model.setEnforcement(enabled: !enforcementEnabled) }
                                    }
                                    .disabled(!model.canUse("receiver-enforcement-v1") || (!enforcementEnabled && !tv.online))
                                    .accessibilityIdentifier("parents.tv.enforcement")
                                    Text(
                                        "The status shows the server's saved setting. The TV must connect to receive a change. Enabling requires the TV to be online."
                                    )
                                    .font(.footnote).foregroundStyle(.secondary)
                                } else {
                                    LabeledContent("Parental controls", value: enforcementEnabled ? "Enabled" : "Disabled")
                                }
                            } else {
                                Text("Parental control activation status is unavailable. Refresh to check this TV's settings.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            if tv.online && !tv.canEnforceDeadline {
                                Text(
                                    "This TV has connected, but countdown enforcement is not ready yet. Refresh after connecting the kids app."
                                )
                                .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Picker("Afterwards", selection: $model.selectedBird) {
                            if dashboard.birdVideos.isEmpty {
                                Text("No approved bird video").tag("")
                            }
                            ForEach(dashboard.birdVideos) { Text($0.name).tag($0.id) }
                        }
                        if dashboard.birdVideos.isEmpty {
                            Text("Choose an approved bird video in server setup before starting a countdown.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Label(model.dashboard == nil ? "Connect parent access" : "No Apple TV paired yet", systemImage: "tv.badge.wifi")
                        NavigationLink("Open parent setup") { ParentSettingsView(model: model) }
                        Text(model
                            .dashboard == nil ? "Connect saved or new parent access in Settings." :
                            "Create Apple TV access in server setup, then connect it in the kids app's parent settings.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Picker("Time remaining", selection: $model.minutes) {
                        ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                    }.pickerStyle(.menu)
                    Button { Task { await model.schedule() } } label: {
                        Label("Start quiet countdown", systemImage: "timer").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }.buttonStyle(.borderedProminent).disabled(!model.canSchedule)
                } header: {
                    Text("Tonight's plan")
                } footer: {
                    Text("No countdown appears on the TV. This ends kids viewing; it leaves the screen on for the birds.")
                }

                if let countdown = model.chosenTV?.countdown {
                    Section("Server's countdown") {
                        LabeledContent("Status", value: countdown.status)
                        LabeledContent("Deadline", value: countdown.deadline.formatted(date: .omitted, time: .shortened))
                        Text("A saved deadline does not confirm TV delivery. Bird playback must be acknowledged by the TV.").font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Cancel countdown", role: .destructive) { Task { await model.cancelCountdown() } }
                            .disabled(!model.canUse("durable-countdown-v1"))
                    }
                }
                Section("A little flexibility") {
                    Button("Finish this episode, then birds", systemImage: "flag.checkered") { Task { await model.finishCurrentEpisode() } }
                        .disabled(!model.canUse("finish-episode-v1") || model.chosenTV?.online != true || model.selectedBird.isEmpty)
                    Text("Uses the selected time as a hard stop if the episode runs long.").font(.footnote).foregroundStyle(.secondary)
                    Button("Add 10 minutes to this countdown", systemImage: "plus.circle") { Task { await model.giveExtraTime(.countdown) }
                    }
                    .disabled(!model.canUse("bonus-time-v1") || model.chosenTV?.countdown == nil)
                }
                Section("Remote control") {
                    HStack {
                        Button("Pause", systemImage: "pause.fill") { Task { await model.remote(.pause) } }
                        Spacer()
                        Button("Resume", systemImage: "play.fill") { Task { await model.remote(.resume) } }
                        Spacer()
                        Button("Skip", systemImage: "forward.end.fill") { Task { await model.remote(.skip) } }
                    }.buttonStyle(.borderless).disabled(!model.canUse("remote-control-v1") || model.chosenTV?.online != true)
                }
                Section {
                    NavigationLink { FamilyRulesView(model: model) } label: { Label(
                        "Family routines and daily allowance",
                        systemImage: "calendar.badge.clock"
                    ) }
                    NavigationLink { ParentHistoryView(model: model) } label: { Label(
                        "Viewing history",
                        systemImage: "clock.arrow.circlepath"
                    ) }
                }
                if model
                    .needsRefresh
                {
                    Section {
                        Text("Refresh before another change. The previous request may have reached the server.").foregroundStyle(.orange)
                    }
                }
                if let notice = model.notice {
                    Section { Text(notice).foregroundStyle(.secondary) }
                }
                if model.capabilities == nil && !model
                    .demo
                {
                    Section { Label(model.controlStatus, systemImage: "info.circle").font(.footnote) }
                }
                if !model.sessions.isEmpty {
                    Section("Jellyfin activity") {
                        ForEach(model.sessions) { session in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.deviceName ?? session.client ?? "Jellyfin device").font(.headline)
                                Text(session.nowPlayingItem?.name ?? "Not playing").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Tonight")
            .refreshable { await model.refresh() }
            .toolbar {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.busy || model.demo)
            }
        }
    }
}
