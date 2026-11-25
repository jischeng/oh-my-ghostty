import Foundation

/// Removes credential-shaped values from a first prompt before it leaves the process.
/// Patterns are deliberately broad: a lost word is cheaper than a leaked token.
enum AISecretRedactor {
    static let placeholder = "[REDACTED]"

    private static let rules: [(pattern: String, template: String)] = [
        // PEM private key blocks, including the trailing END line when present.
        ("-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----(?:[\\s\\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----|[\\s\\S]*)",
         placeholder),
        // URL userinfo such as https://user:token@host/ (tokens often sit in the user slot).
        ("\\b([a-z][a-z0-9+.-]*)://[^/\\s@]+@", "$1://\(placeholder)@"),
        ("(?i)\\bbearer\\s+[A-Za-z0-9._~+/=-]{8,}", "Bearer \(placeholder)"),
        ("\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}", placeholder),
        ("\\bsk-ant-[A-Za-z0-9_-]{8,}", placeholder),
        ("\\bsk-[A-Za-z0-9_-]{16,}", placeholder),
        ("\\bxox[abprs]-[A-Za-z0-9-]{8,}", placeholder),
        ("\\bgithub_pat_[A-Za-z0-9_]{20,}", placeholder),
        ("\\bgh[pousr]_[A-Za-z0-9]{20,}", placeholder),
        ("\\bglpat-[A-Za-z0-9_-]{16,}", placeholder),
        ("\\bAKIA[0-9A-Z]{16}\\b", placeholder),
        ("\\bAIza[0-9A-Za-z_-]{30,}", placeholder),
        ("\\bnpm_[A-Za-z0-9]{30,}", placeholder),
        ("(?i)\\b(api[_-]?key|access[_-]?key|secret[_-]?key|key|token|password|passwd|secret)"
         + "(\\s*[:=]\\s*)([\"']?)(?![\\s\"']*(?:\\[REDACTED\\]|<\\/))[^\\s\"']{4,}\\3",
         "$1$2$3\(placeholder)$3"),
    ]

    private static let expressions: [(NSRegularExpression, String)] = rules.compactMap { rule in
        (try? NSRegularExpression(pattern: rule.pattern)).map { ($0, rule.template) }
    }

    /// False if a pattern failed to compile and is therefore not applied. Asserted by the tests.
    static var allRulesCompiled: Bool { expressions.count == rules.count }

    /// For text shown to the user that a service wrote, such as an error body: removes
    /// every literal occurrence of `secret` (the key that was sent) before the pattern rules run.
    static func redact(_ text: String, hiding secret: String?) -> String {
        guard let secret, !secret.isEmpty else { return redact(text) }
        return redact(text.replacingOccurrences(of: secret, with: placeholder))
    }

    static func redact(_ text: String) -> String {
        var result = text
        for (expression, template) in expressions {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        return result
    }
}
