import Metal
import simd

struct GPUUniforms {
    var viewportSize: SIMD2<Float>
}

struct GPURectangle {
    var rect: SIMD4<Float>
    var color: SIMD4<Float>
}

struct GPUGlyph {
    var rect: SIMD4<Float>
    var uv: SIMD4<Float>
    var color: SIMD4<Float>
}

struct GPUBufferSlice {
    var buffer: MTLBuffer?
    var count = 0
}

struct MetalSceneRow {
    var backgrounds = GPUBufferSlice()
    var monochromeGlyphs = GPUBufferSlice()
    var colorGlyphs = GPUBufferSlice()
    var decorations = GPUBufferSlice()
    var cursorAndFocus = GPUBufferSlice()
}

@MainActor
final class MetalSceneResources {
    private(set) var rows: [MetalSceneRow] = []

    func update(
        scene: TerminalScene,
        rowIndices: IndexSet,
        device: MTLDevice,
        monochromeAtlas: GlyphAtlas,
        colorAtlas: GlyphAtlas
    ) {
        if rows.count != scene.rows.count {
            rows = Array(repeating: MetalSceneRow(), count: scene.rows.count)
        }
        for rowIndex in rowIndices where scene.rows.indices.contains(rowIndex) {
            let source = scene.rows[rowIndex]
            var destination = rows[rowIndex]
            destination.backgrounds = uploadRectangles(
                source.backgrounds,
                existing: destination.backgrounds,
                device: device
            )
            destination.decorations = uploadRectangles(
                source.decorations,
                existing: destination.decorations,
                device: device
            )
            destination.cursorAndFocus = uploadRectangles(
                source.cursorAndFocus,
                existing: destination.cursorAndFocus,
                device: device
            )
            destination.monochromeGlyphs = uploadGlyphs(
                source.monochromeGlyphs,
                existing: destination.monochromeGlyphs,
                device: device,
                atlas: monochromeAtlas
            )
            destination.colorGlyphs = uploadGlyphs(
                source.colorGlyphs,
                existing: destination.colorGlyphs,
                device: device,
                atlas: colorAtlas
            )
            rows[rowIndex] = destination
        }
    }

    private func uploadRectangles(
        _ instances: [SceneRectangle],
        existing: GPUBufferSlice,
        device: MTLDevice
    ) -> GPUBufferSlice {
        let values = instances.map { GPURectangle(rect: $0.rect, color: $0.color) }
        return upload(values, existing: existing, device: device)
    }

    private func uploadGlyphs(
        _ glyphs: [SceneGlyph],
        existing: GPUBufferSlice,
        device: MTLDevice,
        atlas: GlyphAtlas
    ) -> GPUBufferSlice {
        let values = glyphs.compactMap { glyph -> GPUGlyph? in
            guard let entry = atlas.entry(for: glyph.request) else { return nil }
            return GPUGlyph(
                rect: glyph.rect,
                uv: SIMD4(entry.u0, entry.v0, entry.u1, entry.v1),
                color: glyph.color
            )
        }
        return upload(values, existing: existing, device: device)
    }

    private func upload<Element>(
        _ values: [Element],
        existing: GPUBufferSlice,
        device: MTLDevice
    ) -> GPUBufferSlice {
        guard !values.isEmpty else { return GPUBufferSlice(buffer: existing.buffer, count: 0) }
        let requiredLength = values.count * MemoryLayout<Element>.stride
        let buffer: MTLBuffer
        if let existingBuffer = existing.buffer, existingBuffer.length >= requiredLength {
            buffer = existingBuffer
        } else {
            guard let newBuffer = device.makeBuffer(length: requiredLength, options: .storageModeShared) else {
                preconditionFailure("Metal could not allocate an instance buffer")
            }
            buffer = newBuffer
        }
        values.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            buffer.contents().copyMemory(from: baseAddress, byteCount: requiredLength)
        }
        return GPUBufferSlice(buffer: buffer, count: values.count)
    }
}

@MainActor
final class MetalPipelines {
    let rectangles: MTLRenderPipelineState
    let monochromeGlyphs: MTLRenderPipelineState
    let colorGlyphs: MTLRenderPipelineState
    let sampler: MTLSamplerState

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        let library = try device.makeLibrary(source: ShaderSource.metal, options: nil)
        rectangles = try Self.makePipeline(
            device: device,
            library: library,
            vertex: "rectangleVertex",
            fragment: "solidFragment",
            pixelFormat: pixelFormat,
            premultiplied: false
        )
        monochromeGlyphs = try Self.makePipeline(
            device: device,
            library: library,
            vertex: "glyphVertex",
            fragment: "monochromeGlyphFragment",
            pixelFormat: pixelFormat,
            premultiplied: false
        )
        colorGlyphs = try Self.makePipeline(
            device: device,
            library: library,
            vertex: "glyphVertex",
            fragment: "colorGlyphFragment",
            pixelFormat: pixelFormat,
            premultiplied: true
        )
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
            preconditionFailure("Metal could not allocate the atlas sampler")
        }
        self.sampler = sampler
    }

    func encode(
        scene: TerminalScene,
        resources: MetalSceneResources,
        target: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        monochromeAtlas: GlyphAtlas,
        colorAtlas: GlyphAtlas,
        clearColor: SIMD4<Float>
    ) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(clearColor.x),
            green: Double(clearColor.y),
            blue: Double(clearColor.z),
            alpha: Double(clearColor.w)
        )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        var uniforms = GPUUniforms(viewportSize: SIMD2(scene.width, scene.height))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 2)

        drawRectangles(resources.rows.map(\.backgrounds), encoder: encoder, pipeline: rectangles)
        drawGlyphs(
            resources.rows.map(\.monochromeGlyphs),
            encoder: encoder,
            pipeline: monochromeGlyphs,
            texture: monochromeAtlas.texture
        )
        drawGlyphs(
            resources.rows.map(\.colorGlyphs),
            encoder: encoder,
            pipeline: colorGlyphs,
            texture: colorAtlas.texture
        )
        drawRectangles(resources.rows.map(\.decorations), encoder: encoder, pipeline: rectangles)
        drawRectangles(resources.rows.map(\.cursorAndFocus), encoder: encoder, pipeline: rectangles)
        encoder.endEncoding()
    }

    private func drawRectangles(
        _ slices: [GPUBufferSlice],
        encoder: MTLRenderCommandEncoder,
        pipeline: MTLRenderPipelineState
    ) {
        encoder.setRenderPipelineState(pipeline)
        for slice in slices where slice.count > 0 {
            guard let buffer = slice.buffer else { continue }
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: slice.count)
        }
    }

    private func drawGlyphs(
        _ slices: [GPUBufferSlice],
        encoder: MTLRenderCommandEncoder,
        pipeline: MTLRenderPipelineState,
        texture: MTLTexture
    ) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        for slice in slices where slice.count > 0 {
            guard let buffer = slice.buffer else { continue }
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: slice.count)
        }
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertex: String,
        fragment: String,
        pixelFormat: MTLPixelFormat,
        premultiplied: Bool
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        let attachment = descriptor.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = premultiplied ? .one : .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}
