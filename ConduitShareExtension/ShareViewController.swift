//
//  ShareViewController.swift
//  ConduitShareExtension
//
//  Conduit's entry in the share sheet (#812). It reads what was shared,
//  lets the user pick a recent chat or a new one, and leaves a draft in the
//  App Group for Conduit to show in that chat's composer. It never talks to
//  Hermes and holds no credentials.
//
//  A share extension can't open its app: NSExtensionContext.open(_:) is
//  only honoured for Today and iMessage extensions, and UIApplication isn't
//  available here. So the draft waits for Conduit's next time on screen,
//  the sheet says so, and, when Conduit may notify, a notification takes
//  the user there in one tap.
//

import SwiftUI
import UIKit
import UserNotifications

final class ShareViewController: UIViewController {
    private var model: ShareDraftModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareDraftModel(
            snapshot: WidgetSnapshotStore.production?.read(),
            inbox: ShareDraftInbox.production,
            composerLimitMegabytes: ShareDraftSettings.composerLimit()
        )
        model.onFinish = { [weak self] outcome in self?.finish(outcome) }
        self.model = model
        let host = UIHostingController(rootView: ShareDraftSheet(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { await model.collect(items) }
    }

    private func finish(_ outcome: ShareDraftModel.Outcome) {
        switch outcome {
        case .saved:
            extensionContext?.completeRequest(returningItems: nil)
        case .cancelled:
            extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
    }
}
