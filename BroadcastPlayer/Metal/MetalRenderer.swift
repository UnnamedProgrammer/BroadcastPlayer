import CoreVideo
import Metal
import QuartzCore
import MetalFX
import OSLog
import simd

nonisolated enum MetalRendererError: LocalizedError {
    case deviceUnavailable
    case commandQueueUnavailable
    case libraryUnavailable(String)
    case functionMissing(String)
    case pipelineCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            "No Metal device is available on this Mac."
        case .commandQueueUnavailable:
            "The Metal command queue could not be created."
        case .libraryUnavailable(let reason):
            "The Metal shader library could not be loaded (\(reason))."
        case .functionMissing(let name):
            "The Metal shader function \"\(name)\" is missing from the default library."
        case .pipelineCreationFailed(let reason):
            "The Metal render pipeline could not be created (\(reason))."
        }
    }
}

private struct FitUniforms {
    var scale: SIMD2<Float>
    var offset: SIMD2<Float> = .zero
}

private struct ClarityUniforms {
    var strength: Float
    var compare: Float
    var drawableWidth: Float
    var shadowLift: Float
}

final class MetalRenderer: NSObject {
    let device: MTLDevice

    private let commandQueue: MTLCommandQueue
    private let clarityPipeline: MTLRenderPipelineState
    private let bgraPipeline: MTLRenderPipelineState
    private let biplanarPipeline: MTLRenderPipelineState
    private let textureManager: MetalTextureManager
    private let naturalPipeline: MTLComputePipelineState
    private var conversionTexture: MTLTexture?
    private var upscaleTexture: MTLTexture?
    private var metalFXTexture: MTLTexture?
    private var spatialScaler: (any MTLFXSpatialScaler)?
    private var upscaleInputSize: SIMD2<Int>?
    private var upscaleOutputSize: SIMD2<Int>?

    var adaptsTo16By10 = false {
        didSet { hasRenderedOnce = false }
    }

    var fillsScreen = false {
        didSet { hasRenderedOnce = false }
    }

    var isNatural4KEnabled = true {
        didSet { hasRenderedOnce = false }
    }

    var sharpness: Float = 0.35 {
        didSet { hasRenderedOnce = false }
    }
    var shadowLift: Float = 0 {
        didSet { hasRenderedOnce = false }
    }
    var comparesOriginal = false {
        didSet { hasRenderedOnce = false }
    }

    private var source: CaptureFrameBuffer?
    private var inFlight: [InFlight] = []
    private var lastRenderedGeneration: UInt64 = 0
    private var hasRenderedOnce = false
    private var lastPresentedGeneration: UInt64?
    private var hasLoggedFirstPresentation = false

    private(set) var renderedFrames = 0
    let statistics = PresentationStatistics()
    private(set) var colorDescription = "—"
    private var displayColorSpace: CGColorSpace?

    private struct InFlight {
        let textures: [CVMetalTexture]
        let commandBuffer: MTLCommandBuffer
    }

    static func make() throws -> MetalRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRendererError.deviceUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalRendererError.commandQueueUnavailable
        }

        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: .main)
        } catch {
            throw MetalRendererError.libraryUnavailable(error.localizedDescription)
        }

        let clarityPipeline = try makePipeline(
            device: device, library: library, fragmentName: "compositor_fragment_clarity"
        )
        let bgraPipeline = try makePipeline(
            device: device, library: library, fragmentName: "compositor_fragment_bgra"
        )
        let biplanarPipeline = try makePipeline(
            device: device, library: library, fragmentName: "compositor_fragment_biplanar"
        )

        guard let naturalFunction = library.makeFunction(name: "natural_4k_upscale") else {
            throw MetalRendererError.functionMissing("natural_4k_upscale")
        }
        let naturalPipeline = try device.makeComputePipelineState(function: naturalFunction)

        return MetalRenderer(
            device: device,
            commandQueue: commandQueue,
            clarityPipeline: clarityPipeline,
            bgraPipeline: bgraPipeline,
            biplanarPipeline: biplanarPipeline,
            naturalPipeline: naturalPipeline
        )
    }

    private init(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        clarityPipeline: MTLRenderPipelineState,
        bgraPipeline: MTLRenderPipelineState,
        biplanarPipeline: MTLRenderPipelineState,
        naturalPipeline: MTLComputePipelineState
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.clarityPipeline = clarityPipeline
        self.bgraPipeline = bgraPipeline
        self.biplanarPipeline = biplanarPipeline
        self.naturalPipeline = naturalPipeline
        self.textureManager = MetalTextureManager(device: device)

        super.init()

        Log.render.info("Metal renderer ready on '\(device.name, privacy: .public)'")
    }

    func attach(source: CaptureFrameBuffer) {
        self.source = source
    }

    func draw(drawable: any CAMetalDrawable, drawableSize: CGSize,
              setColorSpace: (CGColorSpace) -> Void) {
        reapCompletedFrames()
        guard inFlight.count < 2 else {
            source?.protectFromDisplayStall(at: CACurrentMediaTime())
            return
        }
        guard let source, let available = source.snapshot() else { return }
        if hasRenderedOnce, available.generation == lastRenderedGeneration { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let captured = source.takeNext() else { return }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        let generation = captured.generation
        guard let frame = textureManager.makeFrame(from: captured.pixelBuffer) else { return }
        if displayColorSpace != frame.color.colorSpace {
            displayColorSpace = frame.color.colorSpace
            colorDescription = frame.color.description
            Log.render.info("Source color space: \(frame.color.description, privacy: .public), matrix: \(frame.color.matrix.rawValue, privacy: .public)")
        }

        let upscaled = isNatural4KEnabled && VideoGeometry.upscaleSize(width: frame.width, height: frame.height, adaptsTo16By10: adaptsTo16By10) != nil
            ? encodeNatural4K(frame: frame, commandBuffer: commandBuffer) : nil
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let presentationHeight = adaptsTo16By10 && frame.width == 1920 && frame.height == 1080
            ? 1200 : frame.height
        var tone = shadowLift
        encoder.setFragmentBytes(&tone, length: MemoryLayout<Float>.stride, index: 1)
        var fit = FitUniforms(scale: VideoGeometry.scale(width: frame.width, height: presentationHeight,
            drawableSize: drawableSize, fill: fillsScreen))
        if let upscaled {
            var clarity = ClarityUniforms(strength: sharpness, compare: comparesOriginal ? 1 : 0,
                                         drawableWidth: Float(drawableSize.width), shadowLift: shadowLift)
            encoder.setFragmentBytes(&clarity, length: MemoryLayout<ClarityUniforms>.stride, index: 0)
            encoder.setFragmentTexture(conversionTexture, index: 1)
            encoder.setRenderPipelineState(clarityPipeline)
            encoder.setVertexBytes(&fit, length: MemoryLayout<FitUniforms>.stride, index: 0)
            encoder.setFragmentTexture(upscaled, index: 0)
        } else {
            switch frame.layout {
            case .bgra(let texture):
                encoder.setRenderPipelineState(bgraPipeline)
                encoder.setVertexBytes(&fit, length: MemoryLayout<FitUniforms>.stride, index: 0)
                encoder.setFragmentTexture(texture, index: 0)

            case .biplanar(let luma, let chroma):
                var params = BiplanarUniforms(isFullRange: frame.isFullRange, matrix: frame.color.matrix)
                encoder.setRenderPipelineState(biplanarPipeline)
                encoder.setVertexBytes(&fit, length: MemoryLayout<FitUniforms>.stride, index: 0)
                encoder.setFragmentBytes(&params, length: MemoryLayout<BiplanarUniforms>.stride, index: 0)
                encoder.setFragmentTexture(luma, index: 0)
                encoder.setFragmentTexture(chroma, index: 1)
            }
        }

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        let statistics = statistics
        let arrival = captured.arrivalTime
        let isNewFrame = generation != lastPresentedGeneration
        if isNewFrame {
            lastPresentedGeneration = generation
            drawable.addPresentedHandler { presented in
                guard presented.presentedTime > 0 else { return }
                statistics.record(time: presented.presentedTime, arrival: arrival)
            }
        }
        commandBuffer.addCompletedHandler { completed in
            if completed.status == .completed {
                statistics.recordGPU(milliseconds: (completed.gpuEndTime - completed.gpuStartTime) * 1000)
            }
        }
        commandBuffer.commit()
        // CAMetalDisplayLink owns presentation timing. Commit rendering first,
        // then present its drawable; timed presentation is not supported here.
        drawable.present()
        // Layer properties apply to the next drawable, after this one is sent.
        setColorSpace(frame.color.colorSpace)

        inFlight.append(InFlight(textures: frame.retained, commandBuffer: commandBuffer))
        lastRenderedGeneration = generation
        hasRenderedOnce = true
        renderedFrames += 1

        if !hasLoggedFirstPresentation {
            hasLoggedFirstPresentation = true
            Log.render.info("Presenting \(frame.width)x\(frame.height) frames to the display")
        }
    }

    func drawableSizeDidChange() {
        hasRenderedOnce = false
        textureManager.flush()
    }

    func setAdaptiveQueue(_ enabled: Bool) {
        source?.setAdaptive(enabled)
    }

    private func encodeNatural4K(frame: FrameTexture, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let outputSize = VideoGeometry.upscaleSize(width: frame.width, height: frame.height, adaptsTo16By10: adaptsTo16By10) else { return nil }
        let inputSize = SIMD2(frame.width, frame.height)
        if upscaleInputSize != inputSize || upscaleOutputSize != outputSize {
            // MetalFX descriptors and textures are dimension-specific. Recreate
            // them together when the capture format changes, not for every frame.
            conversionTexture = nil
            metalFXTexture = nil
            upscaleTexture = nil
            spatialScaler = nil
            if MTLFXSpatialScalerDescriptor.supportsDevice(device) {
                let descriptor = MTLFXSpatialScalerDescriptor()
                descriptor.inputWidth = frame.width
                descriptor.inputHeight = frame.height
                descriptor.outputWidth = outputSize.x
                descriptor.outputHeight = outputSize.y
                descriptor.colorTextureFormat = .bgra8Unorm
                descriptor.outputTextureFormat = .bgra8Unorm
                descriptor.colorProcessingMode = .perceptual
                spatialScaler = descriptor.makeSpatialScaler(device: device)
            }
            upscaleInputSize = inputSize
            upscaleOutputSize = outputSize
        }
        if conversionTexture == nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: frame.width, height: frame.height, mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            if let spatialScaler { descriptor.usage.formUnion(spatialScaler.colorTextureUsage) }
            conversionTexture = device.makeTexture(descriptor: descriptor)
        }
        guard let input = conversionTexture else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = input
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let conversion = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var tone: Float = 0
        conversion.setFragmentBytes(&tone, length: MemoryLayout<Float>.stride, index: 1)
        var fit = FitUniforms(scale: SIMD2<Float>(1, 1))
        conversion.setVertexBytes(&fit, length: MemoryLayout<FitUniforms>.stride, index: 0)
        switch frame.layout {
        case .bgra(let texture):
            conversion.setRenderPipelineState(bgraPipeline)
            conversion.setFragmentTexture(texture, index: 0)
        case .biplanar(let luma, let chroma):
            var params = BiplanarUniforms(isFullRange: frame.isFullRange, matrix: frame.color.matrix)
            conversion.setRenderPipelineState(biplanarPipeline)
            conversion.setFragmentBytes(&params, length: MemoryLayout<BiplanarUniforms>.stride, index: 0)
            conversion.setFragmentTexture(luma, index: 0)
            conversion.setFragmentTexture(chroma, index: 1)
        }
        conversion.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        conversion.endEncoding()

        if let spatialScaler {
            if metalFXTexture == nil {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: outputSize.x, height: outputSize.y, mipmapped: false
                )
                descriptor.storageMode = .private
                descriptor.usage = spatialScaler.outputTextureUsage.union(.shaderRead)
                metalFXTexture = device.makeTexture(descriptor: descriptor)
            }
            if let metalFXTexture {
                spatialScaler.colorTexture = input
                spatialScaler.outputTexture = metalFXTexture
                spatialScaler.inputContentWidth = frame.width
                spatialScaler.inputContentHeight = frame.height
                spatialScaler.encode(commandBuffer: commandBuffer)
                // Preserve MetalFX reconstruction; sharpen only after display scaling.
                return metalFXTexture
            }
        }
        if upscaleTexture == nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: outputSize.x, height: outputSize.y, mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            upscaleTexture = device.makeTexture(descriptor: descriptor)
            upscaleTexture?.label = "4K reconstruction fallback"
        }
        guard let destination = upscaleTexture else { return nil }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.label = "4K reconstruction fallback"
        encoder.setComputePipelineState(naturalPipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: outputSize.x, height: outputSize.y, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1)
        )
        encoder.endEncoding()
        return destination
    }

    private func reapCompletedFrames() {
        inFlight.removeAll { entry in
            switch entry.commandBuffer.status {
            case .completed, .error:
                true
            default:
                false
            }
        }
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        fragmentName: String
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunction = library.makeFunction(name: "compositor_vertex") else {
            throw MetalRendererError.functionMissing("compositor_vertex")
        }
        guard let fragmentFunction = library.makeFunction(name: fragmentName) else {
            throw MetalRendererError.functionMissing(fragmentName)
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = fragmentName
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalRendererError.pipelineCreationFailed(error.localizedDescription)
        }
    }

}
