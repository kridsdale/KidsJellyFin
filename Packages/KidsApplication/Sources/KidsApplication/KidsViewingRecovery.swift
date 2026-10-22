//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import KidsDomain
import KidsPlaybackSession
import KidsViewingControl

public extension KidsAppModel {
    var canArchiveViewingRecovery: Bool {
        unlocked && !isPreview && viewingRuntime?.epochRecoveryRequired == true && viewingRuntime?.recoveringEpoch == false
    }

    internal func noteViewingEpochConflict(_ code: String?, runtime: KidsViewingRuntime) {
        guard code == "command_epoch_changed", viewingRuntime === runtime else { return }
        runtime.epochRecoveryRequired = true
        runtime.reportingFault = true
        runtime.lease = ViewingLease(
            serverID: runtime.configuration.serverID,
            childUserID: runtime.configuration.childUserID,
            deviceID: runtime.configuration.deviceID,
            requiresPlaybackGrants: runtime.configuration.requiresPlaybackGrants
        )
        runtime.admittedIntentID = nil
        viewingHeld = true
        cancelPendingStart()
        activePlayback?.driver.pause()
        viewingControlStatus = "A grown-up needs to reconnect parent controls after server recovery."
    }

    /// A structured epoch fault plus a fresh parent PIN unlock is required.
    /// This preserves accounting evidence locally and changes no server state.
    func archiveViewingRecovery() async throws {
        guard canArchiveViewingRecovery, let runtime = viewingRuntime, let binding,
              binding.serverID == runtime.configuration.serverID, binding.userID == runtime.configuration.childUserID
        else { throw KidsContractError.denied }
        runtime.recoveringEpoch = true
        defer { runtime.recoveringEpoch = false }
        runtime.reportingFault = true
        viewingHeld = true
        cancelPendingStart()
        runtime.ambientTask?.cancel()
        let flight = runtime.policyFlight
        flight?.task.cancel()
        let prepared = runtime.admissionController
        await stopPlayback(endSession: false)
        if let prepared {
            await prepared.stop()
        }
        if let flight {
            _ = try? await flight.task.value
            if runtime.policyFlight?.id == flight.id {
                runtime.policyFlight = nil
            }
        }
        guard unlocked, viewingRuntime === runtime, self.binding == binding, !Task.isCancelled else { throw KidsContractError.denied }
        _ = try runtime.admission.archiveForEpochRecovery()
        let fresh = try runtime.freshAfterRecovery()
        // Fence every delayed command/monitor callback by runtime identity.
        // Only a fresh instance may fetch new policy after the archive.
        viewingRuntime = fresh
        ambientMode = true
        viewingControlStatus = "Old requests were saved. Check the receiver token; fresh server permission is still required."
        viewingControlRevision = UUID()
    }
}
