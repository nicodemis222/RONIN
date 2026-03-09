import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var copilotVM: LiveCopilotViewModel
    @EnvironmentObject var tutorialVM: TutorialViewModel

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .environmentObject(tutorialVM)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            LLMSettingsTab()
                .tabItem {
                    Label("LLM", systemImage: "brain")
                }

            OverlaySettingsTab()
                .environmentObject(copilotVM)
                .tabItem {
                    Label("Overlay", systemImage: "rectangle.on.rectangle")
                }

            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 520, height: 440)
        .preferredColorScheme(.dark)
    }
}

// MARK: - General Tab

struct GeneralSettingsTab: View {
    @EnvironmentObject var tutorialVM: TutorialViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("> GENERAL")
                .font(.matrixTitle)
                .foregroundColor(.matrixNeon)
                .matrixGlow(radius: 4)

            // Tutorial section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tutorial")
                            .font(.matrixHeadline)
                            .foregroundColor(.matrixBright)
                        Text("Re-launch the onboarding walkthrough")
                            .font(.matrixCaption)
                            .foregroundColor(.matrixDim)
                    }

                    Spacer()

                    Button("Show Tutorial") {
                        tutorialVM.relaunchTutorial()
                        // Close settings window so tutorial is visible
                        NSApplication.shared.keyWindow?.close()
                    }
                    .buttonStyle(MatrixSecondaryButtonStyle())
                }
            }
            .matrixGroupBox(title: "ONBOARDING")

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.matrixBlack)
    }
}

// MARK: - LLM Settings Tab

struct LLMSettingsTab: View {
    @StateObject private var vm = LLMSettingsViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("> LLM_PROVIDER")
                    .font(.matrixTitle)
                    .foregroundColor(.matrixNeon)
                    .matrixGlow(radius: 4)

                VStack(alignment: .leading, spacing: 12) {
                    // Provider picker — four options
                    Picker("Provider", selection: $vm.selectedProvider) {
                        ForEach(LLMSettingsViewModel.Provider.allCases) { provider in
                            HStack {
                                Text(provider.displayName)
                                if provider.isAppleIntelligence && !LLMSettingsViewModel.isAppleIntelligenceAvailable {
                                    Text("(unavailable)")
                                        .foregroundColor(.matrixFaded)
                                }
                            }
                            .tag(provider)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .foregroundColor(.matrixText)

                    // Privacy/status notes
                    if let cloudWarning = vm.selectedProvider.cloudWarning {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.matrixWarning)
                            Text(cloudWarning)
                                .font(.matrixCaption)
                                .foregroundColor(.matrixWarning)
                        }
                        .padding(8)
                        .background(Color.matrixWarning.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.matrixWarning.opacity(0.3), lineWidth: 1)
                        )
                    }

                    if vm.selectedProvider.isAppleIntelligence {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: LLMSettingsViewModel.isAppleIntelligenceAvailable
                                  ? "checkmark.shield.fill" : "xmark.shield.fill")
                                .foregroundColor(LLMSettingsViewModel.isAppleIntelligenceAvailable
                                                 ? .matrixNeon : .matrixStatusError)
                            Text(LLMSettingsViewModel.isAppleIntelligenceAvailable
                                 ? "Everything stays on your Mac. No API key required."
                                 : "Apple Intelligence requires macOS 26 and a supported Mac.")
                                .font(.matrixCaption)
                                .foregroundColor(LLMSettingsViewModel.isAppleIntelligenceAvailable
                                                 ? .matrixNeon : .matrixStatusError)
                        }
                        .padding(8)
                        .background((LLMSettingsViewModel.isAppleIntelligenceAvailable
                                     ? Color.matrixNeon : Color.matrixStatusError).opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke((LLMSettingsViewModel.isAppleIntelligenceAvailable
                                         ? Color.matrixNeon : Color.matrixStatusError).opacity(0.3), lineWidth: 1)
                        )
                    }

                    Divider().overlay(Color.matrixDivider)

                    // Provider-specific settings
                    switch vm.selectedProvider {
                    case .local:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Server URL")
                                .font(.matrixCaption)
                                .foregroundColor(.matrixDim)
                            TextField("http://localhost:1234/v1", text: $vm.localURL)
                                .textFieldStyle(MatrixTextFieldStyle())
                            Text("Requires LM Studio running with a loaded model")
                                .font(.matrixCaption)
                                .foregroundColor(.matrixFaded)
                        }

                    case .openai:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("API Key")
                                .font(.matrixCaption)
                                .foregroundColor(.matrixDim)
                            SecureField("sk-...", text: $vm.openaiApiKey)
                                .textFieldStyle(MatrixTextFieldStyle())
                            Text("Model (optional)")
                                .font(.matrixCaption)
                                .foregroundColor(.matrixDim)
                            TextField("gpt-4o-mini", text: $vm.llmModel)
                                .textFieldStyle(MatrixTextFieldStyle())
                            Text("Default: gpt-4o-mini")
                                .font(.matrixCaption)
                                .foregroundColor(.matrixFaded)
                        }

                    case .anthropic:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("API Key")
                                .font(.matrixCaption)
                                .foregroundColor(.matrixDim)
                            SecureField("sk-ant-...", text: $vm.anthropicApiKey)
                                .textFieldStyle(MatrixTextFieldStyle())
                            Text("Model (optional)")
                                .font(.matrixCaption)
                                .foregroundColor(.matrixDim)
                            TextField("claude-sonnet-4-20250514", text: $vm.llmModel)
                                .textFieldStyle(MatrixTextFieldStyle())
                            Text("Default: claude-sonnet-4-20250514")
                                .font(.matrixCaption)
                                .foregroundColor(.matrixFaded)
                        }

                    case .appleIntelligence:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No configuration needed. Apple Intelligence runs entirely on-device.")
                                .font(.matrixCaption)
                                .foregroundColor(.matrixDim)
                        }
                    }
                }
                .matrixGroupBox(title: "CONFIGURATION")

                HStack {
                    Spacer()
                    Button("Save & Restart Backend") {
                        vm.save()
                    }
                    .buttonStyle(MatrixPrimaryButtonStyle())
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.matrixBlack)
    }
}

// MARK: - Overlay Tab

struct OverlaySettingsTab: View {
    @EnvironmentObject var copilotVM: LiveCopilotViewModel

    @State private var opacityValue: Double = 0.95

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("> OVERLAY")
                .font(.matrixTitle)
                .foregroundColor(.matrixNeon)
                .matrixGlow(radius: 4)

            VStack(alignment: .leading, spacing: 16) {
                // Default compact mode
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Start in compact mode")
                            .font(.matrixBody)
                            .foregroundColor(.matrixText)
                        Text("Overlay launches in compact view by default")
                            .font(.matrixCaption)
                            .foregroundColor(.matrixDim)
                    }

                    Spacer()

                    Toggle("", isOn: $copilotVM.isCompact)
                        .toggleStyle(.switch)
                        .tint(.matrixNeon)
                }

                Divider().overlay(Color.matrixDivider)

                // Layout orientation
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Panel layout")
                            .font(.matrixBody)
                            .foregroundColor(.matrixText)
                        Text("Auto adapts to window shape")
                            .font(.matrixCaption)
                            .foregroundColor(.matrixDim)
                    }

                    Spacer()

                    Picker("", selection: $copilotVM.layoutOrientation) {
                        ForEach(LiveCopilotViewModel.LayoutOrientation.allCases) { orientation in
                            Text(orientation.label).tag(orientation)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }

                Divider().overlay(Color.matrixDivider)

                // Overlay opacity
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Default opacity")
                            .font(.matrixBody)
                            .foregroundColor(.matrixText)
                        Spacer()
                        Text("\(Int(opacityValue * 100))%")
                            .font(.matrixBody)
                            .foregroundColor(.matrixBright)
                            .matrixGlow(radius: 2)
                    }

                    Slider(value: $opacityValue, in: 0.3...1.0, step: 0.05)
                        .tint(.matrixNeon)
                        .onChange(of: opacityValue) { _, newValue in
                            copilotVM.overlayOpacity = newValue
                        }
                }
            }
            .matrixGroupBox(title: "OVERLAY_DEFAULTS")

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.matrixBlack)
        .onAppear {
            opacityValue = copilotVM.overlayOpacity
        }
    }
}

// MARK: - About Tab

struct AboutTab: View {
    private var provider: LLMSettingsViewModel.Provider {
        LLMSettingsViewModel.currentProvider
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.matrixNeon)
                .matrixGlow(radius: 16)

            Text("RONIN")
                .font(.matrixLargeTitle)
                .foregroundColor(.matrixNeon)
                .matrixGlow(radius: 8)

            Text("Local-first meeting copilot")
                .font(.matrixBody)
                .foregroundColor(.matrixDim)

            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                .font(.matrixCaption)
                .foregroundColor(.matrixFaded)

            Spacer()

            Group {
                switch provider {
                case .openai:
                    Text("Audio stays on your Mac. Transcript sent to OpenAI for analysis.")
                case .anthropic:
                    Text("Audio stays on your Mac. Transcript sent to Anthropic for analysis.")
                case .local, .appleIntelligence:
                    Text("Everything stays on your Mac.")
                }
            }
            .font(.matrixCaption)
            .foregroundColor(.matrixFaded)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.matrixBlack)
    }
}
