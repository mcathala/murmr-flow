import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Which style each app gets, and the apps that get none at all.
///
/// The one setting here that is not a style is **Off**, and it is the reason the section
/// exists at all: in a terminal, clean-up "fixes" the punctuation of a command you have
/// just spoken, and in a password field nothing should leave the machine. Those are not
/// tastes, they are places the feature does harm — so turning it off for one app has to be
/// as reachable as choosing a style for another.
///
/// Rules are stored against the bundle id, so the row survives an app being renamed or
/// moved; the name is kept beside it only for drawing the row.
struct AppStylesSection: View {

    let prompts: PromptStore

    var body: some View {
        Group {
            SectionLabel(title: "By app")

            if prompts.appRules.isEmpty {
                Text("Every app uses \(prompts.dictationPrompt.name). Add one to give it a "
                     + "style of its own, or to type into it exactly as heard.")
                    .font(Theme.Text.small)
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(prompts.appRules) { rule in
                row(rule)
            }

            addButton
        }
    }

    // MARK: - One rule

    private func row(_ rule: AppStyleRule) -> some View {
        Card {
            HStack(spacing: 10) {
                icon(for: rule.bundleID)
                Text(rule.appName).font(Theme.Text.bodyStrong)

                Spacer(minLength: 8)

                Menu {
                    // A Picker, so the system draws the checkmark beside the one in use.
                    Picker("Style", selection: outcome(for: rule)) {
                        ForEach(prompts.presets) { preset in
                            Text(preset.name).tag(AppStyleRule.Outcome.style(preset.id))
                        }
                        Divider()
                        Text("Off — type it as heard").tag(AppStyleRule.Outcome.off)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(label(for: rule.outcome)).lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(
                    rule.outcome == .off ? Theme.Palette.muted : Theme.Palette.gold
                )

                Button {
                    prompts.removeRule(bundleID: rule.bundleID)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.faint)
                .help("Remove this rule — \(rule.appName) goes back to the standing style")
            }
        }
    }

    private func label(for outcome: AppStyleRule.Outcome) -> String {
        switch outcome {
        case .off: "Off"
        case .style(let id): prompts.preset(id: id)?.name ?? prompts.dictationPrompt.name
        }
    }

    private func outcome(for rule: AppStyleRule) -> Binding<AppStyleRule.Outcome> {
        Binding(
            get: { rule.outcome },
            set: { new in
                var updated = rule
                updated.outcome = new
                prompts.setRule(updated)
            }
        )
    }

    /// The app's own icon, so the list is scanned rather than read. An app that has since
    /// been uninstalled keeps its row and shows a placeholder — the rule is still the
    /// person's, and silently dropping it would be worse than a grey square.
    private func icon(for bundleID: String) -> some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
            } else {
                Image(systemName: "questionmark.app.dashed")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Theme.Palette.faint)
            }
        }
        .frame(width: 20, height: 20)
    }

    // MARK: - Adding one

    /// Running apps first, because the app you want a rule for is usually the one you just
    /// came from. Anything else is one more click through the open panel rather than a
    /// second list nobody would scroll.
    private var addButton: some View {
        Menu {
            ForEach(runningApps, id: \.bundleID) { app in
                Button(app.name) { add(bundleID: app.bundleID, name: app.name) }
            }
            if !runningApps.isEmpty { Divider() }
            Button("Other\u{2026}") { chooseApp() }
        } label: {
            Label("Add an app", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
    }

    private var runningApps: [(bundleID: String, name: String)] {
        let ruled = Set(prompts.appRules.map(\.bundleID))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (bundleID: String, name: String)? in
                guard let id = app.bundleIdentifier, let name = app.localizedName,
                      id != Bundle.main.bundleIdentifier, !ruled.contains(id)
                else { return nil }
                return (bundleID: id, name: name)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.message = "Pick an app to give its own style."
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier
        else { return }
        add(bundleID: id, name: FileManager.default.displayName(atPath: url.path))
    }

    /// A new rule starts on the standing style rather than on Off. Adding a row should
    /// change nothing until the person says what it is for; starting on Off would silently
    /// stop clean-up in an app they had only meant to list.
    private func add(bundleID: String, name: String) {
        prompts.setRule(
            AppStyleRule(
                bundleID: bundleID, appName: name,
                outcome: .style(prompts.dictationPromptID)
            )
        )
    }
}
