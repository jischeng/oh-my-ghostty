import Foundation
import Testing
@testable import Ghostty

struct AISecretRedactorTests {
    @Test func everyPatternCompiles() {
        #expect(AISecretRedactor.allRulesCompiled)
    }

    @Test func redactsWellKnownTokenShapes() {
        let prompt = """
            export OPENAI_API_KEY=sk-proj-AbCdEfGhIjKlMnOpQrStUvWx
            key sk-ant-api03-AbCdEfGhIjKlMnOpQrSt
            slack xoxb-123456789012-AbCdEfGhIjKl
            github ghp_0123456789abcdefghijABCDEF
            pat github_pat_11ABCDEFG0123456789_abcdefghijklmnop
            npm npm_0123456789abcdefghijABCDEFGHIJ
            """
        let redacted = AISecretRedactor.redact(prompt)
        for secret in ["sk-proj-", "sk-ant-", "xoxb-", "ghp_", "github_pat_", "npm_"] {
            #expect(!redacted.contains(secret), "\(secret) survived: \(redacted)")
        }
        #expect(redacted.contains("[REDACTED]"))
    }

    @Test func redactsJWTBearerAndURLUserinfo() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        let prompt = "Authorization: Bearer abcdefgh12345678\n"
            + "token \(jwt)\n"
            + "clone https://x-access-token:ghp_abcdefghijklmnopqrstuvwxyz@github.com/acme/repo\n"
            + "plain https://github.com/acme/repo"
        let redacted = AISecretRedactor.redact(prompt)
        #expect(!redacted.contains("abcdefgh12345678"))
        #expect(!redacted.contains(jwt))
        #expect(!redacted.contains("x-access-token"))
        #expect(redacted.contains("https://[REDACTED]@github.com/acme/repo"))
        #expect(redacted.contains("plain https://github.com/acme/repo"))
    }

    @Test func redactsKeyValuePairs() {
        let prompt = "password: hunter2\napi_key = \"abc123xyz\"\nSECRET='shh-very-secret'\nkey=abcdefgh"
        let redacted = AISecretRedactor.redact(prompt)
        for secret in ["hunter2", "abc123xyz", "shh-very-secret", "key=abcdefgh"] {
            #expect(!redacted.contains(secret), "\(secret) survived: \(redacted)")
        }
        #expect(redacted.contains("password: [REDACTED]"))
        #expect(redacted.contains("api_key = \"[REDACTED]\""))
    }

    @Test func redactsPEMBlocks() {
        let pem = """
            before
            -----BEGIN RSA PRIVATE KEY-----
            MIIEowIBAAKCAQEA1234
            -----END RSA PRIVATE KEY-----
            after
            """
        let redacted = AISecretRedactor.redact(pem)
        #expect(!redacted.contains("MIIEowIBAAKCAQEA1234"))
        #expect(!redacted.contains("BEGIN RSA PRIVATE KEY"))
    }

    @Test func leavesOrdinaryPromptTextAlone() {
        let prompt = "Fix the inbox sorting test in TabInboxModel and add a regression test."
        #expect(AISecretRedactor.redact(prompt) == prompt)
        #expect(AISecretRedactor.redact("https://github.com/acme/repo") == "https://github.com/acme/repo")
    }

    @Test func aKnownSecretIsRemovedFromServiceTextWhateverItLooksLike() {
        let key = "plain-looking-value"
        let body = #"{"error":"Incorrect API key provided: plain-looking-value. Find yours in the dashboard."}"#
        let shown = AISecretRedactor.redact(body, hiding: key)
        #expect(!shown.contains(key))
        #expect(shown.contains("Incorrect API key provided"))
        #expect(AISecretRedactor.redact(body, hiding: nil) == AISecretRedactor.redact(body))
        #expect(AISecretRedactor.redact(body, hiding: "") == AISecretRedactor.redact(body))
    }

    @Test func redactionIsIdempotent() {
        let prompt = "password: hunter2 and sk-abcdefghijklmnopqrstuvwx"
        let once = AISecretRedactor.redact(prompt)
        #expect(AISecretRedactor.redact(once) == once)
    }
}
