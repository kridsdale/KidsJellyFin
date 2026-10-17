//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import KidsDomain
import KidsParentControl
import KidsPlaybackSession

enum KidsAdmissionHold: Equatable { case paused, buffering, expired, preparing }

extension KidsAppModel {
    func configureViewingAdmission(_ controller: KidsPlaybackController) {
        guard let runtime = viewingRuntime, runtime.configuration.activated, runtime.lease.requiresPlaybackGrants else { return }
        controller.onResumeRequested = { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.requestViewingResume(controller, automatic: false)
        }
    }

    /// Runs before transport start. All network calls share the policy flight;
    /// the receipt never substitutes for the fresh exact bound policy below.
    func admitViewingPlayback(
        _ controller: KidsPlaybackController,
        binding: KidsBinding,
        authorization: () -> Bool = { true }
    ) async throws {
        guard let runtime = viewingRuntime, runtime.configuration.activated, runtime.lease.requiresPlaybackGrants else { return }
        guard receiverForeground, viewingRuntime === runtime, self.binding == binding,
              activePlayback == nil || activePlayback === controller,
              KidsEligibility.permits(controller.item, binding: binding),
              !controller.hasEndedPlayback else { throw KidsContractError.denied }
        if runtime.admissionController?.id != controller.id {
            runtime.automaticAdmissionAttempts = 0
            runtime.nextAutomaticAdmissionNS = 0
            runtime.resumeObservation = nil
        }
        runtime.admissionController = controller
        runtime.heldSessionID = controller.id
        runtime.admissionHold = .preparing
        let epoch = runtime.admissionEpoch
        // Retire any earlier generation, including one left by a dead process.
        if let old = runtime.admission.intent {
            try runtime.admission.abandon(old.commandID)
        } else if let policy = runtime.lease.policy, let id = policy.playbackIntentID,
                  let session = policy.leasePlaybackSessionID, let item = policy.leaseItemID
        {
            try runtime.admission.stageSurrender(intentID: id, sessionID: session, itemID: item)
        }
        try await drainViewingAdmission(runtime)
        if runtime.admission.intent == nil, let policy = runtime.lease.policy,
           let id = policy.playbackIntentID, let session = policy.leasePlaybackSessionID, let item = policy.leaseItemID
        {
            try runtime.admission.stageSurrender(intentID: id, sessionID: session, itemID: item)
            try await drainViewingAdmission(runtime)
        }
        guard viewingRuntime === runtime, !Task.isCancelled, receiverForeground,
              runtime.admissionEpoch == epoch, self.binding == binding, !controller.hasEndedPlayback, authorization(),
              activePlayback == nil || activePlayback === controller,
              runtime.lease.permitsBrowsing(controller.item, binding: binding, at: DispatchTime.now().uptimeNanoseconds),
              let revision = runtime.lease.policy?.revision else { throw KidsContractError.denied }
        let request = KidsAdmissionJournal.Intent(
            commandID: UUID(),
            expectedRevision: revision,
            sessionID: controller.id.uuidString,
            itemID: controller.item.id
        )
        try runtime.admission.stage(request)
        try await drainViewingAdmission(runtime)
        guard viewingRuntime === runtime, !Task.isCancelled, receiverForeground, self.binding == binding,
              runtime.admissionEpoch == epoch, !controller.hasEndedPlayback, authorization(),
              activePlayback == nil || activePlayback === controller,
              runtime.admission.intent?.commandID == request.commandID,
              runtime.admission.intent?.persisted == true,
              runtime.lease.permitsPlayback(
                  controller.item,
                  binding: binding,
                  intentID: request.commandID,
                  sessionID: controller.id.uuidString,
                  at: DispatchTime.now().uptimeNanoseconds
              ),
              !runtime.reportingFault else { throw KidsContractError.denied }
        runtime.admittedIntentID = request.commandID
        runtime.heldSessionID = nil
        runtime.admissionHold = nil
        configureViewingAdmission(controller)
        rememberViewingGrant(controller)
    }

    func abandonPreparedViewing(_ controller: KidsPlaybackController) async {
        guard let runtime = viewingRuntime, runtime.lease.requiresPlaybackGrants else { await controller.stop()
            return
        }
        holdViewingTransport(controller, reason: .preparing)
        do {
            if let intent = runtime.admission.intent, intent.sessionID == controller.id.uuidString {
                try runtime.admission.abandon(intent.commandID)
            }
        } catch { runtime.reportingFault = true }
        await controller.stop()
    }

    func holdViewingTransport(_ controller: KidsPlaybackController, reason: KidsAdmissionHold) {
        guard let runtime = viewingRuntime, runtime.configuration.activated, runtime.lease.requiresPlaybackGrants,
              runtime.ambientSessionID != controller.id, activePlayback == nil || activePlayback === controller else { return }
        let alreadyBufferHeld = runtime.heldSessionID == controller.id && runtime.admissionHold == .buffering
        runtime.admissionEpoch = UUID()
        runtime.heldSessionID = controller.id
        runtime.admissionHold = reason
        runtime.stablePlayingSinceNS = nil
        if reason == .buffering, !alreadyBufferHeld {
            runtime.bufferReadyBaseline = (controller.id, controller.driver.frame.bufferReadySequence)
        }
        controller.driver.pause()
    }

    /// Called only after actual pause/buffering observation or completed driver
    /// drain. Reports are queued before the separately captured surrender.
    func stageViewingSurrender(_ controller: KidsPlaybackController) {
        guard let runtime = viewingRuntime, runtime.lease.requiresPlaybackGrants,
              runtime.ambientSessionID != controller.id,
              let intent = runtime.admission.intent, intent.sessionID == controller.id.uuidString else { return }
        do {
            try runtime.admission.stageSurrender(intentID: intent.commandID, sessionID: intent.sessionID, itemID: intent.itemID)
        } catch { runtime.reportingFault = true }
    }

    func resolveViewingMutations(_ runtime: KidsViewingRuntime) async throws {
        guard runtime.events.isEmpty else { return }
        if let intent = runtime.admission.intent, !intent.abandoned, runtime.admissionController == nil {
            try runtime.admission.abandon(intent.commandID)
        }
        if let request = runtime.admission.intent, !request.persisted {
            do {
                try await runtime.api.requestPlaybackIntent(
                    commandID: request.commandID,
                    expectedRevision: request.expectedRevision,
                    playbackSessionID: request.sessionID,
                    itemID: request.itemID
                )
            } catch let conflict as ReceiverMutationConflict {
                if conflict.isDefiniteIntentRefusal {
                    try runtime.admission.rejectUncommittedIntent(request.commandID)
                } else {
                    runtime.reportingFault = true
                }
                throw conflict
            }
            guard viewingRuntime === runtime, !Task.isCancelled else { throw CancellationError() }
            try runtime.admission.acknowledgeIntent(request.commandID)
        }
        if let request = runtime.admission.surrender {
            try await runtime.api.surrenderPlayback(
                commandID: request.commandID,
                playbackIntentID: request.intentID,
                playbackSessionID: request.sessionID,
                itemID: request.itemID
            )
            guard viewingRuntime === runtime, !Task.isCancelled else { throw CancellationError() }
            try runtime.admission.acknowledgeSurrender(request.commandID)
            if runtime.admittedIntentID == request.intentID {
                runtime.admittedIntentID = nil
            }
            if runtime.announcedSessionID?.uuidString == request.sessionID {
                runtime.announcedSessionID = nil
                runtime.lastFrame = nil
                runtime.lastTransportState = nil
                runtime.accumulatedPlaying = 0
            }
        }
    }

    func drainViewingAdmission(_ runtime: KidsViewingRuntime) async throws {
        // At most128 queued reports,16 per refresh. A slow flight yields to the
        // independent watchdog and never authorizes while evidence is pending.
        for _ in 0 ..< 10 {
            try await synchronizeViewingPolicy(runtime)
            guard viewingRuntime === runtime, !Task.isCancelled else { throw CancellationError() }
            if runtime.events.isEmpty, runtime.admission.surrender == nil,
               runtime.admission.intent?.persisted != false
            {
                return
            }
        }
        throw KidsContractError.denied
    }

    @discardableResult
    func requestViewingResume(
        _ controller: KidsPlaybackController,
        automatic: Bool,
        control: ReceiverPolicy.Command? = nil
    ) -> Task<Bool, Never>? {
        guard let runtime = viewingRuntime, isCurrentPlayback(controller), receiverForeground,
              runtime.configuration.activated, runtime.lease.requiresPlaybackGrants,
              runtime.ambientSessionID != controller.id, !controller.hasEndedPlayback,
              !controller.failed, !controller.driver.frame.failed,
              runtime.admissionFlight == nil else { return nil }
        if automatic {
            guard runtime.admissionHold == .buffering, controller.hasBegunPlayback,
                  !controller.driver.frame.buffering, !controller.driver.frame.preparing,
                  !controller.driver.frame.failed, !controller.driver.frame.terminal,
                  runtime.bufferReadyBaseline?.sessionID == controller.id,
                  controller.driver.frame.bufferReadySequence > (runtime.bufferReadyBaseline?.sequence ?? .max),
                  runtime.automaticAdmissionAttempts < 3,
                  DispatchTime.now().uptimeNanoseconds >= runtime.nextAutomaticAdmissionNS else { return nil }
            runtime.automaticAdmissionAttempts += 1
            runtime.nextAutomaticAdmissionNS = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        } else {
            runtime.automaticAdmissionAttempts = 0
        }
        let id = UUID()
        let task = Task { [weak self, weak controller] in
            guard let self, let controller, let binding = self.binding else { return false }
            self.holdViewingTransport(controller, reason: automatic ? .buffering : .paused)
            self.flushViewingProgress(controller)
            self.stageViewingSurrender(controller)
            do {
                try await self.admitViewingPlayback(controller, binding: binding) {
                    control.map { runtime.lease.mayApply(
                        $0,
                        playbackSessionID: controller.id.uuidString,
                        at: DispatchTime.now().uptimeNanoseconds
                    ) } ?? true
                }
                guard self.viewingRuntime === runtime, self.isCurrentPlayback(controller), self.receiverForeground,
                      self.permitsViewingPlayback(controller, binding: binding), controller.driver.frame.paused,
                      !automatic || (!controller.driver.frame.buffering && !controller.driver.frame.preparing &&
                          controller.driver.frame.bufferReadySequence > (runtime.bufferReadyBaseline?.sequence ?? .max))
                else {
                    throw KidsContractError.denied
                }
                runtime.resumeObservation = (controller.id, controller.driver.frame.seconds)
                controller.recovery = false
                runtime.nextAutomaticAdmissionNS = 0
                controller.driver.togglePlayPause()
                return true
            } catch {
                if self.viewingRuntime === runtime, self.isCurrentPlayback(controller) {
                    runtime.heldSessionID = controller.id
                    runtime.admissionHold = automatic ? .buffering : .paused
                    if let intent = runtime.admission.intent, intent.sessionID == controller.id.uuidString {
                        do { try runtime.admission.abandon(intent.commandID) } catch { runtime.reportingFault = true }
                    }
                }
                return false
            }
        }
        runtime.admissionFlight = (id, controller.id, task)
        Task { [weak runtime] in
            _ = await task.value
            if runtime?.admissionFlight?.id == id {
                runtime?.admissionFlight = nil
            }
        }
        return task
    }

    func tickViewingAdmission(_ runtime: KidsViewingRuntime, at now: UInt64) async {
        if runtime.reportingFault || runtime.lease.deadlineReached(at: now) ||
            (runtime.lease.policy?.playbackIntentAvailable == false && !runtime.lease.allowsNormalViewing(at: now))
        {
            await enterViewingHold(latchControl: runtime.lease.deadlineReached(at: now))
            return
        }
        guard let controller = activePlayback, runtime.ambientSessionID != controller.id,
              !controller.hasEndedPlayback, let binding else { return }
        configureViewingAdmission(controller)
        if runtime.admissionFlight == nil {
            let frame = controller.driver.frame
            if (controller.hasBegunPlayback && frame.buffering) || (frame.paused && !frame.preparing && !frame.applyingStartPosition) {
                if runtime.heldSessionID != controller.id {
                    holdViewingTransport(controller, reason: frame.buffering ? .buffering : .paused)
                }
                flushViewingProgress(controller)
                stageViewingSurrender(controller)
            }
            if runtime.heldSessionID == controller.id {
                if !controller.driver.frame.paused {
                    controller.driver.pause()
                }
                requestViewingResume(controller, automatic: true)
            } else if !permitsViewingPlayback(controller, binding: binding) {
                holdViewingTransport(controller, reason: .expired)
                flushViewingProgress(controller)
                if frame.paused || frame.buffering {
                    stageViewingSurrender(controller)
                }
            }
        }
        if permitsViewingPlayback(controller, binding: binding), controller.driver.frame.playing,
           !controller.driver.frame.paused, !controller.driver.frame.buffering
        {
            if let since = runtime.stablePlayingSinceNS, now >= since, now - since >= 10_000_000_000 {
                runtime.automaticAdmissionAttempts = 0
            } else if runtime.stablePlayingSinceNS == nil {
                runtime.stablePlayingSinceNS = now
            }
        } else {
            runtime.stablePlayingSinceNS = nil
        }
        // A resumed generation needs actual transport observation before its
        // started report; a receipt or paused old controller is not that event.
        if runtime.announcedSessionID != controller.id, mayAnnounceViewingStart(controller, runtime: runtime),
           permitsViewingPlayback(controller, binding: binding)
        {
            rememberViewingGrant(controller)
            queueViewingEvent(.started, controller: controller)
            runtime.resumeObservation = nil
        }
    }

    func mayAnnounceViewingStart(_ controller: KidsPlaybackController, runtime: KidsViewingRuntime) -> Bool {
        let frame = controller.driver.frame
        guard controller.hasBegunPlayback, !controller.hasEndedPlayback, frame.playing, !frame.paused,
              !frame.buffering, !frame.preparing, !frame.failed, !frame.terminal, frame.seconds.isFinite else { return false }
        return runtime.resumeObservation?.sessionID != controller.id || frame.seconds > (runtime.resumeObservation?.position ?? 0) + 0.1
    }

    public func playbackWillStop(_ controller: KidsPlaybackController) {
        guard isCurrentPlayback(controller) else { return }
        flushViewingProgress(controller)
        holdViewingTransport(controller, reason: .paused)
    }

    public func playbackDidStop(_ controller: KidsPlaybackController) {
        guard isCurrentPlayback(controller) else { return }
        queueViewingEvent(.stopped, controller: controller)
        stageViewingSurrender(controller)
    }

    public func playbackPaused(_ controller: KidsPlaybackController) {
        guard let runtime = viewingRuntime, runtime.configuration.activated, runtime.lease.requiresPlaybackGrants,
              isCurrentPlayback(controller), runtime.ambientSessionID != controller.id, runtime.admissionFlight == nil else { return }
        if runtime.heldSessionID == controller.id, runtime.admission.intent == nil, runtime.admission.surrender == nil {
            return
        }
        if runtime.heldSessionID != controller.id {
            holdViewingTransport(controller, reason: .paused)
        }
        flushViewingProgress(controller)
        stageViewingSurrender(controller)
        Task { [weak self] in try? await self?.synchronizeViewingPolicy(runtime) }
    }

    public func playbackBufferingChanged(_ controller: KidsPlaybackController, buffering: Bool) {
        guard let runtime = viewingRuntime, runtime.configuration.activated, runtime.lease.requiresPlaybackGrants,
              isCurrentPlayback(controller), runtime.ambientSessionID != controller.id, controller.hasBegunPlayback else { return }
        if buffering {
            runtime.bufferReadyBaseline = (controller.id, controller.driver.frame.bufferReadySequence)
        }
        guard runtime.admissionFlight == nil else { return }
        if buffering {
            if runtime.heldSessionID == controller.id, runtime.admission.intent == nil, runtime.admission.surrender == nil {
                return
            }
            if runtime.heldSessionID != controller.id {
                holdViewingTransport(controller, reason: .buffering)
            }
            flushViewingProgress(controller)
            stageViewingSurrender(controller)
            Task { [weak self] in try? await self?.synchronizeViewingPolicy(runtime) }
        } else {
            requestViewingResume(controller, automatic: true)
        }
    }
}
