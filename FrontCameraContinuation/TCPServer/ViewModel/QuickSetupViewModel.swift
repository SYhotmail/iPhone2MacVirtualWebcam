import Foundation
import Combine
import Observation
import SwiftUI

@Observable
final class QuickSetupViewModel {
    struct Step {
        let title: String
        let detail: String
    }
    
    let title = "Quick Setup"
    let subtitle = "Use this guide when you need a reminder. The main receiver window stays focused on starting the stream and monitoring the feed."
    
    @ObservationIgnored
    let shouldAnimate: Bool
    @ObservationIgnored
    let stepsShownPublisher = PassthroughSubject<Void, Never>()
    
    init(shouldAnimate: Bool = true) {
        self.shouldAnimate = shouldAnimate
        if !shouldAnimate {
            steps = Self.finalSteps
        }
    }
    
    @ObservationIgnored
    private var cancellable: AnyCancellable! {
        didSet {
            guard let oldValue, oldValue !== cancellable else {
                return
            }
            oldValue.cancel()
        }
    }
    
    private(set)var steps = [Step]()
    
    private func shouldAddSteps() -> Bool {
        let diff = Self.finalSteps.count - self.steps.count
        return diff > 0
    }
    
    func onAppear() {
        guard shouldAddSteps(), cancellable == nil else {
            return
        }
        
        cancellable = Timer.publish(every: 0.1, tolerance: 0.1/2, on: .main, in: .common).autoconnect().sink { [weak self] date in
            guard let self else {
                return
            }
            
            guard self.shouldAddSteps() else {
                self.resetCancellable()
                self.stepsShownPublisher.send()
                return
            }
            self.steps.append(Self.finalSteps[self.steps.count])
        }
    }
    
    private func resetCancellable() {
        cancellable = nil
    }
    
    func onDissappear() {
        resetCancellable()
    }
    

    private static let finalSteps = [
        Step(
            title: "Move the app to Applications",
            detail: "System extension installation is most reliable when the host app runs from `/Applications`."
        ),
        Step(
            title: "Install the virtual camera",
            detail: "Use the install button in the receiver window, then approve any macOS permission prompt."
        ),
        Step(
            title: "Start the receiver",
            detail: "Launch the listener on your Mac before you start streaming from the iPhone."
        ),
        Step(
            title: "Connect from iPhone",
            detail: "Enter the Mac IP address and port shown in the receiver window, then tap Start Stream on the phone."
        ),
        Step(
            title: "Pick the virtual camera in apps",
            detail: "Choose `Remote Camera` in Zoom, Meet, QuickTime, or another macOS camera app."
        )
    ]
}
