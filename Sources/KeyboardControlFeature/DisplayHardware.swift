import Foundation
import IOKit

/// Physical transport information is independent of WindowServer's sometimes
/// stale online list. Queried only on a worker or recovery-process thread.
enum DisplayHardware {
    struct Transport {
        let registryID: UInt64
        let vendor: UInt32
        let model: UInt32
        let serial: UInt32
    }

    static func transports() throws -> [Transport] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPortTransportState"), &iterator) == KERN_SUCCESS else {
            throw DisplayConnection.Failure(message: "Could not verify the physical display connections.")
        }
        defer { IOObjectRelease(iterator) }
        var result: [Transport] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let data = IORegistryEntryCreateCFProperty(service, "EDID" as CFString, nil, 0)?.takeRetainedValue() as? Data,
                  data.count >= 128 else { continue }
            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else { continue }
            let bytes = [UInt8](data)
            result.append(Transport(registryID: registryID,
                vendor: UInt32(bytes[8]) << 8 | UInt32(bytes[9]),
                model: UInt32(bytes[10]) | UInt32(bytes[11]) << 8,
                serial: UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24))
        }
        return result
    }
}
