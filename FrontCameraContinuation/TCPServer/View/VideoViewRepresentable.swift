import SwiftUI

struct VideoViewRepresentable: NSViewRepresentable {
    let videoView: VideoView

    func makeNSView(context: Context) -> VideoView {
        videoView
    }

    func updateNSView(_ nsView: VideoView, context: Context) {}
}