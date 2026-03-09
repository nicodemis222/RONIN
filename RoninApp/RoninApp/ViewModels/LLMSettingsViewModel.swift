import Foundation

/// ViewModel for LLM provider configuration.
///
/// Four modes: Local (LM Studio), OpenAI (GPT), Anthropic (Claude), or Apple Intelligence (on-device).
/// API keys are stored in the macOS Keychain for security.
@MainActor
class LLMSettingsViewModel: ObservableObject {

    // MARK: - Provider Enum

    enum Provider: String, CaseIterable, Identifiable {
        case local = "local"
        case openai = "openai"
        case anthropic = "anthropic"
        case appleIntelligence = "apple_intelligence"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .local: return "Local Model (LM Studio)"
            case .openai: return "OpenAI (GPT)"
            case .anthropic: return "Anthropic (Claude)"
            case .appleIntelligence: return "Apple Intelligence (On-Device)"
            }
        }

        var isCloud: Bool {
            self == .openai || self == .anthropic
        }

        var requiresApiKey: Bool {
            self == .openai || self == .anthropic
        }

        var isAppleIntelligence: Bool {
            self == .appleIntelligence
        }

        /// Short label for display in status badges
        var shortLabel: String {
            switch self {
            case .local: return "Local"
            case .openai: return "GPT"
            case .anthropic: return "Claude"
            case .appleIntelligence: return "AI"
            }
        }

        /// Cloud privacy warning text for the provider, if applicable.
        var cloudWarning: String? {
            switch self {
            case .openai:
                return "Transcript text will be sent to OpenAI servers. Audio always stays on your Mac."
            case .anthropic:
                return "Transcript text will be sent to Anthropic servers. Audio always stays on your Mac."
            default:
                return nil
            }
        }
    }

    // MARK: - Published Properties

    @Published var selectedProvider: Provider
    @Published var openaiApiKey: String = ""
    @Published var anthropicApiKey: String = ""
    @Published var llmModel: String = ""
    @Published var localURL: String = "http://localhost:1234/v1"

    // MARK: - Keys

    private enum Keys {
        static let provider = "ronin.llm.provider"
        static let localURL = "ronin.llm.localURL"
        static let llmModel = "ronin.llm.model"
        static let openaiKey = "ronin.openai-api-key"
        static let anthropicKey = "ronin.anthropic-api-key"
    }

    // MARK: - Init

    init() {
        let raw = UserDefaults.standard.string(forKey: Keys.provider) ?? "local"
        self.selectedProvider = Provider(rawValue: raw) ?? .local
        self.localURL = UserDefaults.standard.string(forKey: Keys.localURL)
            ?? "http://localhost:1234/v1"
        self.llmModel = UserDefaults.standard.string(forKey: Keys.llmModel) ?? ""

        // Load API keys from Keychain
        self.openaiApiKey = KeychainHelper.load(key: Keys.openaiKey) ?? ""
        self.anthropicApiKey = KeychainHelper.load(key: Keys.anthropicKey) ?? ""
    }

    // MARK: - Persistence

    /// Save all settings to UserDefaults + Keychain and notify the backend to restart.
    func save() {
        UserDefaults.standard.set(selectedProvider.rawValue, forKey: Keys.provider)
        UserDefaults.standard.set(localURL, forKey: Keys.localURL)
        UserDefaults.standard.set(llmModel, forKey: Keys.llmModel)

        // Save API keys to Keychain (or delete if empty)
        if !openaiApiKey.isEmpty {
            KeychainHelper.save(key: Keys.openaiKey, value: openaiApiKey)
        } else {
            KeychainHelper.delete(key: Keys.openaiKey)
        }

        if !anthropicApiKey.isEmpty {
            KeychainHelper.save(key: Keys.anthropicKey, value: anthropicApiKey)
        } else {
            KeychainHelper.delete(key: Keys.anthropicKey)
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

    /// Whether Apple Intelligence is available on this device.
    static var isAppleIntelligenceAvailable: Bool {
        FoundationModelsAvailability.isAvailable
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let roninLLMSettingsChanged = Notification.Name("roninLLMSettingsChanged")
}
