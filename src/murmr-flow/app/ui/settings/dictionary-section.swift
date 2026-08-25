import SwiftUI

/// The dictionary: one list for spelling corrections and snippets alike.
///
/// They were going to be two features — a chip field for words, a separate screen for
/// longer text — and they are the same thing at different lengths. `Cavalley → Kovalee` and
/// `"my email address" → mc@kovalee.app` are one rule written twice, so they are one list
/// with one card.
///
/// The card is the app's established shape for a list you own: closed is a name and its
/// badges, open is the editor, one at a time. Five entries expanded at once would be a
/// wall, and you only ever edit one.
///
/// The **only** thing a reader has to understand is that an entry with a trigger is exact
/// and local while an entry without one is a hint for the model — so that is what the card
/// shows, and the warning at the top is the one place it is spelled out, and only when
/// clean-up being off has actually made the hints inert.
struct DictionarySection: View {

    let dictionary: DictionaryStore
    /// Hints go into the clean-up prompt, so with clean-up off they do nothing. Exact
    /// replacements are unaffected, which is the whole reason this tab is not hidden with
    /// the rest of the section.
    let cleanupIsOn: Bool

    @State private var open: UUID?

    private var hintCount: Int {
        dictionary.entries.filter { !$0.isReplacement && $0.isUsable }.count
    }

    var body: some View {
        Group {
            if !cleanupIsOn, hintCount > 0 {
                WarningRow(
                    message: "\(hintCount == 1 ? "One entry has" : "\(hintCount) entries have") "
                        + "nothing in \u{201C}When I say\u{201D}, so they are hints for the "
                        + "clean-up — which is off. Give them a trigger and they work "
                        + "either way."
                )
            }

            ForEach(dictionary.entries) { entry in
                card(entry)
            }

            Button {
                open = dictionary.add().id
            } label: {
                Label("New entry", systemImage: "plus")
            }
            .controlSize(.small)

            if dictionary.entries.isEmpty {
                Text("Say \u{201C}my email address\u{201D} and have your address typed, or "
                     + "add a name the speech model keeps getting wrong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - One entry

    private func card(_ entry: DictionaryEntry) -> some View {
        let isOpen = open == entry.id
        return Card(highlighted: isOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if entry.isReplacement {
                        Text("\u{201C}\(entry.trigger)\u{201D}")
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.Palette.faint)
                        Text(oneLine(entry.replacement))
                            .font(.callout)
                            .foregroundStyle(Theme.Palette.muted)
                            .lineLimit(1)
                    } else {
                        Text(entry.replacement.isEmpty ? "Empty entry" : entry.replacement)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text("spelling hint")
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.faint)
                    }

                    Spacer(minLength: 0)

                    Badge(text: entry.scope.label, symbol: symbol(entry.scope))

                    Button(isOpen ? "Close" : "Edit") {
                        open = isOpen ? nil : entry.id
                    }
                    .controlSize(.small)
                }

                if isOpen { editor(entry) }
            }
        }
    }

    private func editor(_ entry: DictionaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            LabeledContent("When I say") {
                TextField(
                    "Leave empty for a spelling hint",
                    text: binding(entry, \.trigger)
                )
                .textFieldStyle(.roundedBorder)
            }
            .font(.caption)

            LabeledContent("Write") {
                // A `TextEditor` rather than a field, because this is where a snippet
                // lives — an address is one line and an intro email is twenty.
                TextEditor(text: binding(entry, \.replacement))
                    .font(.callout)
                    .frame(minHeight: 54)
                    .scrollDisabled(true)
                    .padding(.horizontal, 4)
                    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 6))
            }
            .font(.caption)

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
