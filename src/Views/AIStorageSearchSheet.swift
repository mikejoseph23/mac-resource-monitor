import SwiftUI

/// "Is my API key sitting in these logs?"
///
/// Answers with file paths and match counts and nothing else. The query is
/// itself the secret the user is worried about; rendering the matched line
/// would copy it onto yet another surface (and into a screenshot, and into a
/// window-server snapshot). The search field is a secure field for the same
/// reason.
struct AIStorageSearchSheet: View {
    @ObservedObject var model: AIStorageModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var isSearching = false
    @State private var outcome: AIStorageCollector.SearchOutcome?
    @State private var searchedSomething = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    SecureField("Text to search for…", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(run)
                    Button("Search", action: run)
                        .disabled(query.isEmpty || isSearching)
                    if isSearching {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    }
                }

                Text("Matches are reported as file paths and counts only — never the matched text. The oMLX prompt cache is binary tensors and is not text-searchable.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                results
            }
            .padding(16)

            Divider()

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 560)
    }

    private var header: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            Text("Search Retained Text")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var results: some View {
        if let outcome {
            if outcome.hits.isEmpty {
                Label("No matches in \(outcome.filesScanned) files.", systemImage: "checkmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(outcome.hits.count) file\(outcome.hits.count == 1 ? "" : "s") contain that text, out of \(outcome.filesScanned) scanned.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(outcome.hits) { hit in
                                HStack(spacing: 8) {
                                    Text(hit.displayPath)
                                        .font(.system(size: 10, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Text("\(hit.matchCount)×")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 240)

                    if outcome.truncated {
                        Text("Stopped early after the file limit — this list may be incomplete.")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }
            }
        } else if searchedSomething && !isSearching {
            Text("Search failed or was cancelled.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func run() {
        let text = query
        guard !text.isEmpty, !isSearching else { return }
        isSearching = true
        searchedSomething = true
        outcome = nil
        Task {
            outcome = await model.search(text)
            isSearching = false
        }
    }
}

#Preview {
    AIStorageSearchSheet(model: AIStorageModel(previewSnapshot: .preview))
}
