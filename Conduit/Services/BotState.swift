import Foundation
import Combine

/// One bot's own state (a Hermes profile on the dashboard): its scheduled
/// jobs and its skills, toolsets and tools first, then its chat list,
/// projects, pins and settings, a slice at a time (the plan: "Combining
/// Hermes instances in Conduit", stage 1, the cut list's bot rows). As with
/// `ChatState`, there is one, `AppState.shownBot`, for the bot on screen,
/// never replaced: a profile switch refills it as AppState's own properties
/// were refilled. Views and tests still read it through AppState's
/// forwarders, and AppState publishes its changes as its own.
@MainActor
final class BotState: ObservableObject {

    // MARK: Scheduled jobs

    @Published var cronJobs: [CronJob] = []
    @Published var cronRuns: [CronRun] = []
    /// The job `cronRuns` is the history of (#1707).
    var cronRunsJobID: String?
    /// The newest Run history read, so an older one that lands last is dropped.
    var cronRunsLoad = 0
    /// Whether `cronRuns` holds an answer for `cronRunsJobID` yet, so the
    /// sheet says a job hasn't run only once it knows.
    @Published var cronRunsLoaded = false
    /// Why the open job's history couldn't be read, before any answer came:
    /// the sheet says so rather than that the job hasn't run.
    @Published var cronRunsFailure: String?
    @Published var cronJobsLoading = false
    @Published var cronJobActionID: String?
    /// Bumped by a job delete so a list load that started before it can't
    /// bring the deleted job back.
    var cronJobsGeneration = 0
    /// The read in flight and the list generation, profile and connection
    /// it is for. A second ask for the same list joins it.
    var cronJobsRead: (owner: String, token: UUID, task: Task<Void, Never>)?
    /// Cron jobs whose runs don't notify (AppState+CronNotifications), for
    /// the dashboard and profile in `cronMutedJobsKey`.
    @Published var cronMutedJobIDs: Set<String> = []
    @Published var cronMutedJobsKey: String?
    /// Cron jobs delivered to a Bot Chat whose report starts the bot's turn
    /// (the rest just show it), read with `cronMutedJobIDs` and keyed by
    /// the same `cronMutedJobsKey`.
    @Published var cronActingJobIDs: Set<String> = []
    /// Whether the host's Hermes shows a Bot Chat job's report without a
    /// turn (the plugin's `shows_reports`), for `cronMutedJobsKey`.
    @Published var cronShowsBotChatReports = false
    @Published var cronNotificationsChangingJobID: String?
    /// A notification read asked for while a save was in flight. The
    /// capability report can land then, so the read is repeated when the
    /// save ends instead of being dropped.
    var cronNotificationsReadDeferred = false
    /// Moves with every save, so a refresh that started before one drops its answer.
    var cronNotificationsGeneration = 0

    // MARK: Skills, toolsets and tools

    @Published var skills: [CapabilitySkill] = []
    @Published var toolsets: [CapabilityToolset] = []
    /// The active profile's tools catalog, for step rows (`ChatStepLabel`).
    @Published var toolCatalog = ToolCatalog()
    /// Whose catalog `toolCatalog` is (dashboard and profile), and the
    /// catalogs Hermes already sent this run, or is sending now.
    var toolCatalogOwner: String?
    var toolCatalogFetched: Set<String> = []
    var toolCatalogLoading: Set<String> = []
    /// The dashboard, bridge and profile the installed skills/toolsets were
    /// read from. Rows are only presentable, and their switches only act,
    /// while this equals `currentCapabilitiesOwner`: two dashboards can have
    /// a profile of the same name.
    @Published var capabilitiesOwner: CapabilitySnapshotOwner?
    /// The installed skills and toolsets shown are the ones kept from
    /// Hermes' last answer (#1533), drawn until it answers again.
    @Published var capabilitiesAreKept = false
    /// Monotonic request token for capability loads; older requests can never
    /// commit over newer ones (protects the A -> B -> A race).
    var capabilityLoadGeneration: UInt64 = 0
    /// Skill and toolset switches, written in the order flipped.
    let capabilityToggleWrites = CapabilityToggleWrites()
    @Published var mcpServers: [CapabilityMcpServer] = []
}
