import AllwardCore
import Foundation

public enum SplitOrientation: String, Codable, Hashable, Sendable, CaseIterable { case horizontal, vertical }
public enum FocusDirection: String, Codable, Hashable, Sendable, CaseIterable { case left, right, up, down }
public enum SplitBranch: String, Codable, Hashable, Sendable { case first, second }

public struct SplitPath: Codable, Hashable, Sendable {
    public var branches: [SplitBranch]
    public init(_ branches: [SplitBranch] = []) { self.branches = branches }
}

public enum SplitTreeError: Error, Equatable, Sendable {
    case paneNotFound(PaneID)
    case duplicatePane(PaneID)
    case invalidRatio(Double)
    case dividerNotFound(SplitPath)
}

public struct SplitChildren: Codable, Hashable, Sendable {
    public var first: SplitTree
    public var second: SplitTree
    public init(first: SplitTree, second: SplitTree) { self.first = first; self.second = second }
}

public indirect enum SplitTree: Codable, Hashable, Sendable {
    case leaf(PaneID)
    case split(orientation: SplitOrientation, ratio: Double, children: SplitChildren)

    public var leaves: [PaneID] {
        switch self {
        case let .leaf(pane): [pane]
        case let .split(_, _, children): children.first.leaves + children.second.leaves
        }
    }

    public func splitting(
        pane: PaneID,
        newPane: PaneID,
        orientation: SplitOrientation,
        ratio: Double = 0.5
    ) throws -> SplitTree {
        try Self.validate(ratio)
        guard !leaves.contains(newPane) else { throw SplitTreeError.duplicatePane(newPane) }
        switch self {
        case let .leaf(current) where current == pane:
            return .split(
                orientation: orientation,
                ratio: ratio,
                children: SplitChildren(first: .leaf(current), second: .leaf(newPane))
            )
        case .leaf:
            throw SplitTreeError.paneNotFound(pane)
        case let .split(axis, currentRatio, children):
            if children.first.leaves.contains(pane) {
                return .split(
                    orientation: axis,
                    ratio: currentRatio,
                    children: SplitChildren(
                        first: try children.first.splitting(
                            pane: pane,
                            newPane: newPane,
                            orientation: orientation,
                            ratio: ratio
                        ),
                        second: children.second
                    )
                )
            }
            if children.second.leaves.contains(pane) {
                return .split(
                    orientation: axis,
                    ratio: currentRatio,
                    children: SplitChildren(
                        first: children.first,
                        second: try children.second.splitting(
                            pane: pane,
                            newPane: newPane,
                            orientation: orientation,
                            ratio: ratio
                        )
                    )
                )
            }
            throw SplitTreeError.paneNotFound(pane)
        }
    }

    public func closing(pane: PaneID) throws -> SplitTree? {
        switch self {
        case let .leaf(current):
            guard current == pane else { throw SplitTreeError.paneNotFound(pane) }
            return nil
        case let .split(orientation, ratio, children):
            if children.first.leaves.contains(pane) {
                guard let remaining = try children.first.closing(pane: pane) else { return children.second }
                return .split(
                    orientation: orientation,
                    ratio: ratio,
                    children: SplitChildren(first: remaining, second: children.second)
                )
            }
            if children.second.leaves.contains(pane) {
                guard let remaining = try children.second.closing(pane: pane) else { return children.first }
                return .split(
                    orientation: orientation,
                    ratio: ratio,
                    children: SplitChildren(first: children.first, second: remaining)
                )
            }
            throw SplitTreeError.paneNotFound(pane)
        }
    }

    public func focus(from pane: PaneID, moving direction: FocusDirection) -> PaneID? {
        let placements = leafPlacements()
        guard let source = placements.first(where: { $0.pane == pane }) else { return nil }
        return placements
            .filter { $0.pane != pane && $0.rect.isCandidate(in: direction, from: source.rect) }
            .min { lhs, rhs in
                let left = lhs.rect.score(in: direction, from: source.rect)
                let right = rhs.rect.score(in: direction, from: source.rect)
                return left == right ? lhs.order < rhs.order : left < right
            }?
            .pane
    }

    public func resizingDivider(at path: SplitPath, to ratio: Double) throws -> SplitTree {
        try Self.validate(ratio)
        return try replacingDivider(at: path.branches[...], ratio: ratio)
    }

    public func resizingDivider(at path: SplitPath, by delta: Double) throws -> SplitTree {
        let current = try dividerRatio(at: path.branches[...])
        return try resizingDivider(at: path, to: min(0.95, max(0.05, current + delta)))
    }

    public var description: SplitTreeDescription {
        switch self {
        case let .leaf(pane): .leaf(pane)
        case let .split(orientation, ratio, children):
            .split(
                orientation: orientation,
                ratio: ratio,
                children: SplitDescriptionChildren(
                    first: children.first.description,
                    second: children.second.description
                )
            )
        }
    }

    public static func restore(from description: SplitTreeDescription) throws -> SplitTree {
        let tree = try restoreNode(description)
        var seen = Set<PaneID>()
        for pane in tree.leaves {
            guard seen.insert(pane).inserted else { throw SplitTreeError.duplicatePane(pane) }
        }
        return tree
    }

    private static func restoreNode(_ description: SplitTreeDescription) throws -> SplitTree {
        switch description {
        case let .leaf(pane): return .leaf(pane)
        case let .split(orientation, ratio, children):
            try validate(ratio)
            return .split(
                orientation: orientation,
                ratio: ratio,
                children: SplitChildren(
                    first: try restoreNode(children.first),
                    second: try restoreNode(children.second)
                )
            )
        }
    }

    private static func validate(_ ratio: Double) throws {
        guard ratio.isFinite, (0.05 ... 0.95).contains(ratio) else {
            throw SplitTreeError.invalidRatio(ratio)
        }
    }

    private func replacingDivider(at path: ArraySlice<SplitBranch>, ratio: Double) throws -> SplitTree {
        guard case let .split(orientation, currentRatio, children) = self else {
            throw SplitTreeError.dividerNotFound(SplitPath(Array(path)))
        }
        guard let branch = path.first else {
            return .split(orientation: orientation, ratio: ratio, children: children)
        }
        switch branch {
        case .first:
            return .split(
                orientation: orientation,
                ratio: currentRatio,
                children: SplitChildren(
                    first: try children.first.replacingDivider(at: path.dropFirst(), ratio: ratio),
                    second: children.second
                )
            )
        case .second:
            return .split(
                orientation: orientation,
                ratio: currentRatio,
                children: SplitChildren(
                    first: children.first,
                    second: try children.second.replacingDivider(at: path.dropFirst(), ratio: ratio)
                )
            )
        }
    }

    private func dividerRatio(at path: ArraySlice<SplitBranch>) throws -> Double {
        guard case let .split(_, ratio, children) = self else {
            throw SplitTreeError.dividerNotFound(SplitPath(Array(path)))
        }
        guard let branch = path.first else { return ratio }
        switch branch {
        case .first: return try children.first.dividerRatio(at: path.dropFirst())
        case .second: return try children.second.dividerRatio(at: path.dropFirst())
        }
    }

    private func leafPlacements() -> [LeafPlacement] {
        var result: [LeafPlacement] = []
        appendPlacements(in: UnitRect(x: 0, y: 0, width: 1, height: 1), to: &result)
        return result
    }

    private func appendPlacements(in rect: UnitRect, to result: inout [LeafPlacement]) {
        switch self {
        case let .leaf(pane):
            result.append(LeafPlacement(pane: pane, rect: rect, order: result.count))
        case let .split(orientation, ratio, children):
            let divided = rect.divided(orientation: orientation, ratio: ratio)
            children.first.appendPlacements(in: divided.first, to: &result)
            children.second.appendPlacements(in: divided.second, to: &result)
        }
    }
}

public struct SplitDescriptionChildren: Codable, Hashable, Sendable {
    public var first: SplitTreeDescription
    public var second: SplitTreeDescription
    public init(first: SplitTreeDescription, second: SplitTreeDescription) {
        self.first = first; self.second = second
    }
}

public indirect enum SplitTreeDescription: Codable, Hashable, Sendable {
    case leaf(PaneID)
    case split(orientation: SplitOrientation, ratio: Double, children: SplitDescriptionChildren)
}

private struct LeafPlacement { var pane: PaneID; var rect: UnitRect; var order: Int }

private struct DirectionScore: Comparable {
    var primary: Double
    var orthogonalGap: Double
    var orthogonalCentreDistance: Double

    static func < (lhs: DirectionScore, rhs: DirectionScore) -> Bool {
        if lhs.primary != rhs.primary { return lhs.primary < rhs.primary }
        if lhs.orthogonalGap != rhs.orthogonalGap { return lhs.orthogonalGap < rhs.orthogonalGap }
        return lhs.orthogonalCentreDistance < rhs.orthogonalCentreDistance
    }
}

private struct UnitRect {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var minX: Double { x }
    var maxX: Double { x + width }
    var minY: Double { y }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }

    func divided(orientation: SplitOrientation, ratio: Double) -> (first: UnitRect, second: UnitRect) {
        switch orientation {
        case .horizontal:
            let firstWidth = width * ratio
            return (
                UnitRect(x: x, y: y, width: firstWidth, height: height),
                UnitRect(x: x + firstWidth, y: y, width: width - firstWidth, height: height)
            )
        case .vertical:
            let firstHeight = height * ratio
            return (
                UnitRect(x: x, y: y, width: width, height: firstHeight),
                UnitRect(x: x, y: y + firstHeight, width: width, height: height - firstHeight)
            )
        }
    }

    func isCandidate(in direction: FocusDirection, from source: UnitRect) -> Bool {
        switch direction {
        case .left: midX < source.midX
        case .right: midX > source.midX
        case .up: midY < source.midY
        case .down: midY > source.midY
        }
    }

    func score(in direction: FocusDirection, from source: UnitRect) -> DirectionScore {
        switch direction {
        case .left:
            DirectionScore(
                primary: max(0, source.minX - maxX),
                orthogonalGap: intervalGap(minY, maxY, source.minY, source.maxY),
                orthogonalCentreDistance: abs(midY - source.midY)
            )
        case .right:
            DirectionScore(
                primary: max(0, minX - source.maxX),
                orthogonalGap: intervalGap(minY, maxY, source.minY, source.maxY),
                orthogonalCentreDistance: abs(midY - source.midY)
            )
        case .up:
            DirectionScore(
                primary: max(0, source.minY - maxY),
                orthogonalGap: intervalGap(minX, maxX, source.minX, source.maxX),
                orthogonalCentreDistance: abs(midX - source.midX)
            )
        case .down:
            DirectionScore(
                primary: max(0, minY - source.maxY),
                orthogonalGap: intervalGap(minX, maxX, source.minX, source.maxX),
                orthogonalCentreDistance: abs(midX - source.midX)
            )
        }
    }

    private func intervalGap(_ aMin: Double, _ aMax: Double, _ bMin: Double, _ bMax: Double) -> Double {
        max(0, max(aMin, bMin) - min(aMax, bMax))
    }
}
