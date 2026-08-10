import Foundation
import XCTest
@testable import VibeNotch

final class HookTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testMaterializedHookUsesInjectedDirectoryAndSpoolsOneEvent() throws {
        let applicationSupport = temporaryDirectory().appendingPathComponent(
            "Vibe Notch Test",
            isDirectory: true
        )

        XCTAssertTrue(try HookScript.materialize(in: applicationSupport))
        XCTAssertFalse(try HookScript.materialize(in: applicationSupport))

        let scriptURL = HookScript.url(in: applicationSupport)
        let attributes = try FileManager.default.attributesOfItem(atPath: scriptURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o755)

        let input = #"{"session_id":"session-1","nested":{"allowed":true}}"#
        let process = Process()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path, "Notification"]
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let eventsDirectory = applicationSupport.appendingPathComponent("events")
        let files = try FileManager.default.contentsOfDirectory(
            at: eventsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        XCTAssertEqual(files.count, 1)
        let eventFile = try XCTUnwrap(files.first)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: eventFile)) as? [String: Any]
        )
        XCTAssertEqual(object["event"] as? String, "Notification")
        XCTAssertNotNil(object["tty"] as? String)
        XCTAssertNotNil(object["ts"] as? NSNumber)
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(payload["session_id"] as? String, "session-1")
        XCTAssertEqual((payload["nested"] as? [String: Any])?["allowed"] as? Bool, true)

        let stagingFiles = try FileManager.default.contentsOfDirectory(
            at: eventsDirectory.appendingPathComponent(".staging"),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(stagingFiles.isEmpty)
    }

    func testInstallerMergesIntoEmptyHooksAndIsIdempotent() throws {
        let directory = temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        let original = Data(#"{"theme":"dark","hooks":{}}"#.utf8)
        try original.write(to: settingsURL)
        let binURL = directory.appendingPathComponent("App Support/bin/vibenotch-hook")
        let installer = HookInstaller(settingsURL: settingsURL)

        XCTAssertTrue(try installer.install(binURL: binURL))
        XCTAssertTrue(installer.hasInstalledHooks())
        let once = try Data(contentsOf: settingsURL)
        XCTAssertFalse(try installer.install(binURL: binURL))
        XCTAssertEqual(try Data(contentsOf: settingsURL), once)
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("settings.json.vibenotch-bak")),
            original
        )

        let settings = try json(at: settingsURL)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(HookInstaller.eventNames))
        for eventName in HookInstaller.eventNames {
            let entries = try XCTUnwrap(hooks[eventName] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(
                command(in: entries[0]),
                "'\(binURL.path)' \(eventName)"
            )
            if eventName == "PreToolUse" {
                XCTAssertEqual(
                    entries[0]["matcher"] as? String,
                    "Edit|MultiEdit|Write|Bash|NotebookEdit|ExitPlanMode|AskUserQuestion"
                )
            } else {
                XCTAssertNil(entries[0]["matcher"])
            }
        }
    }

    func testInstallPreservesForeignHooksForSameAndDifferentEvents() throws {
        let directory = temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        let foreignSame: [String: Any] = [
            "matcher": "foreign",
            "hooks": [["type": "command", "command": "/tmp/foreign Stop"]]
        ]
        let foreignDifferent: [String: Any] = [
            "hooks": [["type": "command", "command": "/tmp/other"]]
        ]
        try writeJSON([
            "theme": "dark",
            "hooks": [
                "Stop": [foreignSame],
                "PostToolUse": [foreignDifferent]
            ]
        ], to: settingsURL)

        let installer = HookInstaller(settingsURL: settingsURL)
        try installer.install(binURL: directory.appendingPathComponent("vibenotch-hook"))

        let hooks = try XCTUnwrap(try json(at: settingsURL)["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2)
        XCTAssertEqual(command(in: stop[0]), "/tmp/foreign Stop")
        let postToolUse = try XCTUnwrap(hooks["PostToolUse"] as? [[String: Any]])
        XCTAssertEqual(postToolUse.count, 1)
        XCTAssertEqual(command(in: postToolUse[0]), "/tmp/other")
    }

    func testInstallReplacesOldPreToolUseMatcher() throws {
        let directory = temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        let binURL = directory.appendingPathComponent("bin/vibenotch-hook")
        try writeJSON([
            "hooks": [
                "PreToolUse": [[
                    "matcher": "Edit|MultiEdit|Write|Bash|NotebookEdit",
                    "hooks": [[
                        "type": "command",
                        "command": "'\(binURL.path)' PreToolUse"
                    ]]
                ]]
            ]
        ], to: settingsURL)
        let installer = HookInstaller(settingsURL: settingsURL)

        XCTAssertFalse(installer.hasInstalledHooks(binURL: binURL))
        XCTAssertTrue(try installer.install(binURL: binURL))

        let hooks = try XCTUnwrap(try json(at: settingsURL)["hooks"] as? [String: Any])
        let entries = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(
            entries[0]["matcher"] as? String,
            "Edit|MultiEdit|Write|Bash|NotebookEdit|ExitPlanMode|AskUserQuestion"
        )
    }

    func testUninstallRemovesOnlyVibeNotchEntries() throws {
        let directory = temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        let installer = HookInstaller(settingsURL: settingsURL)
        try writeJSON([
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "/tmp/vibenotch-hook Stop"]]],
                    ["hooks": [["type": "command", "command": "/tmp/foreign"]]]
                ],
                "Custom": [
                    ["hooks": [["type": "command", "command": "/tmp/custom"]]]
                ]
            ]
        ], to: settingsURL)

        XCTAssertTrue(try installer.uninstall())
        XCTAssertFalse(try installer.uninstall())

        let hooks = try XCTUnwrap(try json(at: settingsURL)["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 1)
        XCTAssertEqual(command(in: stop[0]), "/tmp/foreign")
        XCTAssertEqual((hooks["Custom"] as? [[String: Any]])?.count, 1)
    }

    func testUninstallWithoutHooksIsANoOp() throws {
        let directory = temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        let original = Data(#"{"theme":"dark"}"#.utf8)
        try original.write(to: settingsURL)

        XCTAssertFalse(try HookInstaller(settingsURL: settingsURL).uninstall())
        XCTAssertEqual(try Data(contentsOf: settingsURL), original)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("settings.json.vibenotch-bak").path
            )
        )
    }

    func testUninstallPreservesForeignCommandInTheSameMatcherGroup() throws {
        let directory = temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        try writeJSON([
            "hooks": [
                "Stop": [[
                    "hooks": [
                        ["type": "command", "command": "/tmp/vibenotch-hook Stop"],
                        ["type": "command", "command": "/tmp/foreign Stop"]
                    ]
                ]]
            ]
        ], to: settingsURL)

        try HookInstaller(settingsURL: settingsURL).uninstall()

        let hooks = try XCTUnwrap(try json(at: settingsURL)["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 1)
        let commands = try XCTUnwrap(stop[0]["hooks"] as? [[String: Any]])
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0]["command"] as? String, "/tmp/foreign Stop")
    }

    func testPartialInstallIsReportedMissingAndInstallRepairsIt() throws {
        let directory = temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        let binURL = directory.appendingPathComponent("bin/vibenotch-hook")
        try writeJSON([
            "hooks": [
                "Stop": [[
                    "hooks": [[
                        "type": "command",
                        "command": "'\(binURL.path)' Stop"
                    ]]
                ]]
            ]
        ], to: settingsURL)
        let installer = HookInstaller(settingsURL: settingsURL)

        XCTAssertFalse(installer.hasInstalledHooks())
        XCTAssertTrue(try installer.install(binURL: binURL))
        XCTAssertTrue(installer.hasInstalledHooks())
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func json(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func command(in entry: [String: Any]) -> String? {
        (entry["hooks"] as? [[String: Any]])?.first?["command"] as? String
    }
}
