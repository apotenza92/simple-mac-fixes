import Testing
@testable import KeyboardControlFeature

@Test func nativeVolumePreservesStereoBalance() {
    let values = AudioHardware.nativeChannelVolumes([0.8, 0.4], percent: 40)
    #expect(abs(values[0] - 0.4) < 0.0001)
    #expect(abs(values[1] - 0.2) < 0.0001)
}

@Test func nativeVolumeHandlesSilenceAndLimits() {
    #expect(AudioHardware.nativeChannelVolumes([0, 0], percent: 50) == [0.5, 0.5])
    #expect(AudioHardware.nativeChannelVolumes([0.5], percent: 150) == [1])
    #expect(AudioHardware.nativeChannelVolumes([0.5], percent: -10) == [0])
}
