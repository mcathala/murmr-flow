import SwiftUI

/// The prompts, and which one each mode uses.
///
/// A group inside AI clean-up rather than a section of its own: a prompt is what the
/// provider is told to do, so it is unreadable apart from the provider that runs it. It
/// keeps its own file because it is 150 lines of editor, not because it is a separate
/// subject.
///
/// The assignment is shown *on the prompt* — one toggle per mode on every row — rather
/// than as two dropdowns elsewhere, so the whole arrangement reads in one look and
/// changes in one click.
struct PromptsSection: View {

    let prompts: PromptStore
    @State private var selected: UUID?

    /// A `Group`, not a `VStack`: the rows become siblings in the enclosing `PaneScroll`,
    /// so they are spaced like every other card in the section instead of forming a
    /// tighter block of their own.
    var body: some View {
        Group {
            ForEach(prompts.presets) { preset in
                row(preset)
            }

            Button {
                let created = prompts.addNew()
                selected = created.id
            } label: {
                Label("New prompt", systemImage: "plus")
            }
            .controlSize(.small)

            if prompts.notetakerPrompt == nil {
                Text("No prompt is assigned to Notetaker, so meetings are saved exactly "
                     + "as transcribed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ preset: PromptPreset) -> some View {
        let isOpen = selected == preset.id
        return Card(highlighted: isOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(preset.name).font(.callout.weight(.semibold))
                    Spacer(minLength: 0)

                    // Which mode uses this prompt, and the way to change it, in one control
                    // per mode on every row. The lit one reads as a badge; the others are a
                    // click away. Nothing turns a mode's prompt *off* here — clean-up has
                    // its own switch — so clicking the lit one does nothing.
                    AssignmentToggle(
                        title: "Dictation", symbol: "mic.fill",
                        isOn: prompts.dictationPromptID == preset.id
                    ) { prompts.dictationPromptID = preset.id }
                    AssignmentToggle(
                        title: "Notetaker", symbol: "text.document",
                        isOn: prompts.notetakerPromptID == preset.id
                    ) { prompts.notetakerPromptID = preset.id }

                    Button(isOpen ? "Done" : "Edit") { toggle(preset) }
                        .controlSize(.small)
                }
                // The whole header opens the editor, not only the button: the row is the
                // thing you want to edit, and a 40-point target at its far end is not.
                // The toggles are buttons, so their taps never reach this gesture.
                .contentShape(Rectangle())
                .onTapGesture { toggle(preset) }

                // Only the open one shows its instructions — five prompts expanded at
                // once would be a wall, and you only ever edit one at a time. So a closed
                // row is a name and its assignments.
                if isOpen { editor(preset) }
            }
        }
    }

    private func toggle(_ preset: PromptPreset) {
        selected = selected == preset.id ? nil : preset.id
    }

    private func editor(_ preset: PromptPreset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            TextEditor(text: nameBinding(preset))
                .font(.callout)
                .frame(height: 22)
                .scrollDisabled(true)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 6))

            // A fixed height that scrolls, not a box that grows with the text. The shipped
            // prompts run to seventy lines; grown to fit, one of them fills the window and
            // the list of prompts, the Reset button and the way out all leave the screen.
            // Sized to show a whole section at once, and set in the app's mono at reading
            // size rather than the system's at 11, which turned prose into a listing.
            TextEditor(text: templateBinding(preset))
                .font(Theme.Text.monoLarge)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(height: 340)
                .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 6))

            // The ways out of an edit you regret. Reset appears only once a built-in has
            // drifted from our wording; Delete is there for every prompt, ours included,
            // except the last one standing and the ones a mode is using — deleting those
            // would silently move that mode onto whichever prompt came first, so the
            // button says why it won't rather than doing that. Duplicate is gone — New
            // prompt starts from plain instructions, which is a better start than a copy.
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if let shipped = PromptStore.shipped(preset), shipped != preset {
                    Button("Reset") { prompts.reset(preset) }
                        .controlSize(.small)
                        .help("Put the wording we ship back")
                }
                Button("Delete") {
                    selected = nil
                    prompts.delete(preset)
                }
                .controlSize(.small)
                .foregroundStyle(Theme.Palette.danger)
                .disabled(!prompts.canDelete(preset) || usedBy(preset) != nil)
                .help(deleteHelp(preset))
            }
        }
    }

    /// Which mode, if any, is using this prompt right now.
    private func usedBy(_ preset: PromptPreset) -> String? {
        switch (prompts.dictationPromptID == preset.id, prompts.notetakerPromptID == preset.id) {
        case (true, true): "Dictation and Notetaker"
        case (true, false): "Dictation"
        case (false, true): "Notetaker"
        case (false, false): nil
        }
    }

    private func deleteHelp(_ preset: PromptPreset) -> String {
        if let mode = usedBy(preset) {
            return "\(mode) uses this style. Pick another one first."
        }
        if !prompts.canDelete(preset) { return "The last style can\u{2019}t be deleted." }
        return "Delete this style"
    }

    // MARK: - Bindings

    private func nameBinding(_ preset: PromptPreset) -> Binding<String> {
        Binding(
            get: { preset.name },
            set: { value in
                var updated = preset
                updated.name = value
                prompts.update(updated)
            }
        )
    }

    private func templateBinding(_ preset: PromptPreset) -> Binding<String> {
        Binding(
            get: { preset.template },
            set: { value in
                var updated = preset
                updated.template = value
                prompts.update(updated)
            }
        )
    }
}

struct Badge: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8))
            Text(text).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .overlay(Capsule().stroke(.tint, lineWidth: 1))
        .foregroundStyle(.tint)
    }
}

/// A mode's claim on a prompt: lit when this prompt is the one it uses.
///
/// Both modes are named on every row, at one width, so the two make a column that lines
/// up down the list and the eye can read it as a table: which prompt, which mode. The lit
/// one is the `Badge` — same capsule, same gold; the others are the same words, quiet.
/// Icons alone were tried first, and a row of unlit circles beside one gold chip read as
/// clutter rather than as a control.
struct AssignmentToggle: View {
    let title: String
    let symbol: String
    let isOn: Bool
    /// Whether clicking the lit pill does anything. On a style row it does not — a mode
    /// always has *some* prompt — but the pane's header row uses the same pill as an
    /// on/off switch, and there the lit click is the off.
    var togglesOff = false
    /// Tooltips for the two states, when "Used for" / "Use for" are the wrong verbs.
    var help: (on: String, off: String)?
    let action: () -> Void

    private var tooltip: String {
        if let help { return isOn ? help.on : help.off }
        return isOn ? "Used for \(title)" : "Use for \(title)"
    }

    var body: some View {
        Button(action: { if !isOn || togglesOff { action() } }) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 8))
                Text(title).font(.caption2.weight(.medium))
            }
            .frame(width: 84, height: 20)
            .foregroundStyle(isOn ? Theme.Palette.gold : Theme.Palette.faint)
            .background(
                Capsule().fill(isOn ? Theme.Palette.gold.opacity(0.10) : Color.white.opacity(0.04))
            )
            .overlay(
                Capsule().stroke(isOn ? Theme.Palette.gold : Color.clear, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }
}
