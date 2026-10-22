//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation
import KidsParentControl

struct TVParentAuthorizationScope: Hashable {
    let generation: UUID
    let serverID: String
    let adultUserID: String
    let connection: ObjectIdentifier
}

struct TVParentAuthorizationPrompt: Identifiable {
    let notice: LANParentAuthorizationNotice
    let authorization: ParentAuthorization
    var id: UUID {
        notice.requestID
    }
}

extension ParentsModel {
    var tvParentAuthorizationScope: TVParentAuthorizationScope? {
        guard !demo, signedIn, !locked, supports("parent-authorization-v1"),
              let credential, let controls else { return nil }
        return TVParentAuthorizationScope(
            generation: generation, serverID: credential.serverID,
            adultUserID: credential.userID, connection: ObjectIdentifier(controls)
        )
    }

    func updateTVParentAuthorizationListener(isForeground: Bool) {
        guard isForeground, let scope = tvParentAuthorizationScope, let api = controls else {
            stopTVParentAuthorization()
            return
        }
        guard tvAuthorizationListeningScope != scope else { return }
        stopTVParentAuthorization()
        tvAuthorizationForeground = true
        tvAuthorizationListeningScope = scope
        let browser = LANParentAuthorizationBrowser()
        tvAuthorizationBrowser = browser
        browser.start(serverID: scope.serverID) { [weak self] notice in
            guard let self, self.currentTVAuthorizationScope(scope), notice.isValid,
                  notice.serverID == scope.serverID,
                  !self.tvAuthorizationSeen.contains(notice.requestID),
                  self.tvParentAuthorizationPrompt?.id != notice.requestID,
                  self.tvAuthorizationCheckingID != notice.requestID,
                  !self.tvAuthorizationQueue.contains(where: { $0.requestID == notice.requestID }) else { return }
            let pending = self.tvAuthorizationQueue.count + (self.tvParentAuthorizationPrompt == nil ? 0 : 1) +
                (self.tvAuthorizationCheckingID == nil ? 0 : 1)
            guard pending < 8 else { return }
            self.tvAuthorizationQueue.append(notice)
            self.checkNextTVAuthorization(scope: scope, api: api)
        }
    }

    func stopTVParentAuthorization() {
        tvAuthorizationForeground = false
        tvAuthorizationListeningScope = nil
        tvAuthorizationBrowser?.stop()
        tvAuthorizationBrowser = nil
        tvAuthorizationLookupTask?.cancel()
        tvAuthorizationExpiryTask?.cancel()
        tvAuthorizationWatchTask?.cancel()
        tvAuthorizationDecisionTask?.cancel()
        tvAuthorizationLookupTask = nil
        tvAuthorizationExpiryTask = nil
        tvAuthorizationWatchTask = nil
        tvAuthorizationDecisionTask = nil
        tvAuthorizationQueue.removeAll()
        tvAuthorizationSeen.removeAll()
        tvAuthorizationCheckingID = nil
        tvParentAuthorizationPrompt = nil
        tvParentAuthorizationDecisionBusy = false
        tvParentAuthorizationError = nil
    }

    private func currentTVAuthorizationScope(_ scope: TVParentAuthorizationScope) -> Bool {
        tvAuthorizationForeground && tvAuthorizationListeningScope == scope && tvParentAuthorizationScope == scope
    }

    private func checkNextTVAuthorization(scope: TVParentAuthorizationScope, api: ParentControlAPI) {
        guard currentTVAuthorizationScope(scope), tvParentAuthorizationPrompt == nil,
              tvAuthorizationLookupTask == nil, !tvAuthorizationQueue.isEmpty else { return }
        let notice = tvAuthorizationQueue.removeFirst()
        tvAuthorizationCheckingID = notice.requestID
        tvAuthorizationLookupTask = Task { [weak self] in
            guard let self else { return }
            let record = try? await api.authorization(notice: notice)
            guard !Task.isCancelled, self.currentTVAuthorizationScope(scope) else { return }
            self.tvAuthorizationLookupTask = nil
            self.tvAuthorizationCheckingID = nil
            if let record, record.status == .pending, record.requestID == notice.requestID,
               record.serverID == scope.serverID, record.expiresAt.timeIntervalSinceNow.isFinite,
               (0 ... 65).contains(record.expiresAt.timeIntervalSinceNow), record.expiresAt > Date()
            {
                self.tvAuthorizationSeen.append(notice.requestID)
                if self.tvAuthorizationSeen.count > 64 {
                    self.tvAuthorizationSeen.removeFirst()
                }
                let prompt = TVParentAuthorizationPrompt(notice: notice, authorization: record)
                self.tvParentAuthorizationError = nil
                self.tvParentAuthorizationPrompt = prompt
                self.monitorTVAuthorization(prompt, scope: scope, api: api)
            } else {
                self.checkNextTVAuthorization(scope: scope, api: api)
            }
        }
    }

    private func monitorTVAuthorization(_ prompt: TVParentAuthorizationPrompt, scope: TVParentAuthorizationScope, api: ParentControlAPI) {
        let delay = max(0, prompt.authorization.expiresAt.timeIntervalSinceNow)
        tvAuthorizationExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled, self.currentTVAuthorizationScope(scope) else { return }
            self.finishTVAuthorization(prompt.id, scope: scope)
        }
        tvAuthorizationWatchTask = Task { [weak self] in
            let clock = ContinuousClock()
            while let self, !Task.isCancelled, self.currentTVAuthorizationScope(scope),
                  self.tvParentAuthorizationPrompt?.id == prompt.id
            {
                let started = clock.now
                guard let record = try? await api.authorization(notice: prompt.notice, wait: true),
                      !Task.isCancelled, self.currentTVAuthorizationScope(scope),
                      self.tvParentAuthorizationPrompt?.id == prompt.id else { return }
                guard record.deviceID == prompt.authorization.deviceID,
                      record.childUserID == prompt.authorization.childUserID
                else {
                    self.finishTVAuthorization(prompt.id, scope: scope)
                    return
                }
                if record.status != .pending || record.expiresAt <= Date() {
                    self.finishTVAuthorization(prompt.id, scope: scope)
                    return
                }
                // A server without a blocking wait must not turn this into a spin loop.
                guard started.duration(to: clock.now) >= .milliseconds(500) else { return }
            }
        }
    }

    private func finishTVAuthorization(_ id: UUID, scope: TVParentAuthorizationScope) {
        guard currentTVAuthorizationScope(scope), tvParentAuthorizationPrompt?.id == id else { return }
        tvAuthorizationExpiryTask?.cancel()
        tvAuthorizationWatchTask?.cancel()
        tvAuthorizationDecisionTask?.cancel()
        tvAuthorizationExpiryTask = nil
        tvAuthorizationWatchTask = nil
        tvAuthorizationDecisionTask = nil
        tvParentAuthorizationPrompt = nil
        tvParentAuthorizationDecisionBusy = false
        tvParentAuthorizationError = nil
    }

    func tvParentAuthorizationDidDismiss() {
        guard let scope = tvAuthorizationListeningScope, let api = controls,
              currentTVAuthorizationScope(scope) else { return }
        checkNextTVAuthorization(scope: scope, api: api)
    }

    func decideTVParentAuthorization(approved: Bool) {
        guard let prompt = tvParentAuthorizationPrompt, let scope = tvAuthorizationListeningScope,
              let api = controls, currentTVAuthorizationScope(scope), !tvParentAuthorizationDecisionBusy else { return }
        guard prompt.authorization.expiresAt > Date() else {
            finishTVAuthorization(prompt.id, scope: scope)
            return
        }
        tvParentAuthorizationDecisionBusy = true
        tvParentAuthorizationError = nil
        tvAuthorizationDecisionTask = Task { [weak self] in
            do {
                let record = try await api.decideAuthorization(prompt.notice, approved: approved)
                guard let self, !Task.isCancelled, self.currentTVAuthorizationScope(scope),
                      self.tvParentAuthorizationPrompt?.id == prompt.id else { return }
                self.tvParentAuthorizationDecisionBusy = false
                self.tvAuthorizationDecisionTask = nil
                if record.status != .pending || record.expiresAt <= Date() {
                    self.finishTVAuthorization(prompt.id, scope: scope)
                } else {
                    self.tvParentAuthorizationError = "No decision was confirmed. Choose Yes or No to try again."
                }
            } catch {
                guard let self, !Task.isCancelled, self.currentTVAuthorizationScope(scope),
                      self.tvParentAuthorizationPrompt?.id == prompt.id else { return }
                self.tvParentAuthorizationDecisionBusy = false
                self.tvAuthorizationDecisionTask = nil
                self.tvParentAuthorizationError = "The decision could not be confirmed. Check the connection and choose again."
            }
        }
    }
}
