import Foundation

/// ADR-5: Custom when-clause expression parser and evaluator.
/// Pure, side-effect-free boolean expressions for plugin visibility.
/// Evaluates in microseconds — safe for the hot path (every focus switch).

// MARK: - AST

/// Abstract syntax tree node for when-clause expressions.
indirect enum WhenClauseNode: Equatable {
    case variable(String)
    case stringLiteral(String)
    case equals(WhenClauseNode, WhenClauseNode)
    case notEquals(WhenClauseNode, WhenClauseNode)
    case and(WhenClauseNode, WhenClauseNode)
    case or(WhenClauseNode, WhenClauseNode)
    case not(WhenClauseNode)
    case alwaysTrue
}

// MARK: - Parser

/// Recursive descent parser for when-clause expressions.
/// Grammar:
///   expr     = or_expr
///   or_expr  = and_expr ('||' and_expr)*
///   and_expr = unary ('&&' unary)*
///   unary    = '!' unary | primary
///   primary  = variable | string_literal | '(' expr ')' | comparison
///   comparison = variable ('==' | '!=') (variable | string_literal)
struct WhenClauseParser {

    struct ParseError: Error, CustomStringConvertible {
        let message: String
        let position: Int
        var description: String { message }
    }

    static func parse(_ input: String) throws -> WhenClauseNode {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .alwaysTrue }
        var parser = WhenClauseParser(input: trimmed)
        let result = try parser.parseExpression()
        parser.skipWhitespace()
        if parser.position < parser.chars.count {
            throw ParseError(message: "Unexpected token '\(parser.chars[parser.position])' at position \(parser.position)", position: parser.position)
        }
        return result
    }

    private let chars: [Character]
    private var position: Int = 0

    private init(input: String) {
        self.chars = Array(input)
    }

    private mutating func parseExpression() throws -> WhenClauseNode {
        try parseOr()
    }

    private mutating func parseOr() throws -> WhenClauseNode {
        var left = try parseAnd()
        while match("||") {
            let right = try parseAnd()
            left = .or(left, right)
        }
        return left
    }

    private mutating func parseAnd() throws -> WhenClauseNode {
        var left = try parseUnary()
        while match("&&") {
            let right = try parseUnary()
            left = .and(left, right)
        }
        return left
    }

    private mutating func parseUnary() throws -> WhenClauseNode {
        if match("!") {
            let operand = try parseUnary()
            return .not(operand)
        }
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws -> WhenClauseNode {
        skipWhitespace()
        guard position < chars.count else {
            throw ParseError(message: "Unexpected end of expression", position: position)
        }

        // Parenthesized expression
        if chars[position] == "(" {
            position += 1
            let expr = try parseExpression()
            skipWhitespace()
            guard position < chars.count, chars[position] == ")" else {
                throw ParseError(message: "Expected ')' at position \(position)", position: position)
            }
            position += 1
            return expr
        }

        // String literal
        if chars[position] == "'" || chars[position] == "\"" {
            return .stringLiteral(try parseString())
        }

        // Variable (possibly followed by comparison operator)
        let varName = parseIdentifier()
        guard !varName.isEmpty else {
            throw ParseError(message: "Expected variable name at position \(position)", position: position)
        }

        skipWhitespace()

        // Check for comparison
        if match("==") {
            let rhs = try parseComparisonRHS()
            return .equals(.variable(varName), rhs)
        }
        if match("!=") {
            let rhs = try parseComparisonRHS()
            return .notEquals(.variable(varName), rhs)
        }

        return .variable(varName)
    }

    private mutating func parseComparisonRHS() throws -> WhenClauseNode {
        skipWhitespace()
        guard position < chars.count else {
            throw ParseError(message: "Expected value after operator at position \(position)", position: position)
        }
        if chars[position] == "'" || chars[position] == "\"" {
            return .stringLiteral(try parseString())
        }
        let name = parseIdentifier()
        guard !name.isEmpty else {
            throw ParseError(message: "Expected value at position \(position)", position: position)
        }
        return .variable(name)
    }

    private mutating func parseString() throws -> String {
        let quote = chars[position]
        position += 1
        var result = ""
        while position < chars.count, chars[position] != quote {
            result.append(chars[position])
            position += 1
        }
        guard position < chars.count else {
            throw ParseError(message: "Unterminated string at position \(position)", position: position)
        }
        position += 1 // consume closing quote
        return result
    }

    private mutating func parseIdentifier() -> String {
        skipWhitespace()
        var result = ""
        while position < chars.count {
            let c = chars[position]
            if c.isLetter || c.isNumber || c == "." || c == "_" {
                result.append(c)
                position += 1
            } else {
                break
            }
        }
        return result
    }

    private mutating func skipWhitespace() {
        while position < chars.count, chars[position].isWhitespace {
            position += 1
        }
    }

    private mutating func match(_ s: String) -> Bool {
        skipWhitespace()
        let sChars = Array(s)
        guard position + sChars.count <= chars.count else { return false }
        for (i, c) in sChars.enumerated() {
            if chars[position + i] != c { return false }
        }
        position += sChars.count
        return true
    }
}

// MARK: - Evaluator

/// Evaluates a parsed when-clause AST against a TerminalContext.
/// Pure function: (WhenClauseNode, TerminalContext) -> Bool
struct WhenClauseEvaluator {

    static func evaluate(_ node: WhenClauseNode, context: TerminalContext) -> Bool {
        switch node {
        case .alwaysTrue:
            return true
        case .variable(let name):
            return resolveBool(name, context: context)
        case .stringLiteral:
            return true // bare string literal is truthy
        case .equals(let lhs, let rhs):
            return resolveString(lhs, context: context) == resolveString(rhs, context: context)
        case .notEquals(let lhs, let rhs):
            return resolveString(lhs, context: context) != resolveString(rhs, context: context)
        case .and(let lhs, let rhs):
            return evaluate(lhs, context: context) && evaluate(rhs, context: context)
        case .or(let lhs, let rhs):
            return evaluate(lhs, context: context) || evaluate(rhs, context: context)
        case .not(let operand):
            return !evaluate(operand, context: context)
        }
    }

    /// Resolve a variable name to a boolean value.
    private static func resolveBool(_ name: String, context: TerminalContext) -> Bool {
        switch name {
        case "env.local": return context.remoteSession == nil
        case "env.ssh":
            if case .ssh = context.remoteSession { return true }
            return false
        case "env.docker":
            if case .docker = context.remoteSession { return true }
            return false
        case "remote": return context.isRemote
        case "git", "git.active": return context.gitContext != nil
        case "git.dirty": return context.gitContext?.isDirty ?? false
        default:
            return false
        }
    }

    /// Resolve a node to a string value for comparison.
    private static func resolveString(_ node: WhenClauseNode, context: TerminalContext) -> String {
        switch node {
        case .variable(let name):
            return resolveStringValue(name, context: context)
        case .stringLiteral(let value):
            return value
        default:
            return ""
        }
    }

    /// Resolve a variable name to a string value.
    private static func resolveStringValue(_ name: String, context: TerminalContext) -> String {
        switch name {
        case "process.name": return context.processName
        case "git.branch": return context.gitContext?.branch ?? ""
        case "env.type":
            if case .ssh = context.remoteSession { return "ssh" }
            if case .docker = context.remoteSession { return "docker" }
            return "local"
        case "remote.host":
            if case .ssh(let host) = context.remoteSession { return host }
            if case .docker(let container) = context.remoteSession { return container }
            return ""
        case "cwd": return context.cwd
        default:
            return ""
        }
    }
}
