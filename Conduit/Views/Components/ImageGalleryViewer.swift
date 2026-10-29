//
//  ImageGalleryViewer.swift
//  Conduit
//
//  The full-screen picture viewer: a chat's pictures, an Artifacts list's or
//  a folder's, paged left and right, closed with a swipe down. Pinch and a
//  double tap zoom; a zoomed picture pans, and its edge hands the swipe on
//  to the next one. Share offers Save Image, Copy and Save to Files, as
//  Quick Look did. Videos, audio and documents still open in Quick Look
//  (MediaPreviewPresenter); only pictures page here.
//
//  A gallery is a list of items, each fetching its own original when its
//  page needs it: the tapped one first, then its neighbours. Nothing is
//  fetched for a picture the reader never swipes near. Copies fetched for
//  the viewer are removed when it closes.
//

import ImageIO
import SwiftUI
import UIKit

/// One picture a gallery can show.
struct ImageGalleryItem: Identifiable {
    /// Which picture it is (`ImageGalleryItem.mediaID(path:)` and the
    /// like), so the one tapped is found in its list.
    let id: String
    /// The name it is shared and saved under, shown above it.
    let title: String
    /// Fetches the original to a file.
    let load: @MainActor () async -> ImageGalleryLoad

    static func mediaID(path: String) -> String { "path:\(path)" }
    static func webID(_ url: String) -> String { "web:\(url)" }
    static func attachmentID(_ attachment: Attachment) -> String {
        if attachment.uri.hasPrefix("/") { return mediaID(path: attachment.uri) }
        if let ref = attachment.inlineImage {
            return "inline:\(ref.sessionId)|\(ref.rowId)|\(ref.index)"
        }
        return "attachment:\(attachment.uri)"
    }
}

/// What fetching a picture's original came to.
enum ImageGalleryLoad: Sendable {
    case file(ImageGalleryFile)
    /// Larger than the phone downloads.
    case tooLarge
    case unavailable

    init(_ file: ImageGalleryFile?) {
        self = file.map(ImageGalleryLoad.file) ?? .unavailable
    }

    var file: ImageGalleryFile? {
        if case .file(let file) = self { return file }
        return nil
    }
}

/// A picture's original on disk.
struct ImageGalleryFile: Sendable {
    let url: URL
    /// A copy fetched for the viewer, removed when it closes. Nil for a file
    /// that stays (a local photo, or one kept on the phone).
    let ownedDirectory: URL?

    init(url: URL, ownedDirectory: URL?) {
        self.url = url
        self.ownedDirectory = ownedDirectory
    }

    init(_ download: DashboardDownloadedFile) {
        self.init(url: download.file, ownedDirectory: download.directory)
    }

    /// A gateway `data:` URL written to its own staging folder, decoded and
    /// written off the main actor.
    static func staged(dataURL: String, filename: String) async -> ImageGalleryFile? {
        await Task.detached(priority: .userInitiated) { () -> ImageGalleryFile? in
            guard let data = DataURLLimits.decodeBase64DataURL(dataURL),
                  let staged = MediaPreviewPresenter.stage(data: data, filename: filename) else { return nil }
            return ImageGalleryFile(url: staged.file, ownedDirectory: staged.directory)
        }.value
    }

    /// Bytes written to their own staging folder off the main actor.
    static func staged(data: Data, filename: String) async -> ImageGalleryFile? {
        await Task.detached(priority: .userInitiated) { () -> ImageGalleryFile? in
            guard let staged = MediaPreviewPresenter.stage(data: data, filename: filename) else { return nil }
            return ImageGalleryFile(url: staged.file, ownedDirectory: staged.directory)
        }.value
    }
}

/// The pictures around the one tapped: a chat's, a list's or a folder's.
/// Screens set it in the environment; a picture asks it for its neighbours
/// only when tapped, so building the list costs nothing while scrolling.
@MainActor
final class ImageGallerySource {
    private var makeItems: @MainActor () -> [ImageGalleryItem]

    init(_ makeItems: @escaping @MainActor () -> [ImageGalleryItem] = { [] }) {
        self.makeItems = makeItems
    }

    /// A screen holding its source as state points it at what it shows
    /// now. The source keeps its identity, so the pictures reading it from
    /// the environment never redraw for it.
    func update(_ makeItems: @escaping @MainActor () -> [ImageGalleryItem]) {
        self.makeItems = makeItems
    }

    func items() -> [ImageGalleryItem] { makeItems() }
}

private struct ImageGallerySourceKey: EnvironmentKey {
    static let defaultValue: ImageGallerySource? = nil
}

extension EnvironmentValues {
    /// The pictures a tapped picture pages through. Nil opens it alone.
    var imageGallery: ImageGallerySource? {
        get { self[ImageGallerySourceKey.self] }
        set { self[ImageGallerySourceKey.self] = newValue }
    }
}

enum ImageGallery {
    /// Where `item` sits in `items`, which holds each picture once (the
    /// first time it shows): `item` alone when the list doesn't have it.
    static func placing(_ item: ImageGalleryItem, in items: [ImageGalleryItem]) -> (items: [ImageGalleryItem], index: Int) {
        let unique = deduplicated(items)
        guard let index = unique.firstIndex(where: { $0.id == item.id }) else { return ([item], 0) }
        return (unique, index)
    }

    static func deduplicated(_ items: [ImageGalleryItem]) -> [ImageGalleryItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    /// Opens `item` among `source`'s pictures, showing `placeholder` (the
    /// row's own copy) until the original is in.
    @MainActor
    @discardableResult
    static func open(_ item: ImageGalleryItem, in source: ImageGallerySource?, placeholder: UIImage? = nil) -> Bool {
        let placed = placing(item, in: source?.items() ?? [])
        return MediaPreviewPresenter.shared.presentGallery(placed.items, startingAt: placed.index, placeholder: placeholder)
    }

    /// The step a finished drag ends in: whether it closes the viewer.
    /// Past a fifth of the screen, or flung, it closes; back towards the
    /// middle, it doesn't.
    static func dragCloses(translation: CGFloat, velocity: CGFloat, height: CGFloat) -> Bool {
        let distance = abs(translation)
        guard distance > 12 else { return false }
        let onward = velocity == 0 || (velocity > 0) == (translation > 0)
        if abs(velocity) > 900 { return onward }
        return distance > max(100, height * 0.2) && (onward || abs(velocity) < 200)
    }

    /// How faded the backdrop is as a picture is dragged `translation` away.
    static func backdropAlpha(translation: CGFloat, height: CGFloat) -> CGFloat {
        guard height > 0 else { return 1 }
        return max(0.25, 1 - abs(translation) / (height * 0.6))
    }

    /// The pages a viewer at `index` fetches: its own, then its neighbours.
    static func prefetchOrder(around index: Int, count: Int) -> [Int] {
        [index, index + 1, index - 1].filter { $0 >= 0 && $0 < count }
    }
}

// MARK: - Viewer

@MainActor
final class ImageGalleryViewController: UIViewController {
    private let items: [ImageGalleryItem]
    private var index: Int
    private let placeholder: UIImage?
    private let pager = UIPageViewController(
        transitionStyle: .scroll,
        navigationOrientation: .horizontal,
        options: [.interPageSpacing: 16]
    )
    private let backdrop = UIView()
    private let topBar = UIView()
    private let topShade = CAGradientLayer()
    private let doneButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let counterLabel = UILabel()
    private lazy var dismissPan = UIPanGestureRecognizer(target: self, action: #selector(dismissPanned(_:)))

    private var files: [Int: ImageGalleryFile] = [:]
    private var loads: [Int: Task<ImageGalleryLoad, Never>] = [:]
    /// Pages whose original couldn't be had, and whether it was too large.
    private var failed: [Int: Bool] = [:]
    /// Every page made, including the pager's neighbours ready offscreen,
    /// so a picture arriving reaches the page about to show it.
    private let pages = NSHashTable<ImageGalleryPageController>.weakObjects()
    private var closed = false
    private var chromeHidden = false
    /// Called once the viewer has closed (or was never shown).
    var onFinish: (() -> Void)?

    init(items: [ImageGalleryItem], startingAt index: Int, placeholder: UIImage?) {
        self.items = items
        self.index = min(max(index, 0), max(items.count - 1, 0))
        self.placeholder = placeholder
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersStatusBarHidden: Bool { chromeHidden }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { chromeHidden }
    override var canBecomeFirstResponder: Bool { true }

    override func loadView() {
        let root = ImageGalleryRootView()
        root.onEscape = { [weak self] in self?.close() }
        root.onPage = { [weak self] step in
            guard let self, self.items.indices.contains(self.index + step) else { return false }
            self.go(by: step)
            return true
        }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .clear
        backdrop.backgroundColor = .black
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdrop)

        addChild(pager)
        pager.view.frame = view.bounds
        pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pager.view.backgroundColor = .clear
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
        pager.dataSource = self
        pager.delegate = self
        pager.setViewControllers([page(at: index)], direction: .forward, animated: false)

        setUpTopBar()

        dismissPan.delegate = self
        // One finger: two are a pinch.
        dismissPan.maximumNumberOfTouches = 1
        // A trackpad's two-finger swipe closes it too, on an iPad or a Mac.
        dismissPan.allowedScrollTypesMask = .continuous
        view.addGestureRecognizer(dismissPan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleChrome))
        tap.delegate = self
        view.addGestureRecognizer(tap)

        showing(index)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { finish() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        topShade.frame = topBar.bounds
    }

    /// Removes every copy fetched for the viewer. Safe to call twice.
    func finish() {
        guard !closed else { return }
        closed = true
        loads.values.forEach { $0.cancel() }
        loads.removeAll()
        for file in files.values { MediaPreviewPresenter.removeDirectory(file.ownedDirectory) }
        files.removeAll()
        onFinish?()
        onFinish = nil
    }

    // MARK: Chrome

    private func setUpTopBar() {
        topShade.colors = [UIColor.black.withAlphaComponent(0.6).cgColor, UIColor.black.withAlphaComponent(0).cgColor]
        topBar.layer.addSublayer(topShade)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        var done = UIButton.Configuration.plain()
        done.title = AppLocalization.string("Done")
        done.baseForegroundColor = .white
        doneButton.configuration = done
        doneButton.titleLabel?.adjustsFontForContentSizeCategory = true
        doneButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        var share = UIButton.Configuration.plain()
        share.image = UIImage(systemName: "square.and.arrow.up")
        share.baseForegroundColor = .white
        shareButton.configuration = share
        shareButton.accessibilityLabel = AppLocalization.string("Share")
        shareButton.addTarget(self, action: #selector(shareCurrent), for: .touchUpInside)

        titleLabel.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.textAlignment = .center
        counterLabel.font = .preferredFont(forTextStyle: .caption1)
        counterLabel.adjustsFontForContentSizeCategory = true
        counterLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        counterLabel.textAlignment = .center

        let titles = UIStackView(arrangedSubviews: [titleLabel, counterLabel])
        titles.axis = .vertical
        titles.alignment = .center
        titles.spacing = 1
        titles.translatesAutoresizingMaskIntoConstraints = false
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        shareButton.translatesAutoresizingMaskIntoConstraints = false
        [doneButton, titles, shareButton].forEach(topBar.addSubview)
        doneButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        shareButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // As tall as its titles need at large text sizes, 56 pt at least.
            topBar.bottomAnchor.constraint(greaterThanOrEqualTo: guide.topAnchor, constant: 56),
            topBar.bottomAnchor.constraint(greaterThanOrEqualTo: titles.bottomAnchor, constant: 8),
            titles.topAnchor.constraint(greaterThanOrEqualTo: guide.topAnchor, constant: 4),
            doneButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 6),
            doneButton.centerYAnchor.constraint(equalTo: guide.topAnchor, constant: 26),
            shareButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -6),
            shareButton.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
            titles.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            {
                let centred = titles.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor)
                centred.priority = .defaultHigh
                return centred
            }(),
            titles.leadingAnchor.constraint(greaterThanOrEqualTo: doneButton.trailingAnchor, constant: 8),
            titles.trailingAnchor.constraint(lessThanOrEqualTo: shareButton.leadingAnchor, constant: -8),
        ])
    }

    @objc private func toggleChrome() {
        setChromeHidden(!chromeHidden)
    }

    private func setChromeHidden(_ hidden: Bool) {
        guard chromeHidden != hidden else { return }
        chromeHidden = hidden
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2) {
            self.topBar.alpha = hidden ? 0 : 1
            self.setNeedsStatusBarAppearanceUpdate()
        }
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    /// Updates the title and counter for page `index`, and fetches it and
    /// its neighbours.
    private func showing(_ newIndex: Int) {
        index = newIndex
        let item = items[newIndex]
        titleLabel.text = item.title
        counterLabel.text = items.count > 1 ? "\(newIndex + 1) / \(items.count)" : nil
        counterLabel.isHidden = items.count < 2
        shareButton.isEnabled = files[newIndex] != nil
        // A picture that failed (a dropped connection) is tried again each
        // time it is paged to; meanwhile it keeps its message.
        if failed[newIndex] == false { failed[newIndex] = nil }
        for prefetch in ImageGallery.prefetchOrder(around: newIndex, count: items.count) {
            startLoading(prefetch)
        }
    }

    @objc private func close() {
        guard !closed else { return }
        dismiss(animated: true)
    }

    @objc private func shareCurrent() {
        guard let file = files[index] else { return }
        let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = shareButton
            popover.sourceRect = shareButton.bounds
        }
        present(controller, animated: true)
    }

    // MARK: Pages

    private func page(at index: Int) -> ImageGalleryPageController {
        let page = ImageGalleryPageController(index: index, title: items[index].title)
        pages.add(page)
        if let file = files[index] {
            page.show(file: file)
        } else if let tooLarge = failed[index] {
            page.showFailure(tooLarge: tooLarge)
        } else if index == self.index, let placeholder {
            page.show(placeholder: placeholder)
        }
        return page
    }

    private var currentPage: ImageGalleryPageController? {
        pager.viewControllers?.first as? ImageGalleryPageController
    }

    private func madePages(_ index: Int) -> [ImageGalleryPageController] {
        pages.allObjects.filter { $0.index == index }
    }

    private func startLoading(_ index: Int) {
        guard !closed, files[index] == nil, loads[index] == nil, failed[index] == nil else { return }
        let load = items[index].load
        let task = Task { @MainActor in await load() }
        loads[index] = task
        Task { @MainActor [weak self] in
            let outcome = await task.value
            guard let self, !self.closed else {
                MediaPreviewPresenter.removeDirectory(outcome.file?.ownedDirectory)
                return
            }
            self.loads[index] = nil
            if let file = outcome.file {
                self.files[index] = file
                self.madePages(index).forEach { $0.show(file: file) }
                if index == self.index { self.shareButton.isEnabled = true }
            } else {
                let tooLarge: Bool
                if case .tooLarge = outcome { tooLarge = true } else { tooLarge = false }
                self.failed[index] = tooLarge
                self.madePages(index).forEach { $0.showFailure(tooLarge: tooLarge) }
            }
        }
    }

    private func go(by step: Int) {
        let target = index + step
        guard items.indices.contains(target) else { return }
        pager.setViewControllers([page(at: target)], direction: step > 0 ? .forward : .reverse,
                                 animated: !UIAccessibility.isReduceMotionEnabled)
        showing(target)
        UIAccessibility.post(notification: .pageScrolled, argument: counterLabel.text)
    }

    // MARK: Swipe down

    private var pagerScrollView: UIScrollView? {
        pager.view.subviews.compactMap { $0 as? UIScrollView }.first
    }

    @objc private func dismissPanned(_ pan: UIPanGestureRecognizer) {
        guard let page = currentPage else { return }
        let translation = pan.translation(in: view).y
        switch pan.state {
        case .began:
            // The pager stays put while the picture is dragged.
            pagerScrollView?.isScrollEnabled = false
            setChromeHidden(true)
        case .changed:
            page.dragOffset(CGPoint(x: pan.translation(in: view).x * 0.3, y: translation))
            backdrop.alpha = ImageGallery.backdropAlpha(translation: translation, height: view.bounds.height)
        case .ended, .cancelled, .failed:
            pagerScrollView?.isScrollEnabled = true
            let velocity = pan.velocity(in: view).y
            if pan.state == .ended,
               ImageGallery.dragCloses(translation: translation, velocity: velocity, height: view.bounds.height) {
                let distance = view.bounds.height * (translation < 0 ? -1 : 1)
                UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.22, delay: 0, options: .curveEaseOut) {
                    page.dragOffset(CGPoint(x: 0, y: distance))
                    self.backdrop.alpha = 0
                } completion: { _ in
                    self.dismiss(animated: false)
                }
            } else {
                UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.3, delay: 0,
                               usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                    page.dragOffset(.zero)
                    self.backdrop.alpha = 1
                }
                setChromeHidden(false)
            }
        default:
            break
        }
    }

    // MARK: Keys and VoiceOver

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(previousKey)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(nextKey)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close)),
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc private func previousKey() { go(by: -1) }
    @objc private func nextKey() { go(by: 1) }
}

/// The viewer's own view: VoiceOver's escape closes it, and a three-finger
/// swipe pages.
private final class ImageGalleryRootView: UIView {
    var onEscape: (() -> Void)?
    var onPage: ((Int) -> Bool)?

    override func accessibilityPerformEscape() -> Bool {
        onEscape?()
        return true
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        switch direction {
        case .left, .next: return onPage?(1) ?? false
        case .right, .previous: return onPage?(-1) ?? false
        default: return false
        }
    }
}

extension ImageGalleryViewController: UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? ImageGalleryPageController, page.index > 0 else { return nil }
        return self.page(at: page.index - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? ImageGalleryPageController, page.index + 1 < items.count else { return nil }
        return self.page(at: page.index + 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let page = currentPage else { return }
        previousViewControllers.compactMap { $0 as? ImageGalleryPageController }.forEach { $0.resetZoom() }
        showing(page.index)
    }
}

extension ImageGalleryViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPan else {
            // A tap on the bar's buttons is theirs.
            let point = gestureRecognizer.location(in: topBar)
            return chromeHidden || !topBar.bounds.contains(point)
        }
        // Only an up or down drag of a picture that isn't zoomed in: a
        // zoomed one pans, and a sideways drag pages.
        guard currentPage?.isZoomedIn == false else { return false }
        let velocity = dismissPan.velocity(in: view)
        return abs(velocity.y) > abs(velocity.x) * 1.2
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // The pager's and the picture's own pans run beside the drag; the
        // pager is held still while it lasts.
        gestureRecognizer === dismissPan && other is UIPanGestureRecognizer
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        // A single tap shows or hides the bar only once it isn't a double tap.
        guard gestureRecognizer !== dismissPan, let tap = other as? UITapGestureRecognizer else { return false }
        return tap.numberOfTapsRequired == 2
    }
}

// MARK: - One page

@MainActor
final class ImageGalleryPageController: UIViewController, UIScrollViewDelegate {
    let index: Int
    private let pictureTitle: String
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let failureLabel = UILabel()
    private var shownFile: URL?
    private var decodeTask: Task<Void, Never>?

    init(index: Int, title: String) {
        self.index = index
        self.pictureTitle = title
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isZoomedIn: Bool { scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = pictureTitle
        imageView.accessibilityTraits = .image
        scrollView.addSubview(imageView)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        failureLabel.text = AppLocalization.string("Image unavailable")
        failureLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        failureLabel.font = .preferredFont(forTextStyle: .body)
        failureLabel.adjustsFontForContentSizeCategory = true
        failureLabel.isHidden = true
        failureLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(failureLabel)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            failureLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            failureLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        if imageView.image == nil, failureLabel.isHidden { spinner.startAnimating() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !isZoomedIn { layoutPicture() }
    }

    /// The picture at its fitted size, centred; zooming scales it from there.
    private func layoutPicture() {
        let bounds = scrollView.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        var fitted = bounds
        if let size = imageView.image?.size, size.width > 0, size.height > 0 {
            let fit = min(bounds.width / size.width, bounds.height / size.height)
            fitted = CGSize(width: size.width * fit, height: size.height * fit)
        }
        imageView.frame = CGRect(origin: .zero, size: fitted)
        scrollView.contentSize = fitted
        centrePicture()
    }

    private func centrePicture() {
        let bounds = scrollView.bounds.size
        let content = scrollView.contentSize
        let x = max(0, (bounds.width - content.width) / 2)
        let y = max(0, (bounds.height - content.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func show(placeholder: UIImage) {
        loadViewIfNeeded()
        guard shownFile == nil else { return }
        imageView.image = placeholder
        layoutPicture()
        spinner.startAnimating()
    }

    func show(file: ImageGalleryFile) {
        loadViewIfNeeded()
        guard shownFile != file.url else { return }
        shownFile = file.url
        failureLabel.isHidden = true
        if imageView.image == nil { spinner.startAnimating() }
        let url = file.url
        // Sharp at the most a pinch zooms, within what a phone decodes.
        let longest = max(view.bounds.width, view.bounds.height, 400) * max(traitCollection.displayScale, 2)
        let maxPixelSize = min(longest * scrollView.maximumZoomScale / 2, 4096)
        decodeTask?.cancel()
        decodeTask = Task { @MainActor [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                ImageGalleryDecoder.image(at: url, maxPixelSize: maxPixelSize)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.spinner.stopAnimating()
            if let image {
                self.imageView.image = image
                if !self.isZoomedIn { self.layoutPicture() }
            } else if self.imageView.image == nil {
                self.failureLabel.isHidden = false
            }
        }
    }

    func showFailure(tooLarge: Bool = false) {
        loadViewIfNeeded()
        spinner.stopAnimating()
        failureLabel.text = tooLarge
            ? AppLocalization.string("Too large to open on this phone")
            : AppLocalization.string("Image unavailable")
        // The row's own copy stays if the original can't be had.
        failureLabel.isHidden = imageView.image != nil
    }

    func resetZoom() {
        guard isViewLoaded else { return }
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
    }

    /// Moves the picture with a swipe down (or back to `.zero`).
    func dragOffset(_ offset: CGPoint) {
        guard isViewLoaded else { return }
        let scale = 1 - min(abs(offset.y) / max(view.bounds.height, 1), 1) * 0.25
        scrollView.transform = CGAffineTransform(translationX: offset.x, y: offset.y).scaledBy(x: scale, y: scale)
    }

    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        if isZoomedIn {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return
        }
        let point = tap.location(in: imageView)
        let scale = min(scrollView.maximumZoomScale, 2.5)
        let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
        scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                   width: size.width, height: size.height), animated: true)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centrePicture()
    }
}

/// Decodes a picture for the viewer, off the main actor.
enum ImageGalleryDecoder {
    /// Frames an animated picture keeps, and the most its frames take
    /// decoded together: the pager holds three pages at once.
    static let maxAnimatedFrames = 120
    static let animatedMaxBytes = 32 * 1024 * 1024

    static func image(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        if let animated = animatedImage(data) { return animated }
        guard case .image(let image) = BoundedRemoteImage.decode(data, maxPixelSize: maxPixelSize) else { return nil }
        return image
    }

    /// A GIF or animated PNG, as Quick Look played it; nil for a still.
    static func animatedImage(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        let kept = min(count, maxAnimatedFrames)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: animatedMaxPixelSize(source, frames: kept),
        ]
        var frames: [UIImage] = []
        var duration: Double = 0
        for frame in 0..<kept {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, frame, options as CFDictionary) else { continue }
            frames.append(UIImage(cgImage: image))
            duration += frameDuration(source, frame)
        }
        guard frames.count > 1 else { return frames.first }
        return UIImage.animatedImage(with: frames, duration: duration)
    }

    /// The longer side each of `frames` frames is drawn at, so together
    /// they stay within `animatedMaxBytes`, and never above 1,024 px.
    static func animatedMaxPixelSize(_ source: CGImageSource, frames: Int) -> CGFloat {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = CGFloat((properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 1024)
        let height = CGFloat((properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 1024)
        return animatedMaxPixelSize(width: width, height: height, frames: frames)
    }

    static func animatedMaxPixelSize(width: CGFloat, height: CGFloat, frames: Int) -> CGFloat {
        let longest = max(width, height, 1)
        let pixels = max(width * height, 1)
        let budget = CGFloat(animatedMaxBytes) / 4 / CGFloat(max(frames, 1))
        let scale = min(1, (budget / pixels).squareRoot())
        return max(64, min(1024, (longest * scale).rounded(.down)))
    }

    private static func frameDuration(_ source: CGImageSource, _ index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let dictionary = (properties?[kCGImagePropertyGIFDictionary] ?? properties?[kCGImagePropertyPNGDictionary]) as? [CFString: Any]
        let delay = (dictionary?[kCGImagePropertyGIFUnclampedDelayTime] ?? dictionary?[kCGImagePropertyGIFDelayTime]
            ?? dictionary?[kCGImagePropertyAPNGUnclampedDelayTime] ?? dictionary?[kCGImagePropertyAPNGDelayTime]) as? Double
        // Browsers play a delay under 20 ms at 100 ms.
        guard let delay, delay >= 0.02 else { return 0.1 }
        return delay
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}
