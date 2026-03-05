import SwiftUI

struct TranscriptPanelView: View {
    let segments: [TranscriptSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .foregroundColor(.matrixBright)
                Text("> Transcript")
                    .font(.matrixHeadline)
                    .foregroundColor(.matrixBright)
                    .matrixGlow(radius: 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().overlay(Color.matrixDivider)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(segments) { segment in
                            HStack(alignment: .top, spacing: 8) {
                                Text(segment.timestamp)
                                    .font(.matrixCaption)
                                    .foregroundColor(.matrixFaded)
                                    .frame(width: 55, alignment: .leading)

                                Text(segment.text)
                                    .font(.matrixBody)
                                    .foregroundColor(.matrixText)
                                    .textSelection(.enabled)
                            }
                            .id(segment.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: segments.count) {
                    if let last = segments.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            if segments.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.badge.mic")
                            .font(.title)
                            .foregroundColor(.matrixFaded)
                        Text("Listening...")
                            .font(.matrixCaption)
                            .foregroundColor(.matrixFaded)
                    }
                    Spacer()
                }
                Spacer()
            }
        }
    }
}
