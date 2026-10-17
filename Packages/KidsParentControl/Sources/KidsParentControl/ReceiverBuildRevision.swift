//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// A declaration of the build's embedded source fingerprint, not attestation or
/// proof of runtime acceptance. Authority still requires server-side commissioning.
public struct ReceiverBuildRevision: RawRepresentable, Equatable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.utf8.count == 64,
              rawValue.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }) else { return nil }
        self.rawValue = rawValue
    }
}
