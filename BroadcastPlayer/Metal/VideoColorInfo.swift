import CoreGraphics
import CoreVideo

nonisolated enum VideoColorMatrix: String {
    case rec601 = "Rec. 601"
    case rec709 = "Rec. 709"
    case rec2020 = "Rec. 2020"

    var coefficients: (kr: Float, kb: Float) {
        switch self {
        case .rec601: (0.299, 0.114)
        case .rec709: (0.2126, 0.0722)
        case .rec2020: (0.2627, 0.0593)
        }
    }
}

// This layout is shared with BiplanarParameters in Compositor.metal.
nonisolated struct BiplanarUniforms {
    var yScale: Float
    var yOffset: Float
    var rCr: Float
    var gCb: Float
    var gCr: Float
    var bCb: Float
    var chromaOffset: Float

    init(isFullRange: Bool, matrix: VideoColorMatrix) {
        let (kr, kb) = matrix.coefficients
        let kg = 1 - kr - kb
        let chromaScale: Float = isFullRange ? 1 : 255.0 / 224.0
        yScale = isFullRange ? 1 : 255.0 / 219.0
        yOffset = isFullRange ? 0 : 16.0 / 255.0
        chromaOffset = 128.0 / 255.0
        rCr = 2 * (1 - kr) * chromaScale
        bCb = 2 * (1 - kb) * chromaScale
        gCb = -2 * kb * (1 - kb) / kg * chromaScale
        gCr = -2 * kr * (1 - kr) / kg * chromaScale
    }
}

nonisolated struct VideoColorInfo {
    let matrix: VideoColorMatrix
    let colorSpace: CGColorSpace
    let description: String

    init(pixelBuffer: CVPixelBuffer) {
        let attachments = CVBufferCopyAttachments(pixelBuffer, .shouldPropagate) as? [String: Any] ?? [:]
        let matrixName = attachments[kCVImageBufferYCbCrMatrixKey as String] as? String
        if matrixName == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String { matrix = .rec601 }
        else if matrixName == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String { matrix = .rec2020 }
        else if matrixName == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String { matrix = .rec709 }
        else { matrix = CVPixelBufferGetHeight(pixelBuffer) <= 576 ? .rec601 : .rec709 }
        // Tell ColorSync which encoded RGB values the shader is presenting.
        // Preserve an explicit ICC/CGColorSpace or synthesize it from source tags.
        if let tagged = CVImageBufferGetColorSpace(pixelBuffer)?.takeUnretainedValue() {
            colorSpace = tagged
        } else if let tagged = CVImageBufferCreateColorSpaceFromAttachments(attachments as CFDictionary)?.takeRetainedValue() {
            colorSpace = tagged
        } else {
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        }
        description = colorSpace.name.map { $0 as String } ?? matrix.rawValue
    }
}
