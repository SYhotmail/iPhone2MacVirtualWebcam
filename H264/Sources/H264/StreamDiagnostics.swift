//
//  StreamDiagnostics.swift
//  H264
//
//  Created by Siarhei Yakushevich on 08/06/2026.
//

import Foundation
import Synchronization

nonisolated
final class StreamDiagnostics: @unchecked Sendable {
    static let shared = StreamDiagnostics()

    enum Counter: String, CaseIterable {
        case tcpReceived = "tcp.received"
        case decodeRequested = "decode.requested"
        case decodeDropped = "decode.dropped"
        case decodeSubmitted = "decode.submitted"
        case decodeOutput = "decode.output"
        case decodeError = "decode.error"
        case previewEnqueued = "preview.enqueued"
        case previewDropped = "preview.dropped"
    }

    private let lock = Mutex(())
    private var counts = [Counter: Int]()
    private var lastFlush = Date()

    private init() {}

    private func markCore(_ counter: Counter, amount: Int) {
        counts[counter, default: 0] += amount

        let now = Date()
        let elapsed = now.timeIntervalSince(lastFlush)
        guard elapsed >= 1 else {
            return
        }

        let snapshot = Counter.allCases.compactMap { counter -> String? in
            guard let count = counts[counter], count > 0 else {
                return nil
            }
            return "\(counter.rawValue)=\(count)/s"
        }

        counts.removeAll(keepingCapacity: true)
        lastFlush = now

        guard !snapshot.isEmpty else {
            return
        }

        debugPrint("STREAM STATS", snapshot.joined(separator: " "))
    }

    func mark(_ counter: Counter, amount: Int = 1) {
        lock.withLock { _ in
            self.markCore(counter, amount: amount)
        }
    }
}
