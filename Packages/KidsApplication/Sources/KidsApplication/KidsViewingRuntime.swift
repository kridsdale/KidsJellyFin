//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation
import KidsAccounts
import KidsCatalog
import KidsDomain
import KidsParentControl
import KidsPlaybackSession
import KidsViewingControl
import UIKit

@MainActor
final class KidsViewingRuntime {
    static var clientRevision: ReceiverBuildRevision? {
        (Bundle.main.object(forInfoDictionaryKey: "KidsEvidenceImplementationRevision") as? String)
            .flatMap { ReceiverBuildRevision(rawValue: $0) }
    }

    var configuration: KidsReceiverConfiguration
    var lease: ViewingLease
    let api: KidsReceiverAPI
    private let transport: any ParentHTTPTransport
    private let ledgerDirectory: URL
    var events: [ReceiverEvent] = []
    var ambientSessionID: UUID?
    var ambientControlID: UUID?
    var ambientShowID: String?
    var ambientAttempts = 0
    var ambientStarting = false
    var ambientTask: Task<Void, Never>?
    var policyFlight: (id: UUID, task: Task<Void, Error>)?
    var reportingFault = false
    var epochRecoveryRequired = false
    var recoveringEpoch = false
    var drainingUnconfirmedEvidence = false
    var lastFrame: (sessionID: UUID, position: Double, uptime: UInt64)?
    var accumulatedPlaying = 0.0
    var lastProgressNS: UInt64 = 0
    var lastControlID: UUID?
    var normalGrant: (sessionID: UUID, revision: Int)?
    var admittedIntentID: UUID?
    let admission: KidsAdmissionJournal
    weak var admissionController: KidsPlaybackController?
    var heldSessionID: UUID?
    var admissionHold: KidsAdmissionHold?
    var admissionEpoch = UUID()
    var admissionFlight: (id: UUID, sessionID: UUID, task: Task<Bool, Never>)?
    var resumeObservation: (sessionID: UUID, position: Double)?
    var automaticAdmissionAttempts = 0
    var nextAutomaticAdmissionNS: UInt64 = 0
    var bufferReadyBaseline: (sessionID: UUID, sequence: UInt64)?
    var stablePlayingSinceNS: UInt64?
    var announcedSessionID: UUID?
    var lastTransportState: ReceiverEvent.Kind?
    var terminalReportKeys: [String] = []
    private var claimedSession: UUID?
    private var claimed: Set<UUID> = []
    private let ledgerURL: URL

    init(
        configuration: KidsReceiverConfiguration,
        transport: any ParentHTTPTransport = ParentURLTransport(),
        ledgerDirectory: URL? = nil
    ) throws {
        self.configuration = configuration
        self.transport = transport
        lease = ViewingLease(
            serverID: configuration.serverID,
            childUserID: configuration.childUserID,
            deviceID: configuration.deviceID,
            requiresPlaybackGrants: configuration.requiresPlaybackGrants
        )
        api = try KidsReceiverAPI(
            server: ParentServer(configuration.serviceURL.absoluteString),
            serverID: configuration.serverID,
            childUserID: configuration.childUserID,
            deviceID: configuration.deviceID.uuidString,
            token: configuration.token,
            clientRevision: Self.clientRevision,
            transport: transport
        )
        let directory = ledgerDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(
                "KidsPlayer/Receiver",
                isDirectory: true
            )
        self.ledgerDirectory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        ledgerURL = directory.appendingPathComponent("\(configuration.deviceID.uuidString).json")
        admission = try KidsAdmissionJournal(configuration: configuration, directory: directory)
    }

    func freshAfterRecovery() throws -> KidsViewingRuntime {
        try KidsViewingRuntime(configuration: configuration, transport: transport, ledgerDirectory: ledgerDirectory)
    }

    private struct Claims: Codable { let sessionID: UUID
        let ids: Set<UUID>
    }

    /// Persist before executing. A new playback UUID cannot inherit old remote commands.
    func claim(_ command: UUID, sessionID: UUID) throws -> Bool {
        if claimedSession != sessionID {
            if FileManager.default.fileExists(atPath: ledgerURL.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: ledgerURL.path)
                guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1_000_000,
                      attributes[.type] as? FileAttributeType == .typeRegular else { throw KidsContractError.denied }
                let saved = try JSONDecoder().decode(Claims.self, from: Data(contentsOf: ledgerURL))
                claimed = saved.sessionID == sessionID ? saved.ids : []
            } else {
                claimed = []
            }
            claimedSession = sessionID
        }
        guard !claimed.contains(command) else { return false }
        guard claimed.count < 4096 else { throw KidsContractError.denied }
        var next = claimed
        next.insert(command)
        let data = try JSONEncoder().encode(Claims(sessionID: sessionID, ids: next))
        try data.write(to: ledgerURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledgerURL.path)
        let handle = try FileHandle(forWritingTo: ledgerURL)
        try handle.synchronize()
        try handle.close()
        claimed = next
        return true
    }
}

extension KidsAppModel {
    public var receiverInstallationID: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "Unavailable"
    }

    public var receiverBuildRevision: String? {
        KidsViewingRuntime.clientRevision?.rawValue
    }

    func resetViewingControlIdentity() {
        viewingRuntime?.ambientTask?.cancel()
        viewingRuntime?.admissionEpoch = UUID()
        viewingRuntime?.admissionFlight?.task.cancel()
        activePlayback?.onResumeRequested = nil
        viewingRuntime = nil
        rawCatalog = [:]
        viewingHeld = false
        ambientMode = false
        viewingControlRevision = UUID()
    }

    func prepareViewingControls(binding: KidsBinding) throws {
        let configuration: KidsReceiverConfiguration?
        do { configuration = try accounts?.receiverConfiguration }
        catch { viewingHeld = true
            viewingControlStatus = "Parent-service credentials could not be read."
            throw error
        }
        guard let configuration else {
            if viewingRuntime != nil {
                resetViewingControlIdentity()
            }
            return
        }
        guard configuration.serverID == binding.serverID, configuration.childUserID == binding.userID,
              configuration.deviceID == UUID(uuidString: receiverInstallationID)
        else {
            viewingHeld = true
            viewingControlStatus = "A grown-up must check this TV's parent-service pairing."
            throw KidsContractError.denied
        }
        if viewingRuntime?.configuration != configuration {
            viewingRuntime = try KidsViewingRuntime(configuration: configuration)
            viewingHeld = configuration.activated
            ambientMode = configuration.activated
            viewingControlStatus = configuration.activated ? "Waiting for fresh viewing permission." : "Paired. Waiting for administrator activation."
            viewingControlRevision = UUID()
        }
    }

    public func pairViewingControls(serviceURL: String, token: String) throws {
        guard unlocked, !isPreview, let accounts, let binding,
              let deviceID = UUID(uuidString: receiverInstallationID) else { throw KidsContractError.denied }
        let service = try ParentServer(serviceURL)
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty, secret.utf8.allSatisfy({ (33 ... 126).contains($0) }) else { throw KidsContractError.denied }
        let previous = try accounts.receiverConfiguration
        let configuration = KidsReceiverConfiguration(
            serviceURL: service.url,
            serverID: binding.serverID,
            childUserID: binding.userID,
            deviceID: deviceID,
            token: secret,
            activated: previous?.activated ?? false,
            latchedControlID: previous?.latchedControlID,
            requiresPlaybackGrants: previous?.requiresPlaybackGrants ?? false
        )
        try accounts.storeReceiverConfiguration(configuration)
        try prepareViewingControls(binding: binding)
        touchGate()
    }

    public func unpairViewingControls() async throws {
        guard unlocked, !isPreview, let accounts else { throw KidsContractError.denied }
        try accounts.storeReceiverConfiguration(nil)
        if ambientMode {
            await stopPlayback(endSession: false)
        }
        resetViewingControlIdentity()
        viewingControlStatus = "Parent service disconnected by a grown-up."
        await refresh()
    }

    func permitsViewing(_ item: KidsItem, binding: KidsBinding) -> Bool {
        guard !viewingHeld, !ambientMode else { return false }
        guard let runtime = viewingRuntime, runtime.configuration.activated else { return KidsEligibility.permits(item, binding: binding) }
        guard item.id != runtime.ambientShowID else { return false }
        return runtime.lease.permitsBrowsing(item, binding: binding, at: DispatchTime.now().uptimeNanoseconds)
    }

    func rememberViewingGrant(_ controller: KidsPlaybackController) {
        guard let runtime = viewingRuntime, runtime.configuration.activated,
              runtime.ambientSessionID != controller.id, let binding,
              permitsViewingPlayback(controller, binding: binding),
              let revision = runtime.lease.policy?.revision else { return }
        if runtime.lease.requiresPlaybackGrants, controller.hasBegunPlayback,
           runtime.announcedSessionID != controller.id,
           !mayAnnounceViewingStart(controller, runtime: runtime)
        {
            // This controller may have played an earlier surrendered generation.
            // A newly admitted but still paused generation is not observed usage.
            return
        }
        runtime.normalGrant = (controller.id, revision)
    }

    func permitsViewingPlayback(_ controller: KidsPlaybackController, binding: KidsBinding) -> Bool {
        guard let runtime = viewingRuntime, runtime.configuration.activated else { return KidsEligibility.permits(
            controller.item,
            binding: binding
        ) }
        guard !viewingHeld, !ambientMode, !runtime.reportingFault else { return false }
        guard runtime.heldSessionID != controller.id else { return false }
        return runtime.lease.permitsPlayback(
            controller.item,
            binding: binding,
            intentID: runtime.admittedIntentID,
            sessionID: controller.id.uuidString,
            at: DispatchTime.now().uptimeNanoseconds
        )
    }

    func filteredForViewing(_ items: [KidsItem], binding: KidsBinding) -> [KidsItem] {
        let permitted = items.filter { permitsViewing($0, binding: binding) }
        guard let runtime = viewingRuntime, runtime.configuration.activated,
              permitted.allSatisfy({ $0.kind == .series }) else { return permitted }
        let preferred = Set(runtime.lease.policy?.shuffle.preferredShowIDs ?? [])
        return permitted.enumerated().sorted { left, right in
            let a = preferred.contains(left.element.id), b = preferred.contains(right.element.id)
            return a == b ? left.offset < right.offset : a && !b
        }.map(\.element)
    }

    func shuffleForViewing(_ items: [KidsItem], binding: KidsBinding) -> [KidsItem] {
        guard let runtime = viewingRuntime, runtime.configuration.activated else { return items }
        return runtime.lease.shuffleCandidates(items, binding: binding, at: DispatchTime.now().uptimeNanoseconds)
    }

    public func foregroundViewingControls() {
        receiverForeground = true
        if ambientMode, let controller = activePlayback, controller.driver.frame.paused {
            controller.driver.togglePlayPause()
        }
    }

    public func requestViewingParentAccess() async {
        viewingRuntime?.ambientAttempts = 3
        await stopPlayback(endSession: false)
        parentPresented = true
    }

    public func resumeViewingAfterParentSheet() {
        viewingRuntime?.ambientAttempts = 0
    }

    public func monitorViewingControls() async {
        guard !isPreview, let runtime = viewingRuntime else { return }
        defer {
            runtime.ambientTask?.cancel()
            runtime.ambientTask = nil
            runtime.policyFlight?.task.cancel()
            runtime.policyFlight = nil
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.viewingPolicyLoop(runtime) }
            group.addTask { await self.viewingTickLoop(runtime) }
            await group.waitForAll()
        }
    }

    private func viewingPolicyLoop(_ runtime: KidsViewingRuntime) async {
        while !Task.isCancelled, viewingRuntime === runtime {
            if receiverForeground {
                do { try await synchronizeViewingPolicy(runtime) }
                catch {
                    guard viewingRuntime === runtime else { return }
                    viewingControlStatus = runtime.reportingFault ? "Viewing is held until parent controls can be confirmed." :
                        (runtime.configuration
                            .activated ? "Waiting for fresh viewing permission." : "Paired; server activation is not ready.")
                }
            }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    func acquireViewingLease() async throws {
        guard let runtime = viewingRuntime, runtime.configuration.activated else { return }
        if runtime.lease.requiresPlaybackGrants {
            try await drainViewingAdmission(runtime)
            guard !Task.isCancelled, viewingRuntime === runtime, !viewingHeld, !ambientMode,
                  runtime.lease.policy?.playbackIntentAvailable == true || runtime.lease
                      .allowsNormalViewing(at: DispatchTime.now().uptimeNanoseconds)
            else { throw KidsContractError.denied }
            return
        }
        try await synchronizeViewingPolicy(runtime)
        guard !Task.isCancelled, viewingRuntime === runtime, runtime.events.isEmpty,
              !viewingHeld, !ambientMode, runtime.lease.allowsNormalViewing(at: DispatchTime.now().uptimeNanoseconds)
        else { throw KidsContractError.denied }
    }

    func synchronizeViewingPolicy(_ runtime: KidsViewingRuntime) async throws {
        guard !runtime.recoveringEpoch else { throw KidsContractError.denied }
        if let flight = runtime.policyFlight {
            defer {
                // A joiner can resume before the original caller's defer.
                // Do not keep joining a completed refresh after staging a
                // mutation; the next drain iteration needs a new flight.
                if runtime.policyFlight?.id == flight.id {
                    runtime.policyFlight = nil
                }
            }
            try await flight.task.value
            return
        }
        let id = UUID()
        let task = Task { try await self.performViewingPolicyRefresh(runtime) }
        runtime.policyFlight = (id, task)
        defer {
            if runtime.policyFlight?.id == id {
                runtime.policyFlight = nil
            }
        }
        try await task.value
    }

    private func performViewingPolicyRefresh(_ runtime: KidsViewingRuntime) async throws {
        guard viewingRuntime === runtime, binding?.serverID == runtime.configuration.serverID,
              binding?.userID == runtime.configuration.childUserID else { throw KidsContractError.denied }
        if runtime.lease.requiresPlaybackGrants, let controller = activePlayback,
           runtime.admissionFlight == nil, runtime.ambientSessionID != controller.id,
           controller.hasBegunPlayback, !controller.hasEndedPlayback,
           controller.driver.frame.paused || controller.driver.frame.buffering
        {
            if runtime.heldSessionID != controller.id {
                holdViewingTransport(
                    controller,
                    reason: controller.driver.frame.buffering ? .buffering : .paused
                )
            }
            flushViewingProgress(controller)
            stageViewingSurrender(controller)
        }
        if runtime.events.isEmpty {
            let observed = activePlayback.flatMap { controller in
                runtime.configuration.activated && runtime.announcedSessionID == controller.id && !controller
                    .hasEndedPlayback ? controller : nil
            }
            queueViewingEvent(.heartbeat, controller: observed)
        }
        for _ in 0 ..< 16 {
            guard let event = runtime.events.first else { break }
            var unconfirmedSession: String?
            do { unconfirmedSession = try await runtime.api.send(event).unconfirmedPlaybackSessionID }
            catch let conflict as ReceiverEventConflict where conflict.allowsHeartbeatRefresh && event.kind == .heartbeat &&
                event.elapsedPlayingSeconds == 0 && event.commandID == nil
            {
                // Only structured stale reachability can be dropped. Usage and
                // integrity/idempotency conflicts remain queued and fail closed.
            } catch let conflict as ReceiverEventConflict {
                runtime.reportingFault = true
                noteViewingEpochConflict(conflict.code, runtime: runtime)
                throw conflict
            } catch ParentControlError.malformedResponse {
                runtime.reportingFault = true
                throw ParentControlError.malformedResponse
            }
            guard viewingRuntime === runtime, !Task.isCancelled else { return }
            if unconfirmedSession != nil {
                runtime.drainingUnconfirmedEvidence = true
            }
            if let unconfirmedSession, let controller = activePlayback,
               controller.id.uuidString == unconfirmedSession, runtime.ambientSessionID != controller.id
            {
                // Persistence of an unconfirmed start is not permission. Retire
                // only that controller; preserve its queued bytes and real stop.
                viewingHeld = true
                cancelPendingStart()
                controller.driver.pause()
                await stopPlayback(endSession: false)
                guard viewingRuntime === runtime, !Task.isCancelled else { return }
            }
            runtime.events.removeFirst()
        }
        // Keep the per-refresh send batch bounded, but never fetch a new grant
        // midway through retiring an unconfirmed controller's old evidence.
        if runtime.drainingUnconfirmedEvidence, !runtime.events.isEmpty {
            return
        }
        if runtime.lease.requiresPlaybackGrants, !runtime.events.isEmpty {
            return
        }
        if runtime.events.isEmpty {
            runtime.reportingFault = false
            runtime.drainingUnconfirmedEvidence = false
        }
        try await resolveViewingMutations(runtime)
        let started = DispatchTime.now().uptimeNanoseconds
        let policy = try await runtime.api.policy()
        guard viewingRuntime === runtime, !Task.isCancelled, let binding,
              binding.serverID == runtime.configuration.serverID,
              binding.userID == runtime.configuration.childUserID else { return }
        var nextLease = runtime.lease
        do { try nextLease.accept(policy, requestStartedNS: started, receivedNS: DispatchTime.now().uptimeNanoseconds) }
        catch { runtime.reportingFault = true
            throw error
        }
        if let controller = activePlayback {
            flushViewingProgress(controller)
        }
        runtime.lease = nextLease
        let ambientBefore = ambientMode
        try updateViewingActivation(runtime, policy: policy)
        if ambientBefore, !ambientMode, activePlayback?.id == runtime.ambientSessionID {
            await stopPlayback(endSession: false)
            runtime.ambientSessionID = nil
        }
        if !runtime.configuration.activated, policy.enforcementEnabled == false, let control = policy.policyControl,
           control.kind == .release, runtime.lastControlID != control.commandID
        {
            runtime.lastControlID = control.commandID
            queueViewingEvent(.commandApplied, controller: activePlayback, commandID: control.commandID)
            if activePlayback?.id == runtime.ambientSessionID {
                await stopPlayback(endSession: false)
                runtime.ambientSessionID = nil
            }
        }
        if runtime.configuration.activated {
            if let controller = activePlayback {
                rememberViewingGrant(controller)
                if runtime.ambientSessionID != controller.id, mayAnnounceViewingStart(controller, runtime: runtime),
                   runtime.announcedSessionID != controller.id,
                   permitsViewingPlayback(controller, binding: binding)
                {
                    queueViewingEvent(.started, controller: controller)
                }
            }
            let available = runtime.lease.requiresPlaybackGrants && policy.playbackIntentAvailable == true &&
                !runtime.lease.deadlineReached(at: DispatchTime.now().uptimeNanoseconds)
            viewingHeld = ambientMode || (!available && !runtime.lease.allowsNormalViewing(at: DispatchTime.now().uptimeNanoseconds))
            catalog = rawCatalog.mapValues { filteredForViewing($0, binding: binding) }
            invalidateEpisodeMetadata()
            viewingControlStatus = viewingHeld ? "Viewing is finished for now." : "Parent viewing rules are active."
            await applyViewingCommands(runtime)
        }
    }

    private func updateViewingActivation(_ runtime: KidsViewingRuntime, policy: ReceiverPolicy) throws {
        let activate = ViewingLease.nextActivation(current: runtime.configuration.activated, policy: policy)
        let old = runtime.configuration
        let latch = policy.policyControl?.kind == .release ? nil : old.latchedControlID
        let requiresGrants = old.requiresPlaybackGrants || runtime.lease.requiresPlaybackGrants
        if activate != old.activated || latch != old.latchedControlID || requiresGrants != old.requiresPlaybackGrants {
            let next = KidsReceiverConfiguration(
                serviceURL: old.serviceURL,
                serverID: old.serverID,
                childUserID: old.childUserID,
                deviceID: old.deviceID,
                token: old.token,
                activated: activate,
                latchedControlID: latch,
                requiresPlaybackGrants: requiresGrants
            )
            do { try accounts?.storeReceiverConfiguration(next) }
            catch {
                viewingHeld = true
                ambientMode = true
                runtime.reportingFault = true
                cancelPendingStart()
                if let controller = activePlayback {
                    controller.driver.pause()
                    Task { [weak self, weak runtime, weak controller] in
                        guard let self, let runtime, let controller, self.viewingRuntime === runtime,
                              self.viewingHeld, self.activePlayback === controller else { return }
                        await self.stopPlayback(endSession: false)
                    }
                }
                throw error
            }
            if old.activated, !activate, let controller = activePlayback, runtime.ambientSessionID != controller.id {
                // End enforced accounting under the old grant even when explicit
                // deactivation permits this controller to keep playing normally.
                flushViewingProgress(controller)
                queueViewingEvent(.stopped, controller: controller)
            }
            runtime.configuration = next
        }
        if !activate {
            activePlayback?.onResumeRequested = nil
            ambientMode = false
            viewingHeld = false
            if let binding {
                catalog = rawCatalog.mapValues { filteredForViewing($0, binding: binding) }
            }
        } else if latch == nil, runtime.lease.allowsNormalViewing(at: DispatchTime.now().uptimeNanoseconds) ||
            (runtime.lease.requiresPlaybackGrants && policy.playbackIntentAvailable == true &&
                !runtime.lease.deadlineReached(at: DispatchTime.now().uptimeNanoseconds))
        {
            ambientMode = false
            viewingHeld = false
        }
    }

    private func viewingTickLoop(_ runtime: KidsViewingRuntime) async {
        while !Task.isCancelled, viewingRuntime === runtime {
            if runtime.configuration.activated, receiverForeground {
                let now = DispatchTime.now().uptimeNanoseconds
                if runtime.lease.requiresPlaybackGrants {
                    await tickViewingAdmission(runtime, at: now)
                } else if !runtime.lease.allowsNormalViewing(at: now) || runtime.reportingFault {
                    await enterViewingHold(latchControl: runtime.lease.deadlineReached(at: now))
                } else if let controller = activePlayback, runtime.ambientSessionID != controller.id,
                          let binding, !permitsViewingPlayback(controller, binding: binding)
                {
                    await stopPlayback()
                }
                sampleViewingProgress(runtime, at: now)
                let ambientAuthority = runtime.lease.ambientCommandID(latchedControlID: runtime.configuration.latchedControlID, at: now)
                if let controller = activePlayback, controller.id == runtime.ambientSessionID,
                   ambientAuthority == nil || ambientAuthority != runtime.ambientControlID || controller.item.id != runtime.lease.policy?
                       .birdItemID
                {
                    await stopPlayback(endSession: false)
                }
                if ambientMode, ambientAuthority != nil, activePlayback == nil, !runtime.ambientStarting, runtime.ambientAttempts < 3 {
                    // Authorization/preparation may be slow; the lease watchdog remains independent.
                    runtime.ambientStarting = true
                    runtime.ambientTask = Task { await self.startViewingAmbient(runtime)
                        runtime.ambientStarting = false
                    }
                }
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    func enterViewingHold(latchControl: Bool = false) async {
        guard let runtime = viewingRuntime, runtime.configuration.activated else { return }
        if latchControl, let id = runtime.lease.policy?.policyControl?.commandID, runtime.configuration.latchedControlID != id {
            let old = runtime.configuration
            let next = KidsReceiverConfiguration(
                serviceURL: old.serviceURL,
                serverID: old.serverID,
                childUserID: old.childUserID,
                deviceID: old.deviceID,
                token: old.token,
                activated: true,
                latchedControlID: id,
                requiresPlaybackGrants: old.requiresPlaybackGrants
            )
            do { try accounts?.storeReceiverConfiguration(next)
                runtime.configuration = next
            } catch { runtime.reportingFault = true }
        }
        let entering = !ambientMode
        viewingHeld = true
        ambientMode = true
        sessionFinished = false
        selectedShow = nil
        selectedMovie = nil
        if let playback = activePlayback, playback.id != runtime.ambientSessionID {
            await stopPlayback(endSession: false)
        } else if entering, activePlayback == nil {
            cancelPendingStart()
        }
    }

    func queueViewingEvent(
        _ kind: ReceiverEvent.Kind,
        controller: KidsPlaybackController? = nil,
        elapsed: Double = 0,
        commandID: UUID? = nil,
        observedPosition: Double? = nil,
        controlRevision: Int? = nil
    ) {
        guard let runtime = viewingRuntime else { return }
        let releaseAck = kind == .commandApplied && runtime.lease.policy?.enforcementEnabled == false &&
            runtime.lease.policy?.policyControl?.kind == .release && commandID == runtime.lease.policy?.policyControl?.commandID
        guard runtime.configuration.activated || kind == .heartbeat || releaseAck else { return }
        let ambientEvent = kind == .ambientStarted || kind == .ambientFailed
        let ambientAuthority = runtime.lease.ambientCommandID(
            latchedControlID: runtime.configuration.latchedControlID,
            at: DispatchTime.now().uptimeNanoseconds
        )
        if ambientEvent {
            guard ambientMode, let ambientAuthority,
                  commandID == nil || commandID == ambientAuthority else { return }
            if let controller {
                guard controller.id == runtime.ambientSessionID, runtime.ambientControlID == ambientAuthority,
                      controller.item.id == runtime.lease.policy?.birdItemID else { return }
            }
        }
        if let controller, !isCurrentPlayback(controller) {
            // Skip acknowledgements refer to the controller just retired by that
            // captured command. Ordinary late playback callbacks never cross accounts.
            guard kind == .commandApplied || kind == .commandFailed, commandID != nil,
                  let binding, runtime.configuration.serverID == binding.serverID,
                  runtime.configuration.childUserID == binding.userID,
                  KidsEligibility.permits(controller.item, binding: binding) else { return }
        }
        guard runtime.events.count < 128 else { runtime.reportingFault = true
            return
        }
        let control = commandID ?? (ambientEvent ? ambientAuthority : nil)
        let revision: Int
        var terminalKey: String?
        switch kind {
        case .started, .progress, .paused, .buffering, .ended, .stopped:
            let previouslyStartedStop = kind == .stopped && controller?.hasBegunPlayback == true &&
                runtime.normalGrant?.sessionID == controller?.id
            if kind != .started, runtime.announcedSessionID != controller?.id, !previouslyStartedStop {
                return
            }
            if kind == .started, runtime.announcedSessionID == controller?.id {
                return
            }
            guard let controller, let grant = runtime.normalGrant, grant.sessionID == controller.id else {
                runtime.reportingFault = true
                return
            }
            revision = grant.revision
            if kind == .ended || kind == .stopped {
                let key = "\(controller.id.uuidString):\(grant.revision)"
                guard !runtime.terminalReportKeys.contains(key) else { return }
                terminalKey = key
            }
        case .commandApplied, .commandFailed: revision = controlRevision ?? runtime.lease.policy?.revision ?? 0
        default: revision = runtime.lease.policy?.revision ?? 0
        }
        runtime.events.append(ReceiverEvent(
            deviceID: runtime.lease.policy?.deviceID ?? runtime.configuration.deviceID.uuidString,
            childUserID: runtime.configuration.childUserID,
            policyRevision: revision,
            playbackSessionID: controller?.id.uuidString,
            itemID: controller?.item.id,
            kind: kind,
            positionSeconds: controller.map { let position = observedPosition ?? $0.seconds
                return max(0, position.isFinite ? position : 0)
            },
            elapsedPlayingSeconds: elapsed,
            commandID: control
        ))
        if let terminalKey {
            runtime.terminalReportKeys.append(terminalKey)
            if runtime.terminalReportKeys.count > 128 {
                runtime.terminalReportKeys.removeFirst()
            }
        }
        if kind == .started || kind == .ambientStarted {
            runtime.resumeObservation = nil
            runtime.announcedSessionID = controller?.id
            runtime.lastTransportState = nil
            runtime.lastFrame = nil
            runtime.accumulatedPlaying = 0
        } else if kind == .ended || kind == .stopped {
            runtime.announcedSessionID = nil
            runtime.lastTransportState = nil
            runtime.lastFrame = nil
            runtime.accumulatedPlaying = 0
        }
    }

    func sampleViewingProgress(_ runtime: KidsViewingRuntime, at now: UInt64) {
        guard let controller = activePlayback, runtime.announcedSessionID == controller.id,
              controller.id != runtime.ambientSessionID
        else { runtime.lastFrame = nil
            return
        }
        let frame = controller.driver.frame
        if let previous = runtime.lastFrame, previous.sessionID == controller.id, now >= previous.uptime {
            runtime.accumulatedPlaying += ViewingLease.playingInterval(
                previousPosition: previous.position,
                position: frame.seconds,
                elapsedSeconds: Double(now - previous.uptime) / 1_000_000_000,
                playing: frame.playing,
                paused: frame.paused,
                buffering: frame.buffering || frame.preparing
            )
        } else {
            runtime.accumulatedPlaying = 0
        }
        runtime.lastFrame = (controller.id, frame.seconds, now)
        let state: ReceiverEvent.Kind = frame.buffering || frame.preparing ? .buffering : (frame.paused ? .paused : .progress)
        if !frame.terminal, !frame.reachedEnd, state != runtime.lastTransportState {
            if runtime.accumulatedPlaying > 0 {
                queueViewingEvent(
                    .progress,
                    controller: controller,
                    elapsed: min(5, runtime.accumulatedPlaying),
                    observedPosition: frame.seconds
                )
                runtime.accumulatedPlaying = 0
            }
            if state != .progress || runtime.lastTransportState != nil {
                queueViewingEvent(state, controller: controller, observedPosition: frame.seconds)
            }
            runtime.lastTransportState = state
            runtime.lastProgressNS = now
        } else if runtime.accumulatedPlaying > 0, now >= runtime.lastProgressNS, now - runtime.lastProgressNS >= 5_000_000_000 {
            queueViewingEvent(
                .progress,
                controller: controller,
                elapsed: min(5, runtime.accumulatedPlaying),
                observedPosition: frame.seconds
            )
            runtime.accumulatedPlaying = 0
            runtime.lastProgressNS = now
        }
    }

    func flushViewingProgress(_ controller: KidsPlaybackController) {
        guard let runtime = viewingRuntime, runtime.configuration.activated, runtime.ambientSessionID != controller.id else { return }
        sampleViewingProgress(runtime, at: DispatchTime.now().uptimeNanoseconds)
        if runtime.accumulatedPlaying > 0 {
            queueViewingEvent(
                .progress,
                controller: controller,
                elapsed: min(5, runtime.accumulatedPlaying),
                observedPosition: controller.driver.frame.seconds
            )
            runtime.accumulatedPlaying = 0
        }
    }

    private func applyViewingCommands(_ runtime: KidsViewingRuntime) async {
        guard let policy = runtime.lease.policy else { return }
        // Leave room for stop/progress callbacks and the acknowledgement before
        // claiming an action. A backlog must not execute unreportable commands.
        guard runtime.events.count < 120 else { runtime.reportingFault = true
            return
        }
        if let control = policy.policyControl, control.commandID != runtime.lastControlID {
            runtime.lastControlID = control.commandID
            runtime.ambientAttempts = 0
            queueViewingEvent(.commandApplied, controller: activePlayback, commandID: control.commandID)
            if control.kind == .release, let playback = activePlayback, playback.id == runtime.ambientSessionID {
                await stopPlayback(endSession: false)
                runtime.ambientSessionID = nil
            }
        }
        for command in policy.commands {
            guard runtime.events.count < 120 else { runtime.reportingFault = true
                return
            }
            guard let controller = activePlayback, let binding, runtime.ambientSessionID != controller.id,
                  runtime.lease.mayApply(command, playbackSessionID: controller.id.uuidString, at: DispatchTime.now().uptimeNanoseconds),
                  permitsViewing(controller.item, binding: binding) else { continue }
            do {
                guard try runtime.claim(command.commandID, sessionID: controller.id) else { continue }
                switch command.action {
                case .pause:
                    holdViewingTransport(controller, reason: .paused)
                    controller.driver.pause()
                case .resume:
                    if runtime.lease.requiresPlaybackGrants, controller.driver.frame.paused || runtime.heldSessionID == controller.id {
                        // Admission cannot await its own policy flight. Claim once
                        // now, then resolve outside this refresh and ACK delivery's
                        // original revision, never a later admission revision.
                        let revision = policy.revision
                        Task { [weak self, weak controller] in
                            guard let self, let controller, self.viewingRuntime === runtime else { return }
                            let result = await self.requestViewingResume(controller, automatic: false, control: command)?.value ?? false
                            guard self.viewingRuntime === runtime else { return }
                            self.queueViewingEvent(
                                result ? .commandApplied : .commandFailed,
                                controller: controller,
                                commandID: command.commandID,
                                controlRevision: revision
                            )
                        }
                        continue
                    } else if controller.driver.frame.paused {
                        controller.driver.togglePlayPause()
                    }
                case .skip:
                    let eligible = filteredForViewing(controller.episodes, binding: binding)
                    let next: KidsItem? = if controller
                        .mode == .shuffle
                    {
                        shuffleForViewing(eligible, binding: binding).first { $0.id != controller.item.id }
                    } else if let index = eligible.firstIndex(where: { $0.id == controller.item.id }),
                              eligible.indices.contains(index + 1)
                    {
                        eligible[index + 1]
                    } else {
                        nil
                    }
                    await stopPlayback(endSession: false)
                    guard viewingRuntime === runtime else { return }
                    if let next {
                        beginPlayback(controller.title, mode: controller.mode, explicitEpisode: next, continuing: true)
                    }
                }
                queueViewingEvent(.commandApplied, controller: controller, commandID: command.commandID)
            } catch { queueViewingEvent(.commandFailed, controller: controller, commandID: command.commandID) }
        }
    }

    private func startViewingAmbient(_ runtime: KidsViewingRuntime) async {
        guard viewingRuntime === runtime, ambientMode, activePlayback == nil, let birdID = runtime.lease.policy?.birdItemID,
              let controlID = runtime.lease.ambientCommandID(
                  latchedControlID: runtime.configuration.latchedControlID,
                  at: DispatchTime.now().uptimeNanoseconds
              ),
              let api, let binding, let playbackFactory else { return }
        runtime.ambientAttempts += 1
        let identity = accounts?.currentIdentity
        let generation = startGeneration
        do {
            let item: KidsItem
            do { item = try await api.authorize(itemID: birdID, expectedKind: .episode, binding: binding) }
            catch KidsContractError.denied { item = try await api.authorize(itemID: birdID, expectedKind: .movie, binding: binding) }
            let title: KidsItem
            if item.kind == .episode {
                guard let showID = item.seriesID else { throw KidsContractError.denied }
                title = try await api.authorize(itemID: showID, expectedKind: .series, binding: binding)
                runtime.ambientShowID = showID
            } else {
                title = item
            }
            let controller = try await playbackFactory.prepare(
                item: item,
                title: title,
                mode: item.kind == .episode ? .once : .movie,
                position: 0,
                episodes: [],
                delegate: self,
                performance: nil,
                simulateStreamFailure: false
            )
            guard !Task.isCancelled, viewingRuntime === runtime, ambientMode, activePlayback == nil, self.binding == binding,
                  accounts?.currentIdentity == identity, startGeneration == generation,
                  runtime.lease.policy?.birdItemID == birdID,
                  runtime.lease.ambientCommandID(
                      latchedControlID: runtime.configuration.latchedControlID,
                      at: DispatchTime.now().uptimeNanoseconds
                  ) == controlID
            else { await controller.stop()
                return
            }
            controller.allowsCheckpoints = false
            runtime.ambientSessionID = controller.id
            runtime.ambientControlID = controlID
            activePlayback = controller
            controller.start()
        } catch {
            guard !Task.isCancelled, viewingRuntime === runtime, runtime.lease.policy?.birdItemID == birdID else { return }
            queueViewingEvent(.ambientFailed, commandID: controlID)
        }
    }
}
