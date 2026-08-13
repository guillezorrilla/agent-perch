@preconcurrency import AppKit
import Foundation
@preconcurrency import UserNotifications

/// Notices a newer release and says so. It deliberately does **not** replace the bundle, and that
/// is the whole design (#75).
///
/// The issue asked for Sparkle with a relaunch. Sparkle replaces the entire `.app` — and #68
/// established that replacing the bundle is precisely what destroys this app's TCC grants:
/// Accessibility, without which answering a card cannot type into the terminal, and "access data
/// from other apps", without which Warp tab-exact jump stops working. A self-updater would
/// therefore revoke both on every single update and leave the app *looking* fine while doing
/// nothing — cards still appear, answers stop landing. That is a worse bug than the manual update
/// it replaces, and no test would catch it.
///
/// So: a notification and a download link. The user drags the app across once, which is the same
/// gesture that keeps the grants, and nothing silently loses a permission.
///
/// Revisit only once a Developer ID's stable designated requirement has been *verified* to carry
/// TCC across a bundle replacement on a second machine — measured the way #68 measured it, not
/// assumed because the documentation says it should.
enum UpdateCheck {
    static let releasesPage = URL(string: "https://github.com/guillezorrilla/vibe-notch/releases/latest")!
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/guillezorrilla/vibe-notch/releases/latest")!

    /// The version `make dmg` stamped into the bundle it shipped.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private struct Release: Decodable {
        let tagName: String
    }

    /// GitHub tags carry a leading `v`; `CFBundleShortVersionString` does not.
    static func version(fromTag tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// `.numeric` compares runs of digits as numbers rather than characters, so 0.10.0 beats
    /// 0.9.0 — which a plain lexicographic compare gets backwards, and getting it backwards means
    /// never offering an update again after the first double-digit release.
    ///
    /// ponytail: no semver parser. `/releases/latest` never returns a draft or a prerelease, so
    /// the `-beta` suffixes that would break this comparison cannot reach it. Parse properly the
    /// day prereleases start being published.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    /// Unparseable JSON reads as `.checkFailed`, never as "up to date". Claiming the app is
    /// current when nothing was actually learned is the one answer this must not give.
    static func state(fromLatestRelease data: Data, current: String) -> UpdateState {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let release = try? decoder.decode(Release.self, from: data) else { return .checkFailed }
        let latest = version(fromTag: release.tagName)
        return isNewer(latest, than: current) ? .available(latest) : .upToDate(current)
    }

    static func fetch(current: String = currentVersion, session: URLSession = .shared) async -> UpdateState {
        guard let (data, response) = try? await session.data(from: latestReleaseAPI),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return .checkFailed }
        return state(fromLatestRelease: data, current: current)
    }
}

enum UpdateState: Equatable, Sendable {
    /// Nothing has been asked yet. Distinct from `.checkFailed` on purpose — "we don't know"
    /// and "we tried and couldn't" are different things to show a user.
    case unknown
    case checking
    case upToDate(String)
    case available(String)
    case checkFailed

    var label: String {
        switch self {
        case .unknown: "Not checked yet"
        case .checking: "Checking…"
        case .upToDate: "Up to date"
        case .available(let version): "\(version) available"
        case .checkFailed: "Couldn't reach GitHub"
        }
    }

    var newVersion: String? {
        if case .available(let version) = self { return version }
        return nil
    }
}

/// Runs the check on launch and once a day, and tells the user at most once per version.
@MainActor
final class UpdateChecker: ObservableObject {
    /// The daily re-check exists because this app is a launch-at-login accessory that runs for
    /// weeks without restarting — a launch-only check would never fire for the people most likely
    /// to want the update.
    static let interval = Duration.seconds(24 * 60 * 60)
    /// Which version the user has already been notified about, so the daily loop is a check and
    /// not a daily nag about the same release.
    private static let notifiedKey = "notifiedUpdateVersion"

    @Published private(set) var state: UpdateState = .unknown

    private let isEnabled: @MainActor () -> Bool
    private let fetch: @Sendable (String) async -> UpdateState
    private let announce: @MainActor (String) -> Void
    private let defaults: UserDefaults
    private var loop: Task<Void, Never>?

    init(
        isEnabled: @escaping @MainActor () -> Bool,
        fetch: @escaping @Sendable (String) async -> UpdateState = { await UpdateCheck.fetch(current: $0) },
        announce: @escaping @MainActor (String) -> Void = UpdateChecker.postNotification(version:),
        defaults: UserDefaults = .standard
    ) {
        self.isEnabled = isEnabled
        self.fetch = fetch
        self.announce = announce
        self.defaults = defaults
    }

    /// Injected rather than called directly so the notification centre is only ever reached for
    /// on a real announcement. `UNUserNotificationCenter.current()` *traps* outside an app bundle
    /// — and under `swift test` the main bundle is Xcode's own `usr/bin`, which has a bundle
    /// identifier, so the nil check `SessionNotifier` relies on does not save you here.
    @MainActor
    static func postNotification(version: String) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = "VibeNotch \(version) is available"
        content.body = "You're on \(UpdateCheck.currentVersion). Click to download."
        content.userInfo = ["open_url": UpdateCheck.releasesPage.absoluteString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "vibenotch-update-\(version)",
            content: content,
            trigger: nil
        ))
    }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkIfEnabled()
                try? await Task.sleep(for: UpdateChecker.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// The Settings button. Always runs, even with the automatic check switched off — the user
    /// pressing "Check now" *is* the consent.
    func checkNow() {
        Task { await check(notifying: false) }
    }

    /// One pass of the daily loop. Internal rather than private so the dedup rule can be tested
    /// by awaiting a pass instead of racing the loop's own timer.
    func checkIfEnabled() async {
        guard isEnabled() else { return }
        await check(notifying: true)
    }

    func check(notifying: Bool) async {
        state = .checking
        let result = await fetch(UpdateCheck.currentVersion)
        state = result
        guard notifying, let version = result.newVersion,
              defaults.string(forKey: Self.notifiedKey) != version else { return }
        defaults.set(version, forKey: Self.notifiedKey)
        announce(version)
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(UpdateCheck.releasesPage)
    }
}
