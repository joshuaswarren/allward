import AllwardDesign
import AllwardTerminal
import CoreGraphics
import Metal
import QuartzCore

@MainActor
public final class TerminalRenderer {
    public var onNeedsFrame: (@MainActor () -> Void)?

    private struct RenderState {
        let snapshot: TerminalSnapshot
        let palette: DesignPalette
        let theme: TerminalTheme
        let focused: Bool
    }

    private struct DrawableConfiguration {
        let size: CGSize
        let scale: CGFloat
    }

    private let layer: CAMetalLayer
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelines: MetalPipelines
    private var metrics: CellMetrics
    private var sceneBuilder: SceneBuilder
    private var monochromeAtlas: GlyphAtlas
    private var colorAtlas: GlyphAtlas
    private var resources = MetalSceneResources()
    private var currentState: RenderState?
    private var currentScene: TerminalScene?
    private var pendingState: RenderState?
    private var atlasDamagedRows = IndexSet()
    private var forceFullRedraw = true
    private var pendingDrawableConfiguration: DrawableConfiguration?
    private var appliedDrawableSize: CGSize

    public init(layer: CAMetalLayer, metrics: CellMetrics) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else {
            preconditionFailure("Allward requires a Metal device")
        }
        self.layer = layer
        self.device = device
        self.commandQueue = commandQueue
        self.metrics = metrics
        appliedDrawableSize = layer.drawableSize
        sceneBuilder = SceneBuilder(metrics: metrics)
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        do {
            pipelines = try MetalPipelines(device: device, pixelFormat: layer.pixelFormat)
        } catch {
            preconditionFailure("Metal shader compilation failed: \(error)")
        }
        monochromeAtlas = GlyphAtlas(device: device, metrics: metrics, kind: .monochrome)
        colorAtlas = GlyphAtlas(device: device, metrics: metrics, kind: .color)
        connectAtlasCallbacks()
    }

    public func update(
        snapshot: TerminalSnapshot,
        palette: DesignPalette,
        theme: TerminalTheme,
        focused: Bool
    ) {
        if let pendingState, pendingState.snapshot.generation > snapshot.generation {
            return
        }
        var newestSnapshot = snapshot
        if let pendingState {
            newestSnapshot.damage = mergedDamage(pendingState.snapshot.damage, snapshot.damage)
        }
        pendingState = RenderState(snapshot: newestSnapshot, palette: palette, theme: theme, focused: focused)
        onNeedsFrame?()
    }

    public func updateMetrics(_ metrics: CellMetrics) {
        guard self.metrics != metrics else { return }
        self.metrics = metrics
        sceneBuilder = SceneBuilder(metrics: metrics)
        monochromeAtlas.rowsDidChange = nil
        colorAtlas.rowsDidChange = nil
        monochromeAtlas = GlyphAtlas(device: device, metrics: metrics, kind: .monochrome)
        colorAtlas = GlyphAtlas(device: device, metrics: metrics, kind: .color)
        resources = MetalSceneResources()
        atlasDamagedRows.removeAll()
        connectAtlasCallbacks()
        forceFullRedraw = true
        if pendingState == nil {
            pendingState = currentState
        }
        onNeedsFrame?()
    }

    public func setDrawableSize(_ size: CGSize, scale: CGFloat) {
        pendingDrawableConfiguration = DrawableConfiguration(
            size: size,
            scale: max(1, scale)
        )
        layer.drawableSize = appliedDrawableSize
        forceFullRedraw = true
    }

    public func invalidatePalette() {
        invalidateResources()
    }

    public func invalidateTheme() {
        invalidateResources()
    }

    public func render() {
        applyPendingState()
        applyAtlasDamage()
        guard let state = currentState,
              let scene = currentScene,
              let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let background = state.theme.defaultBackground
        pipelines.encode(
            scene: scene,
            resources: resources,
            target: drawable.texture,
            commandBuffer: commandBuffer,
            monochromeAtlas: monochromeAtlas,
            colorAtlas: colorAtlas,
            clearColor: SIMD4(
                Float(background.red),
                Float(background.green),
                Float(background.blue),
                Float(background.alpha)
            )
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func invalidateResources() {
        forceFullRedraw = true
        if pendingState == nil, pendingDrawableConfiguration == nil {
            pendingState = currentState
            onNeedsFrame?()
        }
    }

    private func applyPendingState() {
        guard let next = pendingState else { return }
        pendingState = nil
        applyDrawableConfiguration()
        let previous = currentState
        var fullRedraw = forceFullRedraw
            || next.snapshot.damage.fullRedraw
            || previous == nil
            || previous?.snapshot.geometry != next.snapshot.geometry
            || previous?.palette != next.palette
            || previous?.theme != next.theme
            || previous?.focused != next.focused
        let scene = sceneBuilder.build(
            snapshot: next.snapshot,
            palette: next.palette,
            theme: next.theme,
            focused: next.focused
        )
        if ensureAtlasCapacity(for: scene) {
            fullRedraw = true
        }
        let damagedRows = fullRedraw
            ? IndexSet(integersIn: scene.rows.indices)
            : rowsToUpload(next: next, previous: previous, rowCount: scene.rows.count)
        resources.update(
            scene: scene,
            rowIndices: damagedRows,
            device: device,
            monochromeAtlas: monochromeAtlas,
            colorAtlas: colorAtlas
        )
        currentState = next
        currentScene = scene
        forceFullRedraw = false
        atlasDamagedRows.subtract(damagedRows)
    }

    private func ensureAtlasCapacity(for scene: TerminalScene) -> Bool {
        let requests = scene.glyphRequests
        let monochromeBudget = GlyphAtlas.workingSetBudget(
            requests: requests,
            metrics: metrics,
            kind: .monochrome
        )
        let colorBudget = GlyphAtlas.workingSetBudget(
            requests: requests,
            metrics: metrics,
            kind: .color
        )
        var changed = false
        if monochromeBudget > monochromeAtlas.capacityBytes {
            monochromeAtlas.rowsDidChange = nil
            monochromeAtlas = GlyphAtlas(
                device: device,
                metrics: metrics,
                kind: .monochrome,
                budgetBytes: monochromeBudget,
                maximumDimension: 8_192
            )
            changed = true
        }
        if colorBudget > colorAtlas.capacityBytes {
            colorAtlas.rowsDidChange = nil
            colorAtlas = GlyphAtlas(
                device: device,
                metrics: metrics,
                kind: .color,
                budgetBytes: colorBudget,
                maximumDimension: 8_192
            )
            changed = true
        }
        if changed {
            resources = MetalSceneResources()
            atlasDamagedRows.removeAll()
            connectAtlasCallbacks()
        }
        return changed
    }

    private func applyDrawableConfiguration() {
        guard let configuration = pendingDrawableConfiguration else { return }
        pendingDrawableConfiguration = nil
        layer.contentsScale = configuration.scale
        layer.drawableSize = configuration.size
        appliedDrawableSize = configuration.size
    }

    private func applyAtlasDamage() {
        guard !atlasDamagedRows.isEmpty,
              let state = currentState
        else { return }
        let scene = sceneBuilder.build(
            snapshot: state.snapshot,
            palette: state.palette,
            theme: state.theme,
            focused: state.focused
        )
        let validRows = IndexSet(atlasDamagedRows.filter { scene.rows.indices.contains($0) })
        resources.update(
            scene: scene,
            rowIndices: validRows,
            device: device,
            monochromeAtlas: monochromeAtlas,
            colorAtlas: colorAtlas
        )
        currentScene = scene
        atlasDamagedRows.removeAll()
    }

    private func rowsToUpload(next: RenderState, previous: RenderState?, rowCount: Int) -> IndexSet {
        var rows = IndexSet()
        for range in next.snapshot.damage.rows {
            let lowerBound = max(0, range.lowerBound)
            let upperBound = min(rowCount, range.upperBound)
            if lowerBound < upperBound {
                rows.insert(integersIn: lowerBound ..< upperBound)
            }
        }
        if next.snapshot.damage.selectionChanged {
            rows.insert(integersIn: 0 ..< rowCount)
        }
        if next.snapshot.damage.cursorMoved {
            if let previous {
                rows.insert(min(max(previous.snapshot.cursor.row, 0), rowCount - 1))
            }
            rows.insert(min(max(next.snapshot.cursor.row, 0), rowCount - 1))
        }
        rows.formUnion(atlasDamagedRows)
        return rows
    }

    private func mergedDamage(_ earlier: Damage, _ later: Damage) -> Damage {
        Damage(
            fullRedraw: earlier.fullRedraw || later.fullRedraw,
            rows: earlier.rows + later.rows,
            cursorMoved: earlier.cursorMoved || later.cursorMoved,
            selectionChanged: earlier.selectionChanged || later.selectionChanged
        )
    }

    private func connectAtlasCallbacks() {
        monochromeAtlas.rowsDidChange = { [weak self] rows in
            self?.atlasRowsChanged(rows)
        }
        colorAtlas.rowsDidChange = { [weak self] rows in
            self?.atlasRowsChanged(rows)
        }
    }

    private func atlasRowsChanged(_ rows: [Int]) {
        atlasDamagedRows.formUnion(IndexSet(rows))
        onNeedsFrame?()
    }
}
