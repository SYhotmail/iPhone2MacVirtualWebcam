import Foundation
import Network
import Testing
@testable import Transport

@Suite("FrameStreamServer Tests")
struct FrameStreamServerTests {
    @Test
    func startPropagatesListenerCreationFailures() async {
        struct ListenerCreationError: Error {}

        let server = FrameStreamServer(listenerFactory: { _ in
            throw ListenerCreationError()
        })

        do {
            try await server.start(on: 0)
            Issue.record("Expected listener creation to fail.")
        } catch is ListenerCreationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func readsCompleteFrameFromConnection() async throws {
        let listener = MockTransportListener()
        let connection = MockTransportConnection(
            receiveResults: helloResults() + [
                .success(Data([0x00, 0x00, 0x00, 0x03])),
                .success(Data([0xAA, 0xBB, 0xCC])),
            ]
        )
        let server = await makeAcceptingServer(listener)

        let recorder = FrameRecorder()
        await server.setFrameHandler { data in
            Task {
                await recorder.store(data)
            }
        }

        try await server.start(on: 9999)
        listener.simulateNewConnection(connection)
        await waitForCondition { connection.startedQueues.count == 1 }
        connection.simulateState(.ready)
        let receivedFrame = await recorder.waitForFrame()

        #expect(receivedFrame == Data([0xAA, 0xBB, 0xCC]))
        #expect(decodedReplies(connection) == [.accepted])
    }

    @Test
    func requestsEntireFramePayloadInSingleReceive() async throws {
        let listener = MockTransportListener()
        let connection = MockTransportConnection(
            receiveResults: helloResults() + [
                .success(Data([0x00, 0x00, 0x00, 0x03])),
                .success(Data([0xAA, 0xBB, 0xCC])),
            ]
        )
        let server = await makeAcceptingServer(listener)

        try await server.start(on: 9999)
        listener.simulateNewConnection(connection)
        await waitForCondition { connection.startedQueues.count == 1 }
        connection.simulateState(.ready)
        await waitForCondition { connection.receiveRequests.count >= 4 }

        #expect(connection.receiveRequests[2] == .init(minimumIncompleteLength: 1, maximumLength: 4))
        #expect(connection.receiveRequests[3] == .init(minimumIncompleteLength: 1, maximumLength: 3))
    }

    @Test
    func cancelConnectionsForceCancelsActiveConnections() async throws {
        let listener = MockTransportListener()
        let connection = MockTransportConnection(receiveResults: [])
        let server = FrameStreamServer(listenerFactory: { _ in listener })

        let recorder = StreamUnavailableRecorder()
        await server.setStreamUnavailableHandler {
            Task {
                await recorder.increment()
            }
        }

        try await server.start(on: 9999)
        listener.simulateNewConnection(connection)
        await waitForCondition { connection.startedQueues.count == 1 }
        await server.disconnectClients(forcefully: true)

        #expect(connection.forceCancelCallCount == 1)
        #expect(await recorder.waitForCount(1) == 1)
        #expect(server.state.connectionState.value == .cancelled)
    }

    @Test
    func rejectsSecondConnectionWhileFirstClientIsStillStreaming() async throws {
        let listener = MockTransportListener()
        var receiveResults = helloResults()
        for _ in 0..<128 {
            receiveResults.append(.success(Data([0x00, 0x00, 0x00, 0x03])))
            receiveResults.append(.success(Data([0xAA, 0xBB, 0xCC])))
        }
        let firstConnection = MockTransportConnection(receiveResults: receiveResults)
        let secondConnection = MockTransportConnection(receiveResults: [])
        let server = await makeAcceptingServer(listener)
        let recorder = FrameRecorder()

        await server.setFrameHandler { data in
            Task {
                await recorder.store(data)
            }
        }

        try await server.start(on: 9999)
        listener.simulateNewConnection(firstConnection)
        await waitForCondition { firstConnection.startedQueues.count == 1 }
        firstConnection.simulateState(.ready)
        _ = await recorder.waitForFrame()

        listener.simulateNewConnection(secondConnection)
        await waitForCondition { secondConnection.forceCancelCallCount == 1 }

        #expect(firstConnection.forceCancelCallCount == 0)
        #expect(firstConnection.cancelCallCount == 0)
        #expect(secondConnection.startedQueues.isEmpty)
        #expect(secondConnection.forceCancelCallCount == 1)
    }

    @Test
    func replacesSecondConnectionWhenFirstClientNeverReachedReady() async throws {
        let listener = MockTransportListener()
        let firstConnection = MockTransportConnection(receiveResults: [])
        let secondConnection = MockTransportConnection(receiveResults: [])
        let server = FrameStreamServer(listenerFactory: { _ in listener })

        try await server.start(on: 9999)
        listener.simulateNewConnection(firstConnection)
        await waitForCondition { firstConnection.startedQueues.count == 1 }

        listener.simulateNewConnection(secondConnection)
        await waitForCondition { firstConnection.cancelCallCount == 1 }
        await waitForCondition { secondConnection.startedQueues.count == 1 }

        #expect(firstConnection.cancelCallCount == 1)
        #expect(firstConnection.forceCancelCallCount == 0)
        #expect(secondConnection.forceCancelCallCount == 0)
        #expect(secondConnection.startedQueues.count == 1)
    }

    @Test
    func readsHelloSplitAcrossManyReceives() async throws {
        let listener = MockTransportListener()
        let packet = FramePacket.packetized(try JSONEncoder().encode(validHello))
        var results = packet.map { Result<Data, Error>.success(Data([$0])) }
        results += [.success(Data([0x00, 0x00, 0x00, 0x01])), .success(Data([0x42]))]
        let connection = MockTransportConnection(receiveResults: results)
        let server = await makeAcceptingServer(listener)
        let recorder = FrameRecorder()
        await server.setFrameHandler { data in
            Task { await recorder.store(data) }
        }

        try await server.start(on: 9999)
        listener.simulateNewConnection(connection)
        await waitForCondition { connection.startedQueues.count == 1 }
        connection.simulateState(.ready)

        #expect(await recorder.waitForFrame() == Data([0x42]))
    }

    @Test
    func rejectedHelloGetsReplyAndNoFramesAreDelivered() async throws {
        let listener = MockTransportListener()
        let badHello = PairingHello.hello(clientID: UUID(), secret: Data(repeating: 1, count: 32))
        let connection = MockTransportConnection(
            receiveResults: helloResults(badHello) + [
                .success(Data([0x00, 0x00, 0x00, 0x01])),
                .success(Data([0x42])),
            ]
        )
        let server = await makeAcceptingServer(listener)
        let recorder = FrameRecorder()
        await server.setFrameHandler { data in
            Task { await recorder.store(data) }
        }

        try await server.start(on: 9999)
        listener.simulateNewConnection(connection)
        await waitForCondition { connection.startedQueues.count == 1 }
        connection.simulateState(.ready)
        await waitForCondition { connection.cancelCallCount == 1 }

        #expect(decodedReplies(connection) == [.rejected("bad secret")])
        #expect(connection.cancelCallCount == 1)
        #expect(await recorder.waitForFrame(timeoutNanoseconds: 50_000_000) == nil)
    }

    @Test
    func rejectsEveryoneWithoutAuthorizer() async throws {
        let listener = MockTransportListener()
        let connection = MockTransportConnection(receiveResults: helloResults())
        let server = FrameStreamServer(listenerFactory: { _ in listener })

        try await server.start(on: 9999)
        listener.simulateNewConnection(connection)
        await waitForCondition { connection.startedQueues.count == 1 }
        connection.simulateState(.ready)
        await waitForCondition { connection.cancelCallCount == 1 }

        #expect(decodedReplies(connection).first?.ok == false)
    }

    @Test
    func closesConnectionSendingOversizedHello() async throws {
        let listener = MockTransportListener()
        let connection = MockTransportConnection(receiveResults: [.success(Data([0x00, 0x01, 0x00, 0x00]))])
        let server = await makeAcceptingServer(listener)

        try await server.start(on: 9999)
        listener.simulateNewConnection(connection)
        await waitForCondition { connection.startedQueues.count == 1 }
        connection.simulateState(.ready)
        await waitForCondition { connection.cancelCallCount == 1 }

        #expect(connection.cancelCallCount == 1)
        #expect(connection.sentPayloads.isEmpty)
        #expect(connection.receiveRequests.count == 1)
    }

    @Test
    func authenticatedButIdleConnectionDoesNotBlockNextClient() async throws {
        let listener = MockTransportListener()
        let firstConnection = MockTransportConnection(receiveResults: helloResults(), endsWhenEmpty: false)
        let secondConnection = MockTransportConnection(receiveResults: [])
        let server = await makeAcceptingServer(listener)

        try await server.start(on: 9999)
        listener.simulateNewConnection(firstConnection)
        await waitForCondition { firstConnection.startedQueues.count == 1 }
        firstConnection.simulateState(.ready)
        await waitForCondition { decodedReplies(firstConnection) == [.accepted] }

        listener.simulateNewConnection(secondConnection)
        await waitForCondition { secondConnection.startedQueues.count == 1 }

        #expect(firstConnection.cancelCallCount == 1)
        #expect(secondConnection.forceCancelCallCount == 0)
    }

    @Test
    func reassemblesDatagramFramesAfterPairing() async throws {
        let listener = MockTransportListener()
        let keyframe = Data(repeating: 1, count: 250)
        let flow = ServerMockDatagramFlow(datagrams: chunks(keyframe, id: 0, keyframe: true) + chunks(Data([2]), id: 1, keyframe: false))
        let connection = MockTransportConnection(receiveResults: helloResults(), endsWhenEmpty: false, datagramFlow: flow)
        let server = await makeAcceptingServer(listener)
        let frames = FrameCollector()
        await server.setFrameHandler { frames.append($0) }

        try await server.start(on: 9999)
        listener.simulateNewConnection(connection)
        await waitForCondition { connection.startedQueues.count == 1 }
        connection.simulateState(.ready)
        await waitForCondition { frames.snapshot().count == 2 }

        #expect(frames.snapshot() == [keyframe, Data([2])])
        #expect(flow.startCount == 1)
        #expect(decodedReplies(connection) == [.accepted])
    }

    @Test
    func lostDatagramFrameRequestsKeyframeOnStream() async throws {
        let listener = MockTransportListener()
        // Frame 1 is lost; frame 2 can't be decoded without it.
        let flow = ServerMockDatagramFlow(datagrams: chunks(Data([1]), id: 0, keyframe: true) + chunks(Data([3]), id: 2, keyframe: false))
        let connection = MockTransportConnection(receiveResults: helloResults(), endsWhenEmpty: false, datagramFlow: flow)
        let server = await makeAcceptingServer(listener)
        let frames = FrameCollector()
        await server.setFrameHandler { frames.append($0) }
        let keyframeRequest = FramePacket.packetized(Data([StreamControlMessage.keyframeRequest.rawValue]))

        try await server.start(on: 9999)
        listener.simulateNewConnection(connection)
        await waitForCondition { connection.startedQueues.count == 1 }
        connection.simulateState(.ready)
        await waitForCondition { connection.sentPayloads.contains(keyframeRequest) }

        #expect(connection.sentPayloads.contains(keyframeRequest))
        #expect(frames.snapshot() == [Data([1])])
    }

    @Test
    func rejectedHelloDoesNotOpenDatagramFlow() async throws {
        let listener = MockTransportListener()
        let flow = ServerMockDatagramFlow(datagrams: [])
        let badHello = PairingHello.hello(clientID: UUID(), secret: Data(repeating: 1, count: 32))
        let connection = MockTransportConnection(receiveResults: helloResults(badHello), datagramFlow: flow)
        let server = await makeAcceptingServer(listener)

        try await server.start(on: 9999)
        listener.simulateNewConnection(connection)
        await waitForCondition { connection.startedQueues.count == 1 }
        connection.simulateState(.ready)
        await waitForCondition { connection.cancelCallCount == 1 }

        #expect(flow.startCount == 0)
    }

    @Test
    func advertisesBonjourServiceWhenNamed() async throws {
        let listener = MockTransportListener()
        let server = FrameStreamServer(listenerFactory: { _ in listener })

        try await server.start(on: 9999, serviceName: "Studio Mac")
        listener.serviceNameRegisteredHandler?("Studio Mac (2)")

        #expect(listener.service?.name == "Studio Mac")
        #expect(listener.service?.type == FrameStreamService.type)
        #expect(server.state.advertisedServiceName.value == "Studio Mac (2)")
    }

    // MARK: - Several listeners (QUIC for iPhone, TLS/TCP for Android)

    @Test
    func startsEveryListenerAdvertisingItsOwnServiceType() async throws {
        let quic = MockTransportListener(serviceType: FrameStreamService.type)
        let tcp = MockTransportListener(serviceType: FrameStreamService.tcpType)
        let server = FrameStreamServer(listenerFactories: [{ _ in quic }, { _ in tcp }])

        try await server.start(on: 9999, serviceName: "Mac")

        #expect(quic.startedQueues.count == 1)
        #expect(tcp.startedQueues.count == 1)
        #expect(quic.service == NWListener.Service(name: "Mac", type: "_cam2mac._udp"))
        #expect(tcp.service == NWListener.Service(name: "Mac", type: "_cam2mac._tcp"))

        // The QR code carries the QUIC listener's registered name; the TCP one must not replace it.
        quic.serviceNameRegisteredHandler?("Mac (2)")
        tcp.serviceNameRegisteredHandler?("Mac")
        #expect(server.state.advertisedServiceName.value == "Mac (2)")
    }

    @Test
    func realListenersReportServiceTypeOfTheirTransport() throws {
        let quic = NWListenerAdapter(listener: try NWListener(using: TransportNetworkProtocol.commonQUIC.nwParameters))
        let tcp = NWListenerAdapter(listener: try NWListener(using: .tcp))

        #expect(quic.serviceType == "_cam2mac._udp")
        #expect(tcp.serviceType == "_cam2mac._tcp")
    }

    @Test
    func listenerCreationFailureStartsNoListener() async {
        struct ListenerCreationError: Error {}
        let quic = MockTransportListener()
        let server = FrameStreamServer(listenerFactories: [
            { _ in quic },
            { _ in throw ListenerCreationError() },
        ])

        await #expect(throws: ListenerCreationError.self) {
            try await server.start(on: 9999)
        }
        #expect(quic.startedQueues.isEmpty)
    }

    @Test
    func reportsReadyOnlyWhenEveryListenerIsReady() async throws {
        let quic = MockTransportListener()
        let tcp = MockTransportListener(serviceType: FrameStreamService.tcpType)
        let server = FrameStreamServer(listenerFactories: [{ _ in quic }, { _ in tcp }])
        try await server.start(on: 9999)

        quic.simulateState(.ready)
        #expect(server.state.listenerState.value == .setup)

        tcp.simulateState(.ready)
        #expect(server.state.listenerState.value == .ready)

        tcp.simulateState(.failed(.posix(.EADDRINUSE)))
        #expect(server.state.listenerState.value == .failed(.posix(.EADDRINUSE)))
    }

    @Test
    func rejectsClientOnOtherListenerWhileOneIsStreaming() async throws {
        let quic = MockTransportListener()
        let tcp = MockTransportListener(serviceType: FrameStreamService.tcpType)
        let server = FrameStreamServer(listenerFactories: [{ _ in quic }, { _ in tcp }])
        await server.setHelloAuthorizer { _ in .accepted }
        let recorder = FrameRecorder()
        await server.setFrameHandler { data in
            Task { await recorder.store(data) }
        }
        try await server.start(on: 9999)

        var receiveResults = helloResults()
        for _ in 0..<128 {
            receiveResults.append(.success(Data([0x00, 0x00, 0x00, 0x01])))
            receiveResults.append(.success(Data([0xAA])))
        }
        let streaming = MockTransportConnection(receiveResults: receiveResults)
        tcp.simulateNewConnection(streaming)
        await waitForCondition { streaming.startedQueues.count == 1 }
        streaming.simulateState(.ready)
        _ = await recorder.waitForFrame()

        let second = MockTransportConnection(receiveResults: [])
        quic.simulateNewConnection(second)
        await waitForCondition { second.forceCancelCallCount == 1 }

        #expect(second.forceCancelCallCount == 1)
        #expect(second.startedQueues.isEmpty)
        #expect(streaming.cancelCallCount == 0)
    }

    @Test
    func replacesStaleClientFromOtherListener() async throws {
        let quic = MockTransportListener()
        let tcp = MockTransportListener(serviceType: FrameStreamService.tcpType)
        let server = FrameStreamServer(listenerFactories: [{ _ in quic }, { _ in tcp }])
        try await server.start(on: 9999)

        let stale = MockTransportConnection(receiveResults: [])
        quic.simulateNewConnection(stale)
        await waitForCondition { stale.startedQueues.count == 1 }

        let replacement = MockTransportConnection(receiveResults: [])
        tcp.simulateNewConnection(replacement)
        await waitForCondition { replacement.startedQueues.count == 1 }

        #expect(stale.cancelCallCount == 1)
        #expect(replacement.startedQueues.count == 1)
    }

    @Test
    func stopCancelsEveryListener() async throws {
        let quic = MockTransportListener()
        let tcp = MockTransportListener(serviceType: FrameStreamService.tcpType)
        let server = FrameStreamServer(listenerFactories: [{ _ in quic }, { _ in tcp }])
        try await server.start(on: 9999)

        await server.stop()

        #expect(quic.cancelCallCount == 1)
        #expect(tcp.cancelCallCount == 1)
    }
}

private let validHello = PairingHello.hello(clientID: UUID(), secret: Data(repeating: 7, count: 32))

private func helloResults(_ hello: PairingHello = validHello) -> [Result<Data, Error>] {
    let packet = FramePacket.packetized(try! JSONEncoder().encode(hello))
    return [.success(packet.prefix(4)), .success(packet.dropFirst(4))]
}

private func makeAcceptingServer(_ listener: MockTransportListener) async -> FrameStreamServer {
    let server = FrameStreamServer(listenerFactory: { _ in listener })
    await server.setHelloAuthorizer { hello in
        hello.secret == validHello.secret ? .accepted : .rejected("bad secret")
    }
    return server
}

private func chunks(_ frame: Data, id: UInt32, keyframe: Bool) -> [Data] {
    VideoDatagram.chunks(of: frame, frameID: id, isKeyframe: keyframe, maximumDatagramSize: 110)
}

private func decodedReplies(_ connection: MockTransportConnection) -> [PairingReply] {
    connection.sentPayloads.compactMap { try? JSONDecoder().decode(PairingReply.self, from: $0.dropFirst(4)) }
}

private func waitForCondition(timeoutNanoseconds: UInt64 = 1_000_000_000, _ condition: @escaping @Sendable () -> Bool) async {
    let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
    while !condition(), ContinuousClock.now < deadline {
        await Task.yield()
    }
}

private actor FrameRecorder {
    private var frame: Data?

    func store(_ data: Data) {
        frame = data
    }

    func waitForFrame(timeoutNanoseconds: UInt64 = 1_000_000_000) async -> Data? {
        let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
        while frame == nil, ContinuousClock.now < deadline {
            await Task.yield()
        }
        return frame
    }
}

private actor StreamUnavailableRecorder {
    private var count = 0

    func increment() {
        count += 1
    }

    func waitForCount(_ expectedCount: Int, timeoutNanoseconds: UInt64 = 1_000_000_000) async -> Int {
        let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
        while count < expectedCount, ContinuousClock.now < deadline {
            await Task.yield()
        }
        return count
    }
}

private final class MockTransportListener: @unchecked Sendable, TransportListener {
    let serviceType: String
    var state: TransportListenerState = .setup
    var stateUpdateHandler: (@Sendable (TransportListenerState) -> Void)?
    var newConnectionHandler: (@Sendable (any TransportConnection) -> Void)?
    var service: NWListener.Service?
    var serviceNameRegisteredHandler: (@Sendable (String) -> Void)?

    private(set) var startedQueues = [DispatchQueue]()
    private(set) var cancelCallCount = 0

    init(serviceType: String = FrameStreamService.type) {
        self.serviceType = serviceType
    }

    func simulateState(_ state: TransportListenerState) {
        self.state = state
        stateUpdateHandler?(state)
    }

    func start(queue: DispatchQueue) {
        startedQueues.append(queue)
    }

    func cancel() {
        cancelCallCount += 1
    }

    func simulateNewConnection(_ connection: any TransportConnection) {
        newConnectionHandler?(connection)
    }
}

private final class MockTransportConnection: @unchecked Sendable, TransportConnection {
    struct ReceiveRequest: Equatable {
        let minimumIncompleteLength: Int
        let maximumLength: Int
    }

    var state: TransportConnectionState = .setup
    var stateUpdateHandler: (@Sendable (TransportConnectionState) -> Void)?
    var pathUpdateHandler: (@Sendable (NWPath) -> Void)?
    var viabilityUpdateHandler: (@Sendable (Bool) -> Void)?
    var betterPathUpdateHandler: (@Sendable (Bool) -> Void)?

    private(set) var startedQueues = [DispatchQueue]()
    private(set) var cancelCallCount = 0
    private(set) var forceCancelCallCount = 0
    private(set) var sentPayloads = [Data]()
    private(set) var receiveRequests = [ReceiveRequest]()
    private var receiveResults: [Result<Data, Error>]
    private let endsWhenEmpty: Bool
    private let datagramFlow: ServerMockDatagramFlow?

    init(receiveResults: [Result<Data, Error>], endsWhenEmpty: Bool = true, datagramFlow: ServerMockDatagramFlow? = nil) {
        self.receiveResults = receiveResults
        self.endsWhenEmpty = endsWhenEmpty
        self.datagramFlow = datagramFlow
    }

    func openDatagramFlow() -> (any TransportDatagramFlow)? {
        datagramFlow
    }

    func start(queue: DispatchQueue) {
        startedQueues.append(queue)
    }

    func cancel() {
        cancelCallCount += 1
    }

    func forceCancel() {
        forceCancelCallCount += 1
    }

    func send(content: Data?) async throws {
        if let content {
            sentPayloads.append(content)
        }
    }

    func receive(minimumIncompleteLength: Int, maximumLength: Int) async throws -> TransportReceiveResult {
        receiveRequests.append(.init(minimumIncompleteLength: minimumIncompleteLength,
                                     maximumLength: maximumLength))
        guard receiveResults.isEmpty == false else {
            if !endsWhenEmpty {
                try await Task.sleep(for: .seconds(60))
            }
            return TransportReceiveResult(data: Data(), contentContext: nil, isComplete: true)
        }

        let next = receiveResults.removeFirst()
        switch next {
        case .success(let data):
            return TransportReceiveResult(data: data, contentContext: nil, isComplete: false)
        case .failure(let error):
            throw error
        }
    }

    func simulateState(_ newState: TransportConnectionState) {
        state = newState
        stateUpdateHandler?(newState)
    }
}

private final class ServerMockDatagramFlow: @unchecked Sendable, TransportDatagramFlow {
    let maximumDatagramSize = 110
    private let lock = NSLock()
    private var pending: [Data]
    private var _startCount = 0

    var startCount: Int { lock.withLock { _startCount } }

    init(datagrams: [Data]) {
        pending = datagrams
    }

    func start(queue: DispatchQueue) {
        lock.withLock { _startCount += 1 }
    }

    func cancel() {}

    func send(_ datagram: Data) {}

    func receive() async throws -> Data {
        if let next = lock.withLock({ pending.isEmpty ? nil : pending.removeFirst() }) {
            return next
        }
        try await Task.sleep(for: .seconds(60))
        throw NWError.posix(.ENOTCONN)
    }
}

private final class FrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = [Data]()
    func append(_ frame: Data) { lock.withLock { frames.append(frame) } }
    func snapshot() -> [Data] { lock.withLock { frames } }
}
