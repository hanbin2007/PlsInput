import Foundation

/// 把大数映射成 Game Center 的 64 位整数分数，并用 context 字段还原显示。
public enum ScoreCodec {
    public struct Encoded: Sendable, Hashable {
        public var score: Int64
        public var context: Int64
        public init(score: Int64, context: Int64) {
            self.score = score
            self.context = context
        }
    }

    private static let scale: Double = 1e12

    public static func encode(_ v: BigNum) -> Encoded {
        let score = Int64(((v.slog10() + 1) * scale).rounded(.down))
        let context = Int64(bitPattern: v.mag.bitPattern)
        return Encoded(score: score, context: context)
    }

    /// 由分数还原大数。context 存的是规范化尾数，层数由分数反推。
    public static func decode(_ e: Encoded) -> BigNum {
        let mag = Double(bitPattern: UInt64(bitPattern: e.context))
        guard mag.isFinite, mag >= 0 else { return decodeFromScoreOnly(e.score) }
        let target = Double(e.score) / scale - 1
        var best = BigNum(layer: 0, mag: mag)
        var bestDistance = abs(best.slog10() - target)
        for layer in 1...64 {
            let candidate = BigNum(layer: layer, mag: mag)
            let d = abs(candidate.slog10() - target)
            if d < bestDistance {
                best = candidate
                bestDistance = d
            }
        }
        return best
    }

    public static func decodeFromScoreOnly(_ score: Int64) -> BigNum {
        BigNum.tetrate10(Double(score) / scale - 1)
    }
}
