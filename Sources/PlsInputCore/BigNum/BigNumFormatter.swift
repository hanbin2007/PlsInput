import Foundation

/// 设计文档 5.3 节的显示规则。
public enum BigNumFormatter {
    public static func string(_ v: BigNum) -> String {
        if v.layer == 0 {
            if v.mag < 1e6 {
                if v.mag == v.mag.rounded() {
                    return grouped(Int64(v.mag))
                }
                return trimmed(v.mag, fractionDigits: 2)
            }
            return scientific(log10: Foundation.log10(v.mag))
        }
        var level = v.layer
        var m = v.mag
        while m >= 1e9 {
            m = Foundation.log10(m)
            level += 1
        }
        while level >= 2 && m >= 1e6 {
            m = Foundation.log10(m)
            level += 1
        }
        switch level {
        case 1:
            return scientific(log10: m)
        case 2...4:
            return String(repeating: "10^", count: level) + trimmed(m, fractionDigits: 2)
        default:
            return "10↑↑" + trimmed(v.slog10(), fractionDigits: 1)
        }
    }

    /// `a.b×10^N`，N 带千分位。
    private static func scientific(log10 lg: Double) -> String {
        var n = lg.rounded(.down)
        var a = Foundation.pow(10, lg - n)
        var mantissa = (a * 10).rounded() / 10
        if mantissa >= 10 {
            n += 1
            a = 1
            mantissa = 1
        }
        return trimmed(mantissa, fractionDigits: 1) + "×10^" + grouped(Int64(n))
    }

    private static func grouped(_ n: Int64) -> String {
        var s = String(n.magnitude)
        var out = ""
        var count = 0
        for ch in s.reversed() {
            if count > 0 && count % 3 == 0 { out.append(",") }
            out.append(ch)
            count += 1
        }
        s = String(out.reversed())
        return n < 0 ? "-" + s : s
    }

    private static func trimmed(_ x: Double, fractionDigits: Int) -> String {
        var s = String(format: "%.\(fractionDigits)f", x)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}
