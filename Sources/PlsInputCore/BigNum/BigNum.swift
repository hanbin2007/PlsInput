import Foundation

/// 非负大数，移植 break_eternity.js 的子集。
///
/// `layer == 0` 时值为 `mag`（0 ≤ mag < 9e15，允许小数，用于中间计算）；
/// `layer >= 1` 时值为 10^10^…^mag，共 `layer` 个 10，此时 mag ≥ log10(9e15)。
public struct BigNum: Sendable, Hashable, Codable {
    /// layer 0 的尾数上限，超过即升层。
    public static let expLimit: Double = 9e15
    /// log10(expLimit)，layer ≥ 1 的尾数低于它即降层。
    public static let layerDown: Double = 15.954242509439325
    /// 双精度能分辨的十进制位数，加法中相差超过它的项直接忽略。
    public static let maxSignificantDigits: Double = 17
    private static let log10OfMaxDouble: Double = 308.2547155599167

    public private(set) var layer: Int
    public private(set) var mag: Double

    public static let zero = BigNum(layer: 0, mag: 0)
    public static let one = BigNum(layer: 0, mag: 1)
    public static let ten = BigNum(layer: 0, mag: 10)

    public init(layer: Int, mag: Double) {
        self.layer = layer
        self.mag = mag
        normalize()
    }

    public init(_ value: Double) {
        self.init(layer: 0, mag: value)
    }

    public init(_ value: Int) {
        self.init(layer: 0, mag: Double(value))
    }

    /// 从十进制数字串构造，任意长度。
    public init?(digits: String) {
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let trimmed = digits.drop(while: { $0 == "0" })
        if trimmed.isEmpty {
            self.init(layer: 0, mag: 0)
            return
        }
        if trimmed.count <= 15 {
            self.init(layer: 0, mag: Double(String(trimmed))!)
        } else {
            let head = Double(String(trimmed.prefix(15)))!
            let lg = Foundation.log10(head) + Double(trimmed.count - 15)
            self.init(layer: 1, mag: lg)
        }
    }

    public var isZero: Bool { layer == 0 && mag == 0 }

    private mutating func normalize() {
        if mag.isNaN {
            layer = 0
            mag = 0
            return
        }
        if mag < 0 {
            // 本游戏的值域是非负数，负数只会来自数值误差。
            mag = 0
        }
        if mag.isInfinite {
            layer += 1
            mag = Self.log10OfMaxDouble
        }
        if layer == 0 {
            if mag >= Self.expLimit {
                layer = 1
                mag = Foundation.log10(mag)
            }
            return
        }
        if mag >= Self.expLimit {
            layer += 1
            mag = Foundation.log10(mag)
        }
        while layer > 0 && mag < Self.layerDown {
            layer -= 1
            mag = Foundation.pow(10, mag)
        }
    }

    // MARK: - 比较

    public static func compare(_ a: BigNum, _ b: BigNum) -> Int {
        if a.layer != b.layer { return a.layer < b.layer ? -1 : 1 }
        if a.mag == b.mag { return 0 }
        return a.mag < b.mag ? -1 : 1
    }

    // MARK: - 对数与幂

    /// log10(self)。零返回 nil；小于 1 的 layer 0 值会返回负数。
    public func log10Value() -> BigNum? {
        if layer == 0 {
            guard mag > 0 else { return nil }
            return BigNum(layer: 0, mag: Foundation.log10(mag))
        }
        return BigNum(layer: layer - 1, mag: mag)
    }

    /// 10^x。
    public static func pow10(_ x: BigNum) -> BigNum {
        if x.layer == 0 {
            if x.mag < layerDown {
                return BigNum(layer: 0, mag: Foundation.pow(10, x.mag))
            }
            return BigNum(layer: 1, mag: x.mag)
        }
        return BigNum(layer: x.layer + 1, mag: x.mag)
    }

    /// self^exponent。约定 0^0 = 1。
    public func power(_ exponent: BigNum) -> BigNum {
        if exponent.isZero { return .one }
        if isZero { return .zero }
        if self == .one { return .one }

        if layer == 0 && exponent.layer == 0 {
            let lg = exponent.mag * Foundation.log10(mag)
            if lg < Self.layerDown {
                var r = Foundation.pow(mag, exponent.mag)
                if mag == mag.rounded() && exponent.mag == exponent.mag.rounded() {
                    r = r.rounded()
                }
                return BigNum(layer: 0, mag: r)
            }
            return BigNum(layer: 1, mag: lg)
        }

        if layer == 0 {
            // self 是普通数，exponent 至少一层：结果 = 10^(log10(self) · exponent)
            let c = Foundation.log10(mag)
            return Self.pow10(Self.multiplyByPlain(exponent, c))
        }

        guard let lg = log10Value() else { return .zero }
        return Self.pow10(lg * exponent)
    }

    /// 把一个 layer ≥ 1 的数乘以普通正数 c（c 可以小于 1）。
    private static func multiplyByPlain(_ big: BigNum, _ c: Double) -> BigNum {
        precondition(big.layer >= 1)
        if c <= 0 { return .zero }
        if big.layer == 1 {
            return BigNum(layer: 1, mag: big.mag + Foundation.log10(c))
        }
        // layer ≥ 2 时，任何普通倍数都在精度之下。
        return big
    }

    /// 阶乘。layer 0 且 ≤ 170 时精确，否则用 Stirling 近似。
    public func factorial() -> BigNum {
        if layer == 0 {
            if mag <= 1 { return .one }
            if mag <= 170 && mag == mag.rounded() {
                var r: Double = 1
                var i: Double = 2
                while i <= mag {
                    r *= i
                    i += 1
                }
                return BigNum(layer: 0, mag: r)
            }
            let n = mag
            let lg = n * Foundation.log10(n) - n * 0.4342944819032518 + 0.5 * Foundation.log10(2 * Double.pi * n)
            return BigNum(layer: 1, mag: lg)
        }
        if layer == 1 {
            // n = 10^m：log10(n!) ≈ n·(m − log10 e)
            let m = mag
            let factor = m - 0.4342944819032518
            let lgFactorial = Self.multiplyByPlain(self, factor)
            return Self.pow10(lgFactorial)
        }
        // layer ≥ 2：log10(n!) ≈ n · log10(n)
        guard let lg = log10Value() else { return .zero }
        return Self.pow10(self * lg)
    }

    // MARK: - 超对数与迭代幂

    /// 以 10 为底的超对数，线性近似（与 break_eternity 一致）。零返回 -1。
    public func slog10() -> Double {
        if isZero { return -1 }
        var result = Double(layer)
        var x = mag
        var i = 0
        while i < 100 {
            if x <= 1 {
                return result + x - 1
            }
            result += 1
            x = Foundation.log10(x)
            i += 1
        }
        return result
    }

    /// 10↑↑height，线性近似，是 `slog10` 的反函数。
    public static func tetrate10(_ height: Double) -> BigNum {
        if height <= -1 { return .zero }
        if height < 0 { return BigNum(layer: 0, mag: height + 1) }
        let k = min(Int(height.rounded(.down)), 1000)
        let f = height - Double(k)
        var x = BigNum(layer: 0, mag: Foundation.pow(10, f))
        for _ in 0..<k {
            x = pow10(x)
        }
        return x
    }
}

// MARK: - 运算符

extension BigNum: Comparable {
    public static func < (lhs: BigNum, rhs: BigNum) -> Bool {
        compare(lhs, rhs) < 0
    }
}

extension BigNum {
    public static func + (a: BigNum, b: BigNum) -> BigNum {
        if a.isZero { return b }
        if b.isZero { return a }
        let (big, small) = a >= b ? (a, b) : (b, a)
        if big.layer == 0 && small.layer == 0 {
            return BigNum(layer: 0, mag: big.mag + small.mag)
        }
        if big.layer >= 2 { return big }
        // big.layer == 1，small.layer 是 0 或 1
        let smallLog: Double = small.layer == 0 ? Foundation.log10(small.mag) : small.mag
        let diff = big.mag - smallLog
        if diff > maxSignificantDigits { return big }
        return BigNum(layer: 1, mag: big.mag + Foundation.log10(1 + Foundation.pow(10, -diff)))
    }

    public static func * (a: BigNum, b: BigNum) -> BigNum {
        if a.isZero || b.isZero { return .zero }
        if a.layer == 0 && b.layer == 0 {
            return BigNum(layer: 0, mag: a.mag * b.mag)
        }
        let (big, small) = a >= b ? (a, b) : (b, a)
        if small.layer == 0 {
            return multiplyByPlain(big, small.mag)
        }
        if big.layer >= 3 || big.layer - small.layer >= 2 { return big }
        guard let la = big.log10Value(), let lb = small.log10Value() else { return .zero }
        return pow10(la + lb)
    }
}

extension BigNum: CustomStringConvertible {
    public var description: String {
        BigNumFormatter.string(self)
    }
}
