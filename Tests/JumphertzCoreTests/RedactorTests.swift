import Testing
@testable import JumphertzCore

struct RedactorTests {
    let redactor = Redactor(userName: "jdoe", fullName: "Jane Doe", homeDirectory: "/Users/jdoe",
                            hostNames: ["Janes-Mac-mini", "Jane’s Mac mini"])

    @Test func homePathsAndOtherUsers() {
        #expect(redactor.redact("/Users/jdoe/Library/Application Support/Jumphertz/config.json")
                == "~/Library/Application Support/Jumphertz/config.json")
        #expect(redactor.redact("see /Users/alice/Desktop/x.txt") == "see /Users/<user>/Desktop/x.txt")
        #expect(redactor.redact("/Users/Shared/file") == "/Users/Shared/file")
    }

    @Test func userAndFullNameAsWholeWords() {
        #expect(redactor.redact("owner: jdoe, name: Jane Doe") == "owner: <user>, name: <user>")
        // Parts of other words stay (the bundle id is public).
        #expect(redactor.redact("com.jdoextra.jumphertz") == "com.jdoextra.jumphertz")
    }

    @Test func hostNames() {
        #expect(redactor.redact("Janes-Mac-mini.local") == "<host>.local")
    }

    @Test func usbSerialNumbers() {
        let uid = "AppleUSBAudioEngine:Focusrite:Scarlett 16i16 4th Gen:Q7W2E9R4T1Y8U3:1,2"
        #expect(redactor.redact(uid) == "AppleUSBAudioEngine:Focusrite:Scarlett 16i16 4th Gen:<serial>:1,2")
        #expect(redactor.redact("serial Y7XHQ2C9KL then") == "serial <serial> then")
    }

    @Test func usefulInformationIsKept() {
        for text in ["Mac16,10", "BlackHole16ch_UID", "Version 26.5.2 (Build 25F84)", "48000 Hz",
                     "Scarlett 16i16 4th Gen", "Apple M4", "com.hnc.Discord"] {
            #expect(redactor.redact(text) == text)
        }
    }

    @Test func realLogLine() {
        let line = #"2026-10-13 23:33:53.875 Df Jumphertz[752:4021] [com.zeropablo.jumphertz:audio] Input leg started: Scarlett 16i16 4th Gen channel 1 at 48000 Hz (uid AppleUSBAudioEngine:Focusrite:Scarlett 16i16 4th Gen:Q7W2E9R4T1Y8U3:1,2, config /Users/jdoe/Library/Application Support/Jumphertz/config.json)"#
        let out = redactor.redact(line)
        #expect(!out.contains("Q7W2E9R4T1Y8U3"))
        #expect(!out.contains("/Users/jdoe"))
        #expect(out.contains("Scarlett 16i16 4th Gen channel 1 at 48000 Hz"))
    }
}
