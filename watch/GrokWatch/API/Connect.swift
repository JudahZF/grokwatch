import Foundation
import SwiftProtobuf

/// Minimal Connect-protocol client (binary proto) for Grok Bot's internal API.
/// Uses plain URLSession data tasks, which watchOS allows without an audio or CallKit session.
/// Wire details: docs/grok-bot-protocol.md.
struct ConnectClient: Sendable {
    static let baseURL = URL(string: "https://api2.cursor.sh")!
    /// Desktop app version whose protocol this client mirrors.
    static let clientVersion = "0.78.1"
    /// URLSession's idle timeout for a stream: it fires only when no bytes arrive for this long, and heartbeats count.
    /// The service's heartbeat interval is not documented; raise this if idle chats reconnect every two minutes.
    static let streamIdleTimeout: TimeInterval = 120

    struct RPCError: LocalizedError {
        let code: String
        let message: String
        var errorDescription: String? { message.isEmpty ? code : "\(code): \(message)" }
        /// The server refused the access token (not the account), so a refreshed token may work.
        var rejectsToken: Bool { code == "unauthenticated" || code == "http_401" }
    }

    let auth: Auth
    var session: URLSession = .shared

    func unary<Response: Message>(_ method: String, _ request: some Message) async throws -> Response {
        let body = try request.serializedData()
        return try await authorized { token in
            var urlRequest = makeRequest(method, contentType: "application/proto", token: token)
            urlRequest.httpBody = body
            let (data, response) = try await session.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw Self.error(from: data, status: status) }
            return try Response(serializedBytes: data)
        }
    }

    /// Server-streaming call. Frames are `[flags: 1][length: 4 BE][payload]`; flag 0x02 marks the end-of-stream trailer.
    func serverStream<Request: Message, Response: Message>(
        _ method: String, _ request: Request, of _: Response.Type = Response.self
    ) -> AsyncThrowingStream<Response, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = Self.envelope(try request.serializedData())
                    // The retry covers only the status check: no frame has been delivered yet.
                    let bytes = try await authorized { token in
                        var urlRequest = makeRequest(method, contentType: "application/connect+proto", token: token)
                        urlRequest.timeoutInterval = Self.streamIdleTimeout
                        urlRequest.httpBody = body
                        let (bytes, response) = try await session.bytes(for: urlRequest)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        guard status == 200 else {
                            var errorBody = Data()
                            for try await byte in bytes { errorBody.append(byte) }
                            throw Self.error(from: errorBody, status: status)
                        }
                        return bytes
                    }
                    var buffer = Data()
                    for try await byte in bytes {
                        buffer.append(byte)
                        while let (flags, payload) = Self.takeEnvelope(from: &buffer) {
                            if flags & 0x02 != 0 {
                                if let error = Self.trailerError(payload) { throw error }
                                continuation.finish()
                                return
                            }
                            continuation.yield(try Response(serializedBytes: payload))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs `call` with the access token. When the server rejects that token, refreshes it and runs `call` once more.
    private func authorized<Result>(_ call: (String) async throws -> Result) async throws -> Result {
        let token = try await auth.accessToken()
        do {
            return try await call(token)
        } catch let error as RPCError where error.rejectsToken {
            return try await call(try await auth.accessToken(replacing: token))
        }
    }

    private func makeRequest(_ method: String, contentType: String, token: String) -> URLRequest {
        var request = URLRequest(url: Self.baseURL.appending(path: method))
        request.httpMethod = "POST"
        for (field, value) in [
            "authorization": "Bearer \(token)",
            "content-type": contentType,
            "connect-protocol-version": "1",
            "x-cursor-client-type": "sand",
            "x-cursor-client-version": Self.clientVersion,
            "x-cursor-client-os": "CLIENT_OS_MACOS",
            "x-sand-box-namespace": "prod",
            "x-ghost-mode": "true",
            "x-cursor-checksum": Self.checksum(machineID: auth.machineID),
            "x-request-id": UUID().uuidString.lowercased(),
        ] {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    /// `x-cursor-checksum`: obfuscated coarse timestamp + machine id, byte-for-byte like the desktop app.
    static func checksum(machineID: String, now: Date = .now) -> String {
        let t = Int32(truncatingIfNeeded: Int64(now.timeIntervalSince1970 * 1000) / 1_000_000)
        // The desktop's JS writes `t >> 40` and `t >> 32`, but JS shift counts wrap mod 32: they are `>> 8` and `>> 0`.
        var bytes = [t >> 8, t, t >> 24, t >> 16, t >> 8, t].map { UInt8(truncatingIfNeeded: $0) }
        var key: UInt8 = 165
        for i in bytes.indices {
            bytes[i] = (bytes[i] ^ key) &+ UInt8(i % 256)
            key = bytes[i]
        }
        return Data(bytes).base64URLEncodedString() + machineID
    }

    static func envelope(_ payload: Data) -> Data {
        var data = Data([0])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { data.append(contentsOf: $0) }
        return data + payload
    }

    static func takeEnvelope(from buffer: inout Data) -> (flags: UInt8, payload: Data)? {
        guard buffer.count >= 5 else { return nil }
        let start = buffer.startIndex
        let length = buffer[(start + 1)..<(start + 5)].reduce(0) { $0 << 8 | Int($1) }
        guard buffer.count >= 5 + length else { return nil }
        let frame = (buffer[start], Data(buffer[(start + 5)..<(start + 5 + length)]))
        buffer.removeFirst(5 + length)
        return frame
    }

    private struct ErrorBody: Decodable {
        let code: String
        let message: String?
    }

    private static func error(from body: Data, status: Int) -> RPCError {
        guard let decoded = try? JSONDecoder().decode(ErrorBody.self, from: body) else {
            return RPCError(code: "http_\(status)", message: "")
        }
        return RPCError(code: decoded.code, message: decoded.message ?? "")
    }

    private static func trailerError(_ payload: Data) -> RPCError? {
        struct Trailer: Decodable { let error: ErrorBody? }
        guard let error = (try? JSONDecoder().decode(Trailer.self, from: payload))?.error else { return nil }
        return RPCError(code: error.code, message: error.message ?? "")
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
