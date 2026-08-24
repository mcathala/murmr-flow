import SwiftUI

/// The prompts, and which one each mode uses.
///
/// The assignment is shown as a badge *on the prompt* rather than as two dropdowns
/// elsewhere, so the whole arrangement reads in one look.
struct PromptsPane: View {

    let prompts: PromptStore
    @State private var selected: UUID?

    var body: some View {
        PaneScroll(title: "Prompts") {
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

            if prompts.notePrompt == nil {
                Text("No prompt is assigned to Note mode, so meetings are saved exactly "
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
                    if prompts.dictationPromptID == preset.id {
                        Badge(text: "Dictaphone", symbol: "mic.fill")
                    }
                    if prompts.notePromptID == preset.id {
                        Badge(text: "Note mode", symbol: "text.document")
                    }
                    Spacer(minLength: 0)
                    Button(isOpen ? "Close" : "Edit") {
                        selected = isOpen ? nil : preset.id
                    }
                    .controlSize(.small)
                }

                // Only the open one shows its instructions — five prompts expanded at
                // once would be a wall, and you only ever edit one at a time. So a closed
                // row is a name and its badges. It used to carry a one-line description
                // as well, which meant three fields to fill in to write a prompt and a
                // second place claiming what it did; the prompt itself says that, in more
                // detail and without going stale.
                if isOpen { editor(preset) }
            }
        }
    }

    private func editor(_ preset: PromptPreset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            TextEditor(text: nameBinding(preset))
                .font(.callout)
                .frame(height: 22)
                .scrollDisabled(true)
                .padding(.horizontal, 4)
                .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 6))

            TextEditor(text: templateBinding(preset))
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 150)
                .padding(.horizontal, 4)
                .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 6))

            HStack(spacing: 8) {
                Button("Use for Dictaphone") { prompts.dictationPromptID = preset.id }
                    .controlSize(.small)
                    .disabled(prompts.dictationPromptID == preset.id)

                Button("Use for Note mode") { prompts.notePromptID = preset.id }
                    .controlSize(.small)
                    .disabled(prompts.notePromptID == preset.id)

                Spacer(minLength: 0)

                Button("Duplicate") {
                    let copy = prompts.duplicate(preset)
                    selected = copy.id
                }
                .controlSize(.small)

                if preset.isBuiltIn {
                    Button("Reset") { prompts.reset(preset) }
                        .controlSize(.small)
                } else {
                    Button("Delete") {
                        selected = nil
                        prompts.delete(preset)
                    }
                    .controlSize(.small)
                }
            }
        }
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
