import XCTest
@testable import AcerDisplayControl

final class MenuPanelAnchorTests: XCTestCase {
    func testResizingInEitherDirectionKeepsMenuAtSameTopEdge() {
        let screen = CGRect(x: -1920, y: 130, width: 1920, height: 1080)
        let original = CGRect(x: -550, y: 892, width: 356, height: 286)
        let anchor = MenuPanelAnchor(displayUUID: UUID(), panel: original, screen: screen)
        for height: CGFloat in [310, 286, 271] {
            let size = CGSize(width: original.width, height: height)
            let frame = CGRect(origin: anchor.origin(size: size, screen: screen, menuBarBottom: original.maxY), size: size)
            XCTAssertEqual(frame.maxY, original.maxY)
            XCTAssertEqual(frame.minX, original.minX)
        }
    }

    func testReopeningWithStaleWindowHeightClosesGapBelowMenuBar() {
        let screen = CGRect(x: -1080, y: -504, width: 1080, height: 1920)
        let menuBottom = screen.maxY - 30
        let staleFrame = CGRect(x: -621, y: menuBottom - 18 - 322, width: 356, height: 322)
        let anchor = MenuPanelAnchor(displayUUID: UUID(), panel: staleFrame, screen: screen)
        let size = CGSize(width: 356, height: 286)
        let frame = CGRect(origin: anchor.origin(size: size, screen: screen, menuBarBottom: menuBottom), size: size)
        XCTAssertEqual(frame.maxY, menuBottom)
        XCTAssertEqual(frame.minX, staleFrame.minX)
    }

    func testReconnectingPrimaryKeepsPositionRelativeToBenQ() {
        let benq = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let panel = CGRect(x: 1250, y: 760, width: 356, height: 288)
        let anchor = MenuPanelAnchor(displayUUID: UUID(), panel: panel, screen: benq)
        let relocated = benq.offsetBy(dx: -1920, dy: 336)
        XCTAssertEqual(anchor.origin(size: panel.size, screen: relocated, menuBarBottom: relocated.maxY - 32),
                       panel.offsetBy(dx: -1920, dy: 336).origin)
    }
}
