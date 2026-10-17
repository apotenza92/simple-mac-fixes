import Testing
@testable import KeyboardControlFeature

@Test func brightnessReadPacket() {
    #expect(DDCController.readPacket(feature: 0x10) == [0x82, 0x01, 0x10, 0xAC])
}

@Test func brightnessWritePacket() {
    let packet = DDCController.writePacket(feature: 0x10, value: 75)
    #expect(packet == [0x84, 0x03, 0x10, 0x00, 0x4B, 0xE3])
    #expect(packet.reduce(0x6E ^ 0x51, ^) == 0)
}

@Test func luminanceResponseValidation() {
    // DDC/CI Get VCP reply: brightness 75 out of 100, with reply checksum.
    let valid: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x4B, 0x8B]
    #expect(DDCController.parseLuminanceResponse(valid)?.current == 75)
    #expect(DDCController.parseLuminanceResponse(valid)?.maximum == 100)
    #expect(DDCController.parseLuminanceResponse(Array(valid.dropLast())) == nil)
    var corrupt = valid
    corrupt[9] = 76
    #expect(DDCController.parseLuminanceResponse(corrupt) == nil)
    for (index, value): (Int, UInt8) in [(3, 1), (4, 0x12), (7, 0), (9, 101)] {
        var invalid = valid
        invalid[index] = value
        invalid[10] = invalid.dropLast().reduce(0x50, ^)
        #expect(DDCController.parseLuminanceResponse(invalid) == nil)
    }
}
