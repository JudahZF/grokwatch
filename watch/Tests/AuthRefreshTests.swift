import Foundation
import os
import SwiftProtobuf
import Testing
@testable import GrokWatch

/// Refresh tokens rotate: a lost pair or a second refresh with the same token signs the watch out.
/// These tests pin how `Auth` and `ConnectClient` handle a rejected access token. The loader is a closure, so no request leaves the process.
struct AuthRefreshTests {
    private static let method = "test/Echo"
    private static let echoPath = "/" + method
    private static let refreshPath = "/oauth/token"

    private let old = Auth.Tokens(accessToken: Self.fakeJWT("old"), refreshToken: "refresh-old")
    private let new = Auth.Tokens(accessToken: Self.fakeJWT("new"), refreshToken: "refresh-new")
    private let requests = OSAllocatedUnfairLock<[String]>(initialState: [])

    @Test func rejectedTokenRefreshesOnceAndRetries() async throws {
        let store = MemoryStore(old)
        let client = makeClient(store: store) { [new] _ in (200, Self.refreshReply(new)) }
        let reply: Google_Protobuf_StringValue = try await client.unary(Self.method, Google_Protobuf_Empty())
        #expect(reply.value == "ok")
        #expect(store.tokens?.accessToken == new.accessToken)
        #expect(store.tokens?.refreshToken == new.refreshToken)
        #expect(count(Self.refreshPath) == 1)
        #expect(count(Self.echoPath) == 2)
    }

    @Test func simultaneousRejectionsShareOneRefresh() async throws {
        let store = MemoryStore(old)
        let client = makeClient(store: store) { [new, requests] _ in
            // Hold the refresh until both calls were rejected, so the second one meets it in flight.
            await eventually { requests.withLock { $0.count { $0 == Self.echoPath } } >= 2 }
            return (200, Self.refreshReply(new))
        }
        async let first: Google_Protobuf_StringValue = client.unary(Self.method, Google_Protobuf_Empty())
        async let second: Google_Protobuf_StringValue = client.unary(Self.method, Google_Protobuf_Empty())
        let replies = try await [first, second]
        #expect(replies.map(\.value) == ["ok", "ok"])
        #expect(count(Self.refreshPath) == 1)
    }

    @Test func refusedRefreshEndsTheSession() async throws {
        let store = MemoryStore(old)
        let client = makeClient(store: store) { _ in (401, Data()) }
        let error = await #expect(throws: Auth.AuthError.self) {
            let _: Google_Protobuf_StringValue = try await client.unary(Self.method, Google_Protobuf_Empty())
        }
        #expect(error?.isSignedOut == true)
        #expect(store.tokens == nil)
    }

    @Test func networkErrorDuringRefreshKeepsThePair() async throws {
        let store = MemoryStore(old)
        let client = makeClient(store: store) { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: URLError.self) {
            let _: Google_Protobuf_StringValue = try await client.unary(Self.method, Google_Protobuf_Empty())
        }
        #expect(store.tokens?.accessToken == old.accessToken)
        #expect(store.tokens?.refreshToken == old.refreshToken)
    }

    @Test func signOutDuringRefreshDropsTheNewPair() async throws {
        let store = MemoryStore(old)
        let signedOut = OSAllocatedUnfairLock(initialState: false)
        let client = makeClient(store: store) { [new] _ in
            await eventually { signedOut.withLock { $0 } }
            return (200, Self.refreshReply(new))
        }
        let call = Task { () -> Google_Protobuf_StringValue in try await client.unary(Self.method, Google_Protobuf_Empty()) }
        await eventually { count(Self.refreshPath) == 1 }
        await client.auth.signOut()
        signedOut.withLock { $0 = true }
        let error = await #expect(throws: Auth.AuthError.self) { try await call.value }
        #expect(error?.isSignedOut == true)
        #expect(store.tokens == nil)
    }

    // MARK: Fixture

    private typealias Route = @Sendable (URLRequest) async throws -> (status: Int, body: Data)

    /// A client whose API accepts only the new access token. `refresh` answers `oauth/token`.
    /// `Auth` and the client both get this loader closure, so a test can never reach the network.
    private func makeClient(store: MemoryStore, refresh: @escaping Route) -> ConnectClient {
        let load: HTTPLoader = { [requests, new] request in
            guard let url = request.url else { throw URLError(.badURL) }
            requests.withLock { $0.append(url.path()) }
            let (status, body): (Int, Data) =
                if url.path() == Self.refreshPath {
                    try await refresh(request)
                } else if request.value(forHTTPHeaderField: "authorization") == "Bearer \(new.accessToken)" {
                    (200, try Google_Protobuf_StringValue("ok").serializedData())
                } else {
                    (401, Data(#"{"code":"unauthenticated"}"#.utf8))
                }
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badServerResponse)
            }
            return (body, response)
        }
        return ConnectClient(auth: Auth(store: store, load: load), load: load)
    }

    private func count(_ path: String) -> Int {
        requests.withLock { $0.count { $0 == path } }
    }

    /// A fake JWT whose `exp` is an hour away, so `Auth` uses it without refreshing first.
    private static func fakeJWT(_ id: String) -> String {
        let claims = #"{"exp":\#(Int(Date.now.timeIntervalSince1970) + 3600),"jti":"\#(id)"}"#
        return "e30.\(Data(claims.utf8).base64URLEncodedString()).fake-signature"
    }

    private static func refreshReply(_ tokens: Auth.Tokens) -> Data {
        Data(#"{"access_token":"\#(tokens.accessToken)","refresh_token":"\#(tokens.refreshToken)"}"#.utf8)
    }
}

/// Waits up to 2 s for `condition`, so a stub can hold a reply while a test sets up a race.
private func eventually(_ condition: @Sendable () -> Bool) async {
    for _ in 0..<200 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private extension Auth.AuthError {
    var isSignedOut: Bool {
        if case .signedOut = self { true } else { false }
    }
}

private final class MemoryStore: TokenStore {
    private let saved: OSAllocatedUnfairLock<Auth.Tokens?>

    init(_ tokens: Auth.Tokens?) {
        saved = OSAllocatedUnfairLock(initialState: tokens)
    }

    var tokens: Auth.Tokens? { saved.withLock { $0 } }
    func load() -> Auth.Tokens? { tokens }
    func save(_ tokens: Auth.Tokens) { saved.withLock { $0 = tokens } }
    func clear() { saved.withLock { $0 = nil } }
}
