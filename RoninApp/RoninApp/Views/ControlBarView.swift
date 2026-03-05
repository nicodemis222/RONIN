import SwiftUI

struct ControlBarView: View {
    @Binding var isPaused: Bool
    @Binding var isMuted: Bool
    let elapsedTime: String
    let onPause: () -> Void
    let onMute: () -> Void
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // Elapsed time
            Text(elapsedTime)
                .font(.matrixBody)
                .foregroundColor(.matrixDim)

            Spacer()

            // Mute
            Button(action: onMute) {
                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .foregroundColor(isMuted ? .matrixStatusError : .matrixText)
            }
            .buttonStyle(.plain)
            .help(isMuted ? "Unmute (⌘⇧M)" : "Mute (⌘⇧M)")

            // Pause/Resume
            Button(action: onPause) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .foregroundColor(.matrixText)
            }
            .buttonStyle(.plain)
            .help(isPaused ? "Resume (⌘⇧P)" : "Pause (⌘⇧P)")

            Divider()
                .overlay(Color.matrixDivider)
                .frame(height: 20)

            // End Meeting
            Button(action: onEnd) {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                    Text("End")
                        .font(.matrixBody)
                }
                .foregroundColor(.matrixStatusError)
            }
            .buttonStyle(.plain)
            .help("End meeting (⌘⇧E)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.matrixBar)
    }
}
