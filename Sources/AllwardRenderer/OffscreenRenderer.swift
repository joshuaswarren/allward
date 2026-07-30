import AllwardDesign
import AllwardTerminal
import CoreGraphics
import Foundation
import Metal

public enum OffscreenRendererError: Error {
    case metalUnavailable
    case allocationFailed
    case commandEncodingFailed
    case renderingFailed(Error?)
    case imageCreationFailed
}

@MainActor
public final class OffscreenRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelines: MetalPipelines
    private let metrics: CellMetrics
    private let sceneBuilder: SceneBuilder

    public init(metrics: CellMetrics, device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let commandQueue = device.makeCommandQueue() else {
            throw OffscreenRendererError.metalUnavailable
        }
        self.device = device
        self.commandQueue = commandQueue
        self.metrics = metrics
        sceneBuilder = SceneBuilder(metrics: metrics)
        pipelines = try MetalPipelines(device: device, pixelFormat: .bgra8Unorm)
    }

    public func render(
        snapshot: TerminalSnapshot,
        palette: DesignPalette,
        theme: TerminalTheme,
        focused: Bool = true
    ) async throws -> CGImage {
        let scene = sceneBuilder.build(snapshot: snapshot, palette: palette, theme: theme, focused: focused)
        let requests = scene.glyphRequests
        let monochromeRequests = requests.filter { $0.key.presentation == .monochrome }
        let colorRequests = requests.filter { $0.key.presentation == .colorEmoji }
        let monochromeAtlas = makeAtlas(kind: .monochrome, requests: monochromeRequests)
        let colorAtlas = makeAtlas(kind: .color, requests: colorRequests)
        await monochromeAtlas.prepare(monochromeRequests)
        await colorAtlas.prepare(colorRequests)

        let resources = MetalSceneResources()
        resources.update(
            scene: scene,
            rowIndices: IndexSet(integersIn: scene.rows.indices),
            device: device,
            monochromeAtlas: monochromeAtlas,
            colorAtlas: colorAtlas
        )

        let pixelWidth = max(1, Int(scene.width.rounded()))
        let pixelHeight = max(1, Int(scene.height.rounded()))
        let target = try makeTarget(width: pixelWidth, height: pixelHeight)
        let alignment = max(256, device.minimumLinearTextureAlignment(for: .bgra8Unorm))
        let bytesPerRow = aligned(pixelWidth * 4, to: alignment)
        guard let readback = device.makeBuffer(length: bytesPerRow * pixelHeight, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            throw OffscreenRendererError.allocationFailed
        }

        let background = theme.defaultBackground
        pipelines.encode(
            scene: scene,
            resources: resources,
            target: target,
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
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw OffscreenRendererError.commandEncodingFailed
        }
        blit.copy(
            from: target,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: pixelWidth, height: pixelHeight, depth: 1),
            to: readback,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * pixelHeight
        )
        blit.endEncoding()
        await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { _ in continuation.resume() }
            commandBuffer.commit()
        }
        guard commandBuffer.status == .completed else {
            throw OffscreenRendererError.renderingFailed(commandBuffer.error)
        }

        let data = Data(bytes: readback.contents(), count: bytesPerRow * pixelHeight)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                      CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else {
            throw OffscreenRendererError.imageCreationFailed
        }
        return image
    }

    private func makeAtlas(kind: GlyphAtlasKind, requests: [GlyphRequest]) -> GlyphAtlas {
        let budget = GlyphAtlas.workingSetBudget(requests: requests, metrics: metrics, kind: kind)
        return GlyphAtlas(
            device: device,
            metrics: metrics,
            kind: kind,
            budgetBytes: budget,
            maximumDimension: 8_192
        )
    }

    private func makeTarget(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw OffscreenRendererError.allocationFailed
        }
        return texture
    }

    private func aligned(_ value: Int, to alignment: Int) -> Int {
        ((value + alignment - 1) / alignment) * alignment
    }
}
