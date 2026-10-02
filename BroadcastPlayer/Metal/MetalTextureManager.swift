import CoreVideo
import Metal
import OSLog

nonisolated enum FrameTextureLayout {
    case bgra(MTLTexture)
    case biplanar(luma: MTLTexture, chroma: MTLTexture)
}

nonisolated struct FrameTexture {
    let layout: FrameTextureLayout
    let width: Int
    let height: Int
    let isFullRange: Bool
    let color: VideoColorInfo
    let retained: [CVMetalTexture]
}

nonisolated final class MetalTextureManager {
    private let cache: CVMetalTextureCache?
    private var unsupportedFormat: OSType = 0
    private var cachedColor: VideoColorInfo?
    private var cachedAttachments: CFDictionary?
    private var cachedSD = false

    init(device: MTLDevice) {
        var created: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &created)

        if status == kCVReturnSuccess, let created {
            cache = created
            CVMetalTextureCacheFlush(created, 0)
        } else {
            cache = nil
            Log.render.error("CVMetalTextureCacheCreate failed with status \(status)")
        }
    }

    func makeFrame(from pixelBuffer: CVPixelBuffer) -> FrameTexture? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        switch format {
        case kCVPixelFormatType_32BGRA:
            return makeBGRA(pixelBuffer)
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return makeBiplanar(pixelBuffer, isFullRange: false)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return makeBiplanar(pixelBuffer, isFullRange: true)
        default:
            if unsupportedFormat != format {
                unsupportedFormat = format
                Log.render.error("Unsupported capture pixel format '\(FourCC.string(from: Int32(bitPattern: format)), privacy: .public)' (\(format))")
            }
            return nil
        }
    }

    func flush() {
        if let cache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    private func colorInfo(for buffer: CVPixelBuffer) -> VideoColorInfo {
        let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate) ?? [:] as CFDictionary
        let isSD = CVPixelBufferGetHeight(buffer) <= 576
        if let cachedColor, let cachedAttachments, cachedSD == isSD,
           CFEqual(attachments, cachedAttachments) {
            return cachedColor
        }
        let color = VideoColorInfo(pixelBuffer: buffer)
        cachedAttachments = attachments
        cachedSD = isSD
        cachedColor = color
        return color
    }

    private func makeBGRA(_ pixelBuffer: CVPixelBuffer) -> FrameTexture? {
        guard let cache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            Log.render.error("BGRA texture creation failed with status \(status)")
            return nil
        }

        return FrameTexture(
            layout: .bgra(texture),
            width: width,
            height: height,
            isFullRange: true,
            color: colorInfo(for: pixelBuffer),
            retained: [cvTexture]
        )
    }

    private func makeBiplanar(_ pixelBuffer: CVPixelBuffer, isFullRange: Bool) -> FrameTexture? {
        guard let cache else { return nil }

        let lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

        var lumaRef: CVMetalTexture?
        var chromaRef: CVMetalTexture?

        let lumaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, .r8Unorm, lumaWidth, lumaHeight, 0, &lumaRef
        )
        let chromaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, .rg8Unorm, chromaWidth, chromaHeight, 1, &chromaRef
        )

        guard lumaStatus == kCVReturnSuccess, chromaStatus == kCVReturnSuccess,
              let lumaRef, let chromaRef,
              let luma = CVMetalTextureGetTexture(lumaRef),
              let chroma = CVMetalTextureGetTexture(chromaRef) else {
            Log.render.error("Biplanar texture creation failed with statuses \(lumaStatus)/\(chromaStatus)")
            return nil
        }

        return FrameTexture(
            layout: .biplanar(luma: luma, chroma: chroma),
            width: lumaWidth,
            height: lumaHeight,
            isFullRange: isFullRange,
            color: colorInfo(for: pixelBuffer),
            retained: [lumaRef, chromaRef]
        )
    }
}