//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import XCTest

@MainActor
final class KidsNavigationTests: XCTestCase {
    private let app = XCUIApplication()
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ scenario: String) {
        app.launchArguments = ["--kids-preview=\(scenario)"]
        // Use frameworks embedded in the installed app. Avoid loader access to the host Documents folder.
        app.launchEnvironment["DYLD_FRAMEWORK_PATH"] = ""
        app.launchEnvironment["DYLD_LIBRARY_PATH"] = ""
        app.launch()
    }

    private func select(_ element: XCUIElement) {
        let focus = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [focus], timeout: 3), .completed, "Expected focus on the requested artwork card")
        XCUIRemote.shared.press(.select)
    }

    private func selectParents(_ parents: XCUIElement) {
        XCUIRemote.shared.press(.up)
        for _ in 0 ..< 4 {
            if parents.hasFocus {
                break
            }
            XCUIRemote.shared.press(.right)
        }
        XCTAssertTrue(parents.hasFocus, "Parents must be reachable by directional remote input")
        XCUIRemote.shared.press(.select)
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Native remote input for the installed receiver; never launches preview data or edits app state.
    func testInstalledReceiverRemoteInput() throws {
        guard let raw = ProcessInfo.processInfo.environment["KIDS_QA_REMOTE_SEQUENCE"],
              let data = raw.data(using: .utf8),
              let actions = try? JSONDecoder().decode([String].self, from: data),
              !actions.isEmpty, actions.count <= 16
        else {
            throw XCTSkip("Explicit installed-receiver remote sequence required.")
        }
        let buttons: [String: XCUIRemote.Button] = [
            "select": .select, "menu": .menu, "up": .up,
            "down": .down, "left": .left, "right": .right, "playPause": .playPause
        ]
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        for action in actions {
            if action.hasPrefix("focus:") {
                let label = String(action.dropFirst(6))
                let target = NSPredicate(format: "label == %@ OR identifier == %@", label, label)
                var found = false
                for direction in [XCUIRemote.Button.down, .up] {
                    for _ in 0 ..< 32 {
                        let focused = app.descendants(matching: .any)
                            .matching(NSPredicate(format: "hasFocus == true")).allElementsBoundByIndex
                        if focused.contains(where: { $0.label == label || $0.identifier == label ||
                                $0.descendants(matching: .any).matching(target).firstMatch.exists
                        }) {
                            found = true
                            break
                        }
                        XCUIRemote.shared.press(direction)
                    }
                    if found {
                        break
                    }
                }
                XCTAssertTrue(found, "Native focus target unavailable: \(label)")
                if !found {
                    return
                }
            } else if action == "inspect" {
                for element in app.descendants(matching: .any)
                    .matching(NSPredicate(format: "hasFocus == true")).allElementsBoundByIndex
                {
                    print("QA_FOCUS label=\(element.label) identifier=\(element.identifier)")
                }
                for element in app.textFields.allElementsBoundByIndex + app.secureTextFields.allElementsBoundByIndex {
                    print("QA_FIELD label=\(element.label) identifier=\(element.identifier)")
                }
            } else {
                let button = try XCTUnwrap(buttons[action], "Unsupported native remote action")
                XCUIRemote.shared.press(button)
            }
        }
        Thread.sleep(forTimeInterval: 1)
    }

    func testShowsTitleAndBackRestoresCard() {
        launch("shows")
        let card = app.buttons["kids.card.show-1"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        select(card)
        XCTAssertTrue(app.buttons["kids.action.next"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["kids.action.shuffle"].exists)
        XCTAssertFalse(app.buttons["Search"].exists)
        capture("show-title-two-actions")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.hasFocus)
        capture("shows-grid-return")
    }

    func testShowTitleParentsIsReachableByDirectionalRemoteInput() {
        launch("shows")
        let card = app.buttons["kids.card.show-1"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        select(card)
        let next = app.buttons["kids.action.next"]
        let parents = app.buttons["kids.title.parents"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(parents.exists)
        XCTAssertTrue(next.hasFocus)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(parents.hasFocus, "Show-title Parents must be reachable from the primary action with one down press")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.secureTextFields["kids.parent.pin"].waitForExistence(timeout: 5))
    }

    func testScrolledCardFocusReturnsAfterTitle() {
        launch("shows")
        XCTAssertTrue(app.buttons["kids.card.show-1"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        let card = app.buttons["kids.card.show-9"]
        select(card)
        XCTAssertTrue(app.buttons["kids.action.next"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hasFocus == true"), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        capture("scrolled-grid-focus-return")
    }

    func testOfflineCatalogCanReachProtectedParents() {
        launch("offline")
        XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 10))
        let parents = app.buttons["kids.parents"]
        XCTAssertTrue(parents.exists)
        capture("offline-protected-help")
        XCUIRemote.shared.press(.down)
        select(parents)
        XCTAssertTrue(app.secureTextFields["kids.parent.pin"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 5))
    }

    func testMovieHasOneResumeAction() {
        launch("resume")
        let card = app.buttons["kids.card.movie-1"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        select(card)
        XCTAssertTrue(app.buttons["kids.action.play"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["kids.action.play"].label.contains("Resume"))
        XCTAssertFalse(app.buttons["kids.action.shuffle"].exists)
        capture("movie-resume")
    }

    func testOrderedFinaleOffersAgain() {
        launch("again")
        let card = app.buttons["kids.card.show-1"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        select(card)
        let next = app.buttons["kids.action.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(next.label.contains("Again"))
        capture("series-again")
    }

    func testParentSidebarUsesQuarterWidthAndRemoteMenuCloses() {
        launch("controls")
        let parents = app.buttons["kids.player.parents"]
        XCTAssertTrue(parents.waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.right)
        select(parents)
        let pin = app.secureTextFields["kids.parent.pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(pin.frame.minX, app.frame.width * 0.75)
        XCTAssertLessThanOrEqual(pin.frame.maxX, app.frame.maxX)
        XCTAssertTrue(app.buttons["kids.parent.unlock"].exists)
        XCTAssertFalse(app.buttons["kids.parent.phone.request"].exists)
        capture("parents-quarter-sidebar")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(pin.waitForNonExistence(timeout: 5), "Remote Menu must close the sidebar")
        XCTAssertTrue(app.buttons["kids.player.playpause"].isEnabled)
        capture("parents-menu-restores-player")
        XCUIRemote.shared.press(.right)
        select(parents)
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        // The sidebar's initial focused action is its explicit close control.
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(pin.waitForNonExistence(timeout: 5), "Back to kids must close the sidebar")
        XCTAssertTrue(app.buttons["kids.player.playpause"].isEnabled)
    }

    func testPausedTimelineAcceptsDirectionalSeek() {
        launch("paused")
        let playPause = app.buttons["kids.player.playpause"]
        let timeline = app.descendants(matching: .any)["kids.player.timeline"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 10))
        XCTAssertTrue(timeline.exists)
        XCTAssertTrue(playPause.hasFocus)
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(timeline.hasFocus, "Paused timeline must be reachable from the playback controls")
        let originalValue = timeline.value as? String
        XCUIRemote.shared.press(.right)
        XCTAssertNotEqual(timeline.value as? String, originalValue, "Right must seek forward while the timeline is focused")
        XCUIRemote.shared.press(.left)
        XCTAssertEqual(timeline.value as? String, originalValue, "Left must seek backward while the timeline is focused")
    }

    func testParentGateMasksPINAndBackReturns() {
        launch("shows")
        let parents = app.buttons["kids.parents"]
        XCTAssertTrue(parents.waitForExistence(timeout: 10))
        selectParents(parents)
        XCTAssertTrue(app.secureTextFields["kids.parent.pin"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["kids.parent.resetall"].exists)
        capture("parent-pin-gate")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["kids.card.show-1"].waitForExistence(timeout: 5))
    }

    private func unlockParents() {
        let parents = app.buttons["kids.parents"]
        XCTAssertTrue(parents.waitForExistence(timeout: 10))
        selectParents(parents)
        enterParentPIN()
    }

    private func enterParentPIN() {
        let pin = app.secureTextFields["kids.parent.pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.select)
        pin.typeText("4242")
        let done = app.buttons.matching(NSPredicate(format: "label ==[c] %@", "done")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        for _ in 0 ..< 5 {
            if done.hasFocus {
                break
            }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(done.hasFocus)
        XCUIRemote.shared.press(.select)
        let fieldFocus = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: pin)
        XCTAssertEqual(XCTWaiter.wait(for: [fieldFocus], timeout: 5), .completed)
        capture("parent-pin-entered")
        XCUIRemote.shared.press(.down)
        // tvOS Form focus belongs to the containing row; the accessibility button is its child.
        let unlockRow = app.cells.containing(.button, identifier: "kids.parent.unlock").firstMatch
        let unlockFocus = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: unlockRow)
        XCTAssertEqual(XCTWaiter.wait(for: [unlockFocus], timeout: 5), .completed)
        XCUIRemote.shared.press(.select)
    }

    func testParentUnlockAndRelock() {
        launch("shows")
        unlockParents()
        XCTAssertTrue(app.buttons["kids.parent.resetall"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["kids.parent.pin"].exists)
        capture("parent-controls-unlocked")
        XCUIRemote.shared.press(.menu)
        let parents = app.buttons["kids.parents"]
        XCTAssertTrue(parents.waitForExistence(timeout: 5))
        selectParents(parents)
        XCTAssertTrue(app.secureTextFields["kids.parent.pin"].waitForExistence(timeout: 5))
    }

    func testOfflinePreviewExposesReceiverIdentityForPreparation() throws {
        launch("shows")
        defer { app.terminate() }
        unlockParents()
        XCTAssertTrue(app.buttons["kids.parent.resetall"].waitForExistence(timeout: 5))
        let identity = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "TV installation ID: ")).firstMatch
        let build = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Client build: ")).firstMatch
        for _ in 0 ..< 80 {
            if identity.exists, build.exists, app.frame.intersects(identity.frame), app.frame.intersects(build.frame) {
                break
            }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(identity.exists && build.exists)
        let rawID = identity.label.replacingOccurrences(of: "TV installation ID: ", with: "")
        let device = try XCTUnwrap(UUID(uuidString: rawID))
        let revision = build.label.replacingOccurrences(of: "Client build: ", with: "")
        XCTAssertEqual(revision.utf8.count, 64)
        XCTAssertTrue(revision.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) })
        let record: [String: Any] = [
            "scope": "offline-preview-identity-only",
            "installationID": device.uuidString,
            "clientBuildSHA256": revision,
            "bundleID": "com.kridsdale.JellyfinPlayer",
            "actualReceiverTrial": false,
            "credentialIssued": false
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: .sortedKeys)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "offline-receiver-identity"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("KIDS_OFFLINE_PREPARATION_IDENTITY " + String(decoding: data, as: UTF8.self))
        capture("offline-parent-pairing-identity")
    }

    private func focusFormAction(_ identifier: String) {
        let row = app.cells.containing(.button, identifier: identifier).firstMatch
        for _ in 0 ..< 40 {
            if row.exists && row.hasFocus {
                return
            }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(row.hasFocus, "Parent action must be independently reachable: \(identifier)")
    }

    func testParentCanSetNextWithoutResettingOtherShow() {
        launch("again")
        unlockParents()
        focusFormAction("kids.parent.setnext.show-1-episode-1")
        capture("parent-episode-picker")
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.menu)
        let first = app.buttons["kids.card.show-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        // Parents is at the right edge; return through the artwork row using the actual remote.
        if !first.hasFocus {
            XCUIRemote.shared.press(.down)
            for _ in 0 ..< 3 {
                if first.hasFocus {
                    break
                }
                XCUIRemote.shared.press(.left)
            }
        }
        select(first)
        let next = app.buttons["kids.action.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertEqual(next.label, "Next")
        XCUIRemote.shared.press(.menu)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 3), .completed)
        XCUIRemote.shared.press(.right)
        select(app.buttons["kids.card.show-2"])
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertEqual(next.label, "Again")
    }

    func testParentMovieStartOverClearsStopCheckpoint() {
        launch("movie-paused")
        let parents = app.buttons["kids.player.parents"]
        XCTAssertTrue(parents.waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(parents.hasFocus)
        XCUIRemote.shared.press(.select)
        enterParentPIN()
        focusFormAction("kids.parent.startover")
        XCUIRemote.shared.press(.select)
        let movie = app.buttons["kids.card.movie-1"]
        XCTAssertTrue(movie.waitForExistence(timeout: 5))
        let playerDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.buttons["kids.player.playpause"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [playerDismissed], timeout: 5), .completed)
        if !movie.hasFocus {
            XCUIRemote.shared.press(.down)
        }
        select(movie)
        let play = app.buttons["kids.action.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertEqual(play.label, "Play")
        capture("movie-explicit-start-over")
    }

    func testEmptyCatalogHasCategoryEscape() {
        launch("empty")
        XCTAssertTrue(app.staticTexts["More pictures are coming!"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["kids.category.movies"].exists)
        capture("empty-catalog")
    }

    func testPendingMoviesKeepsVerifiedShowsReachable() {
        launch("movies-loading")
        XCTAssertTrue(app.staticTexts["Finding your movies…"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["More pictures are coming!"].exists)
        XCTAssertFalse(app.buttons["kids.card.movie-1"].exists)
        XCTAssertTrue(app.buttons["kids.parents"].exists)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["kids.card.show-1"].waitForExistence(timeout: 5))
        capture("verified-shows-while-movies-pending")
    }

    func testMoviesBackReturnsToShows() {
        launch("movies")
        XCTAssertTrue(app.buttons["kids.card.movie-1"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["kids.card.show-1"].waitForExistence(timeout: 5))
    }

    func testDeniedAccountHidesPreviouslyVisibleCatalog() {
        launch("denied")
        XCTAssertTrue(app.staticTexts["A grown-up can help."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["kids.card.show-1"].exists)
        XCTAssertFalse(app.buttons["kids.card.movie-1"].exists)
        XCTAssertFalse(app.staticTexts["Friendly Show 1"].exists)
        capture("denied-account-neutral-state")
    }

    func testReconnectingPlayerCanReturnWithoutAdvancing() {
        launch("reconnecting")
        let retry = app.buttons["kids.status.action"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertEqual(retry.label, "Try again")
        XCTAssertTrue(retry.isHittable, "The status action must be usable in the visible recovery screen")
        XCTAssertTrue(app.buttons["Back"].exists)
        capture("reconnecting-player-recovery")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["kids.card.show-1"].waitForExistence(timeout: 5))
    }

    func testPausedPlayerFocusAndTimeline() {
        launch("paused")
        let play = app.buttons["kids.player.playpause"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertTrue(play.hasFocus)
        capture("paused-player-timeline")
        XCUIRemote.shared.press(.up)
        let timeline = app.descendants(matching: .any)["kids.player.timeline"]
        XCTAssertTrue(timeline.hasFocus)
        XCUIRemote.shared.press(.right)
        XCTAssertEqual(timeline.value as? String, "2:15")
        XCUIRemote.shared.press(.playPause)
        XCTAssertEqual(play.label, "Pause", "Play/Pause must work while the seek timeline owns focus.")
        XCUIRemote.shared.press(.playPause)
        XCTAssertEqual(play.label, "Play")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["kids.player.surface"].waitForExistence(timeout: 5))
    }

    func testCountdownStopAndSessionEnding() {
        launch("countdown")
        let stop = app.buttons["Stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertTrue(stop.hasFocus)
        capture("countdown-stop-focused")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["kids.card.show-1"].waitForExistence(timeout: 5))
        launch("session-end")
        let back = app.buttons["Back to shows"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        capture("session-end-card")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["kids.card.show-1"].waitForExistence(timeout: 5))
    }
}
