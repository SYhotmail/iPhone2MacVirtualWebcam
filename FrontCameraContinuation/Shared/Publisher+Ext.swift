//
//  Publisher+Ext.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 12/05/2026.
//

import Combine
import Foundation

extension Publisher {
    nonisolated
    func onMainAnyPublisher() -> AnyPublisher<Output, Failure> {
        receive(on: RunLoop.main).eraseToAnyPublisher()
    }
}
