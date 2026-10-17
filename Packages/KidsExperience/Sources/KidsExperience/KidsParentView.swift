//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import KidsAccounts
import KidsApplication
import KidsCatalog

// SPDX-License-Identifier: MPL-2.0
import KidsDomain
import SwiftUI

struct KidsParentView: View {
    @ObservedObject
    var model: KidsAppModel
    var playbackPresentation: any KidsPlaybackPresentation = KidsPreviewPlaybackPresentation()
    @Environment(\.dismiss)
    private var dismiss
    @State
    private var pin = ""
    @State
    private var newPIN = ""
    @State
    private var confirmPIN = ""
    @State
    private var serverURL = "http://1531server.local:8096"
    @State
    private var username = "kidsplayer"
    @State
    private var password = ""
    @State
    private var message: String?
    @State
    private var busy = false
    @State
    private var episodes: [KidsItem] = []
    @State
    private var selectedShow: KidsItem?
    @State
    private var selectedSeason: Int = 1
    @State
    private var confirmReset = false
    @State
    private var resetShowID: String?
    @State
    private var diagnostics = false
    @State
    private var recovering = false
    @State
    private var parentServiceURL = "http://192.168.10.100:8097"
    @State
    private var receiverToken = ""
    @FocusState
    private var speechFocused: Bool
    private var needsSetup: Bool {
        model.binding == nil || model.requiresParent
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.hasParentPIN && !model.unlocked && !recovering {
                    Section("Grown-ups") {
                        SecureField("Parent PIN", text: $pin).keyboardType(.numberPad)
                            .accessibilityIdentifier("kids.parent.pin")
                        KidsParentAction("Unlock") {
                            if model.unlock(pin) {
                                pin = ""
                                message = nil
                            } else {
                                message = model
                                    .parentPINProblem ??
                                    (model.gate.mayAttempt(at: .now) ? "That PIN did not match." : "Please wait before trying again.")
                                pin = ""
                            }
                        }.disabled(!model.gate.mayAttempt(at: .now))
                            .accessibilityIdentifier("kids.parent.unlock")
                        Text("The parent PIN is separate from the Jellyfin password.").foregroundStyle(.secondary)
                        KidsParentAction("Recover parent setup") { recovering = true
                            message = "Sign in with the previous kids account to reset synced playback setup. Your media stays unchanged."
                        }
                    }
                } else if model.needsLocalReset && !recovering {
                    Section("Restore local playback state") {
                        Text(
                            "Local playback settings could not be read. Reset them after verifying the same kids account and both approved libraries. Media files stay unchanged."
                        )
                        KidsParentAction("Reset synced progress and playback settings", role: .destructive) {
                            resetShowID = nil
                            confirmReset = true
                        }
                    }
                } else if needsSetup || !model.hasParentPIN || recovering {
                    setupSection
                } else {
                    sessionSection
                    episodeSection
                    connectionSection
                    Section("Parent phone controls") {
                        Text("TV installation ID: \(model.receiverInstallationID)")
                        if let revision = model.receiverBuildRevision {
                            Text("Client build: \(revision)").font(.caption)
                        } else {
                            Text("Client build is unavailable. Commissioning requires a stamped build.").font(.caption)
                        }
                        Text(model.viewingControlStatus).foregroundStyle(.secondary)
                        TextField("Parent service address", text: $parentServiceURL).textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Device-scoped receiver token", text: $receiverToken).textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text(
                            "Issue a receiver token for this installation ID in the server's parent administration page. Pairing alone does not activate controls."
                        )
                        .font(.footnote)
                        KidsParentAction("Pair this TV") {
                            do { try model.pairViewingControls(serviceURL: parentServiceURL, token: receiverToken)
                                receiverToken = ""
                                message = "Pairing saved. The administrator must commission and activate this TV on the server."
                            } catch { message = "Pairing could not be saved. Check the device-scoped token and server address." }
                        }.disabled(receiverToken.isEmpty)
                        KidsParentAction("Disconnect parent service", role: .destructive) {
                            Task { do { try await model.unpairViewingControls()
                                message = "Parent-service pairing removed."
                            } catch { message = "A grown-up must unlock before removing this pairing." }
                            }
                        }
                    }
                    Section("Parent PIN") {
                        SecureField("New PIN (4-8 digits)", text: $newPIN).keyboardType(.numberPad)
                        SecureField("Confirm new PIN", text: $confirmPIN).keyboardType(.numberPad)
                        KidsParentAction("Change PIN") {
                            do { guard newPIN == confirmPIN else { message = "The PINs must match."
                                return
                            }
                            try model.setPIN(newPIN)
                            newPIN = ""
                            confirmPIN = ""
                            message = "Parent PIN changed."
                            } catch { message = (error as? KidsParentPINError)?.localizedDescription ?? "Choose a PIN with 4 to 8 digits." }
                        }.disabled(newPIN.isEmpty)
                    }
                    Section("Recovery") {
                        KidsParentAction("Reset synced progress and playback settings", role: .destructive) { model.touchGate()
                            resetShowID = nil
                            confirmReset = true
                        }.accessibilityIdentifier("kids.parent.resetall")
                        Text(
                            "This resets ordered positions, movie progress, shuffle history, and preferences on Apple TVs using the same iCloud and Jellyfin accounts. Media files are never changed."
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                if let message {
                    Section { Text(message).foregroundStyle(.orange) }
                }
                Section { KidsParentAction("Back to kids") { model.lockParents()
                    dismiss()
                } }
            }
            .navigationTitle("Parents")
            .alert(resetShowID == nil ? "Reset synced playback state?" : "Reset this show’s progress?", isPresented: $confirmReset) {
                Button("Reset", role: .destructive) {
                    if let resetShowID {
                        model.resetProgress(showID: resetShowID)
                        message = "This show’s ordered progress reset."
                    } else {
                        Task {
                            do {
                                try await model.resetLocalState()
                                message = "Synced playback state reset."
                            } catch {
                                message = "Unable to verify the kids account. Check the connection before resetting."
                            }
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(resetShowID == nil ? "Ordered positions and settings on this Apple TV will be reset. Your media stays unchanged." :
                    "Only this show’s ordered position will reset. Other shows, movies, and settings stay unchanged.")
            }
            .task { selectedShow = model.selectedShow ?? model.catalog[.shows]?.first
                await loadEpisodes()
            }
            .onChange(of: selectedShow) { Task { await loadEpisodes() } }
            .onChange(of: model.unlocked) {
                if model.unlocked {
                    Task { await loadEpisodes() }
                } else {
                    episodes = []
                }
            }
            .onExitCommand { model.lockParents()
                dismiss()
            }
        }
    }

    private var setupSection: some View {
        Section("Connect the kids account") {
            Text(
                "Use a non-admin Jellyfin account with access only to Kid TV and Kid Movies. The app verifies permissions before showing any artwork."
            )
            .foregroundStyle(.secondary)
            TextField("Server URL", text: $serverURL).autocorrectionDisabled().textInputAutocapitalization(.never)
            TextField("Username", text: $username).autocorrectionDisabled().textInputAutocapitalization(.never)
            SecureField("Jellyfin password", text: $password)
            SecureField(
                recovering ? "New parent PIN (4-8 digits)" : (model.hasParentPIN ? "Confirm parent PIN" : "Choose parent PIN (4-8 digits)"),
                text: $newPIN
            )
            .keyboardType(.numberPad)
            if !model.hasParentPIN || recovering {
                SecureField("Confirm parent PIN", text: $confirmPIN).keyboardType(.numberPad)
            }
            KidsParentAction(busy ? "Connecting…" : "Connect") {
                guard (model.hasParentPIN && !recovering) || newPIN == confirmPIN else { message = "The parent PINs must match."
                    return
                }
                busy = true
                message = nil
                Task {
                    do {
                        try await model.signIn(
                            urlText: serverURL,
                            username: username,
                            password: password,
                            parentPIN: newPIN,
                            recovering: recovering
                        )
                        password = ""
                        newPIN = ""
                        confirmPIN = ""
                        busy = false
                        if !model.requiresParent {
                            recovering = false
                            model.lockParents()
                            dismiss()
                        }
                    } catch is CancellationError {
                        busy = false
                        password = ""
                    } catch { busy = false
                        password = ""
                        message = (error as? KidsParentPINError)?.localizedDescription ?? (error as? KidsAPIError)?.localizedDescription ??
                            "Check the account, server address, and parent PIN."
                    }
                }
            }.disabled(busy || password.isEmpty || newPIN.isEmpty)
        }
    }

    private var sessionSection: some View {
        Section("Playback & Session") {
            Picker(
                "Episodes per session",
                selection: Binding(get: { model.state?.preferences.episodeLimit ?? 2 }, set: { model.savePreferences(limit: $0) })
            ) {
                Text("One").tag(1)
                Text("Two").tag(2)
                Text("Continuous").tag(0)
            }
            Toggle(isOn: Binding(get: { model.state?.preferences.spokenNavigation ?? false }, set: { model.savePreferences(spoken: $0) })) {
                Text("Spoken navigation").foregroundStyle(speechFocused ? Color.black : Color.white)
            }.focused($speechFocused)
            KidsParentAction("Preview spoken navigation") { model.touchGate()
                model.narration("Shows. Next. Shuffle. Movies.", preview: true)
            }
            Text(
                "A session cap is a stopping point. Kids can begin another session. VoiceOver and Reduce Motion are available in Apple TV Accessibility settings."
            )
            .foregroundStyle(.secondary)
            if let session = model.activePlayback {
                playbackPresentation.tracks(for: session, authorize: {
                    model.touchGate()
                    return model.unlocked
                })
            }
            if let movie = model.activePlayback?.title.kind == .movie ? model.activePlayback?.title : model.selectedMovie,
               movie.kind == .movie
            {
                KidsParentAction("Start this movie over") { model.startMovieOver(movie)
                    dismiss()
                }.accessibilityIdentifier("kids.parent.startover")
            }
        }
    }

    private var episodeSection: some View {
        Section("Choose an episode") {
            Picker("Show", selection: $selectedShow) {
                ForEach(model.catalog[.shows] ?? []) { show in Text(show.name).tag(Optional(show)) }
            }
            Picker("Season", selection: $selectedSeason) {
                ForEach(Array(Set(episodes.compactMap(\.season))).sorted(), id: \.self) { season in Text("Season \(season)").tag(season) }
            }
            ForEach(episodes.filter { $0.season == selectedSeason }) { episode in
                HStack(spacing: 24) {
                    KidsArtwork(model: model, item: episode, wide: true).frame(width: 180, height: 100)
                    Text("\(episode.episode ?? 0). \(episode.name)").lineLimit(2)
                }
                // Each protected action owns a Form row, so tvOS focus can select it independently.
                KidsParentAction("Play once") {
                    guard let show = selectedShow else { return }
                    model.playOnce(show: show, episode: episode)
                    dismiss()
                }.accessibilityIdentifier("kids.parent.playonce.\(episode.id)")
                KidsParentAction("Set Next here") { model.chooseNext(episode)
                    message = "Next will start at \(episode.name)."
                }.accessibilityIdentifier("kids.parent.setnext.\(episode.id)")
            }
            if let selectedShow {
                KidsParentAction("Reset ordered progress for this show", role: .destructive) { model.touchGate()
                    resetShowID = selectedShow.id
                    confirmReset = true
                }.accessibilityIdentifier("kids.parent.resetshow")
            }
        }
    }

    private var connectionSection: some View {
        Section("Connection & Help") {
            LabeledContent("Server", value: model.serverName)
            LabeledContent("Account", value: "Restricted kids playback")
            LabeledContent("Playback sync", value: model.cloudSyncStatus)
                .accessibilityIdentifier("kids.parent.syncstatus")
            if let date = model.lastPlayback {
                LabeledContent(
                    "Last successful playback",
                    value: date.formatted(date: .abbreviated, time: .shortened)
                )
            }
            KidsParentAction("Test connection and refresh approved catalog") {
                model.touchGate()
                Task { await model.refresh(forceMetadata: true)
                    message = model.problem ?? "Connected. Both approved libraries verified."
                }
            }
            KidsParentAction("Replace the Jellyfin account") { model.touchGate()
                Task { await model.signOut() }
            }
            Text("Manage library additions and metadata in Jellyfin's admin interface. This app never scans drives or deletes media.")
                .foregroundStyle(.secondary)
        }
    }

    private func loadEpisodes() async {
        episodes = []
        guard model.unlocked, let selectedShow, let binding = model.binding else { return }
        model.touchGate()
        do {
            let loaded = try await model.episodes(for: selectedShow)
            guard !Task.isCancelled, model.unlocked, model.binding == binding, self.selectedShow?.id == selectedShow.id else { return }
            episodes = loaded
            selectedSeason = loaded.first?.season ?? 1
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), model.binding == binding,
                  self.selectedShow?.id == selectedShow.id else { return }
            episodes = []
            message = "Unable to load regular episodes. Check the show in Jellyfin."
        }
    }
}

/// Native tvOS Form focus is held by the row. Give its SwiftUI label explicit contrast in either state.
private struct KidsParentAction: View {
    let title: String
    let role: ButtonRole?
    let action: () -> Void
    @FocusState
    private var focused: Bool

    init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Text(title).foregroundStyle(focused ? Color.black : (role == .destructive ? Color.red : Color.white))
        }.focused($focused)
    }
}
