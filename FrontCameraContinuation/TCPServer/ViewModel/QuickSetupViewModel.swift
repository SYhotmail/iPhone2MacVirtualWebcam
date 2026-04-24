import Foundation
import Observation

@Observable
final class QuickSetupViewModel {
    struct Step: Identifiable {
        let id: String
        let number: String
        let title: String
        let detail: String
    }

    let title = "Quick Setup"
    let subtitle = "Use this guide when you need a reminder. The main receiver window stays focused on starting the stream and monitoring the feed."

    let steps: [Step] = [
        Step(
            id: "move-to-applications",
            number: "1",
            title: "Move the app to Applications",
            detail: "System extension installation is most reliable when the host app runs from `/Applications`."
        ),
        Step(
            id: "install-camera",
            number: "2",
            title: "Install the virtual camera",
            detail: "Use the install button in the receiver window, then approve any macOS permission prompt."
        ),
        Step(
            id: "start-receiver",
            number: "3",
            title: "Start the receiver",
            detail: "Launch the listener on your Mac before you start streaming from the iPhone."
        ),
        Step(
            id: "connect-from-iphone",
            number: "4",
            title: "Connect from iPhone",
            detail: "Enter the Mac IP address and port shown in the receiver window, then tap Start Stream on the phone."
        ),
        Step(
            id: "pick-virtual-camera",
            number: "5",
            title: "Pick the virtual camera in apps",
            detail: "Choose `Remote Camera` in Zoom, Meet, QuickTime, or another macOS camera app."
        )
    ]
}
