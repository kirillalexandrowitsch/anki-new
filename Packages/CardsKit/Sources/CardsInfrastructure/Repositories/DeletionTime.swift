import Darwin
import Foundation

/// Continuous time includes sleep and is comparable across app launches in the same boot.
struct DeletionInstant: Sendable {
    let bootID: String
    let seconds: Double
}

protocol DeletionTime: Sendable {
    func now() throws -> DeletionInstant
}

struct SystemDeletionTime: DeletionTime {
    func now() throws -> DeletionInstant {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else {
            throw CocoaError(.fileReadUnknown)
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        let bootID = String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return DeletionInstant(bootID: bootID,
            seconds: Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000)
    }
}
