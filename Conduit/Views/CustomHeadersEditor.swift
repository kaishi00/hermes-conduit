import SwiftUI

/// Editor for the extra proxy headers saved for one server (issue #305).
/// Shared by the login card and Gateway settings; the caller persists.
struct CustomHeadersEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let serverURL: String
    let onSave: ([CustomHeader]) -> Void
    @State private var rows: [CustomHeader]
    @State private var revealedValues: Set<UUID> = []

    init(serverURL: String, headers: [CustomHeader], onSave: @escaping ([CustomHeader]) -> Void) {
        self.serverURL = serverURL
        self.onSave = onSave
        _rows = State(initialValue: headers)
    }

    private var origin: String? { CustomHeaderPolicy.origin(forServerURL: serverURL) }

    /// Rows left completely blank are dropped on save, so they never block it.
    private func issue(for row: CustomHeader) -> CustomHeaderIssue? {
        if row.trimmedName.isEmpty && row.value.isEmpty { return nil }
        return CustomHeaderPolicy.issue(for: row)
    }

    private var duplicateNames: Set<String> {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for row in rows where !row.trimmedName.isEmpty {
            let key = row.trimmedName.lowercased()
            if !seen.insert(key).inserted { duplicates.insert(key) }
        }
        return duplicates
    }

    /// The row's problem in words, shown under it and read by VoiceOver on
    /// the name field so the error isn't conveyed by colour alone.
    private func problem(for row: CustomHeader) -> String? {
        if let issue = issue(for: row) { return issue.message }
        if duplicateNames.contains(row.trimmedName.lowercased()) {
            return AppLocalization.string("This header is already in the list.")
        }
        return nil
    }

    /// 1-based row number, so VoiceOver can tell rows apart.
    private func position(of row: CustomHeader) -> Int {
        (rows.firstIndex { $0.id == row.id } ?? 0) + 1
    }

    private var canSave: Bool {
        origin != nil
            && rows.allSatisfy { issue(for: $0) == nil }
            && duplicateNames.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(AppLocalization.string("Sent with every request to this server, for reverse proxies such as Pangolin, Traefik, or nginx that check a header. Values stay in Keychain."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let origin {
                        Text(verbatim: origin)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(AppLocalization.string("Extra headers are only sent over HTTPS. Enter an https:// server address first."))
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                ForEach($rows) { $row in
                    Section {
                        TextField(AppLocalization.string("Header name"), text: $row.name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("extra-headers.name")
                            .accessibilityLabel(AppLocalization.string("Header \(String(position(of: row))) name"))
                            .accessibilityHint(problem(for: row) ?? "")
                        HStack {
                            Group {
                                if revealedValues.contains(row.id) {
                                    TextField(AppLocalization.string("Value"), text: $row.value)
                                } else {
                                    SecureField(AppLocalization.string("Value"), text: $row.value)
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("extra-headers.value")
                            .accessibilityLabel(AppLocalization.string("Header \(String(position(of: row))) value"))
                            Button {
                                if revealedValues.contains(row.id) {
                                    revealedValues.remove(row.id)
                                } else {
                                    revealedValues.insert(row.id)
                                }
                            } label: {
                                Image(systemName: revealedValues.contains(row.id) ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(revealedValues.contains(row.id)
                                ? AppLocalization.string("Hide value")
                                : AppLocalization.string("Show value"))
                        }
                        if let problem = problem(for: row) {
                            Text(problem)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        Button(role: .destructive) {
                            rows.removeAll { $0.id == row.id }
                        } label: {
                            Label(AppLocalization.string("Remove header"), systemImage: "trash")
                        }
                        .accessibilityLabel(AppLocalization.string("Remove header \(String(position(of: row)))"))
                    }
                }
                Section {
                    Button {
                        rows.append(CustomHeader(name: "", value: ""))
                    } label: {
                        Label(AppLocalization.string("Add header"), systemImage: "plus")
                    }
                    .accessibilityIdentifier("extra-headers.add")
                }
            }
            .navigationTitle(AppLocalization.string("Extra headers"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("Save")) {
                        onSave(rows)
                        dismiss()
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("extra-headers.save")
                }
            }
        }
    }
}
