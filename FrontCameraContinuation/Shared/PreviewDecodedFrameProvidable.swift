//
//  PreviewDecodedFrameProvidable.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 15/05/2026.
//

import Foundation
import CoreMedia
import Combine

protocol PreviewDecodedFrameProvidable {
   nonisolated func decodedFrameSubject() -> AnyPublisher<CMSampleBuffer, Never>
}
