//
//  RichCardViews.swift
//  Conduit
//
//  How rich cards look, in a chat and on a call's screen. Each card is
//  drawn from what Hermes said plus what Apple Maps knows, and keeps the
//  two apart: Apple's details carry the Apple Maps mark, Hermes' facts
//  name their source, its note reads as its own words, and a place Apple
//  Maps can't find says so instead of showing guesses.
//

import MapKit
import SwiftUI

/// A list of cards, one under another.
struct RichCardsView: View {
    let cards: [RichCard]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(cards) { card in
                RichCardView(card: card)
            }
        }
    }
}

struct RichCardView: View {
    let card: RichCard

    var body: some View {
        switch card.kind {
        case .map:
            RichMapCard(card: card)
        case .place:
            if let place = card.places.first {
                RichPlaceCard(place: place, title: card.title)
            }
        case .places:
            RichPlacesCarousel(card: card)
        case .stats:
            RichStatsCard(card: card)
        case .chart:
            RichChartCard(card: card)
        case .weather:
            RichWeatherCard(card: card)
        case .comparison:
            RichComparisonCard(card: card)
        case .steps:
            RichStepsCard(card: card)
        case .media:
            RichMediaCard(card: card)
        case .contact:
            RichContactCard(card: card)
        case .status:
            RichStatusCard(card: card)
        }
    }
}

/// The card surface every rich card sits on.
private struct RichCardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .settingsCard(cornerRadius: 22)
    }
}

extension View {
    func richCardSurface() -> some View { modifier(RichCardSurface()) }
}

// MARK: - Map

struct RichMapCard: View {
    let card: RichCard

    @State private var matches: [RichPlaceMatch?] = []
    @State private var route: MKRoute?
    @State private var looked = false
    @State private var showsMap = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showsMap = true
            } label: {
                RichMapPicture(coordinates: found.map(\.coordinate), route: route?.polyline, height: 190, looked: looked)
            }
            .buttonStyle(.plain)
            // The full map opens with the pins and route found, and only
            // when there is one to show.
            .disabled(!looked || found.isEmpty)
            .accessibilityLabel(Text(verbatim: card.title ?? card.places.map(\.name).joined(separator: ", ")))
            .accessibilityHint(looked && !found.isEmpty ? Text("Opens the map") : Text(verbatim: ""))

            VStack(alignment: .leading, spacing: 10) {
                if let title = card.title {
                    Text(verbatim: title)
                        .font(.headline)
                }
                if let route, let destination = card.route {
                    RichRouteSummary(route: route, mode: destination.mode)
                }
                ForEach(card.places, id: \.index) { place in
                    RichPlaceRow(place: place, number: card.places.count > 1 ? place.index + 1 : nil,
                                 match: match(place), looked: looked)
                }
                RichAppleMapsMark(found: found.contains { $0.isVerified })
            }
            .padding(14)
        }
        .richCardSurface()
        .task(id: card) { await look() }
        .sheet(isPresented: $showsMap) {
            RichMapScreen(card: card, matches: matches, route: route)
        }
    }

    private var found: [RichPlaceMatch] { matches.compactMap { $0 } }

    private func match(_ place: RichPlace) -> RichPlaceMatch? {
        matches.indices.contains(place.index) ? matches[place.index] : nil
    }

    private func look() async {
        matches = []
        route = nil
        looked = false
        let lookups = await RichPlaceLookup.matches(card.places)
        // A newer card's lookup owns the state now.
        guard !Task.isCancelled else { return }
        matches = lookups
        if let planned = card.route, let to = match(card.places[planned.to]) {
            let from = planned.from.flatMap { match(card.places[$0]) }
            if planned.from == nil || from != nil {
                let found = await RichPlaceLookup.route(from: from, to: to, mode: planned.mode)
                guard !Task.isCancelled else { return }
                route = found
            }
        }
        looked = true
    }
}

/// A still map of the places, with a pin each (numbered when there are
/// several) and the route.
struct RichMapPicture: View {
    let coordinates: [CLLocationCoordinate2D]
    let route: MKPolyline?
    let height: CGFloat
    /// The lookups are done: no places means none could be found.
    let looked: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?
    /// The snapshot couldn't be drawn: a still icon rather than a spinner.
    @State private var failed = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.12))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else if (looked && coordinates.isEmpty) || failed {
                    Image(systemName: "map")
                        .font(.title)
                        .foregroundStyle(.conduitTertiary)
                } else {
                    ProgressView()
                }
            }
            .frame(width: geometry.size.width, height: height)
            .clipped()
            .task(id: key(width: geometry.size.width)) {
                await draw(width: geometry.size.width)
            }
        }
        .frame(height: height)
        // Decorative: the button around it, or the rows beside it, name the
        // places.
        .accessibilityHidden(true)
    }

    private func key(width: CGFloat) -> String {
        "\(coordinates.map { "\($0.latitude),\($0.longitude)" })|\(RichMapSnapshot.routeKey(route))|\(Int(width))|\(colorScheme == .dark)"
    }

    private func draw(width: CGFloat) async {
        failed = false
        guard !coordinates.isEmpty else {
            image = nil
            return
        }
        let drawn = await RichMapSnapshot.image(
            coordinates: coordinates, route: route, size: CGSize(width: width, height: height),
            dark: colorScheme == .dark, accent: UIColor(Color.conduitAccent)
        )
        // A newer size or scheme started its own snapshot.
        guard !Task.isCancelled else { return }
        failed = drawn == nil
        withAnimation(.easeOut(duration: 0.2)) { image = drawn }
    }
}

private struct RichRouteSummary: View {
    let route: MKRoute
    let mode: RichCard.TravelMode

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: RichTravel.symbol(mode))
                .accessibilityHidden(true)
            Text(verbatim: RichTravel.duration(route.expectedTravelTime))
                .fontWeight(.semibold)
            Text(verbatim: "·")
                .foregroundStyle(.secondary)
            Text(verbatim: RichTravel.distance(route.distance))
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .foregroundStyle(Color.conduitAccent)
        .accessibilityElement(children: .combine)
    }
}

/// One place in a map card's list.
private struct RichPlaceRow: View {
    let place: RichPlace
    let number: Int?
    let match: RichPlaceMatch?
    let looked: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(Color.conduitAccent)
                if let number {
                    Text(verbatim: "\(number)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: match?.symbol ?? "mappin")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: match?.name ?? place.name)
                    .font(.subheadline.weight(.semibold))
                RichPlaceWhere(match: match, looked: looked)
                RichPlaceFacts(place: place)
                if let note = place.note {
                    RichHermesNote(note: note)
                }
            }
            .environment(\.richSourceActionsOnRow, true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .richSourceAction(place.rating?.source, url: place.rating?.url, onRow: true)
        .richSourceAction(place.price?.source, url: place.price?.url, onRow: true)
        .richSourceAction(place.hours?.source, url: place.hours?.url, onRow: true)
    }
}

// MARK: - Place

struct RichPlaceCard: View {
    let place: RichPlace
    var title: String? = nil
    var mode: RichCard.TravelMode = .driving

    @State private var match: RichPlaceMatch?
    @State private var looked = false
    @State private var travelTime: TimeInterval?
    @State private var showsMap = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 10) {
                if let title, title != place.name {
                    Text(verbatim: title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: match?.name ?? place.name)
                        .font(.title3.weight(.semibold))
                    RichPlaceWhere(match: match, looked: looked)
                }
                RichPlaceFacts(place: place)
                if let travelTime {
                    Label {
                        Text(verbatim: RichTravel.duration(travelTime))
                    } icon: {
                        Image(systemName: RichTravel.symbol(mode))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.conduitAccent)
                }
                if let note = place.note {
                    RichHermesNote(note: note)
                }
                if let match {
                    RichPlaceActions(match: match, mode: mode)
                }
                RichAppleMapsMark(found: match?.isVerified == true)
            }
            .padding(14)
        }
        .richCardSurface()
        .task(id: place) {
            // A reused card shows nothing of the place it showed before.
            travelTime = nil
            match = nil
            looked = false
            let found = await RichPlaceLookup.match(place)
            guard !Task.isCancelled else { return }
            match = found
            looked = true
            guard let found else { return }
            let time = await RichPlaceLookup.travelTime(to: found, mode: mode)
            guard !Task.isCancelled else { return }
            travelTime = time
        }
        .sheet(isPresented: $showsMap) {
            if let match {
                RichMapScreen(place: place, match: match, mode: mode)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if let photo = place.photo {
            RichPhotoHeader(photo: photo, placeName: place.name, height: 160)
            // The photo opens its source, so a strip of map opens the map.
            if let match { mapButton(match, height: 80) }
        } else if let match {
            mapButton(match, height: 120)
        }
    }

    private func mapButton(_ match: RichPlaceMatch, height: CGFloat) -> some View {
        Button {
            showsMap = true
        } label: {
            RichMapPicture(coordinates: [match.coordinate], route: nil, height: height, looked: looked)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: match.name))
        .accessibilityHint(Text("Opens the map"))
    }
}

/// A photo Hermes found, with where it's from.
private struct RichPhotoHeader: View {
    let photo: RichPlace.Photo
    let placeName: String
    let height: CGFloat

    @Environment(\.openURL) private var openURL

    private var sourceURL: URL { photo.pageURL ?? photo.url }

    var body: some View {
        RichCardImage(url: photo.url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Rectangle().fill(Color.secondary.opacity(0.12))
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .bottomTrailing) {
            Button {
                openURL(sourceURL)
            } label: {
                Text(verbatim: photo.source)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(placeName), \(photo.source)"))
        .richSourceAction(photo.source, url: sourceURL)
    }
}

/// Apple Maps' address and kind of place, or that Apple Maps has nothing.
private struct RichPlaceWhere: View {
    let match: RichPlaceMatch?
    let looked: Bool

    var body: some View {
        if let match, match.isVerified {
            if let address = match.address {
                Label {
                    Text(verbatim: address)
                } icon: {
                    Image(systemName: match.symbol)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .labelStyle(RichCompactLabelStyle())
            }
        } else if looked {
            Group {
                if match == nil {
                    Text("Not found in Apple Maps")
                } else {
                    Text("Location from Hermes")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Ratings, hours and prices Hermes found, each with its source.
private struct RichPlaceFacts: View {
    let place: RichPlace

    var body: some View {
        if place.rating != nil || place.hours != nil || place.price != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let rating = place.rating {
                    RichRatingLine(rating: rating)
                }
                if let price = place.price {
                    RichSourcedLine(symbol: "banknote", fact: price)
                }
                if let hours = place.hours {
                    RichSourcedLine(symbol: "clock", fact: hours)
                }
            }
        }
    }
}

private struct RichRatingLine: View {
    let rating: RichPlace.Rating

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 1) {
                ForEach(0..<5, id: \.self) { star in
                    Image(systemName: Self.symbol(star: star, value: rating.value))
                }
            }
            .font(.caption)
            .foregroundStyle(.orange)
            Text(verbatim: rating.value.formatted(.number.precision(.fractionLength(1)).locale(AppLocalization.formattingLocale)))
                .font(.subheadline.weight(.semibold))
            if let count = rating.count {
                Text(verbatim: "(\(count.formatted(.number.locale(AppLocalization.formattingLocale))))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            RichSource(name: rating.source, url: rating.url)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Rated \(rating.value.formatted(.number.precision(.fractionLength(1)).locale(AppLocalization.formattingLocale))) out of 5 on \(rating.source)"))
        .richSourceAction(rating.source, url: rating.url)
    }

    static func symbol(star: Int, value: Double) -> String {
        let filled = value - Double(star)
        if filled >= 0.75 { return "star.fill" }
        if filled >= 0.25 { return "star.leadinghalf.filled" }
        return "star"
    }
}

private struct RichSourcedLine: View {
    let symbol: String
    let fact: RichSourcedFact

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(verbatim: fact.text)
                .font(.subheadline)
            RichSource(name: fact.source, url: fact.url)
        }
        .accessibilityElement(children: .combine)
        .richSourceAction(fact.source, url: fact.url)
    }
}

private extension View {
    /// A line that reads as one element hides the source's link button, so
    /// VoiceOver gets it back as an "Open <source>" action. Inside a place
    /// row or tile the action goes on the whole row instead (`onRow`), so
    /// it's there once however the row's children are combined.
    @ViewBuilder
    func richSourceAction(_ name: String?, url: URL?, onRow: Bool = false) -> some View {
        if let name, let url {
            modifier(RichSourceAction(name: name, url: url, onRow: onRow))
        } else {
            self
        }
    }
}

private struct RichSourceAction: ViewModifier {
    let name: String
    let url: URL
    let onRow: Bool

    @Environment(\.openURL) private var openURL
    @Environment(\.richSourceActionsOnRow) private var actionsOnRow

    func body(content: Content) -> some View {
        if actionsOnRow && !onRow {
            content
        } else {
            content.accessibilityAction(named: Text("Open \(name)")) { openURL(url) }
        }
    }
}

private struct RichSourceActionsOnRowKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    /// Set inside a place row or tile, which carries its lines' source actions itself.
    var richSourceActionsOnRow: Bool {
        get { self[RichSourceActionsOnRowKey.self] }
        set { self[RichSourceActionsOnRowKey.self] = newValue }
    }
}

/// Where a fact is from: a link when Hermes gave its page.
private struct RichSource: View {
    let name: String
    let url: URL?

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: "·")
            if let url {
                Button {
                    openURL(url)
                } label: {
                    Text(verbatim: name).underline()
                }
                .buttonStyle(.plain)
            } else {
                Text(verbatim: name)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Hermes' own note on a place, set apart from the facts.
private struct RichHermesNote: View {
    let note: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "text.bubble")
                .font(.caption)
                .foregroundStyle(Color.conduitAccent)
                .accessibilityHidden(true)
            Text(verbatim: note)
                .font(.subheadline)
                .italic()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Note") + Text(verbatim: ": \(note)"))
    }
}

/// Directions, Call and Website for a place Apple Maps found.
private struct RichPlaceActions: View {
    let match: RichPlaceMatch
    let mode: RichCard.TravelMode

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 8) {
            Button {
                RichPlaceLookup.openDirections(to: match, mode: mode)
            } label: {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.conduitAccent)
            if let tel = match.telURL {
                Button {
                    openURL(tel)
                } label: {
                    Label("Call", systemImage: "phone.fill")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 28)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(Text("Call"))
            }
            if let website = match.website {
                Button {
                    openURL(website)
                } label: {
                    Label("Website", systemImage: "safari.fill")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 28)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(Text("Website"))
            }
        }
        .font(.subheadline.weight(.semibold))
        .controlSize(.regular)
    }
}

/// Whose details these are.
private struct RichAppleMapsMark: View {
    let found: Bool

    var body: some View {
        if found {
            Label {
                Text("Apple Maps")
            } icon: {
                Image(systemName: "map.fill")
            }
            .font(.caption2)
            .foregroundStyle(.conduitTertiary)
            .labelStyle(RichCompactLabelStyle())
        }
    }
}

struct RichCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Several places

struct RichPlacesCarousel: View {
    let card: RichCard

    @State private var opened: RichPlace?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = card.title {
                Text(verbatim: title)
                    .font(.headline)
                    .padding(.horizontal, 4)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(card.places, id: \.index) { place in
                        Button {
                            opened = place
                        } label: {
                            RichPlaceTile(place: place)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
        }
        .sheet(item: $opened) { place in
            NavigationStack {
                ScrollView {
                    RichPlaceCard(place: place)
                        .padding(16)
                }
                .navigationTitle(Text(verbatim: place.name))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { opened = nil }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

extension RichPlace: Identifiable {
    var id: Int { index }
}

/// One place in a carousel.
private struct RichPlaceTile: View {
    let place: RichPlace

    @State private var match: RichPlaceMatch?
    @State private var looked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let photo = place.photo {
                RichPhotoHeader(photo: photo, placeName: place.name, height: 110)
            } else {
                RichMapPicture(coordinates: match.map { [$0.coordinate] } ?? [], route: nil, height: 110, looked: looked)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: match?.name ?? place.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                RichPlaceWhere(match: match, looked: looked)
                    .lineLimit(1)
                if let rating = place.rating {
                    RichRatingLine(rating: rating)
                        .lineLimit(1)
                }
                if let note = place.note {
                    Text(verbatim: note)
                        .font(.caption)
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(12)
            Spacer(minLength: 0)
        }
        .environment(\.richSourceActionsOnRow, true)
        // Grows with larger text rather than clipping it.
        .frame(width: 250, alignment: .top)
        .frame(minHeight: 250, alignment: .top)
        .richCardSurface()
        .contentShape(Rectangle())
        .task(id: place) {
            match = nil
            looked = false
            let found = await RichPlaceLookup.match(place)
            guard !Task.isCancelled else { return }
            match = found
            looked = true
        }
        .accessibilityElement(children: .combine)
        .richSourceAction(place.photo?.source, url: place.photo.map { $0.pageURL ?? $0.url }, onRow: true)
        .richSourceAction(place.rating?.source, url: place.rating?.url, onRow: true)
    }
}

// MARK: - The live map

/// A card's places on a full map: pins, the route, the user, and the
/// selected place's details with Look Around.
struct RichMapScreen: View {
    let places: [RichPlace]
    /// Each found place, by its index in the card.
    let matches: [Int: RichPlaceMatch]
    let route: MKRoute?
    let title: String?
    var mode: RichCard.TravelMode = .driving

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int?
    @State private var scene: MKLookAroundScene?

    init(card: RichCard, matches: [RichPlaceMatch?], route: MKRoute?) {
        places = card.places
        var found: [Int: RichPlaceMatch] = [:]
        for (index, match) in matches.enumerated() { found[index] = match }
        self.matches = found
        self.route = route
        title = card.title
        mode = card.route?.mode ?? .driving
    }

    /// One place on its own.
    init(place: RichPlace, match: RichPlaceMatch, mode: RichCard.TravelMode) {
        places = [place]
        matches = [place.index: match]
        route = nil
        title = match.name
        self.mode = mode
    }

    var body: some View {
        NavigationStack {
            Map(initialPosition: initialPosition, selection: $selection) {
                ForEach(places, id: \.index) { place in
                    if let match = match(place) {
                        Marker(match.name, systemImage: match.symbol, coordinate: match.coordinate)
                            .tint(Color.conduitAccent)
                            .tag(place.index)
                    }
                }
                if let route {
                    MapPolyline(route.polyline)
                        .stroke(Color.conduitAccent, lineWidth: 5)
                }
                if RichPlaceLookup.canUseLocation {
                    UserAnnotation()
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .safeAreaInset(edge: .bottom) {
                if let selected = selectedMatch {
                    selectedPanel(selected)
                }
            }
            .navigationTitle(Text(verbatim: title ?? ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if places.count == 1 || selection == nil { selection = places.first(where: { match($0) != nil })?.index }
            }
            .task(id: selection) { await lookAround() }
        }
    }

    private var initialPosition: MapCameraPosition {
        let coordinates = places.compactMap { matches[$0.index]?.coordinate }
        guard !coordinates.isEmpty else { return .automatic }
        return .region(RichMapSnapshot.region(fitting: coordinates, route: route?.polyline))
    }

    private func match(_ place: RichPlace) -> RichPlaceMatch? {
        matches[place.index]
    }

    private var selectedMatch: (place: RichPlace, match: RichPlaceMatch)? {
        guard let selection, let place = places.first(where: { $0.index == selection }), let match = match(place) else {
            return nil
        }
        return (place, match)
    }

    private func selectedPanel(_ selected: (place: RichPlace, match: RichPlaceMatch)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let scene {
                LookAroundPreview(initialScene: scene)
                    .frame(height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel(Text("Look Around"))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: selected.match.name)
                    .font(.headline)
                RichPlaceWhere(match: selected.match, looked: true)
            }
            RichPlaceFacts(place: selected.place)
            if selected.match.isVerified {
                RichPlaceActions(match: selected.match, mode: mode)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func lookAround() async {
        scene = nil
        guard let selected = selectedMatch, selected.match.isVerified else { return }
        let request = MKLookAroundSceneRequest(mapItem: selected.match.item)
        let found = try? await request.scene
        // Another place was picked meanwhile; its own task fills the scene.
        guard !Task.isCancelled else { return }
        scene = found
    }
}

// MARK: - Travel text

enum RichTravel {
    static func symbol(_ mode: RichCard.TravelMode) -> String {
        switch mode {
        case .driving: return "car.fill"
        case .walking: return "figure.walk"
        case .transit: return "tram.fill"
        case .cycling: return "bicycle"
        }
    }

    /// "12 min", "1 hr 5 min", in the app's language.
    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.calendar = calendar
        return formatter.string(from: max(seconds, 60)) ?? ""
    }

    static func distance(_ meters: CLLocationDistance) -> String {
        let formatter = MKDistanceFormatter()
        formatter.unitStyle = .abbreviated
        formatter.locale = AppLocalization.formattingLocale
        return formatter.string(fromDistance: meters)
    }

    private static var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = AppLocalization.formattingLocale
        return calendar
    }
}
