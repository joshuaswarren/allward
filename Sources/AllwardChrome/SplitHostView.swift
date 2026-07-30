import AllwardCore
import AllwardDesign
import AppKit
import SwiftUI

/// The layout Chrome renders. It is derived from the control layer's split tree
/// but kept local so the view has one narrow input and no knowledge of how the
/// tree is edited.
public indirect enum PaneLayoutNode: Hashable, Sendable {
    case leaf(PaneID)
    case split(axis: PaneSplitAxis, ratio: Double, first: PaneLayoutNode, second: PaneLayoutNode)

    public var leaves: [PaneID] {
        switch self {
        case .leaf(let pane): [pane]
        case .split(_, _, let first, let second): first.leaves + second.leaves
        }
    }
}

public enum PaneSplitAxis: String, Hashable, Sendable, Codable {
    /// Children sit side by side.
    case horizontal
    /// Children stack vertically.
    case vertical
}

@MainActor
public protocol SplitHostDelegate: AnyObject {
    /// A divider was dragged. The host reports the new ratio for the node at
    /// `path`; the model owns the tree and publishes the next layout.
    func splitHost(_ host: SplitHostView, didResizeNodeAt path: [Int], to ratio: Double)
}

/// Lays out pane containers over an Allward-owned split tree. An adapter's
/// internal layout stays opaque: a herdr workspace compositor is one leaf.
@MainActor
public final class SplitHostView: NSView {
    public weak var delegate: (any SplitHostDelegate)?
    public var palette: DesignPalette { didSet { needsLayout = true } }

    private var layoutTree: PaneLayoutNode?
    private var containers: [PaneID: PaneContainerView] = [:]
    private var dividers: [DividerView] = []

    public init(palette: DesignPalette) {
        self.palette = palette
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SplitHostView is code-only") }

    public override var isFlipped: Bool { true }

    /// Registers the container for each pane. Containers are owned by the model
    /// so a pane keeps its terminal across layout changes.
    public func setContainers(_ newContainers: [PaneID: PaneContainerView]) {
        for (_, container) in containers where container.superview === self {
            container.removeFromSuperview()
        }
        containers = newContainers
        needsLayout = true
    }

    public func setLayout(_ newLayout: PaneLayoutNode?) {
        layoutTree = newLayout
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        for divider in dividers { divider.removeFromSuperview() }
        dividers.removeAll(keepingCapacity: true)
        for (_, container) in containers where container.superview === self {
            container.removeFromSuperview()
        }
        guard let layoutTree else { return }
        place(layoutTree, in: bounds, path: [])
    }

    private var dividerThickness: CGFloat { 1 }
    /// A wider invisible hit area keeps a one-pixel seam draggable.
    private var dividerHitSlop: CGFloat { 3 }

    private func place(_ node: PaneLayoutNode, in rect: CGRect, path: [Int]) {
        switch node {
        case .leaf(let pane):
            guard let container = containers[pane] else { return }
            container.frame = rect.integral
            addSubview(container)
        case .split(let axis, let ratio, let first, let second):
            let clamped = min(max(ratio, 0.08), 0.92)
            let (firstRect, dividerRect, secondRect) = divide(rect, axis: axis, ratio: clamped)
            place(first, in: firstRect, path: path + [0])
            let divider = DividerView(
                axis: axis, color: palette[.strokeDivider].nsColor, hitSlop: dividerHitSlop
            ) { [weak self] delta in
                guard let self else { return }
                let span = axis == .horizontal ? rect.width : rect.height
                guard span > 0 else { return }
                let next = clamped + Double(delta / span)
                self.delegate?.splitHost(self, didResizeNodeAt: path, to: next)
            }
            divider.frame = dividerRect
            addSubview(divider)
            dividers.append(divider)
            place(second, in: secondRect, path: path + [1])
        }
    }

    private func divide(_ rect: CGRect, axis: PaneSplitAxis, ratio: Double) -> (
        CGRect, CGRect, CGRect
    ) {
        switch axis {
        case .horizontal:
            let firstWidth = ((rect.width - dividerThickness) * ratio).rounded()
            let first = CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height)
            let divider = CGRect(
                x: first.maxX, y: rect.minY, width: dividerThickness, height: rect.height)
            let second = CGRect(
                x: divider.maxX, y: rect.minY, width: rect.maxX - divider.maxX,
                height: rect.height)
            return (first, divider, second)
        case .vertical:
            let firstHeight = ((rect.height - dividerThickness) * ratio).rounded()
            let first = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight)
            let divider = CGRect(
                x: rect.minX, y: first.maxY, width: rect.width, height: dividerThickness)
            let second = CGRect(
                x: rect.minX, y: divider.maxY, width: rect.width,
                height: rect.maxY - divider.maxY)
            return (first, divider, second)
        }
    }
}

/// One pane: a reserved header band above a terminal surface. The band is part
/// of the same geometry transaction as the split, so populating it never
/// resizes the grid (DESIGN-LANGUAGE §23.1).
@MainActor
public final class PaneContainerView: NSView {
    public let paneID: PaneID
    public let terminal: TerminalPaneView
    private let headerHost: NSHostingView<AnyView>
    private var headerVisible = false

    public init(paneID: PaneID, terminal: TerminalPaneView) {
        self.paneID = paneID
        self.terminal = terminal
        self.headerHost = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: .zero)
        wantsLayer = true
        headerHost.isHidden = true
        addSubview(headerHost)
        addSubview(terminal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PaneContainerView is code-only") }

    public override var isFlipped: Bool { true }

    public func setHeader(_ model: PaneHeaderModel?, palette: DesignPalette, focused: Bool) {
        guard let model else {
            headerVisible = false
            headerHost.isHidden = true
            needsLayout = true
            return
        }
        headerVisible = true
        headerHost.isHidden = false
        headerHost.rootView = AnyView(
            PaneHeaderView(model: model, isFocused: focused).allwardPalette(palette))
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let headerHeight = headerVisible ? headerHost.fittingSize.height : 0
        headerHost.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        terminal.frame = CGRect(
            x: 0, y: headerHeight, width: bounds.width,
            height: max(0, bounds.height - headerHeight))
    }
}

/// A structural seam, not a card border. It shows a resize cursor and drags.
@MainActor
final class DividerView: NSView {
    private let axis: PaneSplitAxis
    private let hitSlop: CGFloat
    private let onDrag: (CGFloat) -> Void
    private var dragOrigin: CGPoint?

    init(
        axis: PaneSplitAxis, color: NSColor, hitSlop: CGFloat,
        onDrag: @escaping (CGFloat) -> Void
    ) {
        self.axis = axis
        self.hitSlop = hitSlop
        self.onDrag = onDrag
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("DividerView is code-only") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let expanded = frame.insetBy(
            dx: axis == .horizontal ? -hitSlop : 0, dy: axis == .vertical ? -hitSlop : 0)
        return expanded.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        let cursor: NSCursor = axis == .horizontal ? .resizeLeftRight : .resizeUpDown
        addCursorRect(bounds.insetBy(dx: -hitSlop, dy: -hitSlop), cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = axis == .horizontal ? point.x - dragOrigin.x : point.y - dragOrigin.y
        guard delta != 0 else { return }
        onDrag(delta)
    }

    override func mouseUp(with event: NSEvent) { dragOrigin = nil }
}
