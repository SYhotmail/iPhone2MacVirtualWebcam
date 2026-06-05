import Foundation
import Network
import Testing
@testable import Transport

@Suite("FrameStreamClient Tests")
struct FrameStreamClientTests {
    @Test
    func connectTransitionsToFailedWhenConnectionWaits() async {
        let mockConnection = MockTransportConnection()
        let manager = FrameStreamClient(connectionFactory: .init { _, _ in
            mockConnection
        })

        let recorder = StatusRecorder()
        await manager.setStatusChangedHandler { status in
            Task {
                await recorder.append(status)
            }
        }

        let didConnect = await manager.connect(toHost: "127.0.0.1", port: 8080)
        #expect(didConnect)

        mockConnection.simulateState(.waiting(.posix(.ECONNREFUSED)))
        let statuses = await recorder.waitForCount(2)
        #expect(statuses == [.connecting, .failed])
    }

    @Test
    func connectAndSendPacketsDataThroughInjectedConnection() async {
        let mockConnection = MockTransportConnection()
        let manager = FrameStreamClient(connectionFactory: .init { _, _ in
            mockConnection
        })

        let recorder = StatusRecorder()
        await manager.setStatusChangedHandler { status in
            Task {
                await recorder.append(status)
            }
        }

        let didConnect = await manager.connect(toHost: "192.168.1.10", port: 9999)
        #expect(didConnect)

        mockConnection.simulateState(.ready)
        let statuses = await recorder.waitForCount(2)

        await manager.send(Data([0x01, 0x02, 0x03]))

        #expect(statuses == [.connecting, .connected])
        #expect(mockConnection.startedQueues.count == 1)
        #expect(mockConnection.sentPayloads == [FramePacket.packetized(Data([0x01, 0x02, 0x03]))])
    }

    @Test
    func reconnectCurrentReusesLastEndpoint() async {
        let factoryRecorder = ConnectionFactoryRecorder()
        let manager = FrameStreamClient(connectionFactory: .init { _, _ in
            let connection = MockTransportConnection()
            factoryRecorder.append(connection)
            return connection
        })

        #expect(await manager.connect(toHost: "10.0.0.2", port: 7777))
        #expect(await manager.reconnect())

        let createdConnections = factoryRecorder.snapshot()
        #expect(createdConnections.count == 2)
        #expect(createdConnections[0].cancelCallCount == 1)
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
    private let lock = NSLock()
    private var connections = [MockTransportConnection]()

    func append(_ connection: MockTransportConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
    }

    func snapshot() -> [MockTransportConnection] {
        lock.lock()
        let snapshot = connections
        lock.unlock()
        return snapshot
    }
}

private final class MockTransportConnection: @unchecked Sendable, TransportConnection {
    var state: TransportConnectionState = .setup
    var stateUpdateHandler: (@Sendable (TransportConnectionState) -> Void)?
    var pathUpdateHandler: (@Sendable (NWPath) -> Void)?
    var viabilityUpdateHandler: (@Sendable (Bool) -> Void)?
    var betterPathUpdateHandler: (@Sendable (Bool) -> Void)?

    private(set) var startedQueues = [DispatchQueue]()
    private(set) var cancelCallCount = 0
    private(set) var forceCancelCallCount = 0
    private(set) var sentPayloads = [Data]()

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
        Issue.record("FrameStreamClient tests should not receive data.")
        return TransportReceiveResult(data: Data(), contentContext: nil, isComplete: true)
    }

    func simulateState(_ newState: TransportConnectionState) {
        state = newState
        stateUpdateHandler?(newState)
    }
}
