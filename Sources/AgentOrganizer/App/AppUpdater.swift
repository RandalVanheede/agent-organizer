import Foundation
import Observation
import Sparkle

/// Sparkle, configured from Info.plist (`SUFeedURL`, `SUPublicEDKey`; checks
/// daily). Disabled — `isAvailable == false` — when the bundle carries no
/// public key: `swift run`, or a build made before `generate_keys` was run.
@MainActor
@Observable
final class AppUpdater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    /// Mirrored from Sparkle (KVO) so SwiftUI redraws.
    private(set) var canCheckForUpdates = false
    private(set) var lastCheck: Date?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    var isAvailable: Bool { controller != nil }

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.isEmpty, !key.hasPrefix("$") else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        sync()
        // KVO closures aren't main-actor isolated: hop, then re-read.
        observations = [
            updater.observe(\.canCheckForUpdates) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            updater.observe(\.lastUpdateCheckDate) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
        ]
    }

    private func sync() {
        guard let updater = controller?.updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        lastCheck = updater.lastUpdateCheckDate
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// Build facts stamped into Info.plist by `make bundle`.
enum BuildInfo {
    static var version: String { info("CFBundleShortVersionString") ?? "dev" }
    static var build: String { info("CFBundleVersion") ?? "0" }
    static var commit: String? { info("AOGitCommit").flatMap { $0.isEmpty || $0.hasPrefix("$") ? nil : $0 } }

    static let repoURL = URL(string: "https://github.com/RandalVanheede/agent-organizer")!
    static var releaseNotesURL: URL { repoURL.appendingPathComponent("releases/tag/v\(version)") }
    static var newIssueURL: URL { repoURL.appendingPathComponent("issues/new") }

    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
