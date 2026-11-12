import Foundation
import Testing
@testable import GrokWatch

/// Connect stream framing: `[flags: 1][length: 4 BE][payload]`. Streams arrive byte by byte,
/// so a frame must only come out once it is complete.
struct EnvelopeTests {
    private let payload = Data("hello".utf8)

    @Test func roundTrip() throws {
        var buffer = ConnectClient.envelope(payload)
        #expect(buffer.count == 5 + payload.count)
        let frame = try #require(ConnectClient.takeEnvelope(from: &buffer))
        #expect(frame.flags == 0)
        #expect(frame.payload == payload)
        #expect(buffer.isEmpty)
    }

    @Test(arguments: [0, 3, 5, 9])
    func partialFrameWaits(byteCount: Int) {
        var buffer = ConnectClient.envelope(payload).prefix(byteCount)
        let before = buffer
        #expect(ConnectClient.takeEnvelope(from: &buffer) == nil)
        #expect(buffer == before)
    }

    @Test func framesComeOutInOrder() throws {
        let second = Data("world!".utf8)
        var buffer = ConnectClient.envelope(payload) + ConnectClient.envelope(second)
        let first = try #require(ConnectClient.takeEnvelope(from: &buffer))
        let next = try #require(ConnectClient.takeEnvelope(from: &buffer))
        #expect(first.payload == payload)
        #expect(next.payload == second)
        #expect(ConnectClient.takeEnvelope(from: &buffer) == nil)
    }

    @Test func returnsTrailerFlag() throws {
        var buffer = Data([0x02, 0, 0, 0, 2]) + Data("{}".utf8)
        let frame = try #require(ConnectClient.takeEnvelope(from: &buffer))
        #expect(frame.flags == 0x02)
        #expect(frame.payload == Data("{}".utf8))
    }

    /// `Data` slices keep their parent's indices, so parsing must not assume `startIndex == 0`.
    @Test func parsesSliceWithNonZeroStartIndex() throws {
        var buffer = (Data([0xFF, 0xFF]) + ConnectClient.envelope(payload)).dropFirst(2)
        #expect(buffer.startIndex == 2)
        let frame = try #require(ConnectClient.takeEnvelope(from: &buffer))
        #expect(frame.payload == payload)
        #expect(buffer.isEmpty)
    }
}
