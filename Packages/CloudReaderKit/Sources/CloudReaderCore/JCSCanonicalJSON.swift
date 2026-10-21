import Foundation

/// RFC 8785 canonical JSON bytes for opaque JSON values and portable records.
enum JCSCanonicalJSON {
    static func bytes(_ value: JSONValue) -> Data { Data(string(value).utf8) }
    static func less(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool { bytes(lhs).lexicographicallyPrecedes(bytes(rhs)) }
    static func string(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let b): b ? "true" : "false"
        // Avoid Decimal's direct NSDecimalNumber-to-Double bridge, which can
        // introduce a one-ULP error for values such as 1e-6 on Apple platforms.
        case .number(let n): number(Double(NSDecimalNumber(decimal: n).stringValue) ?? .nan)
        case .string(let s): quote(s)
        case .array(let a): "[" + a.map(string).joined(separator: ",") + "]"
        case .object(let o): "{" + o.keys.sorted(by: utf16Less).map { quote($0) + ":" + string(o[$0]!) }.joined(separator: ",") + "}"
        }
    }
    private static func utf16Less(_ a: String, _ b: String) -> Bool { a.utf16.lexicographicallyPrecedes(b.utf16) }
    private static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5c: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x09: out += "\\t"
            case 0x0a: out += "\\n"
            case 0x0c: out += "\\f"
            case 0x0d: out += "\\r"
            case 0...0x1f: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == 0 { return "0" }
        let raw = String(value).lowercased()
        let parts = raw.split(separator: "e", omittingEmptySubsequences: false)
        let exponent = parts.count == 2 ? (Int(parts[1]) ?? 0) : 0
        let mantissa = String(parts[0])
        let sign = mantissa.hasPrefix("-") ? "-" : ""
        let unsigned = mantissa.hasPrefix("-") ? String(mantissa.dropFirst()) : mantissa
        let digits = unsigned.replacingOccurrences(of: ".", with: "")
        let decimalPosition = (unsigned.firstIndex(of: ".").map { unsigned.distance(from: unsigned.startIndex, to: $0) } ?? unsigned.count) + exponent
        if exponent == 0 && !mantissa.contains("e") { return mantissa.hasSuffix(".0") ? String(mantissa.dropLast(2)) : mantissa }
        if decimalPosition > 0 && decimalPosition <= 21 {
            if decimalPosition >= digits.count { return sign + digits + String(repeating: "0", count: decimalPosition - digits.count) }
            return sign + digits.prefix(decimalPosition) + "." + digits.dropFirst(decimalPosition)
        }
        if decimalPosition <= 0 && decimalPosition > -6 {
            return sign + "0." + String(repeating: "0", count: -decimalPosition) + digits
        }
        let coefficient = String(digits.prefix(1)) + (digits.count > 1 ? "." + digits.dropFirst() : "")
        let scientificExponent = decimalPosition - 1
        return sign + coefficient + "e" + (scientificExponent >= 0 ? "+" : "") + String(scientificExponent)
    }
}
