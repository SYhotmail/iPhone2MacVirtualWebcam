import Foundation
import Network
import Testing
@testable import Transport

@Suite("FrameStreamClient Tests")
struct FrameStreamClientTests {
    private static let pairHello = PairingHello.pair(
        token: Data(repeating: 9, count: 16),
        clientID: UUID(),
        secret: Data(repeating: 3, count: 32),
        deviceName: "Test iPhone"
    )
    private static let destination = FrameStreamClient.Destination.host(
        "192.168.1.10", port: 9999,
        pinnedFingerprint: Data(repeating: 0xAB, count: 32),
        hello: pairHello
    )!

    @Test
    func connectTransitionsToFailedWhenConnectionWaits() async {
        let mockConnection = MockTransportConnection()
        let manager = FrameStreamClient(connectionFactory: { _ in mockConnection })
        let recorder = StatusRecorder()
        await manager.setStatusChangedHandler { status in
            Task { await recorder.append(status) }
        }

        await manager.connect(to: Self.destination)
        mockConnection.simulateState(.waiting(.posix(.ECONNREFUSED)))

        #expect(await recorder.waitForCount(2) == [.connecting, .failed])
    }

    @Test
    func sendsHelloFirstAndConnectsAfterAcceptedReply() async throws {
        let mockConnection = MockTransportConnection(replies: [.accepted])
        let manager = FrameStreamClient(connectionFactory: { _ in mockConnection })
        let recorder = StatusRecorder()
        await manager.setStatusChangedHandler { status in
            Task { await recorder.append(status) }
        }

        await manager.connect(to: Self.destination)
        mockConnection.simulateState(.ready)
        #expect(await recorder.waitForCount(2) == [.connecting, .connected])

        await manager.send(Data([0x01, 0x02, 0x03]))

        let sent = mockConnection.sentPayloads
        #expect(sent.count == 2)
        #expect(try JSONDecoder().decode(PairingHello.self, from: sent[0].dropFirst(4)) == Self.pairHello)
        #expect(sent[1] == FramePacket.packetized(Data([0x01, 0x02, 0x03])))
    }

    @Test
    func dropsFramesBeforeHandshakeCompletes() async {
        let mockConnection = MockTransportConnection()
        let manager = FrameStreamClient(connectionFactory: { _ in mockConnection })

        await manager.connect(to: Self.destination)
        await manager.send(Data([0x01]))

        #expect(mockConnection.sentPayloads.isEmpty)
    }

    @Test
    func rejectedReplyIsStickyAndCancelsConnection() async {
        let mockConnection = MockTransportConnection(replies: [.rejected("unknown client")])
        let manager = FrameStreamClient(connectionFactory: { _ in mockConnection })
        let recorder = StatusRecorder()
        await manager.setStatusChangedHandler { status in
            Task { await recorder.append(status) }
        }

        await manager.connect(to: Self.destination)
        mockConnection.simulateState(.ready)
        #expect(await recorder.waitForCount(2) == [.connecting, .rejected(reason: "unknown client")])

        mockConnection.simulateState(.failed(.posix(.ECONNRESET)))
        try? await Task.sleep(for: .milliseconds(20))

        #expect(await recorder.values() == [.connecting, .rejected(reason: "unknown client")])
        #expect(mockConnection.cancelCallCount == 1)
    }

    @Test
    func reconnectAfterPairingUsesHelloInsteadOfSpentToken() async {
        let factoryRecorder = ConnectionFactoryRecorder()
        let manager = FrameStreamClient(connectionFactory: { destination in
            let connection = MockTransportConnection(replies: [.accepted])
            factoryRecorder.append(connection, destination: destination)
            return connection
        })
        let recorder = StatusRecorder()
        await manager.setStatusChangedHandler { status in
            Task { await recorder.append(status) }
        }

        await manager.connect(to: Self.destination)
        factoryRecorder.snapshot()[0].connection.simulateState(.ready)
        _ = await recorder.waitForCount(2)
        #expect(await manager.reconnect())

        let created = factoryRecorder.snapshot()
        #expect(created.count == 2)
        #expect(created[0].connection.cancelCallCount == 1)
        #expect(created[0].destination.hello.kind == .pair)
        #expect(created[1].destination.hello == .hello(clientID: Self.pairHello.clientID, secret: Self.pairHello.secret))
        #expect(created[1].destination.endpoint == Self.destination.endpoint)
    }

    @Test
    func serviceDestinationTargetsBonjourType() {
        let destination = FrameStreamClient.Destination.service(
            named: "Studio Mac",
            pinnedFingerprint: Data(),
            hello: Self.pairHello
        )
        #expect(destination.endpoint == .service(name: "Studio Mac", type: "_cam2mac._udp", domain: "local.", interface: nil))
    }
}

private actor StatusRecorder {
    private var statuses = [FrameStreamClient.Status]()

    func append(_ status: FrameStreamClient.Status) {
        statuses.append(status)
    }

    func values() -> [FrameStreamClient.Status] {
        statuses
    }

    func waitForCount(_ expectedCount: Int, timeoutNanoseconds: UInt64 = 1_000_000_000) async -> [FrameStreamClient.Status] {
        let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
        while statuses.count < expectedCount, ContinuousClock.now < deadline {
            await Task.yield()
        }
        return statuses
    }
}

private final class ConnectionFactoryRecorder: @unchecked Sendable {
    struct Entry {
        let connection: MockTransportConnection
        let destination: FrameStreamClient.Destination
    }

    private let lock = NSLock()
    private var entries = [Entry]()

    func append(_ connection: MockTransportConnection, destination: FrameStreamClient.Destination) {
        lock.withLock { entries.append(.init(connection: connection, destination: destination)) }
    }

    func snapshot() -> [Entry] {
        lock.withLock { entries }
    }
}

private final class MockTransportConnection: @unchecked Sendable, TransportConnection {
    var state: TransportConnectionState = .setup
    var stateUpdateHandler: (@Sendable (TransportConnectionState) -> Void)?
    var pathUpdateHandler: (@Sendable (NWPath) -> Void)?
    var viabilityUpdateHandler: (@Sendable (Bool) -> Void)?
    var betterPathUpdateHandler: (@Sendable (Bool) -> Void)?

    private let lock = NSLock()
    private var _startedQueues = [DispatchQueue]()
    private var _cancelCallCount = 0
    private var _sentPayloads = [Data]()
    private var pendingReceive: Data

    var startedQueues: [DispatchQueue] { lock.withLock { _startedQueues } }
    var cancelCallCount: Int { lock.withLock { _cancelCallCount } }
    var sentPayloads: [Data] { lock.withLock { _sentPayloads } }

    init(replies: [PairingReply] = []) {
        pendingReceive = replies.reduce(into: Data()) { buffer, reply in
            buffer.append(FramePacket.packetized(try! JSONEncoder().encode(reply)))
        }
    }

    func start(queue: DispatchQueue) {
        lock.withLock { _startedQueues.append(queue) }
    }

    func cancel() {
        lock.withLock { _cancelCallCount += 1 }
    }

    func forceCancel() {}

    func send(content: Data?) async throws {
        if let content {
            lock.withLock { _sentPayloads.append(content) }
        }
    }

    func receive(minimumIncompleteLength: Int, maximumLength: Int) async throws -> TransportReceiveResult {
        let chunk: Data = lock.withLock {
            let chunk = pendingReceive.prefix(maximumLength)
            pendingReceive = pendingReceive.dropFirst(chunk.count)
            return Data(chunk)
        }
        return TransportReceiveResult(data: chunk, contentContext: nil, isComplete: chunk.isEmpty)
    }

    func simulateState(_ newState: TransportConnectionState) {
        state = newState
        stateUpdateHandler?(newState)
    }
}
