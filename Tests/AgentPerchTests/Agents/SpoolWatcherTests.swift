import Foundation
import XCTest
@testable import AgentPerch

final class SpoolWatcherTests: XCTestCase {
    func testProcessesLeftoversOldestFirstAndDeletesThem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let newer = directory.appendingPathComponent("newer.json")
        let older = directory.appendingPathComponent("older.json")
        try eventData(name: "Stop", timestamp: 20).write(to: newer)
        try eventData(name: "SessionStart", timestamp: 10).write(to: older)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 20)],
            ofItemAtPath: newer.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 10)],
            ofItemAtPath: older.path
        )
        var events: [String] = []
        let watcher = SpoolWatcher(directoryURL: directory) { events.append($0.event) }

        watcher.processPendingFiles()

        XCTAssertEqual(events, ["SessionStart", "Stop"])
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    private func eventData(name: String, timestamp: Int) -> Data {
        Data("""
        {"event":"\(name)","tty":"ttys001","ts":\(timestamp),"payload":{"session_id":"session-1"}}
        """.utf8)
    }
}
