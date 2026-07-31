import AllwardCore
import AllwardDesign
import AllwardRenderer
import AllwardTerminal
import AppKit

/// The terminal surface: one `CAMetalLayer`, one snapshot generation, one input
/// target. SwiftUI composes chrome around this view but never owns grid
/// rendering (SPEC §4).
///
/// Everything the user types goes straight to the delegate; input never waits
/// on render coalescing.
@MainActor
public protocol TerminalPaneDelegate: AnyObject {
    func pane(_ pane: TerminalPaneView, send bytes: [UInt8])
    func pane(_ pane: TerminalPaneView, resizeTo geometry: TerminalGeometry)
    func pane(_ pane: TerminalPaneView, didChangeSelection selection: Selection?)
    func paneDidBecomeFirstResponder(_ pane: TerminalPaneView)
    func paneRequestsScroll(_ pane: TerminalPaneView, byRows rows: Int)
}

@MainActor
public final class TerminalPaneView: NSView {
    public weak var delegate: (any TerminalPaneDelegate)?
    public private(set) var snapshot: TerminalSnapshot?
    public private(set) var metrics: CellMetrics

    public var palette: DesignPalette {
        didSet { renderer?.invalidatePalette(); needsDisplay = true }
    }
    public var theme: TerminalTheme {
        didSet {
            renderer?.invalidateTheme()
            layer?.backgroundColor = theme.defaultBackground.cgColor
            needsDisplay = true
        }
    }
    /// The Room tint drawn as the pane's seam. Identity stays legible without
    /// hue through the header name, so this is decoration plus reinforcement.
    public var roomTint: TokenColor?

    private var renderer: TerminalRenderer?
    private var scheduler: FrameScheduler?
    private let metalLayer = CAMetalLayer()
    private var captureLayer: CALayer?
    private var fontFamily: String?
    private var fontSize: Double
    private var trackingAreaRef: NSTrackingArea?
    private var pendingMouseButton: Int?

    /// Breathing room between the window edge and the first cell. Every mature
    /// terminal has it; without it the first column collides with the frame and
    /// the window reads as broken rather than dense.
    public var gridInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10) {
        didSet { needsLayout = true }
    }

    public init(palette: DesignPalette, theme: TerminalTheme, fontFamily: String?, fontSize: Double)
    {
        self.palette = palette
        self.theme = theme
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.metrics = FontMetrics.metrics(family: fontFamily, size: fontSize, scale: 2)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = theme.defaultBackground.cgColor
        metalLayer.isOpaque = true
        metalLayer.contentsGravity = .topLeft
        metalLayer.needsDisplayOnBoundsChange = true
        layer?.addSublayer(metalLayer)
        allowedTouchTypes = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("TerminalPaneView is code-only") }

    // MARK: Lifecycle

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var canBecomeKeyView: Bool { true }
    public override var wantsUpdateLayer: Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        let scale = window.backingScaleFactor
        metrics = FontMetrics.metrics(family: fontFamily, size: fontSize, scale: scale)
        metalLayer.contentsScale = scale
        if renderer == nil {
            let renderer = TerminalRenderer(layer: metalLayer, metrics: metrics)
            let scheduler = FrameScheduler { [weak renderer] in renderer?.render() }
            renderer.onNeedsFrame = { [weak scheduler] in scheduler?.requestFrame() }
            self.renderer = renderer
            self.scheduler = scheduler
        } else {
            renderer?.updateMetrics(metrics)
            // Returning to a window after being reparented must restart the
            // display link, or the pane goes permanently black.
            scheduler?.requestFrame()
        }
        publishGeometry()
    }

    /// Leaving the window must stop the display link, or an off-screen pane
    /// keeps submitting frames and the idle-frame budget is blown.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { scheduler?.invalidate() }
    }

    /// The rect the grid occupies, inside the padding.
    private var gridRect: CGRect {
        CGRect(
            x: gridInsets.left, y: gridInsets.top,
            width: max(1, bounds.width - gridInsets.left - gridInsets.right),
            height: max(1, bounds.height - gridInsets.top - gridInsets.bottom))
    }

    public override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? metalLayer.contentsScale
        let rect = gridRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = rect
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: max(1, rect.width * scale), height: max(1, rect.height * scale))
        layer?.backgroundColor = theme.defaultBackground.cgColor
        CATransaction.commit()
        renderer?.setDrawableSize(metalLayer.drawableSize, scale: scale)
        publishGeometry()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    /// Terminal geometry is derived from resolved font metrics, never guessed,
    /// so the renderer and the accessibility projection agree exactly.
    public var currentGeometry: TerminalGeometry {
        TerminalGeometry.fitting(
            gridRect.size, metrics: metrics, scale: metalLayer.contentsScale)
    }

    /// The insets a pane puts around its grid, so a caller sizing a shell
    /// before the view exists reaches the same answer this view will.
    public static let gridInsetSize = NSSize(width: 20, height: 12)

    private func publishGeometry() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        delegate?.pane(self, resizeTo: currentGeometry)
    }

    /// A still of the grid, shown in place of the Metal layer while the window
    /// is captured. `cacheDisplay` cannot read a `CAMetalLayer`, and
    /// compositing the grid afterwards means reimplementing AppKit's coordinate
    /// handling by hand, which put panes thirty points above where they render.
    /// A real layer is placed by the same code that places everything else.
    public func showCaptureStill(_ image: CGImage?) {
        guard let image else {
            captureLayer?.removeFromSuperlayer()
            captureLayer = nil
            metalLayer.isHidden = false
            return
        }
        let still = captureLayer ?? CALayer()
        still.contentsGravity = .resize
        still.contents = image
        still.frame = gridRect
        if still.superlayer == nil { layer?.addSublayer(still) }
        captureLayer = still
        metalLayer.isHidden = true
    }

    /// An unfocused split recedes instead of competing. Every terminal that
    /// supports splits does this; it answers "which pane am I typing into"
    /// before the eye has to hunt for a focus ring.
    public static let unfocusedOpacity: Float = 0.7

    public private(set) var isPaneFocused = true

    public func apply(_ snapshot: TerminalSnapshot, focused: Bool) {
        self.snapshot = snapshot
        isPaneFocused = focused
        metalLayer.opacity = focused ? 1 : Self.unfocusedOpacity
        renderer?.update(
            snapshot: snapshot, palette: palette, theme: theme, focused: focused)
        setAccessibilityNeedsRefresh()
    }

    public func setFont(family: String?, size: Double) {
        fontFamily = family
        fontSize = size
        metrics = FontMetrics.metrics(
            family: family, size: size, scale: metalLayer.contentsScale)
        renderer?.updateMetrics(metrics)
        publishGeometry()
    }

    // MARK: Keyboard

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            delegate?.paneDidBecomeFirstResponder(self)
            if let snapshot { apply(snapshot, focused: true) }
        }
        return became
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, let snapshot { apply(snapshot, focused: false) }
        return resigned
    }

    public override func keyDown(with event: NSEvent) {
        let modes = snapshot?.modes ?? TerminalModes()
        guard let bytes = InputEncoder.encode(keyEvent: KeyEvent(event), modes: modes) else {
            // Unmapped chords stay available to the responder chain so app
            // shortcuts keep working instead of being swallowed by the grid.
            super.keyDown(with: event)
            return
        }
        delegate?.pane(self, send: bytes)
    }

    public override func flagsChanged(with event: NSEvent) { super.flagsChanged(with: event) }

    public override func insertText(_ insertString: Any) {
        guard let text = insertString as? String else { return }
        delegate?.pane(self, send: Array(text.utf8))
    }

    /// Paste honours bracketed paste so a shell can tell typed input from a
    /// pasted block.
    public func paste(_ text: String) {
        let modes = snapshot?.modes ?? TerminalModes()
        delegate?.pane(self, send: InputEncoder.encodePaste(text, bracketed: modes.bracketedPaste))
    }

    // MARK: Mouse

    private func gridPosition(for event: NSEvent) -> (row: Int, column: Int) {
        let raw = convert(event.locationInWindow, from: nil)
        let rect = gridRect
        let point = CGPoint(x: raw.x - rect.minX, y: raw.y - rect.minY)
        let scale = metalLayer.contentsScale
        let column = Int((point.x * scale / metrics.cellWidth).rounded(.down))
        let row = Int((point.y * scale / metrics.cellHeight).rounded(.down))
        let geometry = currentGeometry
        return (
            row: min(max(0, row), geometry.rows - 1),
            column: min(max(0, column), geometry.columns - 1)
        )
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let modes = snapshot?.modes ?? TerminalModes()
        let position = gridPosition(for: event)
        if modes.mouseTracking != .off,
            let bytes = InputEncoder.encode(
                mouseButton: 0, pressed: true, row: position.row, column: position.column,
                modifiers: KeyModifiers(event.modifierFlags), modes: modes)
        {
            pendingMouseButton = 0
            delegate?.pane(self, send: bytes)
            return
        }
        beginSelection(at: position, extending: event.modifierFlags.contains(.shift))
    }

    public override func mouseDragged(with event: NSEvent) {
        let modes = snapshot?.modes ?? TerminalModes()
        let position = gridPosition(for: event)
        if let button = pendingMouseButton, modes.mouseTracking == .buttonMotion
            || modes.mouseTracking == .anyMotion
        {
            if let bytes = InputEncoder.encode(
                mouseMotion: button, row: position.row, column: position.column,
                modifiers: KeyModifiers(event.modifierFlags), modes: modes)
            {
                delegate?.pane(self, send: bytes)
            }
            return
        }
        extendSelection(to: position)
    }

    public override func mouseUp(with event: NSEvent) {
        let modes = snapshot?.modes ?? TerminalModes()
        let position = gridPosition(for: event)
        if let button = pendingMouseButton {
            pendingMouseButton = nil
            if let bytes = InputEncoder.encode(
                mouseButton: button, pressed: false, row: position.row, column: position.column,
                modifiers: KeyModifiers(event.modifierFlags), modes: modes)
            {
                delegate?.pane(self, send: bytes)
            }
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        let lines = Int(event.scrollingDeltaY.rounded())
        guard lines != 0 else { return }
        delegate?.paneRequestsScroll(self, byRows: lines)
    }

    private var selectionOrigin: SelectionAnchor?

    private func anchor(at position: (row: Int, column: Int)) -> SelectionAnchor? {
        guard let snapshot, snapshot.rowIDs.indices.contains(position.row) else { return nil }
        return SelectionAnchor(
            line: snapshot.rowIDs[position.row], graphemeOffset: position.column)
    }

    private func beginSelection(at position: (row: Int, column: Int), extending: Bool) {
        guard let anchor = anchor(at: position) else { return }
        if extending, let origin = selectionOrigin {
            delegate?.pane(self, didChangeSelection: Selection(start: origin, end: anchor))
        } else {
            selectionOrigin = anchor
            delegate?.pane(self, didChangeSelection: nil)
        }
    }

    private func extendSelection(to position: (row: Int, column: Int)) {
        guard let origin = selectionOrigin, let anchor = anchor(at: position) else { return }
        delegate?.pane(self, didChangeSelection: Selection(start: origin, end: anchor))
    }

    // MARK: Accessibility

    /// The grid is projected as static text rather than a custom control tree:
    /// VoiceOver reads real rows, and the projection uses the same resolved
    /// metrics as the renderer (DESIGN-LANGUAGE §24.1).
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    public override func accessibilityLabel() -> String? { snapshot?.title ?? "Terminal" }

    public override func accessibilityValue() -> Any? {
        guard let snapshot else { return "" }
        return (0..<snapshot.geometry.rows).map { snapshot.plainText(row: $0) }
            .joined(separator: "\n")
    }

    public override func accessibilityNumberOfCharacters() -> Int {
        (accessibilityValue() as? String)?.count ?? 0
    }

    private func setAccessibilityNeedsRefresh() {
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
}

/// The subset of an `NSEvent` the encoder needs, so key handling stays testable
/// without constructing AppKit events.
extension KeyEvent {
    init(_ event: NSEvent) {
        self.init(
            characters: event.charactersIgnoringModifiers ?? "",
            keyCode: event.keyCode,
            shift: event.modifierFlags.contains(.shift),
            control: event.modifierFlags.contains(.control),
            option: event.modifierFlags.contains(.option),
            command: event.modifierFlags.contains(.command)
        )
    }
}

extension KeyModifiers {
    /// AllwardTerminal stays AppKit-free so the engine still builds on Linux;
    /// the conversion belongs here, the only place AppKit events exist.
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self = modifiers
    }
}
