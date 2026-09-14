import Foundation

extension BigNum {
    /// 解析阈值写法：`1e3`、`1e100`、`10^10^3`、`10^^4`、纯数字。
    public init?(threshold text: String) {
        let s = text.replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty else { return nil }
        if let range = s.range(of: "^^") {
            let base = String(s[s.startIndex..<range.lowerBound])
            let height = String(s[range.upperBound...])
            guard base == "10", let h = Double(height), h >= 0 else { return nil }
            self = BigNum.tetrate10(h)
            return
        }
        if s.contains("^") {
            let parts = s.split(separator: "^", omittingEmptySubsequences: false).map(String.init)
            guard parts.allSatisfy({ !$0.isEmpty }) else { return nil }
            var values: [BigNum] = []
            for p in parts {
                guard let v = BigNum(threshold: p) else { return nil }
                values.append(v)
            }
            var acc = values[values.count - 1]
            for v in values.dropLast().reversed() {
                acc = v.power(acc)
            }
            self = acc
            return
        }
        if let eIndex = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            let mantissaText = String(s[s.startIndex..<eIndex])
            let exponentText = String(s[s.index(after: eIndex)...])
            guard let m = Double(mantissaText), m > 0, let e = Double(exponentText) else { return nil }
            let lg = Foundation.log10(m) + e
            if lg < BigNum.layerDown {
                self = BigNum(layer: 0, mag: Foundation.pow(10, lg).rounded())
            } else {
                self = BigNum(layer: 1, mag: lg)
            }
            return
        }
        if let v = BigNum(digits: s) {
            self = v
            return
        }
        return nil
    }
}
