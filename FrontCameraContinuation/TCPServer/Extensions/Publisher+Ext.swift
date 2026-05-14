//
//  Publisher+Ext.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 12/05/2026.
//

import Combine
import Foundation
import CoreMedia

extension Publisher {
    nonisolated
    func onMainAnyPublisher() -> AnyPublisher<Output, Failure> {
        receive(on: RunLoop.main).eraseToAnyPublisher()
    }
}

protocol PreviewDecodedFrameProvidable {
   nonisolated func decodedFrameSubject() -> AnyPublisher<CMSampleBuffer, Never>
}
