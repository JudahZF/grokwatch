import Testing
@testable import GrokWatch

/// Stream reconnects back off so a dead network does not drain the watch battery, but never wait more than a minute.
struct RetryDelayTests {
    @Test func doublesFromThreeSeconds() {
        let delays = (0...7).map { ConnectClient.reconnectDelay(afterFailures: $0) }
        #expect(delays == [3, 3, 6, 12, 24, 48, 60, 60].map { .seconds($0) })
    }

    @Test func staysAtOneMinute() {
        #expect(ConnectClient.reconnectDelay(afterFailures: 1_000) == .seconds(60))
    }
}
