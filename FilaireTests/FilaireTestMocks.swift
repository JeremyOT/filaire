import Foundation
import UIKit
import SwiftTerm
@testable import Filaire

final class FakeBackgroundTaskProvider: BackgroundTaskProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var nextId = 1
    var beginCalls: [(name: String?, id: UIBackgroundTaskIdentifier, handler: (() -> Void)?)] = []
    var endCalls: [UIBackgroundTaskIdentifier] = []

    func beginBackgroundTask(withName name: String?, expirationHandler handler: (() -> Void)?) -> UIBackgroundTaskIdentifier {
        lock.lock()
        defer { lock.unlock() }
        let id = UIBackgroundTaskIdentifier(rawValue: nextId)
        nextId += 1
        beginCalls.append((name: name, id: id, handler: handler))
        return id
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        endCalls.append(identifier)
    }

    func triggerExpiration(for identifier: UIBackgroundTaskIdentifier) {
        let handler: (() -> Void)?
        lock.lock()
        handler = beginCalls.first(where: { $0.id == identifier })?.handler
        lock.unlock()
        handler?()
    }
}

final class MockTerminalGrid: TerminalCharacterGrid {
    let cols: Int
    let rows: Int
    var lines: [String]
    var explicitLinks: [String: String] = [:]

    init(lines: [String], cols: Int? = nil) {
        self.lines = lines
        self.rows = lines.count
        self.cols = cols ?? (lines.map { $0.count }.max() ?? 80)
    }

    func character(col: Int, row: Int) -> Character? {
        guard row >= 0, row < lines.count else { return nil }
        let line = lines[row]
        guard col >= 0 else { return nil }
        if col < line.count {
            let index = line.index(line.startIndex, offsetBy: col)
            return line[index]
        }
        return " "
    }

    func explicitLink(col: Int, row: Int) -> String? {
        explicitLinks["\(col),\(row)"]
    }
}
