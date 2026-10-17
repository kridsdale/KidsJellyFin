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

struct FamilyRulesView: View {
    @Bindable
    var model: ParentsModel
    var body: some View {
        Form {
            if let dashboard = model.dashboard {
                Section { Picker("Child", selection: $model.selectedChild) {
                    ForEach(dashboard.children) { Text($0.name).tag($0.id) }
                }.disabled(model.busy) }
            }
            if let profile = model.profile {
                Section {
                    LabeledContent("Today", value: profile.budget.localDate)
                    LabeledContent("Watched", value: "\(profile.budget.usedSeconds / 60) minutes")
                    if profile.budget.enabled {
                        LabeledContent(
                            "Remaining",
                            value: profile.budget.remainingSeconds.map { "\($0 / 60) minutes" } ?? "Unknown — refresh"
                        )
                        if let held = profile.budget.reservedSeconds, let unconfirmed = profile.budget.unconfirmedSeconds {
                            DisclosureGroup("Usage details") {
                                Text("\(held) seconds held for active TVs").font(.caption).foregroundStyle(.secondary)
                                Text("\(unconfirmed) seconds awaiting playback reports").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("No daily limit").foregroundStyle(.secondary)
                    }
                    NavigationLink("Change daily allowance") { BudgetEditor(model: model, profile: profile) }
                        .disabled(!model.demo && !model.supports("daily-budget-v1"))
                    Button("Give 10 extra minutes today", systemImage: "plus.circle") { Task { await model.giveExtraTime(.budget) } }
                        .disabled(!model.canUse("bonus-time-v1") || !profile.budget.enabled)
                } header: { Text("Daily allowance") } footer: {
                    Text("Shared across this child's TVs. Extra time does not open a closed viewing window.")
                }
                Section("Weekly routines") {
                    ForEach(profile.routines) { rule in
                        HStack { VStack(alignment: .leading) {
                            Text(rule.name)
                            Text(Self.summary(rule)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: rule.enabled ? "checkmark.circle" : "pause.circle").foregroundStyle(.secondary)
                        }
                    }
                    if profile.routines.isEmpty {
                        Text("No weekly restrictions").foregroundStyle(.secondary)
                    }
                    NavigationLink("Edit weekly routines") { RoutineEditor(model: model, profile: profile) }
                        .disabled(!model.demo && !model.supports("routines-v1"))
                    LabeledContent("Time zone", value: profile.timeZone)
                }
                Section("Shuffle") {
                    LabeledContent("Unwatched first", value: profile.shuffle.preferUnwatched ? "Yes" : "No")
                    LabeledContent("Repeat cooldown", value: "\(profile.shuffle.repeatCooldownDays) days")
                    NavigationLink("Tune shuffle") { ShuffleEditor(model: model, profile: profile) }
                        .disabled(!model.demo && !model.supports("shuffle-preferences-v1"))
                }
            } else {
                ContentUnavailableView(
                    "Family rules aren't available yet",
                    systemImage: "calendar.badge.clock",
                    description: Text("Connect the parent service in Settings, then refresh to load this child's rules.")
                )
            }
            if model
                .needsRefresh
            {
                Section {
                    Text("Refresh before making another change. A previous request may have reached the server.").foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Family rules")
        .refreshable { await model.loadProfile() }
        .task(id: model.selectedChild) { await model.loadProfile() }
    }

    static func summary(_ routine: ViewingRoutine) -> String {
        let labels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let days = routine.weekdays.sorted().compactMap { (1 ... 7).contains($0) ? labels[$0 - 1] : nil }.joined(separator: ", ")
        return "\(days) · \(time(routine.startMinute))–\(time(routine.endMinute))"
    }

    static func time(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}

private struct BudgetEditor: View {
    @Bindable
    var model: ParentsModel
    let profile: ParentProfileSettings
    @State
    private var enabled: Bool
    @State
    private var minutes: Int
    @Environment(\.dismiss)
    private var dismiss
    init(model: ParentsModel, profile: ParentProfileSettings) {
        self.model = model
        self.profile = profile
        _enabled = State(initialValue: profile.budget.enabled)
        _minutes = State(initialValue: profile.budget.dailyMinutes)
    }

    var body: some View {
        Form {
            Toggle("Use a daily allowance", isOn: $enabled)
            Stepper("\(minutes) minutes per day", value: $minutes, in: 0 ... 1440, step: 5)
            Text(
                "Changing the allowance preserves minutes already watched today. Zero minutes blocks normal viewing while the allowance is enabled."
            )
            .font(.footnote).foregroundStyle(.secondary)
            Button("Save allowance") { Task {
                await model.saveBudget(enabled: enabled, minutes: minutes, profile: profile)
                if model.error == nil && !model.needsRefresh {
                    dismiss()
                }
            } }.disabled(!model.canUse("daily-budget-v1") || profile.childUserID != model.selectedChild)
        }.navigationTitle("Daily allowance")
    }
}

struct RoutineEditor: View {
    @Bindable
    var model: ParentsModel
    let profile: ParentProfileSettings
    @State
    private var routines: [ViewingRoutine]
    @State
    private var timeZone: String
    @Environment(\.dismiss)
    private var dismiss
    init(model: ParentsModel, profile: ParentProfileSettings) {
        self.model = model
        self.profile = profile
        _routines = State(initialValue: profile.routines)
        _timeZone = State(initialValue: profile.timeZone)
    }

    private var valid: Bool {
        TimeZone(identifier: timeZone) != nil && routines.allSatisfy { (try? $0.validate()) != nil }
    }

    var body: some View {
        Form {
            Section {
                Text("TV is available during the enabled windows. Without enabled windows, there is no weekly restriction.")
                    .font(.subheadline)
            }
            ForEach($routines) { $rule in
                Section {
                    TextField("Routine name", text: $rule.name)
                    Toggle("Enabled", isOn: $rule.enabled)
                    ForEach(1 ... 7, id: \.self) { day in
                        Toggle(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][day - 1], isOn: Binding(
                            get: { rule.weekdays.contains(day) }, set: { on in
                                if on {
                                    rule.weekdays = Array(Set(rule.weekdays + [day])).sorted()
                                } else {
                                    rule.weekdays.removeAll { $0 == day }
                                }
                            }
                        ))
                    }
                    DatePicker("From", selection: minuteBinding($rule.startMinute), displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                    DatePicker("Until", selection: minuteBinding($rule.endMinute), displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                    if (try? rule.validate()) ==
                        nil
                    {
                        Text("Choose days and an end time after the start.").foregroundStyle(.orange).font(.footnote)
                    }
                    Button("Remove routine", role: .destructive) { routines.removeAll { $0.id == rule.id } }
                }
            }
            Button("Add a viewing window", systemImage: "plus") { routines.append(ViewingRoutine()) }.disabled(routines.count >= 32)
            Section("Time zone") {
                TextField("IANA time zone", text: $timeZone).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("For example, America/Los_Angeles. Overnight windows need two entries.").font(.footnote).foregroundStyle(.secondary)
            }
            Button("Save routines") { Task {
                await model.saveRoutines(routines, timeZone: timeZone, profile: profile)
                if model.error == nil && !model.needsRefresh {
                    dismiss()
                }
            } }.disabled(!valid || !model.canUse("routines-v1") || profile.childUserID != model.selectedChild)
        }.navigationTitle("Weekly routines")
    }

    private func minuteBinding(_ value: Binding<Int>) -> Binding<Date> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return Binding(
            get: { calendar.date(from: DateComponents(
                year: 2001,
                month: 1,
                day: 1,
                hour: value.wrappedValue / 60,
                minute: value.wrappedValue % 60
            ))! },
            set: { date in value.wrappedValue = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date) }
        )
    }
}

struct ShuffleEditor: View {
    @Bindable
    var model: ParentsModel
    let profile: ParentProfileSettings
    @State
    private var preferences: ParentShufflePreferences
    @Environment(\.dismiss)
    private var dismiss
    init(model: ParentsModel, profile: ParentProfileSettings) {
        self.model = model
        self.profile = profile
        _preferences = State(initialValue: profile.shuffle)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Prefer unwatched episodes", isOn: $preferences.preferUnwatched)
                Stepper("Avoid repeats for \(preferences.repeatCooldownDays) days", value: $preferences.repeatCooldownDays, in: 0 ... 30)
            } footer: { Text("If every available episode is recent, shuffle can repeat one. Viewing restrictions always apply.") }
            Section("Preferred shows") {
                ForEach(model.dashboard?.shows.filter { $0.childUserID == profile.childUserID } ?? []) { show in
                    Toggle(isOn: Binding(get: { preferences.preferredShowIDs.contains(show.id) }, set: { on in
                        if on {
                            preferences.preferredShowIDs = Array(Set(preferences.preferredShowIDs + [show.id])).sorted()
                        } else {
                            preferences.preferredShowIDs.removeAll { $0 == show.id }
                        }
                    })) {
                        VStack(alignment: .leading) {
                            Text(show.name)
                            if !show.enabled {
                                Text("Currently turned off").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text(
                    "Preferred shows appear first on the home screen. Shuffle stays within the selected show. Ordered episodes keep their progress and order."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Button("Save shuffle preferences") { Task {
                await model.saveShuffle(preferences, profile: profile)
                if model.error == nil && !model.needsRefresh {
                    dismiss()
                }
            } }.disabled(!model.canUse("shuffle-preferences-v1") || profile.childUserID != model.selectedChild)
        }.navigationTitle("Shuffle")
    }
}
