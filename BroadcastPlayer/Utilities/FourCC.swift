import Foundation

nonisolated enum FourCC {
    static func string(from code: Int32) -> String {
        guard code != 0 else { return "—" }

        var result = ""
        for shift in stride(from: 24, through: 0, by: -8) {
            let byte = UInt8(truncatingIfNeeded: code >> shift)
            if (0x20...0x7E).contains(byte), let scalar = UnicodeScalar(UInt32(byte)) {
                result.append(Character(scalar))
            } else {
                result.append("?")
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}