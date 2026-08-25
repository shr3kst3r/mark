import Darwin
import Foundation

/// The Unix-domain socket the CLI talks to, per
/// `2026-08-24-cli-app-unix-socket-ipc`.
///
/// > The app binds a Unix domain socket at `$TMPDIR/mark-$UID.sock` on launch,
/// > mode `0600`, unlinking any stale socket first. The protocol is
/// > newline-delimited JSON, request/response […] The app verifies the peer's
/// > uid via `LOCAL_PEERCRED` and rejects anything else.
///
/// Two of that ADR's traps are handled here rather than discovered later:
///
/// * **`sun_path` is 104 bytes on macOS**, not Linux's 108. The whole path,
///   including its NUL terminator, has to fit. ``SocketPath/resolve(...)``
///   refuses to return a path that does not, and ``AppDelegate`` treats that
///   refusal as a startup failure — the ADR says *assert at startup rather than
///   discovering it via a truncated path*, and a truncated path is silent: bind
///   succeeds, on a path nobody will ever connect to.
/// * **The socket stays out of `~/Library/Containers`,
///   `~/Library/Application Support/<bundle-id>` and `~/Library/Group
///   Containers`.** macOS 15+ raises the "would like to access data from other
///   apps" TCC prompt when a non-sandboxed process touches another bundle's
///   container, which is exactly the prompt this whole design exists to avoid.
///   ``SocketPath/isForbiddenLocation(_:)`` states that as a check rather than
///   as a comment, and it is asserted in the tests.
public enum SocketPath {

    /// `sizeof(struct sockaddr_un.sun_path)` on macOS: **104**, not the 108
    /// every Linux example assumes (`sys/un.h:79`).
    public static let sunPathCapacity = MemoryLayout.size(
        ofValue: sockaddr_un().sun_path)

    /// The longest path that fits, once the NUL terminator is paid for.
    public static let maxPathLength = sunPathCapacity - 1

    /// Why a socket path is unusable.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The path would not fit in `sun_path`.
        case tooLong(path: String, length: Int, limit: Int)
        /// The path is inside a location that raises the macOS 15+ App Data
        /// prompt. Never reachable from `$TMPDIR` in practice; checked because
        /// the ADR makes it a standing constraint on future work, and a
        /// constraint nothing enforces is a comment.
        case forbiddenLocation(path: String)

        public var description: String {
            switch self {
            case .tooLong(let path, let length, let limit):
                return """
                    socket path is \(length) bytes and the macOS limit is \(limit) \
                    (sizeof sockaddr_un.sun_path is \(SocketPath.sunPathCapacity), \
                    not Linux's 108): \(path). Set TMPDIR to a shorter directory.
                    """
            case .forbiddenLocation(let path):
                return """
                    socket path is inside an app container, which raises the macOS 15+ \
                    "access data from other apps" prompt: \(path)
                    """
            }
        }
    }

    /// The directory the socket goes in: `$TMPDIR`, which launchd sets
    /// per-user for both a terminal and a LaunchServices-launched app, so the
    /// CLI and the app compute the same path without agreeing on anything else.
    public static func temporaryDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let raw = environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSTemporaryDirectory()
        return raw.isEmpty ? "/tmp" : raw
    }

    /// `$TMPDIR/mark-$UID.sock`.
    ///
    /// - Note: the trailing-slash trim matters. `$TMPDIR` conventionally ends
    ///   in `/` and `NSTemporaryDirectory()` always does, so joining naively
    ///   yields `…/T//mark-501.sock` — which *works*, and is a different string
    ///   from what `mark-cli` computes, so `mark doctor` would report a path
    ///   that does not match the one in use.
    public static func resolve(
        directory: String? = nil,
        uid: uid_t = getuid(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        var base = directory ?? temporaryDirectory(environment: environment)
        while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
        let path = "\(base)/mark-\(uid).sock"

        let length = path.utf8.count
        guard length <= maxPathLength else {
            throw Failure.tooLong(path: path, length: length, limit: maxPathLength)
        }
        guard !isForbiddenLocation(path) else {
            throw Failure.forbiddenLocation(path: path)
        }
        return path
    }

    /// The three locations ADR-3 puts off limits.
    public static func isForbiddenLocation(_ path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        let home = NSHomeDirectory()
        let forbidden = [
            "\(home)/Library/Containers/",
            "\(home)/Library/Group Containers/",
            "\(home)/Library/Application Support/dev.mark",
        ]
        return forbidden.contains { standardized.hasPrefix($0) }
    }
}

/// Why the socket could not be served.
public enum SocketServerError: Error, CustomStringConvertible {
    case path(SocketPath.Failure)
    case syscall(String, errno: Int32)

    public var description: String {
        switch self {
        case .path(let failure):
            return failure.description
        case .syscall(let name, let code):
            return "\(name) failed: \(String(cString: strerror(code))) (errno \(code))"
        }
    }
}

/// The accept loop: newline-delimited JSON in, newline-delimited JSON out, one
/// `LOCAL_PEERCRED` check per connection.
///
/// Deliberately not `@MainActor`. Accepting and reading happen on a private
/// dispatch queue through `DispatchIO`, so a CLI that connects and then goes
/// away mid-request cannot stall the UI; only ``handler`` runs on the main
/// actor, and only for as long as one command takes.
///
/// Connections are long-lived by construction — the loop reads until EOF — but
/// `mark-cli` sends one request and closes, so in practice each connection is a
/// single round trip. Responses on one connection stay ordered even if a client
/// pipelines, because each request awaits the one before it.
public final class SocketServer: @unchecked Sendable {

    /// One request line in, one response line out. Runs off the main actor;
    /// ``CommandRouter`` is what hops onto it.
    public typealias Handler = @Sendable (String) async -> String

    public let path: String

    private let handler: Handler
    private let queue = DispatchQueue(label: "dev.mark.ipc", qos: .userInitiated)
    private var listenDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var isRunning = false

    /// Connections currently open, so ``stop()`` can close them.
    private var connections: [ObjectIdentifier: Connection] = [:]

    /// Peer connections refused by the uid check, for the log and the tests.
    ///
    /// Written on ``queue`` and read from wherever a caller happens to be, so
    /// the read hops onto the queue rather than tearing: this type is
    /// `@unchecked Sendable`, which means the compiler is trusting us here
    /// rather than checking.
    public var rejectedPeerCount: Int { queue.sync { refusedPeers } }
    private var refusedPeers = 0

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    /// Bind, chmod 0600, and start accepting.
    ///
    /// The stale-socket case is ADR-3's: *"unlinking any stale socket first"*.
    /// We probe before unlinking, purely so that displacing a **live** server —
    /// which only happens when two copies of the app run at once, since
    /// LaunchServices keeps one instance per bundle — appears in the log
    /// instead of looking like a mystery on the other side.
    public func start() throws {
        precondition(!isRunning, "SocketServer.start() called twice")

        if let failure = existingSocketState() {
            Log.ipc.notice("\(failure, privacy: .public)")
        }
        unlink(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketServerError.syscall("socket", errno: errno) }

        // Non-blocking, and this is load-bearing rather than hygiene: the
        // accept loop below drains until `accept` reports EWOULDBLOCK. On a
        // blocking descriptor that last call parks the IPC queue inside
        // `accept()` forever — which also wedges every `DispatchIO` read on the
        // same queue, so the app would answer exactly one command and then go
        // silent. `SocketServerTests.roundTrip` found this by hanging.
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        // Without this, a CLI that dies between our `write` and its `read`
        // delivers SIGPIPE, whose default action kills the app. A viewer must
        // not be killable by ^C in a terminal.
        var noSignal: Int32 = 1
        setsockopt(
            descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
            socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let written = Self.write(path: path, into: &address)
        guard written else {
            close(descriptor)
            throw SocketServerError.path(
                .tooLong(
                    path: path, length: path.utf8.count, limit: SocketPath.maxPathLength))
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        // 0600 twice over: the umask closes the window between `bind` creating
        // the node and `chmod` tightening it, and the `chmod` covers a umask
        // that already allowed more.
        let previousMask = umask(0o177)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw SocketServerError.syscall("bind", errno: code)
        }
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            close(descriptor)
            unlink(path)
            throw SocketServerError.syscall("chmod", errno: code)
        }
        guard listen(descriptor, 32) == 0 else {
            let code = errno
            close(descriptor)
            unlink(path)
            throw SocketServerError.syscall("listen", errno: code)
        }

        listenDescriptor = descriptor
        isRunning = true

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(descriptor) }
        acceptSource = source
        source.resume()

        Log.ipc.info(
            "listening on \(self.path, privacy: .public) (\(self.path.utf8.count) of \(SocketPath.maxPathLength) bytes, mode 0600)"
        )
    }

    /// Stop accepting, close every open connection, and remove the socket file.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        acceptSource?.cancel()
        acceptSource = nil
        listenDescriptor = -1
        let open = queue.sync { () -> [Connection] in
            let values = Array(connections.values)
            connections.removeAll()
            return values
        }
        for connection in open { connection.close() }
        unlink(path)
        Log.ipc.info("socket closed and unlinked")
    }

    deinit {
        acceptSource?.cancel()
    }

    // MARK: - Accepting

    private func acceptPending() {
        while true {
            var address = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenDescriptor, $0, &length)
                }
            }
            guard client >= 0 else {
                if errno != EWOULDBLOCK && errno != EAGAIN && errno != EINTR && isRunning {
                    Log.ipc.error("accept failed: \(String(cString: strerror(errno)), privacy: .public)")
                }
                return
            }

            guard let peer = Self.peerUID(of: client), peer == getuid() else {
                refusedPeers += 1
                Log.ipc.error(
                    "refused a connection from uid \(Self.peerUID(of: client).map(String.init) ?? "unknown", privacy: .public); this socket serves uid \(getuid(), privacy: .public) only"
                )
                close(client)
                continue
            }

            var noSignal: Int32 = 1
            setsockopt(
                client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                socklen_t(MemoryLayout<Int32>.size))
            let clientFlags = fcntl(client, F_GETFL, 0)
            _ = fcntl(client, F_SETFL, clientFlags | O_NONBLOCK)

            let connection = Connection(descriptor: client, queue: queue, handler: handler) {
                [weak self] finished in
                guard let self else { return }
                self.queue.async { self.connections.removeValue(forKey: ObjectIdentifier(finished)) }
            }
            connections[ObjectIdentifier(connection)] = connection
            connection.resume()
        }
    }

    /// ADR-3's peer check. `LOCAL_PEERCRED` is the BSD `getsockopt` that
    /// reports the credentials the peer had *when it connected*, so it cannot
    /// be raced by the peer exec'ing something else afterwards.
    static func peerUID(of descriptor: Int32) -> uid_t? {
        var credentials = xucred()
        var size = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &size) == 0,
            credentials.cr_version == XUCRED_VERSION
        else {
            return nil
        }
        return credentials.cr_uid
    }

    /// Copy `path` into the fixed-size `sun_path` array, refusing to truncate.
    static func write(path: String, into address: inout sockaddr_un) -> Bool {
        let bytes = Array(path.utf8)
        guard bytes.count < SocketPath.sunPathCapacity else { return false }
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: SocketPath.sunPathCapacity) { raw in
                for (offset, byte) in bytes.enumerated() { raw[offset] = CChar(bitPattern: byte) }
                raw[bytes.count] = 0
            }
        }
        return true
    }

    /// Whether something is already listening on our path, described for the
    /// log. `nil` when the path is free or holds a socket nobody answers.
    private func existingSocketState() -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return nil }
        defer { close(probe) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        guard Self.write(path: path, into: &address) else { return nil }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
            ? "another mark is already listening on \(path); taking the socket over"
            : "removing a stale socket at \(path)"
    }
}

// MARK: - One connection

/// A single client, read to EOF.
///
/// `DispatchIO` rather than a blocking read on a thread: a client that connects
/// and then stalls costs a buffer, not a thread, and `stop()` can tear
/// everything down without waiting for a `read` to return.
private final class Connection: @unchecked Sendable {

    private let descriptor: Int32
    private let queue: DispatchQueue
    private let handler: SocketServer.Handler
    private let onFinish: (Connection) -> Void
    private var channel: DispatchIO?
    private var buffer = Data()

    /// The most recently dispatched request. Each new one awaits it before
    /// replying, so a client that pipelines gets its answers back in the order
    /// it asked — `mark-cli` sends one request per connection, but a wire
    /// protocol whose ordering depends on how fast each command happens to be
    /// is a trap for the next client. Only ever touched on ``queue``.
    private var tail: _Concurrency.Task<Void, Never>?

    /// A request line longer than this is refused rather than buffered. The
    /// largest legitimate command is an `open` carrying a path, so anything
    /// near this is either a bug or someone pointing a firehose at the socket.
    private static let maxLineBytes = 64 * 1024

    init(
        descriptor: Int32,
        queue: DispatchQueue,
        handler: @escaping SocketServer.Handler,
        onFinish: @escaping (Connection) -> Void
    ) {
        self.descriptor = descriptor
        self.queue = queue
        self.handler = handler
        self.onFinish = onFinish
    }

    func resume() {
        let channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue) {
            _ in Darwin.close(self.descriptor)
        }
        channel.setLimit(lowWater: 1)
        self.channel = channel
        channel.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.absorb(Data(data))
            }
            if done {
                if error != 0 && error != ECANCELED {
                    Log.ipc.error(
                        "read failed: \(String(cString: strerror(error)), privacy: .public)")
                }
                self.finish()
            }
        }
    }

    func close() {
        channel?.close(flags: .stop)
        channel = nil
    }

    private func finish() {
        channel = nil
        onFinish(self)
    }

    private func absorb(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            dispatch(String(decoding: line, as: UTF8.self))
        }
        if buffer.count > Self.maxLineBytes {
            Log.ipc.error("request line exceeded \(Self.maxLineBytes) bytes; closing the connection")
            buffer.removeAll()
            close()
        }
    }

    private func dispatch(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let handler = self.handler
        let previous = tail
        let queue = self.queue
        tail = _Concurrency.Task { [weak self] in
            await previous?.value
            let response = await handler(trimmed)
            guard let self else { return }
            queue.async { self.send(response) }
        }
    }

    private func send(_ response: String) {
        guard let channel else { return }
        var payload = Data(response.utf8)
        payload.append(UInt8(ascii: "\n"))
        payload.withUnsafeBytes { raw in
            let data = DispatchData(bytes: raw)
            channel.write(offset: 0, data: data, queue: queue) { _, _, error in
                if error != 0 && error != EPIPE && error != ECANCELED {
                    Log.ipc.error(
                        "write failed: \(String(cString: strerror(error)), privacy: .public)")
                }
            }
        }
    }
}
