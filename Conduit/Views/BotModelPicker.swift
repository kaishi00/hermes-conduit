import SwiftUI

/// A bot's Model page: the gateway's `model.options` inventory on the Model
/// page every model setting opens (ModelChooserPage). A new bot can also
/// keep the main profile's model; an edited bot always has a pick of its
/// own. Edit Bot > Work's Workstream Model opens it too, with reasoning.
struct BotModelPicker: View {
    @Binding var provider: String
    @Binding var model: String
    /// Offers "Same as Main Profile" (empty provider and model).
    let allowsInherit: Bool
    /// What that choice is called where it inherits something else (Edit
    /// Bot > Work's Workstream Model: the Bot Chat's).
    var inheritTitle: String? = nil
    /// The pick's reasoning, where the setting has one (Workstream Model).
    var reasoning: ModelChooserReasoning? = nil

    @EnvironmentObject private var appState: AppState
    /// The models, kept from Hermes' last answer until it answers again
    /// (#1533). Kept ones wait for that answer before they can be picked:
    /// a bot's save pins its pick without Hermes checking it, and a kept
    /// model may be gone.
    @State private var catalog = KeptModelCatalog()
    /// Refresh models is asking Hermes for every provider's live list.
    @State private var refreshing = false
    /// Counts the catalog reads, so only the last one asked lands.
    @State private var catalogRead = 0
    /// A plain read was asked while Refresh models ran: it runs once the
    /// refresh lands.
    @State private var readAfterRefresh = false
    /// The read that failed was Refresh models, so Try Again asks for the
    /// live lists again rather than the cached ones.
    @State private var refreshFailed = false

    var body: some View {
        ModelChooserPage(
            catalog: ModelChooserCatalog(catalog),
            retry: { Task { if refreshFailed { await refreshModels() } else { await load() } } },
            refresh: ModelChooserRefresh(refreshing: refreshing) { Task { await refreshModels() } },
            defaultChoice: allowsInherit
                ? ModelChooserDefault(title: inheritTitle ?? AppLocalization.string("Same as Main Profile", table: .bots))
                : nil,
            pick: provider.isEmpty && model.isEmpty ? nil : ModelChooserPick(provider: provider, model: model),
            reasoning: reasoning,
            onDefault: {
                provider = ""
                model = ""
            },
            onPick: { option, item in
                provider = option.name
                model = item.id
            }
        )
        // What Hermes listed last time, before the first frame; its answer
        // follows.
        .onAppear {
            catalog.showKept(Self.pickable(appState.keptModelProviders()))
        }
        .task {
            guard !catalog.answered else { return }
            await load()
            // Hermes fetches a stale provider list in the background
            // meanwhile (issue 1807).
            await ModelCatalogSettle.readAgain { await load() }
        }
    }

    /// Refresh models, from the toolbar or Try Again after one failed.
    private func refreshModels() async {
        guard !refreshing else { return }
        refreshing = true
        await load(refresh: true)
        refreshing = false
        // A refresh that failed stays said: Try Again asks again.
        let readSkipped = readAfterRefresh
        readAfterRefresh = false
        if readSkipped, !catalog.failed {
            await load()
        }
    }

    /// `refresh` is Refresh models: Hermes fetches every provider's live
    /// list first. The search and the pick stay as they are.
    private func load(refresh: Bool = false) async {
        // A Refresh models under way has the newer answer coming.
        guard refresh || !refreshing else {
            readAfterRefresh = true
            return
        }
        catalogRead += 1
        let read = catalogRead
        catalog.readStarted()
        let loaded = await appState.loadModelProviders(refresh: refresh)
        // A read asked since has the newer answer.
        guard read == catalogRead else { return }
        // A plain read that fails after a failed refresh keeps the refresh
        // owed, so Try Again still asks for the live lists.
        refreshFailed = loaded == nil && (refresh || refreshFailed)
        if let loaded {
            catalog.hermesAnswered(Self.pickable(loaded))
        } else {
            catalog.readFailed()
        }
    }

    /// A provider with no models has nothing to pick.
    static func pickable(_ providers: [ProviderInfo]) -> [ProviderInfo] {
        providers.filter { !$0.models.isEmpty }
    }

    /// The Model row's value: the pick, or what an empty pick means.
    static func summary(model: String, allowsInherit: Bool) -> String {
        if !model.isEmpty { return model }
        return allowsInherit
            ? AppLocalization.string("Same as Main Profile", table: .bots)
            : AppLocalization.string("Not set")
    }
}
