import Foundation

/// State of a single dependency check during backend startup.
enum CheckState: Equatable {
    case pending
    case checking
    case passed
    case failed(String)
    case skipped(String)

    var isPassed: Bool {
        if case .passed = self { return true }
        return false
    }

    var isSkipped: Bool {
        if case .skipped = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// A dependency that must be verified before the backend is considered ready.
struct DependencyCheck: Identifiable, Equatable {
    let id: String
    let label: String
    let state: CheckState
    let detail: String?
    let failureMessage: String?

    static func == (lhs: DependencyCheck, rhs: DependencyCheck) -> Bool {
        lhs.id == rhs.id && lhs.state == rhs.state && lhs.detail == rhs.detail
    }

    // MARK: - Factory Methods

    static func pythonRuntime(_ state: CheckState, detail: String = "") -> DependencyCheck {
        DependencyCheck(
            id: "python",
            label: "Python Runtime",
            state: state,
            detail: detail.isEmpty ? nil : detail,
            failureMessage: failureMessage(for: state)
        )
    }

    static func backendProcess(_ state: CheckState) -> DependencyCheck {
        DependencyCheck(
            id: "backend",
            label: "Backend Process",
            state: state,
            detail: nil,
            failureMessage: failureMessage(for: state)
        )
    }

    static func whisperModel(_ state: CheckState, detail: String = "") -> DependencyCheck {
        DependencyCheck(
            id: "whisper",
            label: "Whisper Model",
            state: state,
            detail: detail.isEmpty ? nil : detail,
            failureMessage: failureMessage(for: state)
        )
    }

    static func llmProvider(_ state: CheckState, detail: String) -> DependencyCheck {
        DependencyCheck(
            id: "llm",
            label: "LLM Provider",
            state: state,
            detail: detail.isEmpty ? nil : detail,
            failureMessage: failureMessage(for: state)
        )
    }

    static func microphoneAccess(_ state: CheckState) -> DependencyCheck {
        DependencyCheck(
            id: "microphone",
            label: "Microphone Access",
            state: state,
            detail: nil,
            failureMessage: failureMessage(for: state)
        )
    }

    private static func failureMessage(for state: CheckState) -> String? {
        switch state {
        case .failed(let message): return message
        case .skipped(let reason): return reason
        default: return nil
        }
    }
}
