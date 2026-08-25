import SwiftUI

/// The dictionary: one list for spelling corrections and snippets alike.
///
/// They were going to be two features — a chip field for words, a separate screen for
/// longer text — and they are the same thing at different lengths. `Cavalley → Kovalee` and
/// `"my email address" → name@example.com` are one rule written twice, so they are one list
/// with one card.
///
/// The card is the app's established shape for a list you own: closed is a name and its
/// badges, open is the editor, one at a time. Five entries expanded at once would be a
/// wall, and you only ever edit one.
///
/// **The kind is chosen, not inferred.** The first version showed both fields always and put
/// *"Leave empty for a spelling hint"* in the trigger's placeholder — an instruction
/// pretending to be an example, asking the user to express a choice by leaving a box blank,
/// in words only this codebase uses. Now the two kinds are a control, each shows only the
/// fields it needs, and every placeholder is an example of what to type.
struct DictionarySection: View {

    let dictionary: DictionaryStore
    /// A spelling fix goes into the clean-up prompt, so with clean-up off it does nothing. A
    /// swap is unaffected, which is the whole reason this tab is not hidden with the rest of
    /// the section.
    let cleanupIsOn: Bool

    @State private var open: UUID?

    /// `openEntry` exists so a snapshot can draw the editor. Nothing else passes it — a
    /// section rendered by `ImageRenderer` cannot be clicked, and the editor is the part of
    /// this view most worth looking at.
    init(dictionary: DictionaryStore, cleanupIsOn: Bool, openEntry: UUID? = nil) {
        self.dictionary = dictionary
        self.cleanupIsOn = cleanupIsOn
        self._open = State(initialValue: openEntry)
    }

    private var spellingCount: Int {
        dictionary.entries.filter { $0.kind == .spelling && $0.isUsable }.count
    }

    var body: some View {
        Group {
            if !cleanupIsOn, spellingCount > 0 {
                WarningRow(
                    message: spellingCount == 1
                        ? "One entry is a spelling fix, which the clean-up applies — and "
                            + "clean-up is off. Swaps still work."
                        : "\(spellingCount) entries are spelling fixes, which the clean-up "
                            + "applies — and clean-up is off. Swaps still work."
                )
            }

            ForEach(dictionary.entries) { entry in
                card(entry)
            }

            Button {
                close()
                open = dictionary.add().id
            } label: {
                Label("New entry", systemImage: "plus")
            }
            .controlSize(.small)

            if dictionary.entries.isEmpty {
                Text("Say \u{201C}my email address\u{201D} and have your address typed, or "
                     + "fix a name the speech model keeps getting wrong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Switching tab or leaving the section closes the editor without anyone pressing
        // Done, and would otherwise be the one way to strand a blank entry.
        .onDisappear { close() }
    }

    /// Shuts whichever editor is open, and takes the entry with it if nothing was typed.
    private func close() {
        if let open { dictionary.discardIfBlank(open) }
        open = nil
    }

    // MARK: - One entry

    private func card(_ entry: DictionaryEntry) -> some View {
        let isOpen = open == entry.id
        return Card(highlighted: isOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    header(entry)

                    Spacer(minLength: 0)

                    Badge(text: entry.scope.label, symbol: symbol(entry.scope))

                    Button(isOpen ? "Done" : "Edit") {
                        close()
                        if !isOpen { open = entry.id }
                    }
                    .controlSize(.small)
                }

                if isOpen { editor(entry) }
            }
        }
    }

    /// A closed card says what the entry does, and an entry with nothing in it yet says only
    /// that it is new — the version that read "Empty entry · spelling hint" managed to be
    /// both accusatory and wrong.
    @ViewBuilder
    private func header(_ entry: DictionaryEntry) -> some View {
        switch entry.kind {
        case .swap:
            if entry.trigger.isEmpty, entry.replacement.isEmpty {
                Text("New entry").font(.callout.weight(.semibold))
            } else {
                Text("\u{201C}\(entry.trigger.isEmpty ? "…" : entry.trigger)\u{201D}")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Palette.faint)
                Text(oneLine(entry.replacement))
                    .font(.callout)
                    .foregroundStyle(Theme.Palette.muted)
                    .lineLimit(1)
            }
        case .spelling:
            Text(entry.replacement.isEmpty ? "New entry" : entry.replacement)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            if !entry.replacement.isEmpty {
                Text("spelling")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.faint)
            }
        }
    }

    private func editor(_ entry: DictionaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            // First, because it decides which fields are below it. Switching keeps whatever
            // has been typed, so changing your mind twice costs nothing.
            PaneTabs(
                tabs: DictionaryEntry.Kind.allCases,
                title: \.label,
                selection: kindBinding(entry),
                alignment: .leading
            )

            switch current(entry).kind {
            case .swap:
                LabeledContent("When I say") {
                    TextField("my email address", text: binding(entry, \.trigger))
                        .textFieldStyle(.roundedBorder)
                }
                .font(.caption)

                LabeledContent("Write") {
                    replacement(entry, placeholder: "name@example.com")
                }
                .font(.caption)

            case .spelling:
                LabeledContent("Word") {
                    // The app's own name, because it is the example: a speech model hears
                    // "murmur flow" and writes it that way every time.
                    TextField("Murmr Flow", text: binding(entry, \.replacement))
                        .textFieldStyle(.roundedBorder)
                }
                .font(.caption)
            }

            HStack(spacing: 10) {
                Text("Used in")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.muted)

                PaneTabs(
                    tabs: DictionaryEntry.Scope.allCases,
                    title: \.label,
                    selection: scopeBinding(entry),
                    alignment: .leading
                )

                Spacer(minLength: 0)

                Button("Delete") {
                    open = nil
                    dictionary.remove(entry)
                }
                .controlSize(.small)
            }
        }
    }

    /// A `TextEditor` rather than a field, because this is where a snippet lives — an
    /// address is one line and an intro email is twenty. It has no placeholder of its own,
    /// hence the overlay.
    private func replacement(_ entry: DictionaryEntry, placeholder: String) -> some View {
        TextEditor(text: binding(entry, \.replacement))
            .font(.callout)
            .frame(minHeight: 54)
            .scrollDisabled(true)
            .padding(.horizontal, 4)
            .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 6))
            .overlay(alignment: .topLeading) {
                if current(entry).replacement.isEmpty {
                    Text(placeholder)
                        .font(.callout)
                        .foregroundStyle(Theme.Palette.faint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
    }

    /// The same two glyphs the prompt badges use, so "Dictation" means the same thing in
    /// both tabs. Both gets an asterisk rather than a third picture of something.
    private func symbol(_ scope: DictionaryEntry.Scope) -> String {
        switch scope {
        case .dictation: "mic.fill"
        case .notetaker: "text.document"
        case .both: "asterisk"
        }
    }

    /// Snippets run to paragraphs, and a card is one line — so the closed row shows the
    /// first line and says nothing about the rest.
    private func oneLine(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? "nothing yet" : flattened
    }

    // MARK: - Bindings

    /// Writes through the store, which persists on every change — the same way the prompt
    /// editor works, so there is no save button to forget.
    private func binding(
        _ entry: DictionaryEntry, _ field: WritableKeyPath<DictionaryEntry, String>
    ) -> Binding<String> {
        Binding(
            get: { current(entry)[keyPath: field] },
            set: { value in
                var updated = current(entry)
                updated[keyPath: field] = value
                dictionary.update(updated)
            }
        )
    }

    private func kindBinding(_ entry: DictionaryEntry) -> Binding<DictionaryEntry.Kind> {
        Binding(
            get: { current(entry).kind },
            set: { value in
                var updated = current(entry)
                updated.kind = value
                dictionary.update(updated)
            }
        )
    }

    private func scopeBinding(_ entry: DictionaryEntry) -> Binding<DictionaryEntry.Scope> {
        Binding(
            get: { current(entry).scope },
            set: { value in
                var updated = current(entry)
                updated.scope = value
                dictionary.update(updated)
            }
        )
    }

    /// The stored copy, not the one captured when the row was drawn — otherwise every
    /// keystroke would be applied to the state the view started with.
    private func current(_ entry: DictionaryEntry) -> DictionaryEntry {
        dictionary.entries.first { $0.id == entry.id } ?? entry
    }
}
