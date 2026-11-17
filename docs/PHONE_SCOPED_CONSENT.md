# Scoped task consent on the phone

**DRAFT SOURCE CANDIDATE — Swift compilation/tests, rendered accessibility UI and
physical paired-phone validation are UNEXECUTED and block readiness.**

Paired notifier source: [hermes-conduit-notifier](https://github.com/kaishi00/hermes-conduit-notifier),
`docs/phone-scoped-consent.md` (protocol/security contract), `phone_consent.py`
and `dashboard/api/phone_consent.py`. Link actual draft PRs at publication; none
are assumed here. The capability is `phone-scoped-consent-v1`.

Bot Work has a dedicated typed scoped-task section, separate from native command
approvals and model-composed cards. It displays the exact task, scope and complete
immutable snapshot, verifies the SHA-256 of the server's canonical snapshot bytes,
and signs only a fresh server challenge bound to the displayed owner, profile,
pairing, installation, enrollment, grant, digest and explicit tap action. No chat
follow-up or ordinary proposal/tap can authorize a task.

The owner first explicitly enrolls this phone's **separate** Ed25519 signing key
through the revalidated owner session. It is saved per dashboard/profile with
WhenUnlockedThisDeviceOnly accessibility; only the public key/signature cross the
captured dashboard bridge. Notification encryption is not consent, its key is
not reused, and enrollment is never automatic. Revoking or replacing the device
ends its grants and requests native interruption; unconfirmed interruption is
shown as unconfirmed. Pairing replacement/removal also invalidates it server-side.

Approval authority is never stored in KeptAnswers. Offline, background, failed
read, unknown capability, wrong device key/pairing and dashboard/profile/chat
switches disable/clear authority. Reconnect rereads; uncertain writes are not
retried or queued. Native approvals and the notifier dashboard remain unchanged.
Scope is task intent, not an operating-system sandbox. Watch, CarPlay, voice,
linked rooms and other installations have no new approval control.

## Checks

Linux can run the contribution checks in CONTRIBUTING, with the feature-map
checker using `--notifier-root` against the paired source checkout. The default
upstream path check requires the new notifier files to reach main first; the
Checked lines need the actual linked draft PR numbers before publication.
Localization coverage includes every shipped language; translations are draft
contribution text and still need native-language/security wording review.

The added `PhoneConsentTests.swift` extends BotModeTests and uses the same public
wire fixture as the notifier: exact challenge/signature bytes and Unicode snapshot
digest, strict decoding, offline/unknown capability, switches, reconnect and no
retry. These are **unexecuted Swift source tests**, not Linux runtime evidence.
The JSON fixture is a normal test-bundle resource under ConduitTests/Fixtures.

Before readiness on an authorized macOS/Xcode lane:

1. Generate/compile the existing project with normal contributor settings and
   execute BotModeTests, including the new phone consent cases and existing native
   approval regressions. Do not change signing/accounts to work around failures.
2. Render full long/Unicode snapshots at compact and accessibility text sizes;
   scroll to every field, inspect the accessibility tree and test VoiceOver.
   Stable IDs start `phoneConsent.section`, `.snapshot.<grant>`, `.approve.<grant>`,
   `.decline.<grant>`, `.stop.<grant>`, `.enroll`, `.revokeDevice`, `.refresh`.
3. Against a disposable installation and paired phone, explicitly enroll, approve
   once, decline, revoke/stop and re-pair; try another phone/profile, stale snapshot
   and challenge, double tap, offline/background/reconnect, lost acknowledgement,
   and dashboard/profile/chat switches while a challenge is pending. Confirm no
   automatic replay and unchanged dashboard/native command approvals.

No macOS use, build/sign/install/account changes, live activation or restart was
performed for this source candidate. Publication is by the coordinator only,
after independent security/functional source review, as linked draft fork PRs.
