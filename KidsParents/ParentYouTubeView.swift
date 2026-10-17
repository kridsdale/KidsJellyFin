//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import KidsParentControl
import SwiftUI
import WebKit

struct ParentYouTubeView: View {
    @Bindable
    var model: ParentsModel
    @State
    private var playlist = ""
    @State
    private var manager: ImportManagerDestination?
    @State
    private var copied = false

    private var validPlaylist: YouTubePlaylist? {
        try? YouTubePlaylist(playlist)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "play.rectangle.on.rectangle").font(.largeTitle).foregroundStyle(.teal)
                        Text("Find it. Review it.\nMake it theirs.").font(.title.bold()).fixedSize(horizontal: false, vertical: true)
                        Text("Add a playlist to the server's review queue, choose the exact videos, then approve the download into Kid TV.")
                            .font(.subheadline).foregroundStyle(.secondary).fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                    }.padding(.vertical, 12)
                }.listRowBackground(Color.clear)
                Section {
                    TextField("https://www.youtube.com/playlist?list=…", text: $playlist, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: playlist) { _, _ in copied = false }
                    if let validPlaylist {
                        Label("Playlist link recognized", systemImage: "checkmark.circle").foregroundStyle(.teal)
                        Text(validPlaylist.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    } else if !playlist.isEmpty {
                        Text("Use a YouTube playlist link, not a search or channel URL.").font(.caption).foregroundStyle(.orange)
                    }
                    Button {
                        guard let validPlaylist else { return }
                        do {
                            let server = try ParentServer(model.importServerText)
                            UIPasteboard.general.string = validPlaylist.url.absoluteString
                            copied = true
                            manager = ImportManagerDestination(url: server.url)
                        } catch { model.error = error.localizedDescription }
                    } label: {
                        Label("Copy link & open import review", systemImage: "arrow.down.doc")
                    }.disabled(validPlaylist == nil || model.demo)
                    if copied {
                        Text("Link copied. Paste it into the manager's playlist field.").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("YouTube playlist")
                } footer: {
                    Text(
                        "The manager opens inside this app. Sign in there with your adult Jellyfin account, paste the link, and review the videos before approving. Copying a link never starts a download."
                    )
                }
                Section("Archive") {
                    NavigationLink { ParentReviewInboxView(model: model) } label: {
                        Label("New-video review inbox", systemImage: "tray.and.arrow.down")
                    }
                    Button("Open collections and download status", systemImage: "tray.full") {
                        do { manager = try ImportManagerDestination(url: ParentServer(model.importServerText).url) }
                        catch { model.error = error.localizedDescription }
                    }.disabled(model.demo)
                    Text(
                        "The existing server workflow owns review, approved storage, downloads, and publication. Collection pause only pauses new work; use viewing restrictions to hide a show."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("YouTube")
                .sheet(item: $manager) { destination in
                    ImportManagerSheet(url: destination.url)
                }
        }
    }
}

struct ImportManagerDestination: Identifiable { let id = UUID()
    let url: URL
    let title: String
    init(url: URL, title: String = "Import review") {
        self.url = url
        self.title = title
    }
}

struct ImportManagerSheet: View {
    let url: URL
    let title: String
    init(url: URL, title: String = "Import review") {
        self.url = url
        self.title = title
    }

    @Environment(\.dismiss)
    private var dismiss
    var body: some View {
        NavigationStack {
            ImportManagerView(url: url).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// The deployed web UI owns its cookie/CSRF/review protocol. No injected script,
/// native credential forwarding, or automatic approval. Each presentation has
/// an ephemeral browser session scoped to this service's origin.
private struct ImportManagerView: UIViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator {
        Coordinator(origin: url)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let origin: URL
        init(origin: URL) {
            self.origin = origin
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let destination = action.request.url,
                  destination.scheme == origin.scheme, destination.host == origin.host,
                  destination.port == origin.port else { return .cancel }
            return .allow
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // Render a constant local error rather than interpolate server content.
            webView.loadHTMLString(
                "<html><meta name='viewport' content='width=device-width'><body style='font:18px -apple-system;padding:24px'><h2>Cannot reach the server manager</h2><p>Check that your iPhone is on the home network and that the service address in Settings is correct. Close this sheet and try again.</p></body></html>",
                baseURL: origin
            )
        }
    }
}
