import SwiftUI

/// Dedicated worker-log screen (Kanban V2 §18).
///
/// - Loads once on appearance and otherwise refreshes EXPLICITLY — no
///   background polling while hidden, and nothing polls at all unless this
///   screen is on screen.
/// - Requests the backend's tail window (`?tail=` bytes, upstream caps at
///   2 MiB) so enormous logs never reach the phone whole.
/// - Renders a capped, selectable monospaced tail with the newest output at
///   the bottom; the full-size/truncation facts stay visible.
struct KanbanWorkerLogScreen: View {
    @EnvironmentObject private var store: KanbanStore
    @Environment(\.dismiss) private var dismiss

    let taskID: String

    /// Tail window requested from the backend. 64 KiB matches the drawer's
    /// "plenty for the drawer" sizing while staying far below the backend's
    /// 2 MiB ceiling.
    static let tailBytes = 65_536
    /// Render cap: SwiftUI Text chokes on megabyte strings; past this we keep
    /// the newest slice and say so.
    static let maxRenderedCharacters = 60_000

    @State private var log: KanbanWorkerLog?
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// Set when a REFRESH failed while a log is already cached: the cached
    /// content stays on screen with a small banner; the full "unavailable"
    /// state is reserved for initial loads with nothing cached.
    @State private var refreshErrorMessage: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch KanbanWorkerLogPresentation.resolve(
                        log: log,
                        loadError: errorMessage,
                        refreshError: refreshErrorMessage
                    ) {
                    case .loading:
                        HStack {
                            Spacer()
                            ProgressView("Loading worker log…")
                            Spacer()
                        }
                        .padding(.top, 40)
                    case .unavailable(let message):
                        ContentUnavailableView(
                            "Log unavailable",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text(message)
                        )
                        .padding(.top, 40)
                    case .content(let cachedLog, let refreshError):
                        if let refreshError {
                            // Non-destructive banner: a failed refresh NEVER
                            // evicts the cached log from the screen.
                            Label("Refresh failed: \(refreshError)", systemImage: "exclamationmark.circle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if !cachedLog.exists {
                            ContentUnavailableView(
                                "No worker output yet",
                                systemImage: "terminal",
                                description: Text("This task has not spawned a worker, so there is no log.")
                            )
                            .padding(.top, 40)
                        } else {
                            summaryFooter(cachedLog)
                            logText(cachedLog)
                                .id("logBottom")
                        }
                    }
                }
                .padding(14)
            }
            .background(ConduitBackdrop())
            .navigationTitle("Worker Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: isLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    }
                    .disabled(isLoading)
                    .accessibilityLabel("Refresh worker log")
                }
            }
            .task { await load(scrollProxy: proxy) }
        }
    }

    private func summaryFooter(_ log: KanbanWorkerLog) -> some View {
        HStack(spacing: 8) {
            Text(ByteCountFormatter.string(fromByteCount: Int64(log.sizeBytes), countStyle: .memory))
            if log.truncated {
                Text("· showing last \(Self.tailBytes / 1024) KiB")
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func logText(_ log: KanbanWorkerLog) -> some View {
        let rendered = Self.renderTail(log.content)
        if rendered.isEmpty {
            Text("(log is empty)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            Text(rendered)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Keeps the NEWEST output when the fetched tail still exceeds the render
    /// budget, prefixing an explicit omission marker instead of freezing the
    /// phone on a giant string. The marker is accounted against the budget so
    /// the returned string NEVER exceeds `maxRenderedCharacters`, newline or
    /// not.
    static func renderTail(_ content: String) -> String {
        guard content.count > maxRenderedCharacters else { return content }
        let marker = "[older output omitted]"
        // Reserve room for the marker up front so no path can exceed budget.
        // Clamped so even a hypothetical tiny budget cannot underflow.
        let suffix = String(content.suffix(max(0, maxRenderedCharacters - marker.count)))
        // Avoid starting mid-line; a tail with no newline at all still stays
        // within budget because the slice was already sized for it.
        let firstNewline = suffix.firstIndex(of: "\n")
        let trimmed = firstNewline.map { String(suffix[$0...]) } ?? suffix
        return marker + trimmed
    }

    private func load(scrollProxy: ScrollViewProxy? = nil) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // Board context comes pinned from the store's loaded snapshot.
            log = try await store.fetchTaskLog(id: taskID, tailBytes: Self.tailBytes)
            // A successful refresh clears any stale refresh banner.
            refreshErrorMessage = nil
            // One run-loop turn lets SwiftUI lay out the (possibly huge)
            // monospaced text before we jump to the bottom; bail out if the
            // screen was dismissed during that window instead of scrolling a
            // dead proxy.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            scrollProxy?.scrollTo("logBottom", anchor: .bottom)
        } catch {
            if log == nil {
                // Initial load failure: nothing is cached, so the full
                // "unavailable" state applies.
                errorMessage = error.localizedDescription
            } else {
                // Refresh failure with cached content: keep the log visible
                // and surface a small non-destructive banner instead.
                refreshErrorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Presentation

/// Presentation resolution for the worker-log screen, extracted so the
/// cached-content refresh-failure rule is deterministically testable:
/// a failed refresh must never evict an already-loaded log, and a successful
/// refresh clears the banner.
enum KanbanWorkerLogPresentation: Equatable {
    /// No log yet and no failure: initial load in flight.
    case loading
    /// Nothing cached and the load failed: full unavailable state.
    case unavailable(String)
    /// A log is on screen. refreshError is non-nil when the most recent
    /// REFRESH failed — the cached content stays visible with a small,
    /// non-destructive banner.
    case content(log: KanbanWorkerLog, refreshError: String?)

    static func resolve(log: KanbanWorkerLog?, loadError: String?, refreshError: String?) -> KanbanWorkerLogPresentation {
        guard let log else {
            if let loadError { return .unavailable(loadError) }
            return .loading
        }
        return .content(log: log, refreshError: refreshError)
    }
}
