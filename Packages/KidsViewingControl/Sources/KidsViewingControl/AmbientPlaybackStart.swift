//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A fresh ambient session skips the intro instead of using watched/resume history.
public enum AmbientPlaybackStart {
    public static let introSeconds = 10.0

    public static func seconds(runtime: Double?) -> Double? {
        var generator = SystemRandomNumberGenerator()
        return seconds(runtime: runtime, using: &generator)
    }

    public static func seconds(runtime: Double?, using generator: inout some RandomNumberGenerator) -> Double? {
        guard let runtime, runtime.isFinite, runtime > introSeconds else { return nil }
        // Exclude EOF even if floating-point addition rounds to the upper bound.
        return min(Double.random(in: introSeconds ..< runtime, using: &generator), runtime.nextDown)
    }
}
