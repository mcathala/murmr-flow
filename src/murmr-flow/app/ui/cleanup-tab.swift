import SwiftUI

/// AI cleanup settings: provider, key, model and prompt.
///
/// The base URL is editable even for Groq. It costs nothing, helps anyone proxying
/// requests, and keeps the provider abstraction honest — if the field only worked for
/// "Custom", the abstraction would have quietly leaked.
struct CleanupTab: View {

    @Bindable var coordinator: DictationCoordinator

    @State private var apiKeyDraft = ""
    @State private var keySaved = false
    @State private var testResult: String?
    @State private var testing = false
    @State private var showPrompt = false

    private var settings: SettingsStore { coordinator.settings }

    var body: some View {
        TabScroll {
            header
            if settings.cleanupEnabled {
                providerPicker
                apiKeyField
                baseURLField
                modelField
                testRow
                Divider()
                promptEditor
            } else {
                Text("Dictation will type the raw transcript, unpunctuated.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { keySaved = settings.hasAPIKey }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            SectionLabel(title: "AI cleanup", icon: "sparkles")
            Spacer()
            Toggle("", isOn: Binding(
                get: { settings.cleanupEnabled },
                set: { settings.cleanupEnabled = $0 }
            ))
            .labelsHidden()
            .controlSize(.mini)
        }
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: Binding(
                get: { settings.providerID },
                set: {
                    settings.providerID = $0
                    keySaved = settings.hasAPIKey
                    apiKeyDraft = ""
                    testResult = nil
                }
            )) {
                ForEach(ProviderCatalog.all) { entry in
                    Text(entry.displayName).tag(entry.id)
                }
            }
            .labelsHidden()

            Text("Only text is sent — never audio.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SecureField(keySaved ? "Saved in Keychain" : "API key", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)

                Button("Save") {
                    try? settings.saveAPIKey(apiKeyDraft)
                    apiKeyDraft = ""
                    keySaved = settings.hasAPIKey
                    testResult = nil
                }
                .controlSize(.small)
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)

                if keySaved {
                    Button("Clear") {
                        try? settings.deleteAPIKey()
                        keySaved = false
                        testResult = nil
                    }
                    .controlSize(.small)
                }
            }

            HStack(spacing: 4) {
                Image(systemName: keySaved ? "lock.fill" : "lock.open")
                    .foregroundStyle(keySaved ? .green : .secondary)
                Text(keySaved
                     ? "Stored in your macOS Keychain."
                     : "Needed for cleanup. Stored in the Keychain, never in a file.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let url = settings.providerEntry.keyURL, !keySaved {
                    Link("Get one", destination: URL(string: url)!)
                        .font(.caption2)
                }
            }
        }
    }

    private var baseURLField: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Base URL").font(.caption2).foregroundStyle(.secondary)
            TextField("https://…", text: Binding(
                get: { settings.baseURL },
                set: { settings.baseURL = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(.caption, design: .monospaced))
        }
    }

    private var modelField: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Model").font(.caption2).foregroundStyle(.secondary)
            TextField("model id", text: Binding(
                get: { settings.model },
                set: { settings.model = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(.caption, design: .monospaced))

            // Free text, not a dropdown: provider model names change monthly and a
            // hardcoded list goes stale within weeks. Suggestions only.
            if !settings.providerEntry.suggestedModels.isEmpty {
                HStack(spacing: 6) {
                    ForEach(settings.providerEntry.suggestedModels, id: \.self) { suggestion in
                        Button(suggestion) { settings.model = suggestion }
                            .buttonStyle(.link)
                            .font(.caption2)
                    }
                }
            }
        }
    }

    private var testRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button("Test connection") {
                    testing = true
                    Task {
                        testResult = await coordinator.testCleanupProvider()
                        testing = false
                    }
                }
                .controlSize(.small)
                .disabled(testing || !keySaved)

                if testing { ProgressView().controlSize(.small) }
            }

            if let testResult {
                Text(testResult)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var promptEditor: some View {
        DisclosureGroup("Cleanup prompt", isExpanded: $showPrompt) {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: Binding(
                    get: { settings.promptTemplate },
                    set: { settings.promptTemplate = $0 }
                ))
                .font(.system(.caption2, design: .monospaced))
                .frame(height: 140)
                .overlay {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(.separator)
                }

                Text(PromptLibrary.placeholders.joined(separator: "  "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button("Reset to default") { settings.resetPrompt() }
                    .controlSize(.small)
            }
            .padding(.top, 4)
        }
        .font(.caption2)
    }
}
