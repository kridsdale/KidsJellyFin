//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// Offline visual inspection only; the model is in inert sample-data mode.
struct ParentFeaturePreview: View {
    let model: ParentsModel
    let screen: String
    static var requestedScreen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--parent-preview-screen"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("DESIGN PREVIEW · Sample data · Controls inactive").font(.caption2.bold())
                .frame(maxWidth: .infinity).padding(8).background(.yellow.opacity(0.22))
            if screen == "settings" {
                ParentSettingsView(model: model)
            } else {
                NavigationStack {
                    switch screen {
                    case "family": FamilyRulesView(model: model)
                    case "history": ParentHistoryView(model: model)
                    case "health": ParentHealthView(model: model)
                    case "review": ParentReviewInboxView(model: model)
                    case "shuffle": if let profile = model.profile {
                            ShuffleEditor(model: model, profile: profile)
                        }
                    case "routines": if let profile = model.profile {
                            RoutineEditor(model: model, profile: profile)
                        }
                    default: FamilyRulesView(model: model)
                    }
                }
            }
        }.tint(.teal)
    }
}
