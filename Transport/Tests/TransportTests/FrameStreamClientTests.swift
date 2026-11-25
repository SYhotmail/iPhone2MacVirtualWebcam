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

        await manager.send(Data([0x01, 0x02, 0x03]), isKeyframe: true)

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
        await manager.send(Data([0x01]), isKeyframe: true)

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
    func sendsFramesAsDatagramChunksWhenTunnelHasDatagramFlow() async throws {
        let flow = MockDatagramFlow(maximumDatagramSize: 110)
        let mockConnection = MockTransportConnection(replies: [.accepted], datagramFlow: flow)
        let manager = FrameStreamClient(connectionFactory: { _ in mockConnection })
        let recorder = StatusRecorder()
        await manager.setStatusChangedHandler { status in
            Task { await recorder.append(status) }
        }

        await manager.connect(to: Self.destination)
        mockConnection.simulateState(.ready)
        _ = await recorder.waitForCount(2)
        let keyframe = Data(repeating: 1, count: 250)
        await manager.send(keyframe, isKeyframe: true)
        await manager.send(Data([2]), isKeyframe: false)

        #expect(flow.startCount == 1)
        #expect(mockConnection.sentPayloads.count == 1) // only the hello on the stream
        let parsed = try flow.sent.map { try #require(VideoDatagram.parse($0)) }
        #expect(parsed.map(\.header) == [
            .init(frameID: 0, chunkIndex: 0, chunkCount: 3, isKeyframe: true),
            .init(frameID: 0, chunkIndex: 1, chunkCount: 3, isKeyframe: true),
            .init(frameID: 0, chunkIndex: 2, chunkCount: 3, isKeyframe: true),
            .init(frameID: 1, chunkIndex: 0, chunkCount: 1, isKeyframe: false),
        ])
        #expect(parsed.prefix(3).reduce(into: Data()) { $0.append($1.payload) } == keyframe)
    }

    @Test
    func keyframeRequestOnStreamCallsHandler() async {
        let keyframeRequest = FramePacket.packetized(Data([StreamControlMessage.keyframeRequest.rawValue]))
        let mockConnection = MockTransportConnection(replies: [.accepted], trailingStreamData: keyframeRequest)
        let manager = FrameStreamClient(connectionFactory: { _ in mockConnection })
        let requests = RequestCounter()
        await manager.setKeyframeRequestHandler {
            requests.increment()
        }

        await manager.connect(to: Self.destination)
        mockConnection.simulateState(.ready)

        let deadline = ContinuousClock.now + .seconds(1)
        while requests.count == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(requests.count == 1)
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

    private let datagramFlow: MockDatagramFlow?

    init(replies: [PairingReply] = [], trailingStreamData: Data = Data(), datagramFlow: MockDatagramFlow? = nil) {
        pendingReceive = replies.reduce(into: Data()) { buffer, reply in
            buffer.append(FramePacket.packetized(try! JSONEncoder().encode(reply)))
        }
        pendingReceive.append(trailingStreamData)
        self.datagramFlow = datagramFlow
    }

    func openDatagramFlow() -> (any TransportDatagramFlow)? {
        datagramFlow
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

private final class MockDatagramFlow: @unchecked Sendable, TransportDatagramFlow {
    let maximumDatagramSize: Int
    private let lock = NSLock()
    private var _sent = [Data]()
    private var _startCount = 0

    var sent: [Data] { lock.withLock { _sent } }
    var startCount: Int { lock.withLock { _startCount } }

    init(maximumDatagramSize: Int) {
        self.maximumDatagramSize = maximumDatagramSize
    }

    func start(queue: DispatchQueue) {
        lock.withLock { _startCount += 1 }
    }

    func cancel() {}

    func send(_ datagram: Data) {
        lock.withLock { _sent.append(datagram) }
    }

    func receive() async throws -> Data {
        throw NWError.posix(.ENOTCONN)
    }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
