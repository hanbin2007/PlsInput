import Testing
@testable import PlsInputCore

@Suite("Expression")
struct ExpressionTests {
    private func eval(_ text: String) -> BigNum? {
        var tokens: [Token] = []
        for ch in text {
            switch ch {
            case "0"..."9": tokens.append(.number(String(ch)))
            case "+": tokens.append(.plus)
            case "×", "*": tokens.append(.times)
            case "^": tokens.append(.pow)
            case "!": tokens.append(.factorial)
            case "(": tokens.append(.lparen)
            case ")": tokens.append(.rparen)
            case " ": continue
            default: fatalError("bad char \(ch)")
            }
        }
        return Expression.evaluate(tokens)
    }

    @Test func precedenceAndAssociativity() {
        #expect(eval("1+2×3") == BigNum(7))
        #expect(eval("2×3^2") == BigNum(18))
        #expect(eval("2^3^2") == BigNum(512))
        #expect(eval("2^3!") == BigNum(64))
        #expect(eval("3!^2") == BigNum(36))
        #expect(eval("(2^3)^2") == BigNum(64))
        #expect(eval("3!!") == BigNum(720))
        #expect(eval("(9!)!") == BigNum(9).factorial().factorial())
    }

    @Test func concatenation() {
        #expect(eval("99") == BigNum(99))
        #expect(eval("1 8 9") == BigNum(189))
        #expect(Expression.evaluate([.number("1"), .number("18"), .number("9")]) == BigNum(1189))
        #expect(eval("99^99")?.layer == 1)
    }

    @Test func towers() {
        let nine = BigNum(9)
        #expect(eval("9^9^9") == nine.power(nine.power(nine)))
        #expect(eval("9^9^9^9") == nine.power(nine.power(nine.power(nine))))
    }

    @Test func zeroRules() {
        #expect(eval("0^0") == .one)
        #expect(eval("0!") == .one)
        #expect(eval("0") == .zero)
        #expect(eval("0×9") == .zero)
    }

    @Test func invalid() {
        #expect(eval("") == nil)
        #expect(eval("+") == nil)
        #expect(eval("9+") == nil)
        #expect(eval("+9") == nil)
        #expect(eval("!") == nil)
        #expect(eval("(9") == nil)
        #expect(eval("9)") == nil)
        #expect(eval("()") == nil)
        #expect(eval("9^") == nil)
        #expect(eval("9 9 ^ ^ 9") == nil)
        #expect(eval("9(9)") == nil)
    }
}
