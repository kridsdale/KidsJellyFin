//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import SwiftUI

struct TVParentAuthorizationView: View {
    @Bindable
    var model: ParentsModel
    let prompt: TVParentAuthorizationPrompt

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "tv.badge.wifi").font(.system(size: 56)).foregroundStyle(.teal)
                Text("Allow parent access?").font(.largeTitle.bold()).multilineTextAlignment(.center)
                Text(prompt.authorization.deviceName).font(.title2).multilineTextAlignment(.center)
                    .accessibilityIdentifier("parents.authorization.tvName")
                Text("This TV is asking to open its parent controls. Allow this request once?")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text("Expires at \(prompt.authorization.expiresAt.formatted(date: .omitted, time: .standard)).")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error = model.tvParentAuthorizationError {
                    Text(error).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                if model.tvParentAuthorizationDecisionBusy {
                    ProgressView("Sending your decision…")
                }
                VStack(spacing: 16) {
                    Button("Yes") { model.decideTVParentAuthorization(approved: true) }
                        .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                        .accessibilityIdentifier("parents.authorization.yes")
                    Button("No", role: .cancel) { model.decideTVParentAuthorization(approved: false) }
                        .buttonStyle(.bordered).controlSize(.large).frame(maxWidth: .infinity)
                        .accessibilityIdentifier("parents.authorization.no")
                }.disabled(model.tvParentAuthorizationDecisionBusy)
            }
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .interactiveDismissDisabled()
        .accessibilityIdentifier("parents.authorization.prompt")
    }
}
