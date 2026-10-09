//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import KidsDiagnostics
import SwiftUI

@main
struct SwiftfinApp: App {

    @UIApplicationDelegateAdaptor(KidsCloudAppDelegate.self)
    private var cloudDelegate

    init() {
        _ = KidsPerformance.launch
        Self.configureEvidenceIfRequested()
        Self.configure()

        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: UIColor.label]
    }

    var body: some Scene {
        WindowGroup {
            OverlayToastView {
                WithLocalUserAuthentication {
                    RootView()
                }
            }
        }
    }

    /// Developer opt-in only. Loading a plan never starts playback or performs
    /// network probes. The revision must be embedded by the build, not a launch
    /// environment override that could misidentify the compiled implementation.
    @MainActor
    private static func configureEvidenceIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--kids-evidence") else { return }
        guard let path = ProcessInfo.processInfo.environment["KIDS_EVIDENCE_PLAN"],
              let revision = Bundle.main.object(forInfoDictionaryKey: "KidsEvidenceImplementationRevision") as? String,
              let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let osBuild = ProcessInfo.processInfo.operatingSystemVersionString.components(separatedBy: "Build ").last?
                  .split(separator: ")").first.map(String.init),
                  let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { KidsEvidenceCapture.setupFailure = .invalidConfiguration
            return
        }
        let url = URL(fileURLWithPath: path)
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path + "/"
        guard url.resolvingSymlinksInPath().path.hasPrefix(home) else {
            KidsEvidenceCapture.setupFailure = .invalidConfiguration
            return
        }
        #if targetEnvironment(simulator)
        let platform = KidsEvidenceClient.Platform.simulator
        #else
        let platform = KidsEvidenceClient.Platform.physical
        #endif
        do {
            let plan = try KidsEvidencePlan.load(fileURL: url)
            let directory = support.appendingPathComponent("KidsPlayer/Evidence", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            KidsEvidenceCapture.shared = try .init(
                plan: plan,
                implementationRevision: revision,
                directory: directory,
                platform: platform,
                appBuild: appBuild,
                osBuild: osBuild
            )
        } catch {
            KidsEvidenceCapture.setupFailure = (error as? KidsEvidenceProtocolError) ?? .invalidConfiguration
        }
    }
}

/// Silent CloudKit pushes are handled by the SDK's persistent-store mirroring.
final class KidsCloudAppDelegate: NSObject, UIApplicationDelegate {
    func applicationWillTerminate(_ application: UIApplication) {
        KidsEvidenceCapture.shared?.finishInterrupted()
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if (Bundle.main.object(forInfoDictionaryKey: "KidsCloudSyncEnabled") as? String) == "YES" {
            application.registerForRemoteNotifications()
        }
        return true
    }
}
