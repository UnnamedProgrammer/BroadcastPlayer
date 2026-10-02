import Foundation
import Metal

@main struct ShadowLiftGPUCheck {
    static func main() throws {
        let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BroadcastPlayer/Metal/Shaders/Compositor.metal")
        let library = try device.makeLibrary(source: String(contentsOf: path, encoding: .utf8), options: nil)
        func texture(_ usage: MTLTextureUsage) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 256, height: 1, mipmapped: false)
            d.storageMode = .shared; d.usage = usage
            return device.makeTexture(descriptor: d)!
        }
        let source = texture(.shaderRead), output = texture(.renderTarget)
        var input = [UInt8](repeating: 255, count: 1024)
        for x in 0..<256 { for c in 0..<3 { input[x * 4 + c] = UInt8(x) } }
        source.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0, withBytes: input, bytesPerRow: 1024)
        func render(_ strength: Float, compare: Bool = false) throws -> [UInt8] {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "compositor_vertex")
            d.fragmentFunction = library.makeFunction(name: compare ? "compositor_fragment_clarity" : "compositor_fragment_bgra")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            let pipeline = try device.makeRenderPipelineState(descriptor: d)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output; pass.colorAttachments[0].storeAction = .store
            let command = queue.makeCommandBuffer()!, encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            var fit = SIMD4<Float>(1, 1, 0, 0), tone = strength
            encoder.setRenderPipelineState(pipeline); encoder.setVertexBytes(&fit, length: 16, index: 0)
            encoder.setFragmentTexture(source, index: 0); encoder.setFragmentTexture(source, index: 1)
            if compare {
                var params: [Float] = [0, 1, 256, strength]
                encoder.setFragmentBytes(&params, length: 16, index: 0)
            } else { encoder.setFragmentBytes(&tone, length: 4, index: 1) }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            precondition(command.status == .completed)
            var bytes = [UInt8](repeating: 0, count: 1024)
            output.getBytes(&bytes, bytesPerRow: 1024, from: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0)
            return bytes
        }
        for strength: Float in [0, 0.25, 1] {
            let result = try render(strength)
            var previous = 0
            for x in 0..<256 {
                let v = Int(result[x * 4])
                precondition(v >= previous, "Shadow tone curve reversed levels"); previous = v
                precondition(result[x * 4] == result[x * 4 + 1] && result[x * 4] == result[x * 4 + 2])
                if x == 0 || x >= 128 || strength == 0 { precondition(abs(v - x) <= 1) }
                if x == 32 && strength > 0 { precondition(v > x) }
            }
        }
        for i in stride(from: 0, to: input.count, by: 4) { input[i] = 32; input[i + 1] = 32; input[i + 2] = 32 }
        source.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0, withBytes: input, bytesPerRow: 1024)
        let compared = try render(1, compare: true)
        precondition(compared[64 * 4] == 32 && compared[192 * 4] > 32)
        print("GPU shadow lift: monotone levels, black/highlights preserved, neutral colors, bypass and original comparison: PASS")
    }
}
