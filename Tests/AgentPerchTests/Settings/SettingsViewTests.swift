import SwiftUI
import XCTest
@testable import AgentPerch

/// Settings is the one screen with no other way to notice it broke: the app runs headless in
/// the notch, so a pane that renders nothing looks exactly like a pane nobody opened.
///
/// This exists because that happened. `TabView` on macOS hoists its tab strip into the window
/// toolbar, and hosted in this app's plain `NSWindow` it drew the first tab's content with no
/// tabs above it at all — a settings window with no way to reach four of its five pages. The
/// build was clean and every other test passed.
final class SettingsViewTests: XCTestCase {
    /// Renders into a real `NSWindow`. `ImageRenderer` is not an option: a grouped `Form` is
    /// NSScrollView-backed on macOS and ImageRenderer only draws pure SwiftUI, so it returns a
    /// blank bitmap for every pane here and the test would pass by accident.
    @MainActor
    private func render(_ view: some View, height: CGFloat = SettingsView.windowSize.height) throws -> NSBitmapImageRep {
        let size = CGSize(width: SettingsView.windowSize.width, height: height)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // NSHostingController sizes the window to the SwiftUI ideal size, and a bare Form's
        // ideal height is 0 — without an explicit frame the content view has no height at all.
        window.contentViewController = NSHostingController(
            rootView: view.frame(width: size.width, height: size.height)
        )
        // Parked off any display but genuinely ordered in: AppKit neither lays out nor draws a
        // window that was never brought on screen, and `cacheDisplay` then copies nothing.
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))

        let content = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        return bitmap
    }

    /// Distinct colours in a horizontal band. One means the band is a flat fill — which is what
    /// "nothing drew here" looks like.
    private func distinctColors(in bitmap: NSBitmapImageRep, rows: Range<Int>) -> Int {
        var seen = Set<Int>()
        for y in rows where y < bitmap.pixelsHigh {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                let key = Int(color.redComponent * 255) << 16
                    | Int(color.greenComponent * 255) << 8
                    | Int(color.blueComponent * 255)
                seen.insert(key)
            }
        }
        return seen.count
    }

    @MainActor
    private func makeSettings() -> AppSettings { AppSettings() }

    @MainActor
    private func makePermissions() -> AnswerPermissionsModel {
        let model = AnswerPermissionsModel(
            installedTargets: {
                [
                    AutomationTarget(name: "iTerm2", bundleIdentifier: "com.googlecode.iterm2", purpose: "Writes the answer."),
                    AutomationTarget(name: "Terminal", bundleIdentifier: "com.apple.Terminal", purpose: "Selects the tab.")
                ]
            },
            statusForTarget: { $0.contains("iterm") ? .granted : .denied },
            accessibilityStatus: { .granted }
        )
        model.refresh()
        return model
    }

    @MainActor
    private func makeUpdates() -> UpdateChecker {
        UpdateChecker(isEnabled: { true }, fetch: { _ in .upToDate("0.1.0") }, announce: { _ in })
    }

    @MainActor
    func testEveryTabDrawsSomething() throws {
        let settings = makeSettings()
        let panes: [(String, any View)] = [
            ("General", GeneralSettings(settings: settings)),
            ("Island", IslandSettings(settings: settings)),
            ("Agents", AgentSettings(settings: settings, usageProviders: ["Claude", "Codex"])),
            ("Answering", AnsweringSettings(permissions: makePermissions())),
            ("Updates", UpdateSettings(settings: settings, updates: makeUpdates()))
        ]
        for (name, pane) in panes {
            let bitmap = try render(AnyView(pane))
            // The top of a pane is where its first control sits, so a flat band there means the
            // pane drew nothing at all.
            XCTAssertGreaterThan(
                distinctColors(in: bitmap, rows: 0..<80), 1,
                "the \(name) pane rendered a flat fill — nothing drew"
            )
        }
    }

    /// A column of sampled pixels down the middle of the image. Two renders that differ only by
    /// something drawn above the content produce different signatures.
    private func signature(of bitmap: NSBitmapImageRep) -> [Int] {
        stride(from: 0, to: min(bitmap.pixelsHigh, 240), by: 4).map { y in
            var row = 0
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 16) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                row = row &* 31 &+ Int(color.redComponent * 255)
                row = row &* 31 &+ Int(color.greenComponent * 255)
                row = row &* 31 &+ Int(color.blueComponent * 255)
            }
            return row
        }
    }

    /// The regression this file was written for. The tab strip is the only way to reach four of
    /// the five panes; if it stops drawing, the window silently becomes single-page.
    ///
    /// Asserting "the top band is not a flat fill" does NOT catch this — the pane's own
    /// background and its first section card already vary, so that assertion passes with the
    /// strip deleted. What actually distinguishes the two is that a `SettingsView` without its
    /// strip renders *identically* to the bare pane it defaults to.
    @MainActor
    func testTheTabStripDraws() throws {
        let settings = makeSettings()
        let full = try render(SettingsView(
            settings: settings,
            permissions: makePermissions(),
            updates: makeUpdates(),
            usageProviders: ["Claude"]
        ))
        let bare = try render(GeneralSettings(settings: settings))

        XCTAssertNotEqual(
            signature(of: full), signature(of: bare),
            "Settings renders the same as its General pane alone — the tab strip is not being drawn, "
                + "leaving four of the five panes unreachable"
        )
    }
}
