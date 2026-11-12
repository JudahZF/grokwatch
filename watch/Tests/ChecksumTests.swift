import Foundation
import Testing
@testable import GrokWatch

/// The service rejects requests whose `x-cursor-checksum` does not match its own algorithm.
/// Expected values come from the desktop's JavaScript run in Node, not from the Swift code.
struct ChecksumTests {
    private let machineID = "0123456789abcdef"

    @Test(arguments: [
        (nowMs: Int64(1_731_412_345_678), expected: "zpudiuW20123456789abcdef"),
        (nowMs: Int64(1_794_000_000_000), expected: "-istOWq_0123456789abcdef"),
    ])
    func matchesDesktopAlgorithm(nowMs: Int64, expected: String) {
        let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        #expect(ConnectClient.checksum(machineID: machineID, now: now) == expected)
    }
}
