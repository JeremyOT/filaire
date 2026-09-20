import XCTest
@testable import Filaire

/// The help content is the only explanation of several non-obvious icons, so these check it stays complete
/// and honest rather than drifting as controls change.
final class ControlHelpTests: XCTestCase {

    private var allEntries: [ControlHelpEntry] {
        ControlHelp.sections.flatMap(\.entries)
    }

    func testEveryEntryExplainsItself() {
        for entry in allEntries {
            XCTAssertFalse(entry.title.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(entry.symbol.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(
                entry.detail.trimmingCharacters(in: .whitespaces).isEmpty,
                "'\(entry.title)' has no description, which is the whole point of this screen"
            )
        }
    }

    func testTitlesAreUnique() {
        let titles = allEntries.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "Duplicate titles make the list ambiguous")
    }

    func testEveryPaneAndWindowControlOnTheBarIsDocumented() {
        // Mirrors the control bar's accessibility labels, so a new button without help is caught here.
        let documented = Set(allEntries.map(\.title))
        let expected = [
            "0 – 9", "Previous window", "Next window", "New window", "Rename window",
            "Split side by side", "Split top and bottom", "Join side by side", "Join top and bottom",
            "Mark pane", "Zoom pane", "Next pane", "Last pane",
            "Break pane out", "Close pane", "Compose", "Snippets"
        ]
        for title in expected {
            XCTAssertTrue(documented.contains(title), "The control bar has '\(title)' with no help entry")
        }
    }

    func testShortcutsMatchTheOnesTheAppRegisters() {
        let shortcuts = Dictionary(
            uniqueKeysWithValues: allEntries.compactMap { entry in
                entry.shortcut.map { (entry.title, $0) }
            }
        )
        XCTAssertEqual(shortcuts["Break pane out"], "Cmd + Shift + B")
        XCTAssertEqual(shortcuts["Compose"], "Cmd + Shift + E")
        XCTAssertEqual(shortcuts["Snippets"], "Cmd + Shift + S")
        XCTAssertEqual(shortcuts["Split side by side"], "Cmd + D")
        XCTAssertEqual(shortcuts["Split top and bottom"], "Cmd + Shift + D")
        XCTAssertEqual(shortcuts["Mark pane"], "Cmd + M")
        XCTAssertEqual(shortcuts["Join side by side"], "Cmd + J")
        XCTAssertEqual(shortcuts["Join top and bottom"], "Cmd + Shift + J")
    }

    func testSectionsAreNamedAndNonEmpty() {
        XCTAssertFalse(ControlHelp.sections.isEmpty)
        for section in ControlHelp.sections {
            XCTAssertFalse(section.name.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(section.entries.isEmpty, "Section '\(section.name)' documents nothing")
        }
    }

    func testSectionOrderMatchesToolbar() {
        let sectionNames = ControlHelp.sections.map(\.name)
        XCTAssertEqual(sectionNames, ["Composing", "tmux panes", "tmux windows", "Keyboard bar"])
    }

    func testComposingEntriesOrderMatchesToolbar() {
        guard let composingSection = ControlHelp.sections.first(where: { $0.name == "Composing" }) else {
            XCTFail("Missing Composing section")
            return
        }
        let titles = composingSection.entries.map(\.title)
        XCTAssertEqual(titles, ["Snippets", "Compose"])
    }

    func testPaneEntriesOrderMatchesToolbar() {
        guard let paneSection = ControlHelp.sections.first(where: { $0.name == "tmux panes" }) else {
            XCTFail("Missing tmux panes section")
            return
        }
        let titles = paneSection.entries.map(\.title)
        XCTAssertEqual(titles.first, "Zoom pane")
    }
}
