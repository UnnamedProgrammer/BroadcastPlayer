import Foundation
import simd

nonisolated enum VideoGeometry {
    static func upscaleSize(width: Int, height: Int, adaptsTo16By10: Bool = false) -> SIMD2<Int>? {
        guard width == 1920, height == 1080 || height == 1200 else { return nil }
        return SIMD2(width * 2, adaptsTo16By10 && height == 1080 ? 2400 : height * 2)
    }

    static func scale(width: Int, height: Int, drawableSize: CGSize, fill: Bool) -> SIMD2<Float> {
        guard width > 0, height > 0, drawableSize.width > 0, drawableSize.height > 0 else {
            return SIMD2(1, 1)
        }
        let x = drawableSize.width / CGFloat(width)
        let y = drawableSize.height / CGFloat(height)
        let factor = fill ? max(x, y) : min(x, y)
        return SIMD2(Float(CGFloat(width) * factor / drawableSize.width),
                     Float(CGFloat(height) * factor / drawableSize.height))
    }
}
