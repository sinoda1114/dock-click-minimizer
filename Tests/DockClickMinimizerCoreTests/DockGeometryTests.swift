import CoreGraphics
import Testing

@testable import DockClickMinimizerCore

struct DockGeometryTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func bottomDockContainsPointsNearBottomEdge() {
        let geometry = DockGeometry(
            orientation: .bottom,
            screenFrame: screen,
            tileSize: 64,
            magnificationEnabled: false,
            magnificationSize: 64
        )

        #expect(geometry.contains(CGPoint(x: 720, y: 40)))
        #expect(!geometry.contains(CGPoint(x: 720, y: 180)))
    }

    @Test func leftDockContainsPointsNearLeftEdge() {
        let geometry = DockGeometry(
            orientation: .left,
            screenFrame: screen,
            tileSize: 64,
            magnificationEnabled: false,
            magnificationSize: 64
        )

        #expect(geometry.contains(CGPoint(x: 30, y: 450)))
        #expect(!geometry.contains(CGPoint(x: 180, y: 450)))
    }

    @Test func rightDockContainsPointsNearRightEdge() {
        let geometry = DockGeometry(
            orientation: .right,
            screenFrame: screen,
            tileSize: 64,
            magnificationEnabled: false,
            magnificationSize: 64
        )

        #expect(geometry.contains(CGPoint(x: 1410, y: 450)))
        #expect(!geometry.contains(CGPoint(x: 1260, y: 450)))
    }

    @Test func magnificationExpandsDockHitArea() {
        let geometry = DockGeometry(
            orientation: .bottom,
            screenFrame: screen,
            tileSize: 48,
            magnificationEnabled: true,
            magnificationSize: 128
        )

        #expect(geometry.activeDockThickness == 176)
        #expect(geometry.contains(CGPoint(x: 720, y: 170)))
    }

    @Test func pointsOutsideScreenAreRejected() {
        let geometry = DockGeometry(
            orientation: .bottom,
            screenFrame: screen,
            tileSize: 64,
            magnificationEnabled: false,
            magnificationSize: 64
        )

        #expect(!geometry.contains(CGPoint(x: 720, y: -1)))
        #expect(!geometry.contains(CGPoint(x: 1500, y: 40)))
    }
}
