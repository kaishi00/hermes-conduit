# Agent Collaboration Guidelines

- The lead agent orchestrates the task and keeps the final result reviewable.
- Delegate implementation and analysis judiciously. Use the cheapest capable model: Codex Spark for trivial work when available, otherwise Luna; Luna for routine bounded work; Terra for everyday coding; and Sol for complex code or protocol review. Do not spawn an agent when orchestration overhead exceeds the work, and do not require every task to use every model.
- Keep delegated work narrow, with disjoint file ownership wherever practical. State ownership before editing and avoid overlapping changes.
- The user's standing authorization includes economical delegation and the normal implementation steps needed to complete an authorized task; agents do not need to ask again to delegate. If the lead agent intends to undertake major new work itself, it should run that proposal by the user first and explain why, unless the work is already explicitly authorized. Already authorized steps may continue.
- Use the Xcode MCP for build and test validation. Prefer focused tests that cover the changed behavior, then run broader checks only when justified. Keep patches small and reviewable, with focused commits when commits are requested or appropriate.
- Do not push upstream or publish changes without an explicit user request.

## Repository Notes

- Conduit connects to the native Hermes dashboard at `/api/ws` (default port `9119`), not the WebUI. Verify protocol fields and errors against the pinned primary Hermes source when a gateway contract is involved.
- Hermes approval request IDs identify individual approval prompts; session IDs identify conversations. Preserve legacy no-ID decoding and keep async client, profile, and session ownership fences around responses.
- Run `xcodegen generate` to generate the Xcode project from `project.yml`; do not hand-edit the generated project. Use the Xcode MCP to discover workspace and test IDs, then run focused regression classes.
- Presentation-cache tests should use isolated `UserDefaults` suites, never shared fixture storage. Keep network-transient failures retryable and treat only verified session-not-found responses as definitive deletion evidence.
- Preserve user work in a dirty tree. Remove only proven build-generated `.xcstrings` changes after validation; do not blanket-revert localization files.
