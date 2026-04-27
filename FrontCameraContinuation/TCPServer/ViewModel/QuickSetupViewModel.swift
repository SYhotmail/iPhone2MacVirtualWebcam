import Foundation
import Observation

@Observable
final class QuickSetupViewModel {
    struct Step: Identifiable {
        let number: Int
        let title: String
        let detail: String
        
        var id: Int { number }
    }

    let title = "Quick Setup"
    let subtitle = "Use this guide when you need a reminder. The main receiver window stays focused on starting the stream and monitoring the feed."

    let steps: [Step] = [
        Step(
            number: 1,
            title: "Move the app to Applications",
            detail: "System extension installation is most reliable when the host app runs from `/Applications`."
        ),
        Step(
            number: 2,
            title: "Install the virtual camera",
            detail: "Use the install button in the receiver window, then approve any macOS permission prompt."
        ),
        Step(
            number: 3,
            title: "Start the receiver",
            detail: "Launch the listener on your Mac before you start streaming from the iPhone."
        ),
        Step(
            number: 4,
            title: "Connect from iPhone",
            detail: "Enter the Mac IP address and port shown in the receiver window, then tap Start Stream on the phone."
        ),
        Step(
            number: 5,
            title: "Pick the virtual camera in apps",
            detail: "Choose `Remote Camera` in Zoom, Meet, QuickTime, or another macOS camera app."
        )
    ]
}
