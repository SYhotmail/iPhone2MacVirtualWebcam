import Foundation
import Network
import Testing
@testable import Transport

@Suite("FrameStreamServer Tests")
struct FrameStreamServerTests {
    @Test
    func startPropagatesListenerCreationFailures() async {
        struct ListenerCreationError: Error {}

        let server = FrameStreamServer(listenerFactory: .init { _ in
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
            receiveResults: [
                .success(Data([0x00, 0x00, 0x00, 0x03])),
                .success(Data([0xAA, 0xBB, 0xCC])),
            ]
        )
        let server = FrameStreamServer(listenerFactory: .init { _ in listener })

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
    }

    @Test
    func requestsEntireFramePayloadInSingleReceive() async throws {
        let listener = MockTransportListener()
        let connection = MockTransportConnection(
            receiveResults: [
                .success(Data([0x00, 0x00, 0x00, 0x03])),
                .success(Data([0xAA, 0xBB, 0xCC])),
            ]
        )
        let server = FrameStreamServer(listenerFactory: .init { _ in listener })

        try await server.start(on: 9999)
        listener.simulateNewConnection(connection)
        await waitForCondition { connection.startedQueues.count == 1 }
        connection.simulateState(.ready)
        await waitForCondition { connection.receiveRequests.count >= 2 }

        #expect(connection.receiveRequests[0] == .init(minimumIncompleteLength: 4, maximumLength: 4))
        #expect(connection.receiveRequests[1] == .init(minimumIncompleteLength: 3, maximumLength: 3))
    }

    @Test
    func cancelConnectionsForceCancelsActiveConnections() async throws {
        let listener = MockTransportListener()
        let connection = MockTransportConnection(receiveResults: [])
        let server = FrameStreamServer(listenerFactory: .init { _ in listener })

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
    func rejectsSecondConnectionWhileFirstClientIsStillActive() async throws {
        let listener = MockTransportListener()
        let firstConnection = MockTransportConnection(receiveResults: [])
        let secondConnection = MockTransportConnection(receiveResults: [])
        let server = FrameStreamServer(listenerFactory: .init { _ in listener })

        try await server.start(on: 9999)
        listener.simulateNewConnection(firstConnection)
        await waitForCondition { firstConnection.startedQueues.count == 1 }

        listener.simulateNewConnection(secondConnection)
        await waitForCondition { secondConnection.forceCancelCallCount == 1 }

        #expect(firstConnection.forceCancelCallCount == 0)
        #expect(firstConnection.cancelCallCount == 0)
        #expect(secondConnection.startedQueues.isEmpty)
        #expect(secondConnection.forceCancelCallCount == 1)
    }
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
    var state: TransportListenerState = .setup
    var stateUpdateHandler: (@Sendable (TransportListenerState) -> Void)?
    var newConnectionHandler: (@Sendable (any TransportConnection) -> Void)?

    private(set) var startedQueues = [DispatchQueue]()
    private(set) var cancelCallCount = 0

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

    init(receiveResults: [Result<Data, Error>]) {
        self.receiveResults = receiveResults
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
