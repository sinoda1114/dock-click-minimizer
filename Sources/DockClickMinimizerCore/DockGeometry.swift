import CoreGraphics

public enum DockOrientation: String, Sendable {
    case bottom
    case left
    case right
}

public struct DockGeometry: Sendable {
    public let orientation: DockOrientation
    public let screenFrame: CGRect
    public let tileSize: CGFloat
    public let magnificationEnabled: Bool
    public let magnificationSize: CGFloat

    public init(
        orientation: DockOrientation,
        screenFrame: CGRect,
        tileSize: CGFloat,
        magnificationEnabled: Bool,
        magnificationSize: CGFloat
    ) {
        self.orientation = orientation
        self.screenFrame = screenFrame
        self.tileSize = tileSize
        self.magnificationEnabled = magnificationEnabled
        self.magnificationSize = magnificationSize
    }

    public var activeDockThickness: CGFloat {
        let largestIcon = magnificationEnabled ? max(tileSize, magnificationSize) : tileSize
        return max(largestIcon + 48, 96)
    }

    public func contains(_ point: CGPoint) -> Bool {
        guard screenFrame.contains(point) else {
            return false
        }

        switch orientation {
        case .left:
            return point.x <= screenFrame.minX + activeDockThickness
        case .right:
            return point.x >= screenFrame.maxX - activeDockThickness
        case .bottom:
            return point.y <= screenFrame.minY + activeDockThickness
        }
    }
}
