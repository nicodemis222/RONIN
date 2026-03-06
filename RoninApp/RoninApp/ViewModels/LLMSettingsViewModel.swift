import Foundation

/// ViewModel for LLM provider configuration.
///
/// Two modes: Local (LM Studio) or Cloud (OpenAI GPT).
/// API keys are stored in the macOS Keychain for security.
@MainActor
class LLMSettingsViewModel: ObservableObject {

    // MARK: - Provider Enum

    enum Provider: String, CaseIterable, Identifiable {
        case local = "local"
        case openai = "openai"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .local: return "Local Model (LM Studio)"
            case .openai: return "OpenAI (GPT)"
            }
        }

        var isCloud: Bool {
            self == .openai
        }

        var requiresApiKey: Bool {
            self == .openai
        }

        /// Short label for display in status badges
        var shortLabel: String {
            switch self {
            case .local: return "Local"
            case .openai: return "GPT"
            }
        }
    }

    // MARK: - Published Properties

    @Published var selectedProvider: Provider
    @Published var openaiApiKey: String = ""
    @Published var llmModel: String = ""
    @Published var localURL: String = "http://localhost:1234/v1"

    // MARK: - Keys

    private enum Keys {
        static let provider = "ronin.llm.provider"
        static let localURL = "ronin.llm.localURL"
        static let llmModel = "ronin.llm.model"
        static let openaiKey = "ronin.openai-api-key"
    }

    // MARK: - Init

    init() {
        let raw = UserDefaults.standard.string(forKey: Keys.provider) ?? "local"
        self.selectedProvider = Provider(rawValue: raw) ?? .local
        self.localURL = UserDefaults.standard.string(forKey: Keys.localURL)
            ?? "http://localhost:1234/v1"
        self.llmModel = UserDefaults.standard.string(forKey: Keys.llmModel) ?? ""

        // Load API key from Keychain
        self.openaiApiKey = KeychainHelper.load(key: Keys.openaiKey) ?? ""
    }

    // MARK: - Persistence

    /// Save all settings to UserDefaults + Keychain and notify the backend to restart.
    func save() {
        UserDefaults.standard.set(selectedProvider.rawValue, forKey: Keys.provider)
        UserDefaults.standard.set(localURL, forKey: Keys.localURL)
        UserDefaults.standard.set(llmModel, forKey: Keys.llmModel)

        // Save API key to Keychain (or delete if empty)
        if !openaiApiKey.isEmpty {
            KeychainHelper.save(key: Keys.openaiKey, value: openaiApiKey)
        } else {
            KeychainHelper.delete(key: Keys.openaiKey)
        }

        // Notify BackendProcessService to restart with new config
        NotificationCenter.default.post(name: .roninLLMSettingsChanged, object: nil)
    }

    // MARK: - Helpers

    /// Current provider for display in other views (reads from UserDefaults)
    static var currentProvider: Provider {
        let raw = UserDefaults.standard.string(forKey: Keys.provider) ?? "local"
        return Provider(rawValue: raw) ?? .local
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let roninLLMSettingsChanged = Notification.Name("roninLLMSettingsChanged")
}
