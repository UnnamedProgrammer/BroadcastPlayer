import AVFoundation
import CoreMedia
import Foundation

nonisolated enum FrameRatePreference: Int, CaseIterable, Identifiable, Sendable {
    case fps60 = 60
    case fps50 = 50
    case fps30 = 30
    case fps25 = 25
    case fps24 = 24

    static let defaultPreference: FrameRatePreference = .fps60

    var id: Int { rawValue }
    var rate: Double { Double(rawValue) }
    var displayName: String { "\(rawValue) fps" }
}

nonisolated struct CaptureFormatSummary: Identifiable, Hashable {
    let index: Int
    let width: Int
    let height: Int
    let minFrameRate: Double
    let maxFrameRate: Double
    let pixelFormatCodes: [String]

    var id: String { "\(index)-\(width)x\(height)@\(minFrameRate)-\(maxFrameRate)" }

    var pixelCount: Int { width * height }

    var resolutionLabel: String { "\(width)\u{00D7}\(height)" }

    var frameRateLabel: String {
        let low = Self.rate(minFrameRate)
        let high = Self.rate(maxFrameRate)
        return low == high ? "\(low) fps" : "\(low)–\(high) fps"
    }

    var isFullHD: Bool {
        width == CaptureFormatManager.targetWidth && height == CaptureFormatManager.targetHeight
    }

    func supports(frameRate: Double, tolerance: Double = 0.5) -> Bool {
        (minFrameRate - tolerance) <= frameRate && frameRate <= (maxFrameRate + tolerance)
    }

    private static func rate(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.01 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.2f", value)
    }
}

nonisolated enum CaptureFormatManager {
    static let targetWidth = 1920
    static let targetHeight = 1080

    static func summaries(for device: AVCaptureDevice) -> [CaptureFormatSummary] {
        var pixelFormats: [Key: Set<String>] = [:]
        var firstIndex: [Key: Int] = [:]
        var order: [Key] = []

        for (index, format) in device.formats.enumerated() {
            let description = format.formatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            let subType = CMFormatDescriptionGetMediaSubType(description)
            let code = FourCC.string(from: Int32(bitPattern: subType))

            for range in format.videoSupportedFrameRateRanges {
                let key = Key(
                    width: Int(dimensions.width),
                    height: Int(dimensions.height),
                    minFrameRate: range.minFrameRate,
                    maxFrameRate: range.maxFrameRate
                )
                if pixelFormats[key] == nil {
                    order.append(key)
                    firstIndex[key] = index
                }
                pixelFormats[key, default: []].insert(code)
            }
        }

        return order
            .map { key in
                CaptureFormatSummary(
                    index: firstIndex[key] ?? 0,
                    width: key.width,
                    height: key.height,
                    minFrameRate: key.minFrameRate,
                    maxFrameRate: key.maxFrameRate,
                    pixelFormatCodes: (pixelFormats[key] ?? []).sorted()
                )
            }
            .sorted { lhs, rhs in
                if lhs.pixelCount != rhs.pixelCount { return lhs.pixelCount > rhs.pixelCount }
                if lhs.maxFrameRate != rhs.maxFrameRate { return lhs.maxFrameRate > rhs.maxFrameRate }
                return lhs.width > rhs.width
            }
    }

    static func preferredFormat(in summaries: [CaptureFormatSummary], frameRate: Double) -> CaptureFormatSummary? {
        let target = targetWidth * targetHeight
        let rateCapable = summaries.filter { $0.supports(frameRate: frameRate) }
        let candidates = rateCapable.isEmpty ? summaries : rateCapable

        return candidates.min { lhs, rhs in
            let lhsDistance = abs(lhs.pixelCount - target)
            let rhsDistance = abs(rhs.pixelCount - target)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs.maxFrameRate > rhs.maxFrameRate
        }
    }

    private struct Key: Hashable {
        let width: Int
        let height: Int
        let minFrameRate: Double
        let maxFrameRate: Double
    }
}