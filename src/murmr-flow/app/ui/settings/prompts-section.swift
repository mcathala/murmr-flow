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
///
/// A style can also hold **a key of its own**, in the same row and for the same reason:
/// which jobs use this style, and how you reach it, are the same question. Holding that key
/// dictates in that style wherever you are, which is why it outranks a rule for the app in
/// front — pressing a key is the more deliberate act.
struct PromptsSection: View {

    let prompts: PromptStore

    /// Binds a key to a style, or clears it with nil, and answers with why it refused.
    /// A closure rather than a store, so this view never learns what a watcher is — and so
    /// a snapshot can render the rows with nothing to arm.
    var bindKey: ((Hotkey?, UUID) -> String?)?

    @State private var selected: UUID?

    /// Which row is listening for a key, if any. One at a time: two recorders would both
    /// swallow the same keypress.
    @State private var recordingKey: UUID?
    @State private var recorder = HotkeyRecorder()
    @State private var rejected: String?

    /// A `Group`, not a `VStack`: the rows become siblings in the enclosing `PaneScroll`,
    /// so they are spaced like every other card in the section instead of forming a
    /// tighter block of their own.
    var body: some View {
        Group {
            // Named, because By app below is — two lists in one tab, and only one of them
            // labelled, reads as a list with an afterthought stuck to it.
            SectionLabel(title: "Styles")

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
                Text("No style is set for Notetaker, so a meeting is saved as the "
                     + "transcript alone, with nothing written above it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ preset: PromptPreset) -> some View {
        let isOpen = selected == preset.id
        // Gold on the card's edge means "this is the one in use" — the palette's one rule
        // for an accent border, and the same thing it means on the provider rows. A style
        // no job uses is a row you can skip, and until the whole card said so the only
        // sign was one pill among four controls. Being *open* is not the same claim: the
        // editor unfolding underneath already says that, and spending the accent on it
        // meant the row you were reading looked like the row in use.
        return Card(highlighted: usedBy(preset) != nil) {
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
                    // Two jobs, because there are two. A meeting is one request now, so
                    // the Notetaker style *is* the one that writes the note — there is no
                    // longer a second style tidying turns for it to read, and no third
                    // chip to explain the difference between.
                    AssignmentToggle(
                        title: "Notetaker", symbol: "text.document",
                        isOn: prompts.notetakerPromptID == preset.id,
                        togglesOff: true,
                        help: (
                            on: "Stop writing a note above the transcript",
                            off: "Write the note above the transcript with this style"
                        )
                    ) {
                        prompts.notetakerPromptID =
                            prompts.notetakerPromptID == preset.id ? nil : preset.id
                    }

                    keySlot(preset)

                    Button(isOpen ? "Done" : "Edit") { toggle(preset) }
                        .controlSize(.small)
                }
                // The whole header opens the editor, not only the button: the row is the
                // thing you want to edit, and a 40-point target at its far end is not.
                // The toggles are buttons, so their taps never reach this gesture.
                .contentShape(Rectangle())
                .onTapGesture { toggle(preset) }

                if recordingKey == preset.id {
                    Text("Press a key\u{2026} Escape cancels. Modifiers can be combined — "
                         + "fn with \u{2325}, say.")
                        .font(Theme.Text.small)
                        .foregroundStyle(Theme.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let rejected, recordingKey == nil,
                          prompts.hotkey(for: preset.id) == nil {
                    Text(rejected)
                        .font(Theme.Text.small)
                        .foregroundStyle(Theme.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Only the open one shows its instructions — five prompts expanded at
                // once would be a wall, and you only ever edit one at a time. So a closed
                // row is a name and its assignments.
                if isOpen { editor(preset) }
            }
        }
        .onDisappear { stopRecording() }
    }

    private func toggle(_ preset: PromptPreset) {
        selected = selected == preset.id ? nil : preset.id
    }


    // MARK: - The style's own key

    /// Three states in one slot: listening, bound, or free. Kept narrow so the rows still
    /// line up as a table — the sentence explaining what to press goes under the row,
    /// where there is room for it.
    @ViewBuilder
    private func keySlot(_ preset: PromptPreset) -> some View {
        if recordingKey == preset.id {
            Button("Cancel") { stopRecording() }
                .controlSize(.small)
        } else if let key = prompts.hotkey(for: preset.id) {
            HStack(spacing: 5) {
                Button { record(preset) } label: { Keycap(text: key.displayName) }
                    .buttonStyle(.plain)
                    .help("Hold \(key.displayName) to dictate in \(preset.name) — click to change")
                Button {
                    rejected = nil
                    _ = bindKey?(nil, preset.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.faint)
                .help("Clear this key")
            }
        } else {
            Button("Add key") { record(preset) }
                .controlSize(.small)
                .help("Hold a key of your own to dictate in \(preset.name)")
        }
    }

    private func record(_ preset: PromptPreset) {
        rejected = nil
        recordingKey = preset.id
        recorder.onFinish = { captured in
            defer { recordingKey = nil }
            guard let captured else { return }  // Escape
            rejected = bindKey?(captured, preset.id)
        }
        recorder.start()
    }

    private func stopRecording() {
        recorder.stop()
        recordingKey = nil
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
                    // The store drops the style's key with it, but the *watcher* for that
                    // key is the app's, and it would go on starting dictations for a style
                    // that no longer exists. Clearing through the same door that binds is
                    // what takes it down.
                    _ = bindKey?(nil, preset.id)
                }
                .controlSize(.small)
                .foregroundStyle(Theme.Palette.danger)
                .disabled(!prompts.canDelete(preset) || usedBy(preset) != nil)
                .help(deleteHelp(preset))
            }
        }
    }

    /// Which jobs are using this prompt right now, named the way the sentence that says
    /// "pick another one first" needs them.
    private func usedBy(_ preset: PromptPreset) -> String? {
        var jobs: [String] = []
        if prompts.dictationPromptID == preset.id { jobs.append("Dictation") }
        if prompts.notetakerPromptID == preset.id { jobs.append("Notetaker") }
        guard !jobs.isEmpty else { return nil }
        if jobs.count == 1 { return jobs[0] }
        return jobs.dropLast().joined(separator: ", ") + " and " + jobs[jobs.count - 1]
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
/// up down the list and the eye can read it as a table: which prompt, which mode. Icons
/// alone were tried first, and a row of unlit circles beside one gold chip read as
/// clutter rather than as a control.
///
/// The lit one is **filled** gold with the ground's own navy on it, the way a ticked
/// checkbox is filled. Outlined gold on a gold word was the same weight as the row's other
/// controls, so which style a job used had to be looked for; filled, it is the one thing on
/// the row you cannot miss, which is what the column is scanned for.
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
                Text(title).font(.caption2.weight(isOn ? .semibold : .medium))
            }
            .frame(width: 84, height: 20)
            .foregroundStyle(isOn ? Theme.Palette.abyss : Theme.Palette.faint)
            .background(
                Capsule().fill(isOn ? Theme.Palette.gold : Color.white.opacity(0.04))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }
}
