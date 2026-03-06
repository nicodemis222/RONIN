import SwiftUI

/// Compact checklist showing startup dependency states.
/// Displayed during backend startup and collapses once everything passes.
struct DependencyChecklistView: View {
    let dependencies: [DependencyCheck]
    var onRetry: (() -> Void)?

    private var hasFailure: Bool {
        dependencies.contains { $0.state.isFailed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(dependencies) { dep in
                HStack(spacing: 8) {
                    statusIcon(for: dep.state)
                        .frame(width: 16, alignment: .center)

                    Text(dep.label)
                        .font(.matrixBody)
                        .foregroundColor(labelColor(for: dep.state))

                    Spacer()

                    // Show detail (e.g. provider name) or failure message
                    if let failure = dep.failureMessage {
                        Text(failure)
                            .font(.matrixCaption)
                            .foregroundColor(.matrixStatusError)
                            .lineLimit(1)
                    } else if let detail = dep.detail {
                        Text(detail)
                            .font(.matrixCaption)
                            .foregroundColor(.matrixFaded)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
                .animation(.easeInOut(duration: 0.25), value: dep.state)
            }

            if hasFailure {
                HStack {
                    Spacer()
                    Button("Retry") {
                        onRetry?()
                    }
                    .font(.matrixCaption)
                    .buttonStyle(MatrixSecondaryButtonStyle())
                }
                .padding(.top, 4)
            }
        }
        .matrixGroupBox(title: "SYSTEM_CHECK")
    }

    // MARK: - Status Icon

    @ViewBuilder
    private func statusIcon(for state: CheckState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .font(.caption2)
                .foregroundColor(.matrixFaded)
        case .checking:
            ProgressView()
                .controlSize(.mini)
                .tint(.matrixNeon)
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.matrixStatusActive)
                .shadow(color: .matrixStatusActive.opacity(0.5), radius: 3)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundColor(.matrixStatusError)
                .shadow(color: .matrixStatusError.opacity(0.5), radius: 3)
        case .skipped:
            Image(systemName: "minus.circle.fill")
                .font(.caption)
                .foregroundColor(.matrixWarning)
        }
    }

    // MARK: - Label Color

    private func labelColor(for state: CheckState) -> Color {
        switch state {
        case .pending: return .matrixFaded
        case .checking: return .matrixDim
        case .passed: return .matrixText
        case .failed: return .matrixStatusError
        case .skipped: return .matrixWarning
        }
    }
}
