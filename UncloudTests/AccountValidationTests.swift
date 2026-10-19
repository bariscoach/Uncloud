import Testing
@testable import Uncloud

@Suite("AccountValidation")
struct AccountValidationTests {
    @Test("Valid emails are trimmed and lowercased", arguments: [
        ("name@example.com", "name@example.com"),
        ("  Name@Example.COM \n", "name@example.com"),
        ("a.b+c@sub.example.co.uk", "a.b+c@sub.example.co.uk"),
        ("josé@example.com", "josé@example.com"),
    ])
    func acceptsValidEmails(raw: String, expected: String) {
        #expect(EmailAddress.normalized(raw) == expected)
    }

    @Test("Malformed emails are rejected", arguments: [
        "",
        "no-at-sign.com",
        "a@b@example.com",
        "@example.com",
        "name@",
        "name@example",
        "name@example.",
        "name@.example.com",
        "name@example..com",
        "name@-example.com",
        "name@example.c",
        "name@example.com1",
        "na me@example.com",
    ])
    func rejectsMalformedEmails(raw: String) {
        #expect(EmailAddress.normalized(raw) == nil)
    }

    @Test("The length limit is 254 characters")
    func lengthLimit() {
        let atLimit = String(repeating: "a", count: 242) + "@example.com"
        let overLimit = String(repeating: "a", count: 243) + "@example.com"
        #expect(atLimit.count == 254)
        #expect(EmailAddress.normalized(atLimit) == atLimit)
        #expect(EmailAddress.normalized(overLimit) == nil)
    }

    @Test("Pasted codes keep only the first six digits")
    func sanitizesCodes() {
        #expect(OneTimeCode.sanitized("123 456") == "123456")
        #expect(OneTimeCode.sanitized("Your code is 123456") == "123456")
        #expect(OneTimeCode.sanitized("1234567") == "123456")
        #expect(OneTimeCode.sanitized("12a34b5") == "12345")
        #expect(OneTimeCode.sanitized("") == "")
    }

    @Test("A code is complete only at exactly six digits")
    func completeCodes() {
        #expect(OneTimeCode.isComplete("123456"))
        #expect(!OneTimeCode.isComplete("12345"))
        #expect(!OneTimeCode.isComplete("1234567"))
        #expect(!OneTimeCode.isComplete("12a456"))
    }
}
