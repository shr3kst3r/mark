import Darwin
import Foundation
import Testing

@testable import MarkKit

/// ADR-3's socket, including the two traps it says are invisible until they
/// bite: the 104-byte `sun_path` limit and the forbidden container locations.
@Suite("SocketServer — ADR-3's transport")
@MainActor
struct SocketServerTests {

    // MARK: - The path

    @Test("sun_path is 104 bytes on macOS, not Linux's 108")
    func sunPathCapacity() {
        #expect(SocketPath.sunPathCapacity == 104)
        #expect(SocketPath.maxPathLength == 103)
        #expect(MemoryLayout<sockaddr_un>.size == 106)
    }

    @Test("the path is $TMPDIR/mark-$UID.sock, with or without a trailing slash")
    func pathShape() throws {
        let withSlash = try SocketPath.resolve(directory: "/tmp/marktest/", uid: 501)
        let without = try SocketPath.resolve(directory: "/tmp/marktest", uid: 501)
        #expect(withSlash == "/tmp/marktest/mark-501.sock")
        #expect(withSlash == without)
    }

    /// The one that has to match `mark-cli` byte for byte, because the two
    /// processes never exchange the path — they each compute it.
    @Test("TMPDIR from the environment is what the path is built from")
    func pathFromEnvironment() throws {
        let path = try SocketPath.resolve(
            uid: 501, environment: ["TMPDIR": "/var/folders/ab/cd/T/"])
        #expect(path == "/var/folders/ab/cd/T/mark-501.sock")
    }

    /// ADR-3: *"Assert this at startup rather than discovering it via a
    /// truncated path."* A truncated path binds **successfully**, on a path no
    /// client computes — so this must throw, not clamp.
    @Test("a path over 104 bytes is refused rather than truncated")
    func pathTooLong() {
        let directory = "/tmp/" + String(repeating: "d", count: 120)
        #expect(throws: SocketPath.Failure.self) {
            try SocketPath.resolve(directory: directory, uid: 501)
        }
        do {
            _ = try SocketPath.resolve(directory: directory, uid: 501)
        } catch let failure as SocketPath.Failure {
            #expect(failure.description.contains("104"))
            #expect(failure.description.contains("TMPDIR"))
        } catch {
            Issue.record("expected a SocketPath.Failure, got \(error)")
        }
    }

    @Test("the limit is 103 bytes of path plus a NUL")
    func pathBoundary() throws {
        let suffix = "/mark-501.sock"
        let directory = "/" + String(repeating: "d", count: SocketPath.maxPathLength - suffix.count - 1)
        let fits = try SocketPath.resolve(directory: directory, uid: 501)
        #expect(fits.utf8.count == SocketPath.maxPathLength)
        #expect(throws: SocketPath.Failure.self) {
            try SocketPath.resolve(directory: directory + "x", uid: 501)
        }
    }

    /// ADR-3 names three directories the socket must never live in, because
    /// touching another bundle's container is what raises the macOS 15+ "would
    /// like to access data from other apps" prompt — the exact prompt this
    /// design exists to avoid. A constraint nothing checks is a comment.
    @Test("the socket may never live in an app container")
    func forbiddenLocations() {
        let home = NSHomeDirectory()
        for directory in [
            "\(home)/Library/Containers/dev.mark.app/Data/tmp",
            "\(home)/Library/Group Containers/group.dev.mark",
            "\(home)/Library/Application Support/dev.mark.app",
        ] {
            #expect(
                SocketPath.isForbiddenLocation("\(directory)/mark-501.sock"),
                "\(directory) must be refused")
            #expect(throws: SocketPath.Failure.self) {
                try SocketPath.resolve(directory: directory, uid: 501)
            }
        }
        #expect(!SocketPath.isForbiddenLocation("/var/folders/ab/cd/T/mark-501.sock"))
    }

    /// The real one, on this machine. If `$TMPDIR` here ever stopped fitting,
    /// every other test in this suite would still pass and nothing would work.
    @Test("this machine's real socket path fits")
    func realPathFits() throws {
        let path = try SocketPath.resolve()
        #expect(path.utf8.count <= SocketPath.maxPathLength)
        #expect(path.hasSuffix("mark-\(getuid()).sock"))
        #expect(!SocketPath.isForbiddenLocation(path))
    }

    // MARK: - The server

    @Test("a request over a real socket comes back as a response")
    func roundTrip() async throws {
        let harness = try ServerHarness()
        defer { harness.stop() }

        let reply = try await harness.send(#"{"version":1,"id":"1","command":"ping"}"#)
        let json = try harness.decode(reply)
        #expect(json["ok"] as? Bool == true)
        #expect(json["id"] as? String == "1")
    }

    /// Newline-delimited, so two requests on one connection get two answers in
    /// order rather than one concatenated mess.
    @Test("two requests on one connection get two answers, in order")
    func pipelining() async throws {
        let harness = try ServerHarness()
        defer { harness.stop() }

        let replies = try await harness.send(
            lines: [
                #"{"version":1,"id":"a","command":"tab-list"}"#,
                #"{"version":1,"id":"b","command":"ping"}"#,
            ], expecting: 2)
        #expect(try harness.decode(replies[0])["id"] as? String == "a")
        #expect(try harness.decode(replies[1])["id"] as? String == "b")
    }

    @Test("the socket file is 0600 and owned by us")
    func permissions() throws {
        let harness = try ServerHarness()
        defer { harness.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: harness.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.int16Value == 0o600)
        #expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
    }

    /// ADR-3: *"unlinking any stale socket first"*. A crash leaves a socket
    /// node that refuses connections; the next launch must take it over rather
    /// than fail to bind with `EADDRINUSE`.
    @Test("a stale socket file is unlinked and rebound")
    func staleSocket() async throws {
        let directory = try ServerHarness.scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = try SocketPath.resolve(directory: directory)

        // A plain file where the socket should be is the harshest version of
        // the same situation.
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        #expect(FileManager.default.fileExists(atPath: path))

        let harness = try ServerHarness(path: path)
        defer { harness.stop() }
        let reply = try await harness.send(#"{"version":1,"id":"1","command":"ping"}"#)
        #expect(try harness.decode(reply)["ok"] as? Bool == true)
    }

    @Test("stopping the server unlinks the socket")
    func cleanup() throws {
        let harness = try ServerHarness()
        #expect(FileManager.default.fileExists(atPath: harness.path))
        harness.stop()
        #expect(!FileManager.default.fileExists(atPath: harness.path))
    }

    /// ADR-3's peer check. Our own connection is the only uid we can produce in
    /// a unit test — spawning a process as another user needs root — so this
    /// asserts the accepting side reads the credential correctly and matches
    /// it, and `LOCAL_PEERCRED` returning our uid for our own socket is the
    /// fact the check rests on.
    @Test("LOCAL_PEERCRED reports the connecting process's uid")
    func peerCredentials() throws {
        let harness = try ServerHarness()
        defer { harness.stop() }

        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(client >= 0)
        defer { close(client) }
        try ServerHarness.connect(client, to: harness.path)

        #expect(SocketServer.peerUID(of: client) == getuid())
        #expect(harness.server.rejectedPeerCount == 0)
    }

    @Test("a line that is not JSON still gets an answer")
    func garbage() async throws {
        let harness = try ServerHarness()
        defer { harness.stop() }
        let json = try harness.decode(try await harness.send("hello?"))
        #expect(json["ok"] as? Bool == false)
        #expect((json["error"] as? [String: Any])?["code"] as? String == "malformed-request")
    }

    @Test("an empty line is ignored rather than answered")
    func blankLines() async throws {
        let harness = try ServerHarness()
        defer { harness.stop() }
        let replies = try await harness.send(
            lines: ["", "   ", #"{"version":1,"id":"only","command":"ping"}"#], expecting: 1)
        #expect(replies.count == 1)
        #expect(try harness.decode(replies[0])["id"] as? String == "only")
    }
}

/// A running ``SocketServer`` on a throwaway path, with a blocking client.
@MainActor
final class ServerHarness {

    let path: String
    let server: SocketServer
    let router: CommandRouter
    private let target = FakeCommandTarget()
    private let directory: String?

    init(path: String? = nil) throws {
        let directory = path == nil ? try Self.scratchDirectory() : nil
        self.directory = directory
        self.path = try path ?? SocketPath.resolve(directory: directory!)
        let router = CommandRouter(target: target)
        self.router = router
        server = SocketServer(path: self.path) { line in
            await router.handle(line: line)
        }
        try server.start()
    }

    /// Short, so the socket path is nowhere near the 104-byte limit even on a
    /// machine with a deep `$TMPDIR`.
    static func scratchDirectory() throws -> String {
        let path = "/tmp/mark-t-\(getpid())-\(Int.random(in: 0..<10000))"
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true)
        return path
    }

    func stop() {
        server.stop()
        if let directory { try? FileManager.default.removeItem(atPath: directory) }
    }

    func send(_ line: String) async throws -> String {
        try await send(lines: [line], expecting: 1)[0]
    }

    /// One blocking round trip, **off the main actor**.
    ///
    /// `mark-cli` blocks on `read` while the app answers, and this has to
    /// reproduce that — but ``CommandRouter`` is `@MainActor`, so a blocking
    /// read on the main thread deadlocks: the reply cannot be produced by the
    /// thread that is waiting for it. That is a property of the *test*, not of
    /// the server (the CLI is a different process), which is why the client
    /// side runs detached.
    func send(lines: [String], expecting: Int) async throws -> [String] {
        let path = self.path
        return try await _Concurrency.Task.detached {
            try Self.exchange(path: path, lines: lines, expecting: expecting)
        }.value
    }

    /// Blocking, on purpose: a test that polled would not notice the server
    /// answering out of order.
    nonisolated static func exchange(path: String, lines: [String], expecting: Int) throws
        -> [String]
    {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.socket }
        defer { close(descriptor) }
        try Self.connect(descriptor, to: path)

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size))

        let payload = Data((lines.joined(separator: "\n") + "\n").utf8)
        try payload.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let wrote = write(descriptor, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                guard wrote > 0 else { throw Failure.write }
                sent += wrote
            }
        }

        var received = Data()
        var replies: [String] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while replies.count < expecting {
            let read = Darwin.read(descriptor, &buffer, buffer.count)
            guard read > 0 else { throw Failure.read }
            received.append(contentsOf: buffer[0..<read])
            replies =
                String(decoding: received, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        }
        return replies
    }

    nonisolated func decode(_ line: String) throws -> [String: Any] {
        let data = try #require(line.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    nonisolated static func connect(_ descriptor: Int32, to path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        guard SocketServer.write(path: path, into: &address) else { throw Failure.path }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw Failure.connect(errno) }
    }

    enum Failure: Error {
        case socket
        case path
        case connect(Int32)
        case write
        case read
    }
}
