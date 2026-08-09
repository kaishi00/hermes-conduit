# Image Paste Provider Support Design

## Goal

Restore image insertion from the iOS keyboard's “Photo to paste” action. The
image should enter the existing composer attachment flow and appear as a
pending image attachment before the user sends the message. This addresses
GitHub issue #26.

## Current behavior and root cause

`ImagePasteTextView` overrides the legacy `paste(_:)` method and inspects
`UIPasteboard.general` for image data. UIKit also exposes a separate
item-provider paste path, `paste(itemProviders:)`. The iOS 27 keyboard action
uses that newer path, so the current override does not invoke the existing
`onPastedImage` callback.

The rest of the flow is already implemented: `ComposerBar` persists the image
data as a temporary attachment, displays it in the composer, and submits it
through the existing image attachment RPC. No backend or attachment-model
changes are needed.

## Chosen approach

Extend `ImagePasteTextView` with an item-provider paste override:

- Detect image-capable `NSItemProvider` values using the existing Uniform Type
  Identifiers APIs.
- Load the provider's image data asynchronously and deliver it to
  `onPastedImage` on the main thread.
- Preserve the current `paste(_:)` implementation for older paste behavior.
- Delegate non-image item providers to UIKit's default implementation so text
  paste continues to work.

The implementation will handle the first image provider supplied by the
keyboard action, matching the current single-image user interaction while
avoiding unrelated attachment-model changes.

## Alternatives considered

1. Poll `UIPasteboard` after the keyboard action. Rejected: timing-dependent
   and does not address the item-provider API that UIKit is using.
2. Replace the text view with a full `UITextPasteDelegate` implementation.
   Rejected for this fix: it is broader than necessary and would risk changing
   ordinary text-paste behavior.
3. Add item-provider handling alongside the existing override. Chosen: smallest
   compatibility fix, preserves existing behavior, and isolates the change to
   the composer bridge.

## Testing and acceptance criteria

- Add a regression test that supplies an image `NSItemProvider` to
  `ImagePasteTextView.paste(itemProviders:)` and verifies the image callback
  receives non-empty data.
- Verify a non-image provider still follows the normal text-paste fallback.
- Run the focused test and the complete iOS test suite/build checks available in
  the repository.
- Validate the “Photo to paste” action on the user's physical iOS 27 device.
- Open a draft PR linked to issue #26 with the root cause, behavior change, and
  verification results.
