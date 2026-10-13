import Testing
@testable import JumphertzCore

private func device(_ name: String, _ manufacturer: String, uid: String, inputs: Int = 2, outputs: Int = 2,
                    aggregate: Bool = false) -> DeviceInfo {
    DeviceInfo(id: 1, uid: uid, name: name, manufacturer: manufacturer,
               inputChannels: inputs, outputChannels: outputs, sampleRate: 48000, isAggregate: aggregate)
}

struct DeviceMatchingTests {
    let s16 = device("Scarlett 16i16 USB", "Focusrite", uid: "AppleUSBAudioEngine:Focusrite:Scarlett 16i16 USB:B:1", inputs: 18, outputs: 16)
    let s2 = device("Scarlett 2i2 4th Gen", "Focusrite", uid: "AppleUSBAudioEngine:Focusrite:Scarlett 2i2 4th Gen:A:1")
    let clarett = device("Clarett+ 4Pre", "Focusrite", uid: "clarett")
    let fakeAggregate = device("Scarlett + BlackHole", "Focusrite", uid: "agg", aggregate: true)
    let bh2 = device("BlackHole 2ch", "Existential Audio Inc.", uid: "BlackHole2ch_UID")
    let bh16 = device("BlackHole 16ch", "Existential Audio Inc.", uid: "BlackHole16ch_UID", inputs: 16, outputs: 16)
    let mac = device("MacBook Pro Microphone", "Apple Inc.", uid: "BuiltInMic", inputs: 1, outputs: 0)

    @Test func scarlettMatching() {
        #expect(DeviceMatching.isScarlett(s16))
        #expect(DeviceMatching.isScarlett(device("SCARLETT SOLO USB", "focusrite", uid: "x")))
        #expect(!DeviceMatching.isScarlett(clarett))
        #expect(!DeviceMatching.isScarlett(fakeAggregate))
        #expect(!DeviceMatching.isScarlett(device("Scarlett 2i2", "Other", uid: "x")))
        #expect(!DeviceMatching.isScarlett(device("Scarlett 2i2", "Focusrite", uid: "x", inputs: 0)))
    }

    @Test func singleScarlettSelectedWithoutWarning() {
        #expect(DeviceMatching.selectInput(from: [mac, s16, bh2], preferredUID: nil) == .selected(s16, warning: nil))
    }

    @Test func multipleScarlettsPickFirstByUIDWithWarning() {
        guard case let .selected(device, warning) = DeviceMatching.selectInput(from: [s16, s2], preferredUID: nil) else {
            Issue.record("expected a selection"); return
        }
        #expect(device == s16)  // "...Scarlett 16i16..." sorts before "...Scarlett 2i2..."
        #expect(warning != nil)
    }

    @Test func configuredUIDWins() {
        #expect(DeviceMatching.selectInput(from: [s16, s2], preferredUID: s16.uid) == .selected(s16, warning: nil))
    }

    @Test func configuredUIDMissingDoesNotFallBack() {
        #expect(DeviceMatching.selectInput(from: [s16], preferredUID: "gone") == .configuredNotFound(uid: "gone"))
    }

    @Test func noScarlett() {
        #expect(DeviceMatching.selectInput(from: [mac, bh2], preferredUID: nil) == .noneFound)
    }

    @Test func defaultOutputIsBlackHole2chByName() {
        #expect(DeviceMatching.selectOutput(from: [bh16, bh2, s16], preferredUID: nil) == .selected(bh2))
        #expect(DeviceMatching.selectOutput(from: [bh16, s16], preferredUID: nil) == .noneFound)
    }

    @Test func configuredOutput() {
        #expect(DeviceMatching.selectOutput(from: [bh16, bh2], preferredUID: bh16.uid) == .selected(bh16))
        #expect(DeviceMatching.selectOutput(from: [bh2], preferredUID: "nope") == .configuredNotFound(uid: "nope"))
    }

    @Test func blackHoleDetection() {
        #expect(DeviceMatching.isBlackHole(bh2))
        #expect(DeviceMatching.isBlackHole(bh16))
        #expect(!DeviceMatching.isBlackHole(s16))
    }

    @Test func feedbackDetection() {
        let multi = AggregateInfo(uid: "m", name: "Multi", isMultiOutput: true, subDeviceUIDs: ["Speakers", bh2.uid])
        let other = AggregateInfo(uid: "o", name: "Other", isMultiOutput: false, subDeviceUIDs: [s16.uid])
        #expect(DeviceMatching.aggregatesContaining(bh2.uid, in: [multi, other]) == [multi])
    }
}
