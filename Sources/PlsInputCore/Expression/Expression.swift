import Foundation

/// 表达式的有效词元。数字词元是格子的有效值字符串（增幅格可能是 "18"）。
public enum Token: Hashable, Sendable {
    case number(String)
    case plus
    case times
    case pow
    case factorial
    case lparen
    case rparen

    public init(symbol: KeySymbol) {
        switch symbol {
        case .digit(let d): self = .number(String(d))
        case .plus: self = .plus
        case .times: self = .times
        case .pow: self = .pow
        case .factorial: self = .factorial
        case .lparen: self = .lparen
        case .rparen: self = .rparen
        }
    }
}

/// 设计文档 3.4 节的语法：
///
///     expr    := term ('+' term)*
///     term    := power ('×' power)*
///     power   := postfix ('^' power)?
///     postfix := atom ('!')*
///     atom    := number | '(' expr ')'
///
/// 相邻数字词元按字符串拼接成一个字面量。
public enum Expression {
    /// 求值。不合法返回 nil。
    public static func evaluate(_ tokens: [Token]) -> BigNum? {
        let merged = mergeNumbers(tokens)
        guard !merged.isEmpty else { return nil }
        var parser = Parser(tokens: merged)
        guard let value = parser.parseExpr(), parser.atEnd else { return nil }
        return value
    }

    /// 合法性检查，与 `evaluate` 一致。
    public static func isValid(_ tokens: [Token]) -> Bool {
        evaluate(tokens) != nil
    }

    static func mergeNumbers(_ tokens: [Token]) -> [Token] {
        var out: [Token] = []
        for t in tokens {
            if case .number(let s) = t, case .number(let prev)? = out.last {
                out[out.count - 1] = .number(prev + s)
            } else {
                out.append(t)
            }
        }
        return out
    }

    private struct Parser {
        let tokens: [Token]
        var pos = 0
        var depth = 0

        init(tokens: [Token]) {
            self.tokens = tokens
        }

        var atEnd: Bool { pos >= tokens.count }
        var current: Token? { pos < tokens.count ? tokens[pos] : nil }

        mutating func parseExpr() -> BigNum? {
            guard var acc = parseTerm() else { return nil }
            while current == .plus {
                pos += 1
                guard let rhs = parseTerm() else { return nil }
                acc = acc + rhs
            }
            return acc
        }

        mutating func parseTerm() -> BigNum? {
            guard var acc = parsePower() else { return nil }
            while current == .times {
                pos += 1
                guard let rhs = parsePower() else { return nil }
                acc = acc * rhs
            }
            return acc
        }

        mutating func parsePower() -> BigNum? {
            guard let base = parsePostfix() else { return nil }
            if current == .pow {
                pos += 1
                guard let exponent = parsePower() else { return nil }
                return base.power(exponent)
            }
            return base
        }

        mutating func parsePostfix() -> BigNum? {
            guard var value = parseAtom() else { return nil }
            while current == .factorial {
                pos += 1
                value = value.factorial()
            }
            return value
        }

        mutating func parseAtom() -> BigNum? {
            guard let t = current else { return nil }
            switch t {
            case .number(let s):
                pos += 1
                return BigNum(digits: s)
            case .lparen:
                pos += 1
                depth += 1
                guard depth <= 64, let inner = parseExpr() else { return nil }
                depth -= 1
                guard current == .rparen else { return nil }
                pos += 1
                return inner
            default:
                return nil
            }
        }
    }
}
