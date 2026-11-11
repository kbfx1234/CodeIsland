import AppKit
import SwiftUI
import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class CollapsedBarTests: XCTestCase {
    private func idleSession(title: String?) -> SessionSnapshot {
        var session = SessionSnapshot()
        session.source = "claude"
        session.cwd = "/Users/dev/code/acme-client-portal"
        session.status = .idle
        session.sessionTitle = title
        session.recap = SessionRecap(text: "Rotated the API keys; waiting on your review.", createdAt: Date())
        return session
    }

    // MARK: - Recap tooltip

    func testRecapTooltipKeepsTheFolderOutWhenProjectNamesAreHidden() {
        let tooltip = SessionMetadataStyle.collapsedRecapTooltip(for: idleSession(title: "Key rotation"), showProjectName: false)
        XCTAssertFalse(tooltip.contains("acme-client-portal"), "the folder name leaked into the tooltip")
        XCTAssertEqual(tooltip, "↻ Key rotation\nRotated the API keys; waiting on your review.")
    }

    func testRecapTooltipFallsBackToTheAgentNotTheFolder() {
        let tooltip = SessionMetadataStyle.collapsedRecapTooltip(for: idleSession(title: nil), showProjectName: false)
        XCTAssertEqual(tooltip, "↻ Claude\nRotated the API keys; waiting on your review.")
    }

    func testRecapTooltipStillLeadsWithTheFolderByDefault() {
        let tooltip = SessionMetadataStyle.collapsedRecapTooltip(for: idleSession(title: "Key rotation"), showProjectName: true)
        XCTAssertEqual(tooltip, "↻ acme-client-portal\nRotated the API keys; waiting on your review.")
        XCTAssertEqual(SessionMetadataStyle.collapsedRecapTooltip(for: nil, showProjectName: true), "")
    }

    // MARK: - Context label

    /// With "Show project name" off the bar leads with the session title,
    /// and an AI title can run to dozens of characters.
    func testLongSessionTitleIsCappedSoTheToolDescriptionKeepsItsRoom() {
        let title = "Refactor the authentication middleware so session tokens rotate on every request"
        XCTAssertEqual(CompactContextLabel.width(for: title), CompactContextLabel.maxWidth)
        XCTAssertLessThanOrEqual(fittingWidth(CompactContextLabel(text: title)), CompactContextLabel.maxWidth)

        // Beside a long tool description in the bar's centre, the title
        // leaves the description the rest of the row instead of splitting it.
        let description = WidthBox()
        let row = HStack(spacing: 5) {
            CompactContextLabel(text: title)
            Text("Sources/Auth/SessionTokenRotationMiddleware.swift")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { description.value = $0 }
        }
        layOut(row, width: 300)
        // Less up to one monospaced character, which truncation rounds away;
        // an even split (the old behaviour) would leave it ~147pt.
        XCTAssertGreaterThanOrEqual(description.value, 300 - 5 - CompactContextLabel.maxWidth - 7)
    }

    func testShortLabelHugsItsText() {
        let width = CompactContextLabel.width(for: "web-app")
        XCTAssertLessThan(width, CompactContextLabel.maxWidth)
        XCTAssertEqual(fittingWidth(CompactContextLabel(text: "web-app")), width, accuracy: 1)
    }

    private func fittingWidth<V: View>(_ view: V) -> CGFloat {
        NSHostingView(rootView: view.fixedSize()).fittingSize.width
    }

    private func layOut<V: View>(_ view: V, width: CGFloat) {
        let host = NSHostingView(rootView: view.frame(width: width, alignment: .leading))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 20)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
    }
}

private final class WidthBox {
    var value: CGFloat = 0
}
