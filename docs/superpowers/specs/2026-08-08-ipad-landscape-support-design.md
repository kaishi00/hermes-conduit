# iPad Landscape Support Design

## Goal

Allow Conduit to rotate between portrait and landscape on iPad while keeping
iPhone portrait-only. This is an orientation declaration change, not a
landscape-specific redesign of the chat UI.

## Shipped behavior

The app declares `UIInterfaceOrientationPortrait` in the universal
`UISupportedInterfaceOrientations` key, so iPhone remains portrait-only. The
`UISupportedInterfaceOrientations~ipad` override contains portrait,
portrait-upside-down, landscape-left, and landscape-right. The deprecated
`UIRequiresFullScreen` key is absent so iPadOS can resize the scene normally.

## Chosen approach

Use idiom-specific keys in the app's explicit `Conduit/Info.plist`:

- Keep `UISupportedInterfaceOrientations` as portrait-only. iPhone continues to
  accept only portrait.
- Add `UISupportedInterfaceOrientations~ipad` containing portrait,
  portrait-upside-down, landscape-left, and landscape-right. iPad then rotates
  automatically between all four orientations.
- Omit `UIRequiresFullScreen` so the app uses the iPadOS 26 dynamic windowing
  behavior.

This keeps platform policy declarative, avoids runtime orientation APIs, and
does not introduce device checks or orientation state into SwiftUI views.

## Alternatives considered

1. Runtime orientation selection in the app delegate. Rejected: more code and
   lifecycle timing risk for a static platform policy.
2. Xcode build-setting-only configuration. Rejected: less explicit than the
   existing checked-in plist and harder to test as the shipped bundle
   contract.

## Testing and acceptance criteria

- Add a bundle-level regression test that verifies the base orientation array
  contains only portrait.
- Verify the iPad-specific array contains portrait, portrait-upside-down,
  landscape-left, and landscape-right.
- Verify `UIRequiresFullScreen` is absent from the shipped app plist.
- Regenerate the Xcode project and run the complete iOS simulator test suite.
- Confirm the generated app plist preserves the two orientation arrays.
- No production SwiftUI view or iPhone behavior changes are required.
