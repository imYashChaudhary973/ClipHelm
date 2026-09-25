import SwiftUI
import AVFoundation
import ClipHelmCaptions
import ClipHelmCore
import ClipHelmMedia

/// Draws the exact transparent caption bitmap used by the frame renderer.
struct CaptionPreviewView: View {
    let program: CaptionProgram
    let engine: PlaybackEngine
    let asset: MediaAsset
    @State private var renderer = CaptionRenderer()

    var body: some View {
        GeometryReader { geometry in
            let videoRect = AVMakeRect(
                aspectRatio: CGSize(width: asset.width, height: asset.height),
                insideRect: CGRect(origin: .zero, size: geometry.size))
            TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                if let time = try? engine.currentSourceTime(),
                   let frame = program.frame(at: time, canvasSize: videoRect.size),
                   let image = renderer.render(frame, canvasSize: videoRect.size) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: videoRect.width, height: videoRect.height)
                        .position(x: videoRect.midX, y: videoRect.midY)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
