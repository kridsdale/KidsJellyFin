//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0

/// Operational playing-time observations, never playback authority. Native media
/// clocks update independently of the sampling timer. Credit a cumulative prefix
/// bounded by both valid media advance and observed active wall time, rather than
/// discarding the slack of each individual sample.
public struct ViewingProgressAccumulator: Sendable {
    public private(set) var observedWallSeconds = 0.0
    public private(set) var observedMediaSeconds = 0.0
    public private(set) var creditedSeconds = 0.0
    private var previous: (position: Double, time: UInt64, playing: Bool)?
    private var clockAnchor: (position: Double, time: UInt64)?
    // Retain at most one observable interval of active wall time across native
    // clock updates. A policy flush may sample just before the clock advances.
    // Negative balance records the existing half-second clock-lead tolerance;
    // it cannot be borrowed again on every update.
    private var clockWallBalance = 0.0

    public init() {}

    public mutating func start(position: Double, at time: UInt64, playing: Bool) {
        self = Self()
        guard position.isFinite, position >= 0 else { return }
        previous = (position, time, playing)
        clockAnchor = (position, time)
    }

    public mutating func sample(position: Double, at time: UInt64, playing: Bool) -> Double {
        guard position.isFinite, position >= 0 else {
            previous = nil
            clockAnchor = nil
            clockWallBalance = 0
            return 0
        }
        guard let old = previous else {
            previous = (position, time, playing)
            clockAnchor = (position, time)
            return 0
        }
        guard time >= old.time else { return 0 }
        let wall = Double(time - old.time) / 1_000_000_000
        previous = (position, time, playing)
        guard old.playing, wall <= 5 else {
            clockAnchor = (position, time)
            clockWallBalance = 0
            return 0
        }
        // A pause/buffer endpoint includes the preceding active interval. Its
        // new state controls the next interval, including any paused seek.
        observedWallSeconds += wall
        clockWallBalance = min(5, clockWallBalance + wall)
        if let anchor = clockAnchor {
            let advance = position - anchor.position
            let clockWall = Double(time - anchor.time) / 1_000_000_000
            if advance > 0 {
                if clockWall <= 5, advance <= clockWallBalance + 0.5 {
                    observedMediaSeconds += advance
                    clockWallBalance -= advance
                } else {
                    // A jump unsupported by the bounded active-wall balance is
                    // a seek. Discard its slack as well as its media advance.
                    clockWallBalance = 0
                }
                clockAnchor = (position, time)
            } else if advance < -0.5 {
                // A real rewind starts a new observation segment. Small native
                // clock regressions retain their high-water position so their
                // subsequent recovery cannot count the same media twice.
                clockAnchor = (position, time)
                clockWallBalance = 0
            }
        } else {
            clockAnchor = (position, time)
        }
        if !playing {
            clockAnchor = (position, time)
            clockWallBalance = 0
        }
        let confirmed = min(observedWallSeconds, observedMediaSeconds)
        let newlyConfirmed = max(0, confirmed - creditedSeconds)
        creditedSeconds = confirmed
        return newlyConfirmed
    }
}
