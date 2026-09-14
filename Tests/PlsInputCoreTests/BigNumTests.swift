import Testing
@testable import PlsInputCore

@Suite("BigNum")
struct BigNumTests {
    @Test func smallPowersAreExact() {
        #expect(BigNum(9).power(BigNum(9)) == BigNum(387_420_489))
        #expect(BigNum(3).power(BigNum(30)) == BigNum(205_891_132_094_649))
        #expect(BigNum(0).power(BigNum(0)) == .one)
        #expect(BigNum(0).power(BigNum(5)) == .zero)
    }

    @Test func nineTowerOfThree() {
        let v = BigNum(9).power(BigNum(9).power(BigNum(9)))
        #expect(v.layer == 1)
        // 9^9 · log10(9) = 387420489 × 0.954242509… = 369,693,099.63
        #expect(abs(v.mag - 369_693_099.63) < 0.01)
    }

    @Test func nineTowerOfFour() {
        let nine = BigNum(9)
        let v = nine.power(nine.power(nine.power(nine)))
        #expect(v.layer == 2)
        // log10(9^(9^9^9)) = 10^369693099.63 · 0.9542 → 层 2 尾数 369693099.63 + log10(0.9542)
        #expect(abs(v.mag - (369_693_099.63 - 0.0203)) < 0.01)
    }

    @Test func factorials() {
        #expect(BigNum(9).factorial() == BigNum(362_880))
        #expect(BigNum(20).factorial() == BigNum(2_432_902_008_176_640_000))
        let big = BigNum(9).factorial().factorial()
        #expect(big.layer == 1)
        #expect(abs(big.mag - 1_859_933.4) < 1)
        let triple = big.factorial()
        #expect(triple.layer == 2)
        #expect(abs(triple.mag - (1_859_933.4 + 6.2689)) < 0.5)
    }

    @Test func additionAndMultiplication() {
        #expect(BigNum(1e20) + BigNum(1e20) == BigNum(2e20))
        #expect(BigNum(99_999_999) * BigNum(99_999_999) == BigNum(9_999_999_800_000_001))
        let a = BigNum(layer: 1, mag: 20)
        let b = BigNum(layer: 1, mag: 20)
        #expect(abs((a + b).mag - 20.30103) < 1e-6)
        #expect(abs((a * b).mag - 40) < 1e-9)
        let huge = BigNum(layer: 3, mag: 20)
        #expect(huge + a == huge)
        #expect(huge * a == huge)
    }

    @Test func thresholdsAreStrictlyIncreasing() throws {
        let texts = ["1e3", "1e6", "1e12", "1e30", "1e100", "10^10^3", "10^10^6", "10^10^10", "10^10^100", "10^^4"]
        let values = try texts.map { try #require(BigNum(threshold: $0)) }
        for i in 1..<values.count {
            #expect(values[i - 1] < values[i], "\(texts[i - 1]) < \(texts[i])")
        }
        #expect(values[0] == BigNum(1000))
        #expect(values[4] == BigNum(layer: 1, mag: 100))
        #expect(values[9] == BigNum(layer: 2, mag: 1e10))
        #expect(values[9].slog10() == 4)
    }

    @Test func orderingAcrossKnownValues() throws {
        let nine = BigNum(9)
        let tower3 = nine.power(nine.power(nine))
        let tower4 = nine.power(tower3)
        let t9 = try #require(BigNum(threshold: "10^10^100"))
        let t10 = try #require(BigNum(threshold: "10^^4"))
        #expect(tower3 < t9)
        #expect(t9 < tower4)
        #expect(tower4 < t10)
    }

    @Test func digitsInit() {
        #expect(BigNum(digits: "0009") == BigNum(9))
        #expect(BigNum(digits: "189") == BigNum(189))
        let long = BigNum(digits: String(repeating: "9", count: 30))
        #expect(long?.layer == 1)
        #expect(abs((long?.mag ?? 0) - 30) < 1e-9)
        #expect(BigNum(digits: "") == nil)
        #expect(BigNum(digits: "1a") == nil)
    }

    @Test func slogIsMonotonic() {
        var rng = SplitMix64(seed: 42)
        var samples: [BigNum] = []
        for _ in 0..<2000 {
            samples.append(randomBigNum(&rng))
        }
        samples.sort()
        for i in 1..<samples.count {
            #expect(samples[i - 1].slog10() <= samples[i].slog10())
        }
    }

    @Test func slogTetrateRoundTrip() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<500 {
            let v = randomBigNum(&rng)
            let back = BigNum.tetrate10(v.slog10())
            #expect(back.layer == v.layer)
            let rel = abs(back.mag - v.mag) / max(v.mag, 1)
            #expect(rel < 1e-6)
        }
    }

    @Test func scoreCodecRoundTripAndOrder() {
        var rng = SplitMix64(seed: 99)
        var samples: [BigNum] = []
        for _ in 0..<2000 {
            samples.append(randomBigNum(&rng))
        }
        samples.sort()
        for i in 0..<samples.count {
            let e = ScoreCodec.encode(samples[i])
            #expect(e.score >= 0)
            #expect(ScoreCodec.decode(e) == samples[i])
            if i > 0 {
                let prev = ScoreCodec.encode(samples[i - 1])
                #expect(prev.score <= e.score)
            }
        }
    }

    @Test func formatter() throws {
        #expect(BigNumFormatter.string(BigNum(362_880)) == "362,880")
        #expect(BigNumFormatter.string(BigNum(1.2e12)) == "1.2×10^12")
        #expect(BigNumFormatter.string(BigNum(9_999_999)) == "1×10^7")
        let nine = BigNum(9)
        let tower3 = nine.power(nine.power(nine))
        #expect(BigNumFormatter.string(tower3) == "4.3×10^369,693,099")
        let tower4 = nine.power(tower3)
        #expect(BigNumFormatter.string(tower4) == "10^10^10^8.57")
        let t10 = try #require(BigNum(threshold: "10^^4"))
        #expect(BigNumFormatter.string(t10) == "10^10^10^10")
        let t7 = try #require(BigNum(threshold: "10^10^6"))
        #expect(BigNumFormatter.string(t7) == "1×10^1,000,000")
        #expect(BigNumFormatter.string(BigNum(layer: 6, mag: 20)) == "10↑↑7.1")
    }

    private func randomBigNum(_ rng: inout SplitMix64) -> BigNum {
        let layer = Int(rng.next() % 5)
        if layer == 0 {
            let mag = Double(rng.next() % 9_000_000_000_000_000)
            return BigNum(layer: 0, mag: mag)
        }
        let unit = Double(rng.next() % 1_000_000) / 1_000_000
        let mag = BigNum.layerDown + unit * (1e9 - BigNum.layerDown)
        return BigNum(layer: layer, mag: mag)
    }
}
