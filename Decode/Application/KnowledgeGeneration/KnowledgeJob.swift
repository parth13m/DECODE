// KnowledgeJob.swift — Knowledge Generation Runtime
//
// The reusable job protocol and supporting types for knowledge generation.
//
// Each job declares what it produces, what it requires, and how it should
// be managed. The planner decides when to run jobs. The runtime executes them.
// The artifact store persists their outputs.
//
// Jobs declare a required CAPABILITY, not a tier. The capability resolver
// maps capabilities to tiers at wiring time, allowing deterministic
// implementations to replace AI without changing job declarations.

import Foundation

// MARK: - Job Protocol

/// Declares a kind of knowledge that the Knowledge Generation Runtime can produce.
///
/// Implementations define:
/// - **Identity**: unique identifier and display name
/// - **Requirements**: capability needed, scope, priority
/// - **Lifecycle**: invalidation trigger, persistence policy, retry behavior
/// - **Execution**: cache check + compute logic
///
/// Jobs are registered once at startup. The planner evaluates them against
/// current state to determine what work is needed. The runtime handles
/// scheduling and execution.
///
/// ## Thread Safety
/// Job descriptors must be `Sendable`. Execution happens off the main actor.
/// Jobs receive their input and capability executor as parameters — they
/// do not hold mutable state.
protocol KnowledgeJobDescriptor: Sendable {

    /// Unique identifier for this job kind (e.g., "file-understanding").
    /// Must be stable across app versions — used as cache key component.
    static var identifier: String { get }

    /// Human-readable name for telemetry and debugging.
    static var displayName: String { get }

    /// The capability this job requires.
    /// The capability resolver maps this to a tier and executor.
    var requiredCapability: KnowledgeCapability { get }

    /// What scope this job operates on.
    var scope: KnowledgeJobScope { get }

    /// What triggers invalidation of this job's cached output.
    var invalidationTrigger: KnowledgeInvalidationTrigger { get }

    /// How the output should be persisted.
    var persistencePolicy: KnowledgePersistencePolicy { get }

    /// Relative priority. Lower values = higher priority.
    /// Used by the runtime for queue ordering.
    var priority: Int { get }

    /// Maximum concurrent executions for this job kind.
    /// The runtime respects this alongside the global concurrency limit.
    var maxConcurrency: Int { get }

    /// Whether and how this job retries on transient failure.
    var retryPolicy: KnowledgeRetryPolicy { get }

    /// Checks whether this job needs to run for a given input.
    ///
    /// The planner calls this to determine if cached output exists
    /// and is still valid. Returns `true` if execution is needed.
    ///
    /// - Parameters:
    ///   - input: The job input (file path, hash, intelligence, etc.)
    ///   - store: Read-only access to the artifact store for cache checks.
    /// - Returns: `true` if the job should execute, `false` if cached output is valid.
    func needsExecution(
        input: KnowledgeJobInput,
        store: KnowledgeArtifactStoreReading
    ) -> Bool

    /// Executes the job and returns the result.
    ///
    /// For deterministic jobs, `capabilityExecutor` is `nil` — the job
    /// computes the result directly. For AI-tier jobs, the executor
    /// routes to the appropriate provider.
    ///
    /// - Parameters:
    ///   - input: The job input with all required data.
    ///   - capabilityExecutor: AI execution closure, or `nil` for deterministic jobs.
    /// - Returns: The job output, ready for persistence.
    /// - Throws: On execution failure (network, parsing, etc.)
    func execute(
        input: KnowledgeJobInput,
        capabilityExecutor: CapabilityExecutor?
    ) async throws -> KnowledgeJobOutput
}

// MARK: - Job Scope

/// The scope at which a job operates.
enum KnowledgeJobScope: String, Sendable, Codable {
    /// Per-file job (e.g., file understanding, file summary).
    case file
    /// Per-module job (e.g., module summary).
    case module
    /// Per-project/system job (e.g., architecture summary).
    case system
}

// MARK: - Invalidation Trigger

/// What triggers invalidation of a job's cached output.
enum KnowledgeInvalidationTrigger: String, Sendable, Codable {
    /// Invalidate when the file's content hash changes.
    case fileChange
    /// Invalidate when any file in the module changes.
    case moduleChange
    /// Invalidate when the module graph or system structure changes.
    case projectChange
    /// Only invalidate on explicit request.
    case manual
}

// MARK: - Persistence Policy

/// How a job's output should be persisted.
enum KnowledgePersistencePolicy: String, Sendable, Codable {
    /// Persist to disk, survives app restart.
    case disk
    /// In-memory cache only, lost on restart.
    case memory
    /// Do not cache — always recompute.
    case none
}

// MARK: - Retry Policy

/// Whether and how a job retries on failure.
enum KnowledgeRetryPolicy: Sendable, Equatable {
    /// No retry — failure is final.
    case none
    /// Retry up to `maxAttempts` times with `backoff` seconds between attempts.
    case retry(maxAttempts: Int, backoff: TimeInterval)
}

// MARK: - Job Input

/// Input data provided to a job for execution.
///
/// Contains all context needed by any job scope. File-scoped jobs
/// use `filePath`, `fileHash`, and `fileIntelligence`. Module-scoped
/// jobs will use `moduleName` (future). System-scoped jobs use
/// `workspaceId` (future).
struct KnowledgeJobInput: Sendable {
    /// The source file path (for file-scoped jobs).
    let filePath: String

    /// The content hash of the file (for cache validation).
    let fileHash: String

    /// Parsed file intelligence (entities, relationships, imports).
    /// `nil` when intelligence is not available.
    let fileIntelligence: FileIntelligence?

    /// The workspace that owns this file.
    let workspaceId: UUID
}

// MARK: - Job Output

/// The output of a job execution, ready for persistence.
struct KnowledgeJobOutput: Sendable {
    /// Which job produced this output.
    let jobIdentifier: String

    /// The cache key for storage and retrieval.
    let key: KnowledgeCacheKey

    /// The encoded result data. Jobs encode their domain-specific
    /// output type and store it as opaque `Data`.
    let data: Data

    /// When this output was computed.
    let computedAt: Date

    /// Which capability tier actually produced this output.
    /// Enables telemetry: "70% of safety layers are now deterministic."
    let actualTier: KnowledgeCapabilityTier
}

// MARK: - Cache Key

/// Uniquely identifies a cached knowledge artifact.
///
/// The combination of (jobIdentifier, filePath, contentHash) ensures
/// that stale artifacts are never served — a changed file produces
/// a different key.
struct KnowledgeCacheKey: Hashable, Codable, Sendable {
    /// Which job produced this artifact.
    let jobIdentifier: String

    /// The file path this artifact is about.
    let filePath: String

    /// The content hash when this artifact was computed.
    let contentHash: String
}

// MARK: - Work Item

/// A scheduled unit of work for the Knowledge Generation Runtime.
///
/// Created by the planner, enqueued into the runtime. Contains all
/// information needed to execute and persist a job.
struct KnowledgeWorkItem: Identifiable, Sendable {
    /// Unique identifier for this work item instance.
    let id: UUID

    /// Which job to execute.
    let jobIdentifier: String

    /// The input data for the job.
    let input: KnowledgeJobInput

    /// Resolved capability tier for this execution.
    let resolvedTier: KnowledgeCapabilityTier

    /// Priority (lower = higher priority).
    let priority: Int

    /// The retry policy inherited from the job descriptor.
    let retryPolicy: KnowledgeRetryPolicy

    /// The persistence policy inherited from the job descriptor.
    let persistencePolicy: KnowledgePersistencePolicy

    /// Current execution state.
    var state: KnowledgeWorkItemState

    /// Number of attempts made so far.
    var attemptCount: Int

    init(
        id: UUID = UUID(),
        jobIdentifier: String,
        input: KnowledgeJobInput,
        resolvedTier: KnowledgeCapabilityTier,
        priority: Int,
        retryPolicy: KnowledgeRetryPolicy = .none,
        persistencePolicy: KnowledgePersistencePolicy = .disk,
        state: KnowledgeWorkItemState = .pending,
        attemptCount: Int = 0
    ) {
        self.id = id
        self.jobIdentifier = jobIdentifier
        self.input = input
        self.resolvedTier = resolvedTier
        self.priority = priority
        self.retryPolicy = retryPolicy
        self.persistencePolicy = persistencePolicy
        self.state = state
        self.attemptCount = attemptCount
    }
}

// MARK: - Work Item State

/// The execution state of a work item.
enum KnowledgeWorkItemState: String, Sendable, Equatable {
    /// Waiting in the queue.
    case pending
    /// Currently executing.
    case executing
    /// Completed successfully.
    case completed
    /// Failed after exhausting retries.
    case failed
    /// Cancelled (workspace closed, app shutting down).
    case cancelled
    /// Deferred by policy (conditions not met).
    case deferred
}
