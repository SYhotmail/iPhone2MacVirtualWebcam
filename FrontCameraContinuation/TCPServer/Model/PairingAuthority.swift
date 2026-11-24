//
//  PairingAuthority.swift
//  Cam2Mac
//

import Combine
import CryptoKit
import Foundation
import os
import Synchronization
import Transport

/// An iPhone allowed to stream to this Mac.
nonisolated struct PairedClient: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    let name: String
    /// SHA-256 of the client's secret; the secret itself is never stored.
    let secretHash: Data
    let pairedAt: Date
}

/// Decides which `PairingHello`s the receiver accepts and remembers paired iPhones.
/// `@unchecked`: mutable state lives in a `Mutex`; `CurrentValueSubject.send` and `UserDefaults` are thread-safe.
nonisolated final class PairingAuthority: @unchecked Sendable {
    static let pairingWindow: TimeInterval = 5 * 60
    private static let defaultsKey = "macPairedClients"

    private struct PendingPairing {
        let token: Data
        let expiresAt: Date
    }

    private struct State {
        var clients: [PairedClient]
        var pending: PendingPairing?
    }

    private let state: Mutex<State>
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    let clientsSubject: CurrentValueSubject<[PairedClient], Never>

    init(defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = Date.init) {
        let clients = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([PairedClient].self, from: $0) } ?? []
        self.defaults = defaults
        self.now = now
        self.state = Mutex(State(clients: clients))
        self.clientsSubject = CurrentValueSubject(clients)
    }

    /// Starts a pairing window and returns its single-use token.
    func beginPairing() -> Data {
        let token = Data(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) })
        let expiresAt = now().addingTimeInterval(Self.pairingWindow)
        state.withLock { $0.pending = PendingPairing(token: token, expiresAt: expiresAt) }
        return token
    }

    func cancelPairing() {
        state.withLock { $0.pending = nil }
    }

    func remove(clientID: UUID) {
        let clients = state.withLock { state in
            state.clients.removeAll { $0.id == clientID }
            return state.clients
        }
        persist(clients)
    }

    func authorize(_ hello: PairingHello) -> PairingReply {
        let reply = decide(hello)
        Self.logger.info("\(hello.kind.rawValue, privacy: .public) from \(hello.clientID, privacy: .public): \(reply.ok ? "accepted" : reply.reason ?? "rejected", privacy: .public)")
        return reply
    }

    private static let logger = Logger(subsystem: "by.sy.TCPServer", category: "pairing")

    private func decide(_ hello: PairingHello) -> PairingReply {
        switch hello.kind {
        case .hello:
            let secretHash = Data(SHA256.hash(data: hello.secret))
            let isKnown = state.withLock { state in
                state.clients.contains { $0.id == hello.clientID && constantTimeEquals($0.secretHash, secretHash) }
            }
            return isKnown ? .accepted : .rejected("This iPhone is not paired with this Mac. Pair again.")

        case .pair:
            guard hello.secret.count >= 32 else {
                return .rejected("Pairing secret is too short.")
            }
            let currentDate = now()
            let result: [PairedClient]? = state.withLock { state in
                guard let pending = state.pending,
                      pending.expiresAt > currentDate,
                      let token = hello.token,
                      constantTimeEquals(pending.token, token) else {
                    return nil
                }
                state.pending = nil
                state.clients.removeAll { $0.id == hello.clientID }
                state.clients.append(PairedClient(
                    id: hello.clientID,
                    name: hello.deviceName ?? "iPhone",
                    secretHash: Data(SHA256.hash(data: hello.secret)),
                    pairedAt: currentDate
                ))
                return state.clients
            }
            guard let result else {
                return .rejected("Pairing code expired or already used. Show a new code on the Mac.")
            }
            persist(result)
            return .accepted
        }
    }

    private func persist(_ clients: [PairedClient]) {
        if let data = try? JSONEncoder().encode(clients) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        clientsSubject.send(clients)
    }
}

private nonisolated func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else {
        return false
    }
    return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}
