// Compile with VideoColorInfo.swift, AdaptiveFramePacing.swift,
// CaptureFrameBuffer.swift and PresentationStatistics.swift.
import CoreVideo
import Foundation
import Metal

@main struct VideoPipelineCheck {
    static func buffer(width: Int = 1920, height: Int = 1080) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &result) == kCVReturnSuccess)
        return result!
    }

    static func main() throws {
        let hd = buffer(), sd = buffer(width: 720, height: 480)
        precondition(VideoColorInfo(pixelBuffer: hd).matrix == .rec709)
        precondition(VideoColorInfo(pixelBuffer: sd).matrix == .rec601)
        CVBufferSetAttachment(hd, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        precondition(VideoColorInfo(pixelBuffer: hd).matrix == .rec2020)
        CVBufferSetAttachment(hd, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(hd, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(hd, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        precondition(VideoColorInfo(pixelBuffer: hd).colorSpace != CGColorSpace(name: CGColorSpace.sRGB)!, "Source color tags ignored")

        let device = MTLCreateSystemDefaultDevice()!
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BroadcastPlayer/Metal/Shaders/Compositor.metal")
        let library = try device.makeLibrary(source: String(contentsOf: path, encoding: .utf8), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "compositor_vertex")!
        descriptor.fragmentFunction = library.makeFunction(name: "compositor_fragment_biplanar")!
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        func texture(_ format: MTLPixelFormat, usage: MTLTextureUsage) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 2, height: 2, mipmapped: false)
            d.storageMode = .shared; d.usage = usage
            return device.makeTexture(descriptor: d)!
        }
        let yTexture = texture(.r8Unorm, usage: .shaderRead)
        let cTexture = texture(.rg8Unorm, usage: .shaderRead)
        let output = texture(.bgra8Unorm, usage: .renderTarget)
        let queue = device.makeCommandQueue()!
        // Known RGB targets exercise all matrices and exact full/video-range endpoints.
        for matrix in [VideoColorMatrix.rec601, .rec709, .rec2020] {
            for fullRange in [false, true] {
                for rgb: SIMD3<Float> in [.zero, SIMD3(repeating: 1), SIMD3(0.8, 0.2, 0.1), SIMD3(0.1, 0.5, 0.9)] {
                    let (kr, kb) = matrix.coefficients
                    let y = kr * rgb.x + (1 - kr - kb) * rgb.y + kb * rgb.z
                    let cb = (rgb.z - y) / (2 * (1 - kb))
                    let cr = (rgb.x - y) / (2 * (1 - kr))
                    let luma = UInt8((fullRange ? y * 255 : y * 219 + 16).rounded())
                    let chroma: [UInt8] = [UInt8((cb * (fullRange ? 255 : 224) + 128).rounded()),
                                            UInt8((cr * (fullRange ? 255 : 224) + 128).rounded())]
                    let yy = Array(repeating: luma, count: 4), cc = Array(repeating: chroma, count: 4).flatMap { $0 }
                    yTexture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: yy, bytesPerRow: 2)
                    cTexture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: cc, bytesPerRow: 4)
                    let command = queue.makeCommandBuffer()!
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = output
                    pass.colorAttachments[0].storeAction = .store
                    let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
                    encoder.setRenderPipelineState(pipeline)
                    var tone: Float = 0
                    encoder.setFragmentBytes(&tone, length: 4, index: 1)
                    var fit = SIMD4<Float>(1, 1, 0, 0)
                    var params = BiplanarUniforms(isFullRange: fullRange, matrix: matrix)
                    encoder.setVertexBytes(&fit, length: 16, index: 0)
                    encoder.setFragmentBytes(&params, length: MemoryLayout<BiplanarUniforms>.stride, index: 0)
                    encoder.setFragmentTexture(yTexture, index: 0); encoder.setFragmentTexture(cTexture, index: 1)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
                    precondition(command.status == .completed)
                    var result = [UInt8](repeating: 0, count: 16)
                    output.getBytes(&result, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
                    for component in 0..<3 {
                        precondition(abs(Float(result[2 - component]) / 255 - rgb[component]) < 0.012,
                            "Wrong GPU color: \(matrix), full=\(fullRange), rgb=\(rgb), output=\(result)")
                    }
                }
            }
        }
        print("GPU color matrices, black/white levels and source profile: PASS")

        let frameBuffer = CaptureFrameBuffer()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            for i in 1...2000 {
                let pixel = buffer(width: 2, height: 2)
                CVBufferSetAttachment(pixel, "TestSequence" as CFString, NSNumber(value: i), .shouldPropagate)
                frameBuffer.store(pixel)
            }
            group.leave()
        }
        for _ in 0..<10000 {
            if let snapshot = frameBuffer.snapshot() {
                let tag = CVBufferCopyAttachment(snapshot.pixelBuffer, "TestSequence" as CFString, nil)! as! NSNumber
                precondition(snapshot.generation == tag.uint64Value, "Buffer and sequence came from different callbacks")
                precondition(snapshot.arrivalTime > 0)
            }
        }
        group.wait()
        precondition(frameBuffer.snapshot()?.generation == 2000)
        precondition(frameBuffer.takeNext()?.generation == 1999, "Capture queue grew beyond two frames")
        precondition(frameBuffer.takeNext()?.generation == 2000, "Queued frames were reordered")
        frameBuffer.clear(); precondition(frameBuffer.snapshot() == nil)
        precondition(frameBuffer.takeNext() == nil)
        print("Concurrent capture snapshots and clearing: PASS")

        let stats = PresentationStatistics()
        // Out-of-order driver callbacks and stale signal must not inflate display FPS.
        for i in (0...120).reversed() { stats.record(time: 10 + Double(i) / 60, arrival: 10 + Double(i) / 60 - 0.02) }
        let snapshot = stats.snapshot(now: 12)
        precondition(abs(snapshot.framesPerSecond - 60) < 0.001)
        precondition(abs(snapshot.processingMilliseconds - 20) < 0.001)
        precondition(stats.snapshot(now: 14).framesPerSecond == 0)
        print("Presentation FPS, processing delay and signal loss: PASS")
    }
}
