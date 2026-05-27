//
//  Publisher+Ext.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 12/05/2026.
//

import Combine
import Dispatch
import Foundation

extension Publisher {
    nonisolated
    func onMainAnyPublisher() -> AnyPublisher<Output, Failure> {
        // AppKit live resize switches the main run loop into tracking modes, which can
        // starve deliveries scheduled on RunLoop.main and cause preview frames to burst later.
        receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }
}
