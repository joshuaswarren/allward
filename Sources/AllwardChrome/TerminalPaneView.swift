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

    /// A bell the user can hear *and* see.
    ///
    /// macOS offers "Flash the screen when an alert sound occurs" precisely
    /// because an audible-only bell is invisible to a deaf user, and a terminal
    /// that only beeps is unusable with the sound off. The flash is a static
    /// tint rather than an animation so Reduce Motion needs no special case.
    private func ringBell() {
        NSSound.beep()
        bellFlash.frame = bounds
        bellFlash.backgroundColor = palette[.strokeKeyboardFocus].withAlpha(0.22).cgColor
        bellFlash.isHidden = false
        bellFlashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.bellFlash.isHidden = true }
        bellFlashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// The focus ring, guaranteed legible against the grid it is drawn on.
    ///
    /// The chrome palette answers to the system appearance while the grid
    /// answers to the Room, so the two can disagree: the dark chrome ring on
    /// the light theme measures 1.90:1, well under the 3:1 WCAG 1.4.11 sets for
    /// a focus indicator. The token is used as the starting point and moved
    /// toward whichever pole clears the floor.
    static func focusRingColor(
        palette: DesignPalette, theme: TerminalTheme, floor: Double = 3
    ) -> TokenColor {
        let background = theme.defaultBackground
        let token = palette[.strokeKeyboardFocus]
        guard token.contrastRatio(against: background) < floor else { return token }
        let pole =
            background.relativeLuminance > 0.5
            ? TokenColor(0, 0, 0) : TokenColor(1, 1, 1)
        var low = 0.0
        var high = 1.0
        for _ in 0 ..< 12 {
            let mid = (low + high) / 2
            if token.mixed(with: pole, amount: mid).contrastRatio(against: background) < floor {
                low = mid
            } else {
                high = mid
            }
        }
        return token.mixed(with: pole, amount: high)
    }

    /// The ring that marks the focused pane.
    ///
    /// It used to be four flat rectangles inside the Metal scene, which made it
    /// square by construction and flush against the first character. A layer
    /// rounds properly, sits outside the grid so the text has room to breathe,
    /// and keeps the render path to glyphs.
    private let focusRing = CALayer()
    private let bellFlash = CALayer()
    private var bellFlashWork: DispatchWorkItem?
    private var fontFamily: String?
    private var fontSize: Double
    private var trackingAreaRef: NSTrackingArea?
    private var pendingMouseButton: Int?

    /// Breathing room between the window edge and the first cell. Every mature
    /// terminal has it; without it the first column collides with the frame and
    /// the window reads as broken rather than dense.
    public var gridInsets = NSEdgeInsets(top: 13, left: 17, bottom: 13, right: 17) {
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
        focusRing.borderWidth = 1
        focusRing.cornerRadius = 8
        focusRing.cornerCurve = .continuous
        focusRing.isHidden = true
        layer?.addSublayer(focusRing)
        bellFlash.isHidden = true
        layer?.addSublayer(bellFlash)
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
        // The ring hugs the pane, not the grid, so the inset above becomes
        // clear space between the ring and the first character.
        focusRing.frame = bounds.insetBy(dx: 4, dy: 4)
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
    public static let gridInsetSize = NSSize(width: 34, height: 26)

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
        let previousBell = self.snapshot?.bellCount ?? snapshot.bellCount
        self.snapshot = snapshot
        if snapshot.bellCount > previousBell { ringBell() }
        isPaneFocused = focused
        metalLayer.opacity = focused ? 1 : Self.unfocusedOpacity
        focusRing.isHidden = focused == false
        focusRing.borderColor = Self.focusRingColor(palette: palette, theme: theme).cgColor
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

    /// Sends a control byte, the way the keyboard would. Clearing the screen
    /// belongs to the shell, so it receives the key rather than the emulator
    /// wiping a grid the shell still believes is full.
    public func sendControl(_ character: Character) {
        guard let ascii = character.asciiValue else { return }
        delegate?.pane(self, send: [ascii & 0x1f])
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

    /// Rebuilt when the snapshot changes, because every text query below is
    /// answered in character offsets and recomputing them per query would make
    /// VoiceOver navigation quadratic in the size of the screen.
    private var textProjection: TerminalTextProjection = .empty
    private var pendingAnnouncement: DispatchWorkItem?

    public override func accessibilityValue() -> Any? { textProjection.text }

    public override func accessibilityNumberOfCharacters() -> Int {
        textProjection.text.utf16.count
    }

    public override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: textProjection.text.utf16.count)
    }

    // MARK: Line navigation
    //
    // VoiceOver reads a terminal line by line. Without these it can only read
    // the screen as one undifferentiated paragraph.

    public override func accessibilityLine(for index: Int) -> Int {
        textProjection.line(for: index)
    }

    public override func accessibilityRange(forLine line: Int) -> NSRange {
        textProjection.range(forLine: line)
    }

    public override func accessibilityString(for range: NSRange) -> String? {
        textProjection.string(for: range)
    }

    public override func accessibilityRange(for index: Int) -> NSRange {
        textProjection.range(forLine: textProjection.line(for: index))
    }

    // MARK: Cursor and selection

    public override func accessibilityInsertionPointLineNumber() -> Int {
        textProjection.cursorLine
    }

    public override func accessibilitySelectedTextRange() -> NSRange {
        textProjection.selectedRange ?? textProjection.cursorRange
    }

    public override func accessibilitySelectedTextRanges() -> [NSValue]? {
        [NSValue(range: accessibilitySelectedTextRange())]
    }

    public override func accessibilitySelectedText() -> String? {
        guard let range = textProjection.selectedRange else { return nil }
        return textProjection.string(for: range)
    }

    /// Where a range of characters sits on screen, in screen coordinates, so
    /// VoiceOver's cursor can track what it is reading.
    public override func accessibilityFrame(for range: NSRange) -> NSRect {
        let line = textProjection.line(for: range.location)
        let lineRange = textProjection.range(forLine: line)
        let column = max(0, range.location - lineRange.location)
        let rect = CGRect(
            x: gridRect.minX + CGFloat(column) * metrics.cellWidth / metalLayer.contentsScale,
            y: gridRect.minY + CGFloat(line) * metrics.cellHeight / metalLayer.contentsScale,
            width: CGFloat(max(1, range.length)) * metrics.cellWidth / metalLayer.contentsScale,
            height: metrics.cellHeight / metalLayer.contentsScale)
        return window?.convertToScreen(convert(rect, to: nil)) ?? rect
    }

    /// Output arrives per frame, and announcing every frame makes VoiceOver
    /// stutter continuously through anything verbose. DESIGN-LANGUAGE §24.2
    /// requires bursts to be coalesced and forbids per-frame announcements, so
    /// content changes are collapsed onto a trailing tick while cursor and
    /// selection movement — which the user caused and is waiting on — go out
    /// immediately.
    private static let announcementInterval: TimeInterval = 0.4

    private func setAccessibilityNeedsRefresh() {
        let previous = textProjection
        textProjection = snapshot.map(TerminalTextProjection.init) ?? .empty

        if textProjection.selectedRange != previous.selectedRange {
            NSAccessibility.post(element: self, notification: .selectedTextChanged)
        }
        if textProjection.cursorRange != previous.cursorRange {
            NSAccessibility.post(element: self, notification: .selectedTextChanged)
        }
        guard textProjection.text != previous.text else { return }
        scheduleContentAnnouncement()
    }

    private func scheduleContentAnnouncement() {
        guard pendingAnnouncement == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingAnnouncement = nil
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
        pendingAnnouncement = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.announcementInterval, execute: work)
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
