import Testing
@testable import KeyboardControlFeature

@Test func decodesSupportedKeyDownEvents() {
    #expect(decode(0).key == .volumeUp)
    #expect(decode(1).key == .volumeDown)
    #expect(decode(2).key == .brightnessUp)
    #expect(decode(3).key == .brightnessDown)
    #expect(decode(7).key == .mute)
    #expect(decode(7).isKeyDown)
}

@Test func decodesKeyUpWithoutTriggeringPress() {
    let data = (Int64(0) << 16) | 0x0B00
    #expect(MediaKeyEvent.decode(data1: data)?.key == .volumeUp)
    #expect(MediaKeyEvent.decode(data1: data)?.isKeyDown == false)
}

@Test func rejectsUnrelatedMediaKeys() {
    let playPause = (Int64(16) << 16) | 0x0A00
    #expect(MediaKeyEvent.decode(data1: playPause) == nil)
}

@Test func decodesBrightnessFunctionKeys() {
    #expect(MediaKeyEvent.decodeFunctionKey(keyCode: 122) == .brightnessDown)
    #expect(MediaKeyEvent.decodeFunctionKey(keyCode: 120) == .brightnessUp)
    #expect(MediaKeyEvent.decodeFunctionKey(keyCode: 107) == .brightnessDown)
    #expect(MediaKeyEvent.decodeFunctionKey(keyCode: 113) == .brightnessUp)
    #expect(MediaKeyEvent.decodeFunctionKey(keyCode: 118) == nil)
}

private func decode(_ code: Int64) -> (key: MediaKey, isKeyDown: Bool) {
    MediaKeyEvent.decode(data1: (code << 16) | 0x0A00)!
}
