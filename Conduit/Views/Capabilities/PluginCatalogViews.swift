//
//  PluginCatalogViews.swift
//  Conduit
//
//  Settings > Capabilities > Plugins' catalog, as Hermes Desktop's plugin
//  catalog browses it: a shelf of featured plugins with their pictures,
//  Browse All with the catalog's tiers (official, verified, community),
//  categories and a search, and a plugin's page with its pictures, what it
//  adds, the keys it needs, its known issues, its links and Install. All
//  from Hermes' `/api/dashboard/plugins/catalog`; pictures come only from
//  GitHub's hosts, as Hermes' catalog allows.
//

import SwiftUI

enum PluginCatalogStyle {
    static func tierPill(_ entry: PluginCatalogEntry) -> CapabilityPillModel {
        tierPill(tier: entry.normalizedTier)
    }

    static func tierPill(tier: String) -> CapabilityPillModel {
        switch tier {
        case "official": return CapabilityPillModel(text: AppLocalization.string("Official"), tint: .conduitAura)
        case "verified": return CapabilityPillModel(text: AppLocalization.string("Verified"), tint: .green)
        default: return CapabilityPillModel(text: AppLocalization.string("Community"))
        }
    }

    static func tierTitle(_ tier: String) -> String { tierPill(tier: tier).text }

    /// `software-development` reads as "Software Development".
    static func categoryTitle(_ category: String) -> String {
        category.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// A plugin's picture, or its glyph on a tinted ground while there's none.
struct PluginCatalogArtwork: View {
    let url: URL?
    var cornerRadius: CGFloat = 12

    var body: some View {
        ZStack {
            Rectangle().fill(Color.conduitAura.opacity(0.12))
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: "shippingbox")
            .scaledFont(.title3)
            .foregroundStyle(Color.conduitAura)
    }
}

/// The Plugins tab's catalog: the featured shelf and Browse All.
struct PluginCatalogShelf: View {
    let store: CapabilitiesStore
    let canManage: Bool

    var body: some View {
        let featured = CapabilityPluginFilter.featured(store.pluginCatalog)
        CapabilitySection(
            title: AppLocalization.string("Plugin catalog"),
            symbol: "shippingbox",
            tint: .conduitAura,
            footer: AppLocalization.string("Reviewed plugins from Hermes' catalog.")
        ) {
            if !featured.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(featured) { entry in
                            NavigationLink {
                                PluginCatalogDetailPage(name: entry.name, store: store, canManage: canManage)
                                    .v2TabBarClearance()
                            } label: {
                                PluginFeaturedCard(entry: entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 10)
                }
                CapabilityRowDivider()
            }
            NavigationLink {
                PluginCatalogBrowsePage(store: store, canManage: canManage)
                    .v2TabBarClearance()
            } label: {
                CapabilityRowLabel(
                    symbol: "square.grid.2x2",
                    title: AppLocalization.string("Browse All Plugins"),
                    meta: "\(store.pluginCatalog.count)",
                    chevron: true
                )
            }
            .buttonStyle(.plain)
        }
    }
}

private struct PluginFeaturedCard: View {
    let entry: PluginCatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PluginCatalogArtwork(url: entry.imageURL)
                .frame(width: 220, height: 124)
            HStack(spacing: 6) {
                Text(verbatim: entry.displayName)
                    .scaledFont(.subheadline.weight(.semibold))
                    .lineLimit(1)
                CapabilityPill(text: PluginCatalogStyle.tierPill(entry).text, tint: PluginCatalogStyle.tierPill(entry).tint)
            }
            Text(verbatim: entry.description)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(width: 220, alignment: .leading)
        }
        .frame(width: 220, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct PluginCatalogBrowsePage: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let store: CapabilitiesStore
    let canManage: Bool
    @State private var query = ""
    @State private var tier: String?
    @State private var category: String?

    var body: some View {
        let catalog = store.pluginCatalog
        let entries = CapabilityPluginFilter.browse(catalog, query: query, tier: tier, category: category)
        CapabilityTabScroll(refresh: { await store.loadPlugins() }) {
            filters(catalog)
            if entries.isEmpty {
                CapabilityEmptyState(
                    title: AppLocalization.string("No matching plugins"),
                    symbol: "shippingbox",
                    message: query.isEmpty ? nil : AppLocalization.string("Nothing matches “\(query)”.")
                )
            } else {
                CapabilitySection(
                    title: tier.map(PluginCatalogStyle.tierTitle) ?? AppLocalization.string("All Plugins"),
                    symbol: "shippingbox",
                    tint: .conduitAura
                ) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        CapabilityCardRow(divided: index > 0) {
                            NavigationLink {
                                PluginCatalogDetailPage(name: entry.name, store: store, canManage: canManage)
                                    .v2TabBarClearance()
                            } label: {
                                PluginCatalogListRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .navigationTitle(Text("Plugin catalog"))
        .searchable(text: $query, prompt: Text("Search plugins"))
    }

    @ViewBuilder
    private func filters(_ catalog: [PluginCatalogEntry]) -> some View {
        let tiers = CapabilityPluginFilter.tiers(in: catalog)
        let categories = CapabilityPluginFilter.categories(in: catalog)
        VStack(alignment: .leading, spacing: 10) {
            if tiers.count > 1 {
                Picker(selection: $tier) {
                    Text("All").tag(String?.none)
                    ForEach(tiers, id: \.self) { tier in
                        Text(verbatim: PluginCatalogStyle.tierTitle(tier)).tag(String?.some(tier))
                    }
                } label: {
                    Text("Tier")
                }
                .pickerStyle(.segmented)
            }
            if categories.count > 1 {
                Menu {
                    Picker(selection: $category) {
                        Text("All Categories").tag(String?.none)
                        ForEach(categories, id: \.self) { category in
                            Text(verbatim: PluginCatalogStyle.categoryTitle(category)).tag(String?.some(category))
                        }
                    } label: {
                        Text("Category")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .accessibilityHidden(true)
                        Text(verbatim: category.map(PluginCatalogStyle.categoryTitle) ?? AppLocalization.string("All Categories"))
                            .scaledFont(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down")
                            .scaledFont(.caption2.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(Color.conduitAccent)
                    .padding(.horizontal, 4)
                }
                .accessibilityLabel(Text("Category"))
            }
        }
    }
}

private struct PluginCatalogListRow: View {
    let entry: PluginCatalogEntry

    private var pills: [CapabilityPillModel] {
        var pills = [PluginCatalogStyle.tierPill(entry)]
        if entry.installed {
            pills.append(CapabilityPillModel(text: AppLocalization.string("Installed"), tint: .green))
        }
        return pills
    }

    var body: some View {
        HStack(spacing: 11) {
            PluginCatalogArtwork(url: entry.imageURL, cornerRadius: 8)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: entry.displayName)
                    .scaledFont(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !entry.category.isEmpty {
                        Text(verbatim: PluginCatalogStyle.categoryTitle(entry.category))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    ForEach(pills, id: \.self) { pill in
                        CapabilityPill(text: pill.text, tint: pill.tint)
                    }
                }
                if !entry.description.isEmpty {
                    Text(verbatim: entry.description)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(.conduitTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

/// A catalog plugin's page: its pictures, what it is, what it adds, the
/// keys it needs, its known issues, its links and Install.
struct PluginCatalogDetailPage: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @Environment(\.openURL) private var openURL
    let name: String
    let store: CapabilitiesStore
    let canManage: Bool
    @State private var confirmsInstall = false
    @State private var message: String?

    /// Read from the store, so an install shows at once.
    private var entry: PluginCatalogEntry? { store.pluginCatalog.first { $0.name == name } }

    var body: some View {
        SettingsDetailContainer {
            if let entry {
                header(entry)
                if !entry.screenshotURLs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(entry.screenshotURLs, id: \.self) { url in
                                PluginCatalogArtwork(url: url)
                                    .frame(width: 260, height: 160)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                adds(entry)
                if !entry.requiresEnv.isEmpty {
                    ConduitSettingsSection(title: AppLocalization.string("Keys It Needs"), symbol: "key", tint: .orange) {
                        ForEach(entry.requiresEnv, id: \.self) { key in
                            Text(verbatim: key)
                                .scaledFont(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text("Hermes reads them from the profile's .env once it's installed.")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !entry.knownIssues.isEmpty {
                    ConduitSettingsSection(title: AppLocalization.string("Known Issues"), symbol: "exclamationmark.triangle", tint: .orange) {
                        ForEach(entry.knownIssues, id: \.self) { issue in
                            Text(verbatim: issue)
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                details(entry)
            } else {
                Text("This plugin is no longer in Hermes' catalog.")
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
        .navigationTitle(Text(verbatim: entry?.displayName ?? name))
        .confirmationDialog(
            Text("Install \(entry?.displayName ?? name)?"),
            isPresented: $confirmsInstall,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("Install")) { install() }
            Button(AppLocalization.string("Cancel"), role: .cancel) {}
        } message: {
            if let entry {
                Text(verbatim: entry.capabilitySummary.isEmpty ? entry.description : entry.capabilitySummary)
            }
        }
    }

    private func header(_ entry: PluginCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if entry.imageURL != nil {
                PluginCatalogArtwork(url: entry.imageURL)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }
            Text(verbatim: entry.displayName)
                .scaledFont(.title3.weight(.semibold))
            if !entry.maintainer.isEmpty {
                Text(verbatim: AppLocalization.string("By \(entry.maintainer)"))
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !entry.description.isEmpty {
                Text(verbatim: entry.description)
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                CapabilityPill(text: PluginCatalogStyle.tierPill(entry).text, tint: PluginCatalogStyle.tierPill(entry).tint)
                if !entry.category.isEmpty {
                    CapabilityPill(text: PluginCatalogStyle.categoryTitle(entry.category))
                }
                if !entry.version.isEmpty {
                    CapabilityPill(text: "v\(entry.version)")
                }
                if entry.updateAvailable {
                    CapabilityPill(text: AppLocalization.string("Update available"), tint: .conduitAccent)
                }
            }
            control(entry)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .settingsCard()
    }

    @ViewBuilder
    private func control(_ entry: PluginCatalogEntry) -> some View {
        if entry.installed {
            Label(AppLocalization.string("Installed"), systemImage: "checkmark.circle.fill")
                .scaledFont(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
            if entry.updateAvailable {
                Text("Update it from its page under Installed.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if canManage {
            let busy = store.pluginBusy.contains(entry.name)
            Button {
                confirmsInstall = true
            } label: {
                Label(
                    busy ? AppLocalization.string("Installing…") : AppLocalization.string("Install"),
                    systemImage: "arrow.down.circle"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .frame(minHeight: 44)
            }
            .disabled(busy)
            .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.14))
        } else {
            Text("Hermes installs plugins for the host's default profile. Switch to it to change them.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        if let message {
            Text(verbatim: message)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func adds(_ entry: PluginCatalogEntry) -> some View {
        let groups: [(String, [String])] = [
            (AppLocalization.string("Tools"), entry.tools),
            (AppLocalization.string("Hooks"), entry.hooks),
            (AppLocalization.string("Middleware"), entry.middleware)
        ].filter { !$0.1.isEmpty }
        if !groups.isEmpty {
            ConduitSettingsSection(title: AppLocalization.string("What It Adds"), symbol: "puzzlepiece.extension", tint: .conduitAccent) {
                ForEach(groups, id: \.0) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: group.0)
                            .scaledFont(.caption.weight(.semibold))
                        CapabilityFlowLayout(spacing: 6) {
                            ForEach(group.1, id: \.self) { item in
                                CapabilityPill(text: item)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func details(_ entry: PluginCatalogEntry) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("Details"), symbol: "list.bullet", tint: .conduitAura) {
            if !entry.platforms.isEmpty {
                SettingsMetricRow(label: AppLocalization.string("Platforms"), value: entry.platforms.joined(separator: ", "), lineLimit: 2)
            }
            SettingsMetricRow(label: AppLocalization.string("Catalog name"), value: entry.name, lineLimit: 2)
            if let url = entry.docsURL {
                Button {
                    openURL(url)
                } label: {
                    Label(AppLocalization.string("Documentation"), systemImage: "book")
                        .scaledFont(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tint(.conduitAccent)
            }
            if let url = entry.repoURL {
                Button {
                    openURL(url)
                } label: {
                    Label(AppLocalization.string("View Source"), systemImage: "arrow.up.right.square")
                        .scaledFont(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tint(.conduitAccent)
            }
        }
    }

    private func install() {
        guard let entry, canManage else { return }
        Haptics.selection()
        message = nil
        Task {
            do {
                let outcome = try await store.installPlugin(entry)
                if !outcome.missingEnv.isEmpty {
                    message = AppLocalization.string("\(outcome.name) is installed but needs a key before it works: \(outcome.missingEnv.joined(separator: ", ")).")
                } else if outcome.restartRequired {
                    message = AppLocalization.string("\(outcome.name) is installed. Restart the gateway to load it.")
                } else {
                    Haptics.success()
                    message = AppLocalization.string("\(outcome.name) is installed and loaded.")
                }
            } catch {
                message = UserFacingError.message(for: error)
            }
        }
    }
}
