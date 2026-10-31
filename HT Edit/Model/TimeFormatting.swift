//
//  TimeFormatting.swift
//  HT Edit
//

import CoreMedia

nonisolated enum TimeFormatting {
    /// Formats seconds as `m:ss` (or `h:mm:ss`), with `fractionDigits` decimals.
    static func string(_ seconds: Double, fractionDigits: Int = 1) -> String {
        guard seconds.isFinite else { return "--:--" }
        let clamped = max(0, seconds)
        let scale = pow(10, Double(fractionDigits))
        let totalUnits = Int((clamped * scale).rounded(.down))
        let fraction = totalUnits % Int(scale)
        let whole = totalUnits / Int(scale)
        let h = whole / 3600, m = (whole % 3600) / 60, s = whole % 60

        var result = h > 0
            ? "\(h):" + twoDigits(m) + ":" + twoDigits(s)
            : "\(m):" + twoDigits(s)
        if fractionDigits > 0 {
            let digits = String(fraction)
            result += "." + String(repeating: "0", count: fractionDigits - digits.count) + digits
        }
        return result
    }

    static func string(_ time: CMTime, fractionDigits: Int = 1) -> String {
        string(time.seconds, fractionDigits: fractionDigits)
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
