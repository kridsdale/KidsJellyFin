//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import Combine
import CoreData
import Foundation
import KidsAccounts
import KidsArtwork
import KidsArtworkUI
import KidsCatalog
import KidsDiagnostics
import KidsDomain
import KidsParentControl
import KidsPersistence
import KidsPlaybackSession
import KidsViewingControl
import SwiftData

// SPDX-License-Identifier: MPL-2.0
import UIKit

@MainActor
public final class KidsAppModel: ObservableObject, KidsPlaybackSessionDelegate {
    @Published
    public private(set) var accountRevision = UUID()
    let playbackFactory: (any KidsPlaybackSessionFactory)?
    let accounts: (any KidsAccountHost)?
    private let admission: KidsAccountAdmission?
    private let accountScope: KidsAccountScope?
    private var activePlaybackLease: KidsAccountScope.Lease?
    private var activePlaybackBinding: KidsBinding?
    @Published
    private(set) var accountIdentity: KidsAccountIdentity?
    @Published
    public var category: KidsCategory = .shows
    @Published
    public internal(set) var catalog: [KidsCategory: [KidsItem]] = [:]
    var rawCatalog: [KidsCategory: [KidsItem]] = [:]
    var viewingRuntime: KidsViewingRuntime?
    @Published
    public internal(set) var viewingControlRevision = UUID()
    @Published
    public internal(set) var viewingHeld = false
    @Published
    public internal(set) var ambientMode = false
    @Published
    public internal(set) var viewingControlStatus = "Parent service is not paired."
    var receiverForeground = true
    @Published
    public internal(set) var loading = true
    @Published
    public internal(set) var catalogComplete = false
    @Published
    public internal(set) var problem: String?
    @Published
    public internal(set) var requiresParent = false
    @Published
    public internal(set) var needsLocalReset = false
    @Published
    public var selectedShow: KidsItem?
    @Published
    public var selectedMovie: KidsItem?
    @Published
    public internal(set) var starting = false
    public internal(set) var isPreview = false
    @Published
    public internal(set) var activePlayback: KidsPlaybackController? {
        didSet {
            activePlaybackLease = activePlayback == nil ? nil : accountScope?.capture()
            activePlaybackBinding = activePlayback == nil ? nil : binding
            if let activePlayback {
                rememberViewingGrant(activePlayback)
            }
        }
    }

    @Published
    public var sessionFinished = false
    @Published
    public internal(set) var sessionEndItem: KidsItem?
    @Published
    public internal(set) var missingItemReplacement: KidsItem?
    @Published
    public var parentPresented = false
    @Published
    public internal(set) var gate = KidsGate()
    @Published
    public internal(set) var state: KidsState?
    @Published
    public internal(set) var lastPlayback: Date?
    @Published
    public internal(set) var cloudSyncStatus = "Playback is saved on this Apple TV."
    public internal(set) var catalogPerformance: KidsPerformanceSpan?
    public var titlePerformance: KidsPerformanceSpan?
    private var persistence: KidsStateRepository?
    private var cloudActive = false
    private var syncBaseline: KidsSyncSnapshot?
    private var syncObservers = Set<AnyCancellable>()
    public var lastFocus: [KidsCategory: String] = [:]
    public internal(set) var episodeCache: [String: [KidsItem]] = [:]
    public var binding: KidsBinding? {
        state?.binding
    }

    private struct APIIdentity: Equatable {
        let url: URL
        let serverID: String
        let userID: String
        let token: String
    }

    @Published
    public private(set) var artworkRevision = UUID()
    private var artworkStore: (binding: KidsBinding, value: KidsArtworkStore)?
    private var retainedAPI: (identity: APIIdentity, value: KidsAPI)?
    private var verifiedEpisodes: (binding: KidsBinding, value: KidsEpisodeCache)?
    private var refreshFlight: (id: UUID, identity: APIIdentity?, task: Task<Void, Never>)?

    private func invalidateArtwork() {
        artworkStore?.value.invalidate()
        artworkStore = nil
        artworkRevision = UUID()
    }

    func invalidateEpisodeMetadata() {
        let old = verifiedEpisodes?.value
        verifiedEpisodes = nil
        episodeCache = [:]
        if let old {
            Task { await old.invalidate() }
        }
    }

    var api: KidsAPI? {
        guard !isPreview, let session = accounts?.currentIdentity else {
            if retainedAPI != nil {
                retainedAPI = nil
                refreshGeneration = UUID()
                invalidateEpisodeMetadata()
                invalidateArtwork()
            }
            return nil
        }
        var url = session.serverURL
        var token = session.accessToken
        #if DEBUG
        if validationScenario == "unavailable" {
            url = URL(string: "http://127.0.0.1:9")!
            token = "invalid-validation-token"
        } else if validationScenario == "invalid-token" {
            token = "invalid-validation-token"
        }
        #endif
        let identity = APIIdentity(url: url, serverID: session.serverID, userID: session.userID, token: token)
        if let retainedAPI, retainedAPI.identity == identity {
            return retainedAPI.value
        }
        refreshGeneration = UUID()
        invalidateEpisodeMetadata()
        invalidateArtwork()
        let value = KidsAPI(serverURL: url, token: token)
        retainedAPI = (identity, value)
        return value
    }

    #if DEBUG
    private var validationStreamFailureUsed = false
    func consumeValidationStreamFailure() -> Bool {
        guard validationScenario == "stream-unavailable", !validationStreamFailureUsed else { return false }
        validationStreamFailureUsed = true
        return true
    }

    private var validationScenario: String? {
        ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--kids-validation=") })?
            .replacingOccurrences(of: "--kids-validation=", with: "")
    }
    #endif

    public var serverName: String {
        accounts?.currentIdentity?.serverName ?? "Your Jellyfin server"
    }

    private var skipNextBrowseRefresh = true
    private var refreshGeneration = UUID()
    private var startTask: Task<Void, Never>?
    var startGeneration = UUID()
    private var speechTask: Task<Void, Never>?
    private let speaker = AVSpeechSynthesizer()
    private var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KidsPlayer/state-v1.json")
    }

    private var cloudRequested: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "KidsCloudSyncEnabled") as? String) == "YES"
    }

    private func repository() throws -> KidsStateRepository {
        if let persistence {
            return persistence
        }
        let trace = KidsPerformance.begin(.storeOpen)
        defer { trace?.finish(Task.isCancelled ? .cancelled : .failure) }
        let defaults = UserDefaults.standard
        let writerKey = "kids.sync.installation.v1"
        let writerID = defaults.string(forKey: writerKey) ?? UUID().uuidString
        defaults.set(writerID, forKey: writerKey)
        let url = stateURL.deletingLastPathComponent().appendingPathComponent("progress.store")
        let container: ModelContainer
        do {
            container = try KidsStateRepository.makeContainer(url: url, cloud: cloudRequested)
            cloudActive = cloudRequested
            cloudSyncStatus = cloudRequested ? "iCloud sync configured. Updates sync when connected." :
                "Saved on this simulator. iCloud requires a signed iCloud-enabled build."
        } catch {
            guard cloudRequested else { throw error }
            // Opening the same SDK store locally retains durable progress if CloudKit
            // cannot initialize. No JSON fallback, store deletion or silent reset.
            container = try KidsStateRepository.makeContainer(url: url, cloud: false)
            cloudActive = false
            cloudSyncStatus = "Saved on this Apple TV. iCloud could not start; reopen the app to retry."
        }
        let store = KidsStateRepository(container: container, writerID: writerID)
        persistence = store
        trace?.finish()
        return store
    }

    private func receiveStoredProgress() {
        guard !isPreview, !starting, activePlayback == nil, let binding, let persistence else { return }
        do {
            let restored = try persistence.load(binding: binding)
            syncBaseline = restored
            state = restored.state
        } catch { show(error) }
    }

    private func observeCloudChanges() {
        NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.receiveStoredProgress() }.store(in: &syncObservers)
        NotificationCenter.default.publisher(for: ModelContext.didSave)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.receiveStoredProgress() }.store(in: &syncObservers)
        NotificationCenter.default.publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, self.cloudActive, let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event, event.endDate != nil else { return }
                if event.succeeded {
                    if event.type == .export {
                        self.cloudSyncStatus = "Last iCloud save: " + event.endDate!.formatted(date: .abbreviated, time: .shortened)
                    }
                    if event.type == .import {
                        self.receiveStoredProgress()
                    }
                } else {
                    self.cloudSyncStatus = "Saved on this Apple TV. iCloud is waiting; it will retry automatically."
                }
            }.store(in: &syncObservers)
    }

    private let bindingKey = "kids.binding.v1"
    private let recoveryBindingKey = "kids.recoveryBinding.v1"
    private let gateKey = "kids.gate.v1"
    public var hasParentPIN: Bool {
        isPreview || accounts?.hasParentPIN != false
    }

    @Published
    public private(set) var parentPINProblem: String?

    public var unlocked: Bool {
        gate.unlocked(at: .now)
    }

    public convenience init(accounts: any KidsAccountHost, playbackFactory: any KidsPlaybackSessionFactory) {
        self.init(accounts: accounts, playbackFactory: playbackFactory, preview: false)
    }

    #if DEBUG
    /// Synthetic preview state cannot activate accounts, perform media IO or persist progress.
    public static func preview(_ scenario: String) -> KidsAppModel {
        KidsPreviewFixtures.model(scenario)
    }
    #endif

    init(accounts: (any KidsAccountHost)? = nil, playbackFactory: (any KidsPlaybackSessionFactory)? = nil, preview: Bool = false) {
        self.playbackFactory = playbackFactory
        self.accounts = accounts
        self.admission = accounts.map { KidsAccountAdmission(host: $0) }
        self.accountScope = accounts.map { KidsAccountScope(host: $0) }
        self.accountIdentity = accounts?.currentIdentity
        if preview {
            isPreview = true
            return
        }
        if let accounts {
            accounts.identityChanges.receive(on: DispatchQueue.main)
                .sink { [weak self] identity in
                    MainActor.assumeIsolated {
                        guard let self, self.accountIdentity != identity else { return }
                        self.accountIdentity = identity
                        self.resetViewingControlIdentity()
                        self.accountRevision = UUID()
                    }
                }.store(in: &syncObservers)
        }
        observeCloudChanges()
        if let data = UserDefaults.standard.data(forKey: gateKey), let saved = try? JSONDecoder().decode(KidsGate.self, from: data) {
            gate = saved
            gate.lock()
        }
    }

    func isCurrentAccount(_ lease: KidsAccountScope.Lease?) -> Bool {
        isPreview || lease?.isCurrent == true
    }

    private func checkAccount(_ lease: KidsAccountScope.Lease?) throws {
        try Task.checkCancellation()
        guard isCurrentAccount(lease) else { throw CancellationError() }
    }

    func isCurrentPlayback(_ controller: KidsPlaybackController) -> Bool {
        activePlayback === controller && isCurrentAccount(activePlaybackLease) && activePlaybackBinding == binding
    }

    public func enterBrowse() {
        guard !isPreview, !loading, !requiresParent, activePlayback == nil else { return }
        if skipNextBrowseRefresh {
            skipNextBrowseRefresh = false
            return
        }
        Task { await refresh() }
    }

    public func refresh(forceMetadata: Bool = false) async {
        guard !isPreview else { return }
        if forceMetadata {
            refreshFlight?.task.cancel()
            refreshFlight = nil
            invalidateEpisodeMetadata()
            invalidateArtwork()
        }
        _ = api // Bind the shared request to the complete current network/account identity.
        let identity = retainedAPI?.identity
        if let flight = refreshFlight, flight.identity == identity {
            await flight.task.value
            return
        }
        refreshFlight?.task.cancel()
        let id = UUID()
        let task = Task { await refreshCatalog() }
        refreshFlight = (id, identity, task)
        await task.value
        if refreshFlight?.id == id {
            refreshFlight = nil
        }
    }

    private func refreshCatalog() async {
        let trace = KidsPerformance.recorder.begin(.catalog, parent: KidsPerformance.launch)
        catalogPerformance = trace
        let outcome = await KidsPerformance.$current.withValue(trace) { await refreshMeasured() }
        trace?.finish(outcome)
    }

    private func refreshMeasured() async -> KidsPerformanceOutcome {
        let accountLease = accountScope?.capture()
        // Re-inserting the browse view after this refresh must not start another refresh loop.
        skipNextBrowseRefresh = true
        let generation = UUID()
        refreshGeneration = generation
        loading = true
        catalogComplete = false
        catalog = [:]
        rawCatalog = [:]
        episodeCache = [:]
        problem = nil
        needsLocalReset = false
        guard let api, let session = accounts?.currentIdentity,
              let data = UserDefaults.standard.data(forKey: bindingKey),
              let stored = try? JSONDecoder().decode(KidsBinding.self, from: data),
              stored.userID == session.userID, stored.serverID == session.serverID
        else {
            state = nil
            selectedShow = nil
            selectedMovie = nil
            lastFocus = [:]
            await stopPlayback()
            guard isCurrentAccount(accountLease), generation == refreshGeneration else { return .cancelled }
            loading = false
            requiresParent = true
            problem = "A grown-up needs to set up your shows."
            return .failure
        }
        do {
            var expected = stored
            try self.prepareViewingControls(binding: stored)
            #if DEBUG
            if validationScenario == "changed-libraries" {
                expected = KidsBinding(
                    serverID: stored.serverID,
                    userID: stored.userID,
                    showsID: "invalid-validation-library",
                    moviesID: stored.moviesID
                )
            }
            #endif
            let first = category
            try await api.catalogs(first: first, binding: expected, prepare: {
                try self.checkAccount(accountLease)
                guard generation == self.refreshGeneration else { throw CancellationError() }
                let load = KidsPerformance.begin(.storeLoad)
                defer { load?.finish(Task.isCancelled ? .cancelled : .failure) }
                let restored = try self.repository().load(binding: stored, legacyURL: self.stateURL)
                guard self.isCurrentAccount(accountLease), generation == self.refreshGeneration,
                      !Task.isCancelled else { throw CancellationError() }
                self.syncBaseline = restored
                self.state = restored.state
                self.requiresParent = !self.hasParentPIN
                load?.finish()
            }, receive: { category, items in
                guard self.isCurrentAccount(accountLease), generation == self.refreshGeneration,
                      !Task.isCancelled else { throw CancellationError() }
                let firstPublication = self.catalog[category] == nil
                self.rawCatalog[category] = items
                self.catalog[category] = self.filteredForViewing(items, binding: stored)
                self.loading = false
                if firstPublication {
                    let phase: KidsPerformancePhase = category == .shows ? .firstShowsReady : .firstMoviesReady
                    KidsPerformance.current?.mark(phase)
                    KidsPerformance.launch?.once(phase)
                }
            })
            guard isCurrentAccount(accountLease), generation == refreshGeneration, !Task.isCancelled else { return .cancelled }
            KidsPerformance.current?.mark(.catalogReady, values: [
                "shows": Double(catalog[.shows]?.count ?? 0), "movies": Double(catalog[.movies]?.count ?? 0)
            ])
            KidsPerformance.launch?.once(.catalogReady)
            catalogComplete = true
            return requiresParent ? .failure : .success
        } catch { guard isCurrentAccount(accountLease), generation == refreshGeneration else { return .cancelled }
            show(error)
            loading = false
            return Task.isCancelled || error is CancellationError ? .cancelled : .failure
        }
    }

    func show(_ error: Error) {
        if error is CancellationError {
            return
        }
        catalog = [:]
        invalidateEpisodeMetadata()
        invalidateArtwork()
        if let error = error as? KidsAPIError {
            problem = error.localizedDescription
            requiresParent = error == .authentication || error == .policy || error == .libraryChanged
            if requiresParent {
                state = nil
                selectedShow = nil
                selectedMovie = nil
                sessionEndItem = nil
                lastFocus = [:]
                startTask?.cancel()
                let generation = startGeneration
                let playback = activePlayback
                let accountLease = accountScope?.capture()
                Task {
                    guard isCurrentAccount(accountLease), startGeneration == generation, activePlayback === playback else { return }
                    await stopPlayback()
                }
            }
        } else if (error as? KidsContractError) == .invalidStateVersion {
            requiresParent = true
            needsLocalReset = true
            state = nil
            problem = "A grown-up needs to restore playback settings."
        } else {
            problem = "Your shows are taking a break. Try again."
            requiresParent = false
        }
    }

    public func episodes(for show: KidsItem, prefetch: Bool = false) async throws -> [KidsItem] {
        #if DEBUG
        if isPreview {
            return KidsPreviewFixtures.episodes(showID: show.id)
        }
        #endif
        guard let api, let binding, KidsEligibility.permits(show, binding: binding),
              show.kind == .series else { throw KidsContractError.denied }
        let generation = refreshGeneration
        let accountLease = accountScope?.capture()
        do {
            if verifiedEpisodes?.binding != binding {
                invalidateEpisodeMetadata()
                verifiedEpisodes = (binding, KidsEpisodeCache(api: api, binding: binding))
            }
            guard let cached = verifiedEpisodes?.value else { throw KidsContractError.denied }
            let items: [KidsItem]
            if prefetch {
                guard let warmed = try await cached.prefetch(for: show, binding: binding) else { return [] }
                items = warmed
            } else {
                items = try await cached.episodes(for: show, binding: binding)
            }
            guard isCurrentAccount(accountLease), !Task.isCancelled, self.binding == binding, refreshGeneration == generation else {
                throw CancellationError()
            }
            let filtered = filteredForViewing(items, binding: binding)
            episodeCache[show.id] = filtered
            return filtered
        } catch {
            guard isCurrentAccount(accountLease), !Task.isCancelled, self.binding == binding, refreshGeneration == generation else {
                throw CancellationError()
            }
            if let failure = error as? KidsAPIError, [.authentication, .policy, .libraryChanged].contains(failure) {
                self.show(failure)
            }
            throw error
        }
    }

    public func artworkImage(for item: KidsItem) async throws -> UIImage {
        guard let api, let binding, !loading, !requiresParent,
              KidsEligibility.permits(item, binding: binding) else { throw KidsContractError.denied }
        // Only objects from this verified catalog or a verified episode list may
        // reach the image pool. A cache hit never widens discovery.
        let listed = item.kind == .episode ? episodeCache[item.seriesID ?? ""]?.contains(item) == true :
            catalog.values.contains { $0.contains(item) }
        guard listed else { throw KidsContractError.denied }
        if artworkStore?.binding != binding {
            if artworkStore != nil {
                invalidateArtwork()
            }
            artworkStore = (binding, KidsArtworkStore(api: api, binding: binding))
        }
        guard let store = artworkStore?.value else { throw KidsContractError.denied }
        let revision = artworkRevision
        let accountLease = accountScope?.capture()
        do {
            let image = try await store.image(for: item, binding: binding)
            guard isCurrentAccount(accountLease), !Task.isCancelled, self.binding == binding, artworkRevision == revision,
                  !loading, !requiresParent else { throw CancellationError() }
            return image
        } catch {
            guard isCurrentAccount(accountLease), !Task.isCancelled, self.binding == binding,
                  artworkRevision == revision else { throw CancellationError() }
            if (error as? KidsAPIError) == .authentication {
                show(error)
            }
            throw error
        }
    }

    private func prefetchArtwork(_ item: KidsItem) async -> Bool {
        guard !Task.isCancelled else { return false }
        do {
            _ = try await artworkImage(for: item)
            return true
        } catch { return false }
    }

    public func prefetch(around focusedID: String?, category: KidsCategory) async {
        guard !isPreview, !loading, catalogComplete, !requiresParent, !starting, activePlayback == nil,
              let focusedID, let items = catalog[category], items.contains(where: { $0.id == focusedID }) else { return }
        guard let binding else { return }
        let plan = KidsPrefetchPlan.make(focusedID: focusedID, category: category, items: items, binding: binding)
        let trace = KidsPerformance.begin(.prefetch, variant: category == .shows ? .shows : .movies)
        let result = await KidsPerformance.$current.withValue(trace) {
            await withTaskGroup(of: Bool.self, returning: (Int, Int).self) { group in
                let model = self
                for item in plan.artwork {
                    group.addTask { [model, item] in
                        await model.prefetchArtwork(item)
                    }
                }
                if let show = plan.show {
                    group.addTask { [model, show] in
                        guard !Task.isCancelled else { return false }
                        do { return try await !model.episodes(for: show, prefetch: true).isEmpty
                        } catch { return false }
                    }
                }
                var completed = 0, failed = 0
                for await success in group {
                    if success {
                        completed += 1
                    } else {
                        failed += 1
                    }
                }
                return (completed, failed)
            }
        }
        trace?.finish(
            Task.isCancelled ? .cancelled : (result.1 > 0 ? .failure : .success),
            values: ["prefetch_count": Double(result.0), "prefetch_failures": Double(result.1)]
        )
    }

    func persist(intent: KidsSyncWriteIntent = .edit) {
        guard !isPreview, let state else { return }
        let trace = KidsPerformance.begin(.storeSave)
        defer { trace?.finish(Task.isCancelled ? .cancelled : .failure) }
        do {
            let store = try repository()
            let baseline = try syncBaseline ?? store.load(binding: state.binding, legacyURL: stateURL)
            let activeKey = activePlayback.flatMap { controller -> String? in
                switch controller.mode {
                case .ordered: "ordered/" + controller.title.id
                case .movie: "movie/" + controller.item.id
                default: nil
                }
            }
            let saved = try store.commit(state, since: baseline, intent: intent, activeKey: activeKey)
            syncBaseline = saved
            self.state = saved.state
            if saved.invalidatesPlayback, let controller = activePlayback {
                controller.allowsCheckpoints = false
                cancelPendingStart()
                Task {
                    guard activePlayback === controller else { return }
                    await stopPlayback(endSession: false)
                }
            }
            trace?.finish()
        } catch { problem = "Playback progress could not be saved. A grown-up can check storage." }
    }

    public func savePreferences(limit: Int? = nil, spoken: Bool? = nil) {
        guard unlocked else { return }
        touchGate()
        if let limit, [0, 1, 2].contains(limit) {
            state?.preferences.episodeLimit = limit
        }
        if let spoken {
            state?.preferences.spokenNavigation = spoken
        }
        persist()
    }

    public func chooseNext(_ item: KidsItem) {
        guard unlocked else { return }
        touchGate()
        do { try state?.setNext(item)
            persist()
        } catch { show(error) }
    }

    public func resetProgress(showID: String) {
        guard unlocked else { return }
        touchGate()
        state?.ordered.removeValue(forKey: showID)
        state?.endSession()
        persist()
    }

    public func resetMovie(_ item: KidsItem) {
        guard unlocked else { return }
        touchGate()
        state?.movies.removeValue(forKey: item.id)
        persist()
    }

    public func resetLocalState() async throws {
        guard unlocked else { throw KidsContractError.denied }
        let accountLease = accountScope?.capture()
        try checkAccount(accountLease)
        let originalBinding = binding
        let storedBinding = UserDefaults.standard.data(forKey: bindingKey)
        var confirmed = originalBinding
        if confirmed == nil, let data = storedBinding {
            confirmed = try? JSONDecoder().decode(KidsBinding.self, from: data)
        }
        guard let confirmed else { throw KidsContractError.denied }
        if !isPreview {
            guard let api, let session = accounts?.currentIdentity,
                  session.userID == confirmed.userID, session.serverID == confirmed.serverID
            else { throw KidsAPIError.authentication }
            try await api.validate(confirmed)
            try checkAccount(accountLease)
        }
        await stopPlayback()
        try checkAccount(accountLease)
        guard binding == originalBinding, UserDefaults.standard.data(forKey: bindingKey) == storedBinding else { throw CancellationError() }
        if isPreview {
            state = KidsState(binding: confirmed)
        } else {
            let reset = try repository().reset(binding: confirmed)
            syncBaseline = reset
            state = reset.state
        }
        needsLocalReset = false
        touchGate()
        await refresh()
    }

    public func narration(_ text: String, preview: Bool = false) {
        speechTask?.cancel()
        speaker.stopSpeaking(at: .immediate)
        guard preview || state?.preferences.spokenNavigation == true, !UIAccessibility.isVoiceOverRunning else { return }
        speechTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = 0.45
            self?.speaker.speak(utterance)
        }
    }

    public func lockParents() {
        admission?.cancel()
        gate.lock()
        saveGate()
        speechTask?.cancel()
        speaker.stopSpeaking(at: .immediate)
    }

    public func touchGate() {
        gate.touch(at: .now)
        saveGate()
    }

    public func checkGate() {
        if !unlocked && parentPresented && hasParentPIN {
            gate.lock()
        }
    }

    private func saveGate() {
        guard !isPreview else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(gate), forKey: gateKey)
    }

    public func setPIN(_ pin: String) throws {
        try replacePIN(pin, verifiedRecovery: false)
    }

    private func replacePIN(_ pin: String, verifiedRecovery: Bool) throws {
        guard !isPreview else { throw KidsContractError.denied }
        guard let accounts else { throw KidsAPIError.authentication }
        try accounts.replaceParentPIN(pin, unlocked: unlocked || verifiedRecovery)
        parentPINProblem = nil
        _ = gate.attempt(correct: true, now: .now)
        saveGate()
    }

    public func unlock(_ pin: String) -> Bool {
        parentPINProblem = nil
        do {
            let correct = isPreview ? pin == "4242" : try accounts?.matchesParentPIN(pin) ?? false
            let result = gate.attempt(correct: correct, now: .now)
            saveGate()
            return result
        } catch {
            gate.lock()
            saveGate()
            parentPINProblem = KidsParentPINError.unavailable.localizedDescription
            return false
        }
    }

    public func signIn(urlText: String, username: String, password: String, parentPIN: String, recovering: Bool = false) async throws {
        guard !isPreview else { throw KidsContractError.denied }
        guard let accounts else { throw KidsAPIError.authentication }
        try accounts.authorizeParentSetup(unlocked: unlocked, recovering: recovering)
        guard (4 ... 8).contains(parentPIN.count), parentPIN.allSatisfy(\.isNumber),
              parentPIN != password else { throw KidsContractError.denied }
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil, url.user == nil,
              url.password == nil else { throw KidsAPIError.connection }
        guard let admission else { throw KidsAPIError.authentication }
        let attempt = try admission.begin()
        do {
            let info = try await KidsAPI(serverURL: url, token: "").serverInfo()
            try attempt.check()
            let authenticated = try await accounts.authenticate(
                url: url,
                serverID: info.id,
                serverName: info.name,
                username: username,
                password: password
            )
            try attempt.check()
            let token = authenticated.identity.accessToken
            let userID = authenticated.identity.userID
            let newAPI = KidsAPI(serverURL: url, token: token)
            let libraries = try await newAPI.libraries(userID: userID)
            try attempt.check()
            guard authenticated.identity.serverURL == url,
                  authenticated.identity.serverID == info.id else { throw KidsContractError.denied }
            guard let shows = libraries.first(where: { $0.name == "Kid TV" && $0.collectionType == "tvshows" }),
                  let movies = libraries.first(where: { $0.name == "Kid Movies" && $0.collectionType == "movies" })
            else { throw KidsAPIError.libraryChanged }
            let binding = KidsBinding(serverID: info.id, userID: userID, showsID: shows.id, moviesID: movies.id)
            try await newAPI.validate(binding)
            try attempt.check()
            try accounts.authorizeParentSetup(unlocked: unlocked, recovering: recovering)
            let restored: KidsSyncSnapshot
            if recovering {
                guard let data = UserDefaults.standard.data(forKey: bindingKey) ?? UserDefaults.standard.data(forKey: recoveryBindingKey),
                      let previous = try? JSONDecoder().decode(KidsBinding.self, from: data), previous == binding
                else { throw KidsContractError.denied }
                // Verify the same restricted account and both library identities before resetting the gate.
                guard gate.mayAttempt(at: .now) else { throw KidsContractError.denied }
                restored = try repository().reset(binding: binding)
            } else {
                if accounts.hasParentPIN {
                    guard try accounts.matchesParentPIN(parentPIN) else { throw KidsContractError.denied }
                }
                // Refreshing credentials for the same binding retains ordered progress, bags, and session budget.
                restored = try repository().load(binding: binding, legacyURL: stateURL)
            }
            // Only the same-account/library recovery above may replace a locked PIN.
            // Parent access is granted after secure storage succeeds.
            try replacePIN(parentPIN, verifiedRecovery: recovering)
            try attempt.check()
            await stopPlayback()
            try attempt.check()
            try attempt.prepare(authenticated, binding: binding)
            let encodedBinding = try JSONEncoder().encode(binding)
            try attempt.check()
            UserDefaults.standard.set(encodedBinding, forKey: bindingKey)
            try attempt.check()
            UserDefaults.standard.set(encodedBinding, forKey: recoveryBindingKey)
            try attempt.check()
            syncBaseline = restored
            state = restored.state
            // Use the existing session lifecycle for playback SDK integration, without exposing its library UI.
            try attempt.check()
            try await attempt.activate(authenticated, binding: binding)
            try attempt.check()
            await refresh()
            try attempt.check()
        } catch {
            // Obsolete failures cannot become a current setup error.
            try attempt.check()
            throw error
        }
    }

    public func signOut() async {
        guard !isPreview, unlocked, let admission else { return }
        let attempt: KidsAccountAdmission.Attempt
        do { attempt = try admission.begin() }
        catch { return }
        do {
            refreshFlight?.task.cancel()
            refreshFlight = nil
            refreshGeneration = UUID()
            retainedAPI = nil
            invalidateEpisodeMetadata()
            invalidateArtwork()
            await stopPlayback()
            try attempt.check()
            catalog = [:]
            try attempt.check()
            lastFocus = [:]
            state = nil
            try attempt.check()
            if let data = UserDefaults.standard.data(forKey: bindingKey) {
                UserDefaults.standard.set(data, forKey: recoveryBindingKey)
            }
            try attempt.check()
            UserDefaults.standard.removeObject(forKey: bindingKey)
            try await attempt.signOut()
            try attempt.check()
            requiresParent = true
            lockParents()
        } catch is CancellationError {
            // A replacement admission owns subsequent effects.
        } catch {
            do { try attempt.check()
                show(error)
            } catch { return }
        }
    }

    public func play(
        _ title: KidsItem,
        mode: KidsPlaybackMode,
        explicitEpisode: KidsItem? = nil,
        retryItem: KidsItem? = nil,
        retryPosition: Double = 0,
        continuing: Bool = false
    ) {
        guard mode != .once || retryItem != nil || unlocked else { return }
        beginPlayback(
            title,
            mode: mode,
            explicitEpisode: explicitEpisode,
            retryItem: retryItem,
            retryPosition: retryPosition,
            continuing: continuing
        )
    }

    public func playOnce(show: KidsItem, episode: KidsItem) {
        guard unlocked, let approvedBinding = binding, show.kind == .series,
              KidsEligibility.permits(show, binding: approvedBinding),
              KidsEligibility.permits(episode, binding: approvedBinding), episode.seriesID == show.id
        else { return }
        touchGate()
        let accountLease = accountScope?.capture()
        Task {
            guard isCurrentAccount(accountLease), !Task.isCancelled else { return }
            await stopPlayback()
            guard isCurrentAccount(accountLease), !Task.isCancelled, binding == approvedBinding else { return }
            // The protected action was authorized before the parent sheet dismissed and relocked.
            beginPlayback(show, mode: .once, explicitEpisode: episode)
        }
    }

    public func startMovieOver(_ movie: KidsItem) {
        guard unlocked, let approvedBinding = binding, movie.kind == .movie,
              KidsEligibility.permits(movie, binding: approvedBinding) else { return }
        touchGate()
        let accountLease = accountScope?.capture()
        Task {
            guard isCurrentAccount(accountLease), !Task.isCancelled else { return }
            await stopPlayback()
            guard isCurrentAccount(accountLease), !Task.isCancelled, binding == approvedBinding else { return }
            // Stop checkpoints the old stream first; then discard that position for this explicit restart.
            state?.movies.removeValue(forKey: movie.id)
            persist()
            beginPlayback(movie, mode: .movie)
        }
    }

    func beginPlayback(
        _ title: KidsItem,
        mode: KidsPlaybackMode,
        explicitEpisode: KidsItem? = nil,
        retryItem: KidsItem? = nil,
        retryPosition: Double = 0,
        continuing: Bool = false
    ) {
        guard startTask == nil, activePlayback == nil, let api, let binding,
              permitsViewing(title, binding: binding) else { return }
        let accountLease = accountScope?.capture()
        guard isCurrentAccount(accountLease) else { return }
        let variant = KidsPerformanceVariant(rawValue: mode.rawValue) ?? .unknown
        let trace = KidsPerformance.begin(.playback, variant: variant, values: ["retry": retryItem == nil ? 0 : 1])
        let evidenceCapture = KidsEvidenceCapture.shared
        let evidenceAction = evidenceCapture?.beginAction(serverID: binding.serverID, userID: binding.userID)
        let evidenceClientID = evidenceCapture == nil ? "" : (UIDevice.current.identifierForVendor?.uuidString ?? "")
        let requestedItem = retryItem ?? explicitEpisode ?? (title.kind == .movie ? title : nil)
        let earlyEvidence = requestedItem.flatMap {
            evidenceCapture?.bind(
                action: evidenceAction,
                itemID: $0.id,
                serverID: binding.serverID,
                userID: binding.userID,
                clientID: evidenceClientID
            )
        }
        starting = true
        sessionFinished = false
        missingItemReplacement = nil
        problem = nil
        let generation = UUID()
        startGeneration = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.startGeneration == generation, self.starting else { return }
            self.cancelPendingStart()
            self.problem = "This video is taking a break. Try again."
        }
        startTask = Task { [weak self] in
            guard let self else {
                earlyEvidence?.finish(monotonicNS: DispatchTime.now().uptimeNanoseconds, disposition: .interrupted)
                return
            }
            var selectedEvidence = earlyEvidence
            var evidenceHandedOff = false
            defer {
                if !evidenceHandedOff {
                    selectedEvidence?.finish(monotonicNS: DispatchTime.now().uptimeNanoseconds, disposition: .interrupted)
                }
                if self.startGeneration == generation {
                    self.startTask = nil
                    self.starting = false
                }
            }
            await KidsPerformance.$current.withValue(trace) { [self] in
                do {
                    try self.checkAccount(accountLease)
                    try await self.acquireViewingLease()
                    try self.checkAccount(accountLease)
                    var item: KidsItem
                    var position = 0.0
                    var allEpisodes: [KidsItem] = []
                    if title.kind == .series {
                        self.selectedShow = title
                        allEpisodes = try await self.episodes(for: title)
                        if let retryItem {
                            guard let current = allEpisodes.first(where: { $0.id == retryItem.id })
                            else { throw KidsContractError.unavailable }
                            item = current
                            position = retryPosition
                        } else if let explicitEpisode {
                            guard let current = allEpisodes.first(where: { $0.id == explicitEpisode.id })
                            else { throw KidsContractError.denied }
                            item = current
                        } else if mode == .shuffle, let retained = self.state?.session, retained.showID == title.id,
                                  retained.mode == .shuffle,
                                  let id = retained.itemID
                        {
                            guard let current = allEpisodes.first(where: { $0.id == id }) else { throw KidsContractError.missingCursor }
                            item = current
                            position = retained.seconds
                        } else if mode == .shuffle {
                            guard let draw = try self.state?.nextShuffle(
                                showID: title.id,
                                episodes: self.shuffleForViewing(allEpisodes, binding: binding)
                            )
                            else { throw KidsContractError.unavailable }
                            item = draw
                        } else {
                            guard let next = try self.state?.orderedNext(showID: title.id, episodes: allEpisodes)
                            else { throw KidsContractError.unavailable }
                            item = next.0
                            position = next.1
                        }
                    } else {
                        item = title
                        if retryItem != nil {
                            position = retryPosition
                        } else if let progress = self.state?.movies[item.id], !progress.complete {
                            position = progress.seconds
                        }
                    }
                    trace?.mark(.itemSelected, values: ["resume_seconds": position, "episodes": Double(allEpisodes.count)])
                    if selectedEvidence == nil {
                        selectedEvidence = evidenceCapture?.bind(
                            action: evidenceAction,
                            itemID: item.id,
                            serverID: binding.serverID,
                            userID: binding.userID,
                            clientID: evidenceClientID
                        )
                    }
                    let verified = try await api.authorize(itemID: item.id, expectedKind: item.kind, binding: binding)
                    guard self.permitsViewing(verified, binding: binding) else { throw KidsContractError.denied }
                    trace?.mark(.authorized)
                    guard self.isCurrentAccount(accountLease), !Task.isCancelled, self.binding == binding else { trace?.finish(.cancelled)
                        return
                    }
                    if verified.kind == .episode {
                        guard verified.seriesID == title.id else { throw KidsContractError.denied }
                    }
                    guard let playbackFactory = self.playbackFactory else { throw KidsAPIError.unavailable }
                    #if DEBUG
                    let simulateStreamFailure = self.consumeValidationStreamFailure()
                    #else
                    let simulateStreamFailure = false
                    #endif
                    let controller = try await KidsEvidenceCapture.$currentAttempt.withValue(selectedEvidence) {
                        try await playbackFactory.prepare(
                            item: verified,
                            title: title,
                            mode: mode,
                            position: position,
                            episodes: allEpisodes,
                            delegate: self,
                            performance: trace, simulateStreamFailure: simulateStreamFailure
                        )
                    }
                    guard self.isCurrentAccount(accountLease), !Task.isCancelled, self.binding == binding,
                          self.startGeneration == generation, self.permitsViewing(verified, binding: binding)
                    else { await controller.stop()
                        trace?.finish(.cancelled)
                        return
                    }
                    trace?.mark(.controllerReady)
                    self.activePlayback = controller
                    evidenceHandedOff = true
                    controller.start()
                } catch {
                    trace?.finish(error: error)
                    guard self.isCurrentAccount(accountLease), !Task.isCancelled, self.startGeneration == generation,
                          self.binding == binding else { return }
                    if (error as? KidsContractError) ==
                        .missingCursor
                    {
                        self.missingItemReplacement = try? self.state?.missingSuccessor(
                            showID: title.id,
                            episodes: self.episodeCache[title.id] ?? []
                        )
                        self.problem = self.missingItemReplacement == nil ? "This episode is missing. A grown-up can choose another." : "This episode is missing. You can choose the next picture."
                    } else if (error as? KidsContractError) == .ambiguousEpisodes {
                        self.problem = "A grown-up needs to check episode numbering."
                    } else {
                        self.show(error)
                    }
                }
            }
        }
    }

    /// A dismissed presentation can only stop the session it actually displayed.
    public func dismissPlayback(_ presented: KidsPlaybackController) async {
        guard activePlayback === presented else { return }
        await stopPlayback()
    }

    public func stopPlayback(endSession: Bool = true) async {
        let generation = UUID()
        startGeneration = generation
        startTask?.cancel()
        startTask = nil
        starting = false
        let playback = activePlayback
        let accountLease = playback == nil ? accountScope?.capture() : activePlaybackLease
        let originalBinding = binding
        if let playback {
            flushViewingProgress(playback)
            await playback.stop()
            if viewingRuntime?.ambientSessionID != playback.id {
                queueViewingEvent(.stopped, controller: playback)
            }
        }
        guard startGeneration == generation, activePlayback === playback else { return }
        activePlayback = nil
        guard isCurrentAccount(accountLease), binding == originalBinding else { return }
        if endSession {
            state?.endSession()
        }
        persist(intent: .playback)
    }

    public func cancelPendingStart() {
        startGeneration = UUID()
        startTask?.cancel()
        startTask = nil
        starting = false
    }

    public func background() {
        receiverForeground = false
        cancelPendingStart()
        lockParents()
        activePlayback?.pauseOnBackground()
    }

    public func playbackBegan(_ controller: KidsPlaybackController) {
        guard isCurrentPlayback(controller) else { return }
        if viewingRuntime?.ambientSessionID == controller.id {
            queueViewingEvent(.ambientStarted, controller: controller)
            return
        }
        queueViewingEvent(.started, controller: controller)
        do { try state?.began(item: controller.item, mode: controller.mode, showID: controller.title.id)
            lastPlayback = .now
            persist(intent: .playback)
        } catch { Task { await dismissPlayback(controller) }
            show(error)
        }
    }

    public func playbackCheckpoint(_ controller: KidsPlaybackController, seconds: Double) {
        guard isCurrentPlayback(controller), controller.allowsCheckpoints else { return }
        state?.checkpoint(item: controller.item, mode: controller.mode, seconds: seconds)
        persist(intent: .playback)
    }

    public func completed(_ controller: KidsPlaybackController) async {
        if isCurrentPlayback(controller), viewingRuntime?.ambientSessionID == controller.id {
            viewingRuntime?.ambientAttempts = 0
            await stopPlayback(endSession: false)
            return
        }
        guard isCurrentPlayback(controller), controller.allowsCheckpoints else { return }
        flushViewingProgress(controller)
        queueViewingEvent(.ended, controller: controller)
        let finishForParent = viewingRuntime?.lease.endsAtEOF(playbackSessionID: controller.id.uuidString) == true
        let accountLease = activePlaybackLease
        let originalBinding = binding
        do {
            let more = try state?.finished(item: controller.item, mode: controller.mode, episodes: controller.episodes) ?? false
            if !more {
                state?.endSession()
            }
            persist(intent: .playback)
            if more && !finishForParent {
                controller.nextEpisode = controller.mode == .shuffle ? try state?.nextShuffle(
                    showID: controller.title.id,
                    episodes: self.shuffleForViewing(controller.episodes, binding: originalBinding!)
                ) : try state?.orderedNext(showID: controller.title.id, episodes: controller.episodes).0
                controller.countdown = 10
                controller.showCountdown = true
                persist(intent: .playback)
            }
            await controller.stop()
            guard isCurrentPlayback(controller) else { return }
            if finishForParent {
                activePlayback = nil
                await enterViewingHold(latchControl: true)
            } else if !more {
                activePlayback = nil
                sessionFinished = controller.mode == .ordered || controller.mode == .shuffle
                if sessionFinished {
                    sessionEndItem = controller.title
                }
            }
        } catch { await stopPlayback()
            guard isCurrentAccount(accountLease), binding == originalBinding else { return }
            show(error)
        }
    }

    public func continuePlayback(_ controller: KidsPlaybackController) async {
        guard isCurrentPlayback(controller) else { return }
        activePlayback = nil
        play(controller.title, mode: controller.mode, continuing: true)
    }

    public func stopPlaybackFromSession(_ controller: KidsPlaybackController) async {
        guard activePlayback === controller else { return }
        await stopPlayback()
    }

    public func retryPlayback(_ controller: KidsPlaybackController, position: Double) {
        guard isCurrentPlayback(controller) else { return }
        activePlayback = nil
        play(controller.title, mode: controller.mode, retryItem: controller.item, retryPosition: position, continuing: true)
    }

    public func playbackFailed(_ controller: KidsPlaybackController, error: KidsPlaybackFailure) {
        guard isCurrentPlayback(controller) else { return }
        if viewingRuntime?.ambientSessionID == controller.id {
            queueViewingEvent(.ambientFailed, controller: controller)
            Task { await self.stopPlayback(endSession: false) }
            return
        }
        if error == .authentication {
            show(KidsAPIError.authentication)
            return
        }
        Task { [weak self, weak controller] in
            guard let self, let controller, self.isCurrentPlayback(controller), let api = self.api,
                  let binding = self.binding else { return }
            do { try await api.validate(binding) }
            catch {
                guard self.isCurrentPlayback(controller), self.binding == binding else { return }
                if let failure = error as? KidsAPIError, [.authentication, .policy, .libraryChanged].contains(failure) {
                    self.show(failure)
                }
            }
        }
    }
}
