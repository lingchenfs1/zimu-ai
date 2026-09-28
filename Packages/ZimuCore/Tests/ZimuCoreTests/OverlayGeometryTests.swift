import XCTest
@testable import ZimuCore

final class OverlayGeometryTests: XCTestCase {
    let start = OverlayFrame(x: 100, y: 200, width: 600, height: 150)

    private func resize(_ edges: ResizeEdges, dx: Double, dy: Double) -> OverlayFrame {
        OverlayGeometry.resized(start, edges: edges, dx: dx, dy: dy, minWidth: 280, minHeight: 70)
    }

    func testRightAndTopEdgesKeepOriginFixed() {
        XCTAssertEqual(resize(.right, dx: 50, dy: 30), OverlayFrame(x: 100, y: 200, width: 650, height: 150))
        XCTAssertEqual(resize(.top, dx: 50, dy: 30), OverlayFrame(x: 100, y: 200, width: 600, height: 180))
    }

    func testLeftEdgeKeepsRightSideFixed() {
        let frame = resize(.left, dx: -40, dy: 0)
        XCTAssertEqual(frame, OverlayFrame(x: 60, y: 200, width: 640, height: 150))
        XCTAssertEqual(frame.x + frame.width, start.x + start.width)
    }

    func testBottomEdgeKeepsTopSideFixed() {
        // 向下拖（dy 为负）变高，顶边不动
        let frame = resize(.bottom, dx: 0, dy: -25)
        XCTAssertEqual(frame, OverlayFrame(x: 100, y: 175, width: 600, height: 175))
        XCTAssertEqual(frame.y + frame.height, start.y + start.height)
    }

    func testCornersMoveTwoEdges() {
        XCTAssertEqual(resize(.bottomRight, dx: 20, dy: -10), OverlayFrame(x: 100, y: 190, width: 620, height: 160))
        XCTAssertEqual(resize(.topLeft, dx: 20, dy: 10), OverlayFrame(x: 120, y: 200, width: 580, height: 160))
        XCTAssertEqual(resize(.topRight, dx: 20, dy: 10), OverlayFrame(x: 100, y: 200, width: 620, height: 160))
        XCTAssertEqual(resize(.bottomLeft, dx: -20, dy: -10), OverlayFrame(x: 80, y: 190, width: 620, height: 160))
    }

    func testMinimumSizeKeepsOppositeEdgesFixed() {
        let shrunk = resize(.topLeft, dx: 1_000, dy: -1_000)
        XCTAssertEqual(shrunk.width, 280)
        XCTAssertEqual(shrunk.height, 70)
        XCTAssertEqual(shrunk.x + shrunk.width, start.x + start.width)
        XCTAssertEqual(shrunk.y, start.y)

        let small = resize(.bottomRight, dx: -1_000, dy: 1_000)
        XCTAssertEqual(small, OverlayFrame(x: 100, y: 280, width: 280, height: 70))
    }

    func testAllHandlesListsEdgesBeforeCorners() {
        XCTAssertEqual(ResizeEdges.allHandles.count, 8)
        XCTAssertEqual(Set(ResizeEdges.allHandles.prefix(4)), [.left, .right, .top, .bottom])
    }
}
