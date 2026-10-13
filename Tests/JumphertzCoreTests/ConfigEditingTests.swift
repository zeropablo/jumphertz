import Foundation
import Testing
@testable import JumphertzCore

/// `jumphertz --set-…` validation against the connected devices.
struct ConfigEditingTests {
    let devices = [scarlett, scarlettSolo, blackHole, blackHole16, builtInMic]

    private func apply(_ edit: ConfigEdit, to config: Config = .default, devices: [DeviceInfo]? = nil) throws -> ConfigEditOutcome {
        try ConfigEditing.apply(edit, to: config, devices: devices ?? self.devices)
    }

    // MARK: Channel

    @Test func channelWithinTheInterface() throws {
        let outcome = try apply(.inputChannel(18))       // auto → first Scarlett by UID ("scarlett" < "solo")
        #expect(outcome.config.inputChannel == 18)
        #expect(outcome.effect == .live)
        #expect(outcome.changes == ["inputChannel: 1 → 18"])
        #expect(outcome.warnings.isEmpty)
    }

    @Test func channelOutOfRangeNamesTheInterfaceAndTheRange() {
        var config = Config.default
        config.deviceUID = "solo"
        #expect(throws: ConfigEditError.channelOutOfRange(requested: 3, device: "Scarlett Solo 4th Gen", inputs: 2)) {
            try apply(.inputChannel(3), to: config)
        }
        let message = ConfigEditError.channelOutOfRange(requested: 3, device: "Scarlett Solo 4th Gen", inputs: 2).description
        #expect(message.contains("use 1–2"))
    }

    @Test func channelMustBePositive() {
        #expect(throws: ConfigEditError.channelNotPositive(0)) { try apply(.inputChannel(0)) }
        #expect(throws: ConfigEditError.channelNotPositive(-2)) { try apply(.inputChannel(-2)) }
    }

    @Test func channelAcceptedWithoutInterfaceWithWarning() throws {
        let outcome = try apply(.inputChannel(5), devices: [blackHole])
        #expect(outcome.config.inputChannel == 5)
        #expect(outcome.warnings.count == 1)
        #expect(outcome.warnings[0].contains("No Scarlett connected"))
    }

    @Test func sameValueIsNoChange() throws {
        let outcome = try apply(.inputChannel(1))
        #expect(outcome.changes.isEmpty)
        #expect(outcome.effect == .none)
    }

    // MARK: Gain

    @Test func gainParsing() throws {
        #expect(try ConfigEditing.parseGain("-6") == -6)
        #expect(try ConfigEditing.parseGain("+3.5") == 3.5)
        #expect(try ConfigEditing.parseGain("0") == 0)
        #expect(try ConfigEditing.parseGain(" -6dB ") == -6)
        #expect(try ConfigEditing.parseGain("-6 db") == -6)
        for bad in ["abc", "nan", "inf", "", "6..5", "--6"] {
            #expect(throws: ConfigEditError.invalidNumber(bad)) { try ConfigEditing.parseGain(bad) }
        }
    }

    @Test func gainRange() throws {
        #expect(try apply(.gainDb(-60)).config.gainDb == -60)
        #expect(try apply(.gainDb(24)).config.gainDb == 24)
        #expect(try apply(.gainDb(-6)).effect == .live)
        #expect(throws: ConfigEditError.gainOutOfRange(25)) { try apply(.gainDb(25)) }
        #expect(throws: ConfigEditError.gainOutOfRange(-61)) { try apply(.gainDb(-61)) }
    }

    // MARK: Interface

    @Test func knownScarlettAndAuto() throws {
        let outcome = try apply(.inputDevice("solo"))
        #expect(outcome.config.deviceUID == "solo")
        #expect(outcome.effect == .rebuildsInput)

        var config = Config.default
        config.deviceUID = "solo"
        #expect(try apply(.inputDevice(nil), to: config).config.deviceUID == nil)
        #expect(ConfigEditing.parseUID("auto") == nil)
        #expect(ConfigEditing.parseUID("AUTO") == nil)
        #expect(ConfigEditing.parseUID(" solo ") == "solo")
    }

    @Test func unknownScarlettListsTheValidUIDs() {
        #expect(throws: ConfigEditError.unknownInputDevice(uid: "nope", valid: [scarlett, scarlettSolo])) {
            try apply(.inputDevice("nope"))
        }
        let message = ConfigEditError.unknownInputDevice(uid: "nope", valid: [scarlett]).description
        #expect(message.contains("jumphertz --set-device \"scarlett\""))
        #expect(message.contains("jumphertz --set-device auto"))
    }

    @Test func otherDevicesAreNotInterfaces() {
        #expect(throws: ConfigEditError.notAScarlett(uid: builtInMic.uid, name: builtInMic.name)) {
            try apply(.inputDevice(builtInMic.uid))
        }
        #expect(throws: ConfigEditError.notAScarlett(uid: blackHole.uid, name: blackHole.name)) {
            try apply(.inputDevice(blackHole.uid))
        }
    }

    @Test func switchingToASmallerInterfaceChecksTheChannel() {
        var config = Config.default
        config.inputChannel = 5
        #expect(throws: ConfigEditError.channelNotOnNewDevice(channel: 5, device: "Scarlett Solo 4th Gen", inputs: 2)) {
            try apply(.inputDevice("solo"), to: config)
        }
    }

    // MARK: Output

    @Test func blackHoleOutputs() throws {
        let outcome = try apply(.outputDevice(blackHole16.uid))
        #expect(outcome.config.outputDeviceUID == blackHole16.uid)
        #expect(outcome.effect == .rebuildsOutput)
        #expect(outcome.warnings.contains { $0.contains("Discord") })

        var config = Config.default
        config.outputDeviceUID = blackHole16.uid
        #expect(try apply(.outputDevice(nil), to: config).config.outputDeviceUID == nil)
    }

    @Test func onlyBlackHoleDevicesAreAccepted() {
        #expect(throws: ConfigEditError.notABlackHole(uid: scarlett.uid, name: scarlett.name)) {
            try apply(.outputDevice(scarlett.uid))
        }
        #expect(throws: ConfigEditError.notABlackHole(uid: builtInMic.uid, name: builtInMic.name)) {
            try apply(.outputDevice(builtInMic.uid))
        }
        let aggregate = DeviceInfo(id: 60, uid: "agg", name: "BlackHole + Speakers", manufacturer: "Apple Inc.",
                                   inputChannels: 2, outputChannels: 4, sampleRate: 48000, isAggregate: true)
        #expect(throws: ConfigEditError.notABlackHole(uid: "agg", name: "BlackHole + Speakers")) {
            try apply(.outputDevice("agg"), devices: devices + [aggregate])
        }
        #expect(throws: ConfigEditError.unknownOutputDevice(uid: "nope", valid: [blackHole16, blackHole])) {
            try apply(.outputDevice("nope"))
        }
    }

    @Test func autoOutputWithoutBlackHoleWarns() throws {
        var config = Config.default
        config.outputDeviceUID = blackHole16.uid
        let outcome = try apply(.outputDevice(nil), to: config, devices: [scarlett, blackHole16])
        #expect(outcome.warnings.contains { $0.contains("brew install blackhole-2ch") })
    }

    // MARK: Reset and effects

    @Test func resetRestoresDefaultsAndReportsChanges() throws {
        let config = Config(deviceUID: "solo", outputDeviceUID: blackHole16.uid, inputChannel: 2, gainDb: -6,
                            enabled: true, outputBufferFrames: 128)
        let outcome = try apply(.reset, to: config)
        #expect(outcome.config == .default)
        #expect(outcome.effect == .rebuildsOutput)
        #expect(outcome.changes.count == 5)
    }

    @Test func effectOfWholeConfigChanges() {
        let base = Config.default
        var c = base
        c.gainDb = -3
        #expect(ConfigEditing.effect(from: base, to: c) == .live)
        c.deviceUID = "solo"
        #expect(ConfigEditing.effect(from: base, to: c) == .rebuildsInput)
        c.reducedLatencyMargin = true
        #expect(ConfigEditing.effect(from: base, to: c) == .rebuildsOutput)
        c.enabled = false
        #expect(ConfigEditing.effect(from: base, to: c) == .startsOrStops)
        #expect(ConfigEditing.effect(from: base, to: base) == .none)
        var buffer = base
        buffer.bufferFrames = 256
        #expect(ConfigEditing.effect(from: base, to: buffer) == .rebuildsInput)
    }
}

/// Atomic writes and reading for edits, in a temporary directory.
struct ConfigStoreTests {
    private func temporaryFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jumphertz-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    @Test func writeThenLoad() throws {
        let url = try temporaryFile()
        var config = Config.default
        config.inputChannel = 3
        config.gainDb = -4.5
        try ConfigStore.write(config, to: url)
        #expect(try ConfigStore.loadForEditing(from: url) == config)
        // Atomic replace leaves nothing else behind.
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(names == ["config.json"])
    }

    @Test func writeReplacesACorruptFile() throws {
        let url = try temporaryFile()
        try Data("{ not json".utf8).write(to: url)
        try ConfigStore.write(.default, to: url)
        guard case .loaded(.default) = ConfigStore.load(from: url) else {
            Issue.record("expected a valid file")
            return
        }
    }

    @Test func editingACorruptFileIsRefused() throws {
        let url = try temporaryFile()
        try Data(#"{"inputChannel": "two"}"#.utf8).write(to: url)
        #expect(throws: ConfigEditError.self) { try ConfigStore.loadForEditing(from: url) }
        do {
            _ = try ConfigStore.loadForEditing(from: url)
        } catch {
            #expect(String(describing: error).contains("--reset-config"))
        }
    }

    @Test func missingFileMeansDefaults() throws {
        #expect(try ConfigStore.loadForEditing(from: try temporaryFile()) == .default)
    }

    @Test func invalidValuesAreNeverWritten() throws {
        let url = try temporaryFile()
        try ConfigStore.write(.default, to: url)
        var bad = Config.default
        bad.gainDb = 99
        #expect(throws: ConfigError.self) { try ConfigStore.write(bad, to: url) }
        #expect(try ConfigStore.loadForEditing(from: url) == .default)
    }
}
