// KnowledgeGenerationRuntime.swift — Knowledge Generation Runtime
//
// Schedules and executes knowledge generation work items.
//
// The runtime is the execution engine. It manages:
// - A priority queue of pending work items
// - Concurrency control (global + per-job limits)
// - Cancellation (workspace closed → cancel workspace work)
// - Retry with backoff
// - Progress reporting (observable state)
//
// The runtime operates with zero registered jobs — it simply idles.
// Jobs are registered in the planner; the runtime receives work items.

import Foundation

// MARK: - Runtime State

/// The observable state of the Knowledge Generation Runtime.
enum KnowledgeRuntimeState: Sendable, Equatable {
    /// No work pending or executing.
    case idle
    /// Work is being generated.
    case generating(completed: Int, total: Int)
    /// All queued work has finished.
    case complete(generated: Int, cached: Int)
}

// MARK: - Runtime Error

/// Errors specific to the Knowledge Generation Runtime.
enum KnowledgeGenerationError: Error, Sendable {
    /// No AI provider is available for an AI-tier job.
    case noProvider
    /// The job is not registered in the planner.
    case unknownJob(String)
    /// The work item was cancelled before execution.
    case cancelled
    /// The job execution failed.
    case executionFailed(String)
}

// MARK: - Telemetry

/// Telemetry record for a completed job execution.
struct KnowledgeJobTelemetry: Sendable {
    let jobIdentifier: String
    let filePath: String
    let tier: KnowledgeCapabilityTier
    let durationMs: Int
    let success: Bool
    let cacheHit: Bool
    let attemptNumber: Int
}

// MARK: - Knowledge Generation Runtime

/// Schedules and executes knowledge generation work items.
///
/// Receives work items from the planner, executes them respecting
/// concurrency limits, persists results to the artifact store,
/// and reports progress.
///
/// ## Concurrency Model
/// - Global limit: max 2 concurrent AI-tier jobs
/// - Deterministic jobs (Tier 0): no concurrency limit
/// - Per-job-kind limits respected within the global limit
/// - Queue drained opportunistically after each completion
///
/// ## Cancellation
/// - `cancelWorkspace(id)`: cancels all work for a workspace
/// - `cancelAll()`: graceful shutdown, cancels everything
///
/// ## Thread Safety
/// `@MainActor` isolated. Execution tasks run detached but
/// deliver results back to the main actor.
@Observable
@MainActor
final class KnowledgeGenerationRuntime {

    // MARK: - Configuration

    /// Maximum concurrent AI-tier executions.
    static let globalMaxConcurrency = 2

    // MARK: - Observable State

    /// Current runtime state, observable by UI.
    private(set) var state: KnowledgeRuntimeState = .idle

    // MARK: - Internal State

    /// Pending work items, sorted by priority.
    private var queue: [KnowledgeWorkItem] = []

    /// Currently executing tasks, keyed by work item ID.
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    /// Completed + failed counts for progress reporting.
    private var completedCount: Int = 0
    private var totalEnqueued: Int = 0
    private var cachedCount: Int = 0

    /// Telemetry records from completed jobs.
    private(set) var telemetry: [KnowledgeJobTelemetry] = []

    // MARK: - Dependencies

    /// Registered job descriptors, keyed by identifier.
    /// Shared with the planner — the runtime needs descriptors to execute.
    private var jobDescriptors: [String: any KnowledgeJobDescriptor] = [:]

    /// The capability resolver for looking up executors.
    private let resolver: KnowledgeCapabilityResolver

    /// The artifact store for persisting results.
    private let store: KnowledgeArtifactStore

    /// Callback fired after each successful artifact is persisted.
    /// Parameters: (workspaceId, filePath, jobIdentifier, artifactData).
    /// Used by AppDependencies to hydrate FileIntelligence with generated enrichment.
    var onArtifactGenerated: ((_ workspaceId: UUID, _ filePath: String, _ jobIdentifier: String, _ data: Data) -> Void)?

    // MARK: - Init

    /// Creates the runtime with its dependencies.
    ///
    /// - Parameters:
    ///   - resolver: Maps capabilities to tiers and executors.
    ///   - store: Persists completed artifacts.
    init(
        resolver: KnowledgeCapabilityResolver,
        store: KnowledgeArtifactStore
    ) {
        self.resolver = resolver
        self.store = store
    }

    // MARK: - Job Registration

    /// Register a job descriptor so the runtime can execute it.
    ///
    /// Must be called for each job type before work items referencing
    /// that job are enqueued.
    func registerJob(_ descriptor: any KnowledgeJobDescriptor) {
        let identifier = type(of: descriptor).identifier
        jobDescriptors[identifier] = descriptor
    }

    // MARK: - Enqueue

    /// Enqueue work items for execution.
    ///
    /// Merges with existing queue. Deduplicates by cache key
    /// (same job + file + hash). Re-sorts by priority.
    /// Deferred items are stored but not executed.
    func enqueue(_ items: [KnowledgeWorkItem]) {
        guard !items.isEmpty else { return }

        // Deduplicate: skip items whose cache key is already pending or executing.
        let existingKeys = Set(queue.map { cacheKey(for: $0) })
        let activeKeys = Set(activeTasks.keys.compactMap { taskId in
            queue.first { $0.id == taskId }.map { cacheKey(for: $0) }
        })
        let allExistingKeys = existingKeys.union(activeKeys)

        var newItems: [KnowledgeWorkItem] = []
        for item in items {
            let key = cacheKey(for: item)
            if !allExistingKeys.contains(key) {
                newItems.append(item)
            }
        }

        guard !newItems.isEmpty else { return }

        let pendingItems = newItems.filter { $0.state == .pending }
        let deferredItems = newItems.filter { $0.state == .deferred }

        queue.append(contentsOf: pendingItems)
        queue.append(contentsOf: deferredItems)
        queue.sort { $0.priority < $1.priority }

        totalEnqueued += pendingItems.count
        updateState()

        #if DEBUG
        print("[KnowledgeRuntime] Enqueued \(pendingItems.count) pending + \(deferredItems.count) deferred items (queue=\(queue.count), active=\(activeTasks.count))")
        #endif

        drainQueue()
    }

    // MARK: - Cancellation

    /// Cancel all pending and active work for a workspace.
    func cancelWorkspace(_ workspaceId: UUID) {
        // Cancel active tasks for this workspace.
        let activeToCancel = activeTasks.filter { taskId, _ in
            queue.first { $0.id == taskId }?.input.workspaceId == workspaceId
        }
        for (_, task) in activeToCancel {
            task.cancel()
        }

        // Remove pending items for this workspace.
        let before = queue.count
        queue.removeAll { $0.input.workspaceId == workspaceId }
        let removed = before - queue.count

        if removed > 0 || !activeToCancel.isEmpty {
            updateState()
            #if DEBUG
            print("[KnowledgeRuntime] Cancelled workspace \(workspaceId): removed \(removed) queued, cancelled \(activeToCancel.count) active")
            #endif
        }
    }

    /// Cancel all work. Called on app shutdown.
    func cancelAll() {
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
        queue.removeAll()
        state = .idle

        #if DEBUG
        print("[KnowledgeRuntime] Cancelled all work")
        #endif
    }

    // MARK: - Reset

    /// Reset progress counters. Called when starting a new planning cycle.
    func resetProgress() {
        completedCount = 0
        totalEnqueued = 0
        cachedCount = 0
        telemetry.removeAll()
        updateState()
    }

    // MARK: - Scheduling

    /// Drains the queue, starting new tasks when concurrency slots are available.
    private func drainQueue() {
        while let nextItem = nextExecutableItem() {
            startExecution(nextItem)
        }
    }

    /// Returns the next pending item that can execute under current concurrency limits.
    private func nextExecutableItem() -> KnowledgeWorkItem? {
        // Check global concurrency limit for AI-tier jobs.
        let aiActiveCount = activeTasks.count  // All active tasks count toward global limit
        let hasAISlot = aiActiveCount < Self.globalMaxConcurrency

        for (index, item) in queue.enumerated() {
            guard item.state == .pending else { continue }

            // Deterministic jobs always have a slot.
            if item.resolvedTier == .deterministic {
                var taken = queue.remove(at: index)
                taken.state = .executing
                return taken
            }

            // AI-tier jobs need a global slot.
            if hasAISlot {
                // Check per-job-kind concurrency.
                let kindActiveCount = activeTasks.keys.compactMap { taskId in
                    queue.first { $0.id == taskId }
                }.filter { $0.jobIdentifier == item.jobIdentifier }.count

                if let descriptor = jobDescriptors[item.jobIdentifier],
                   kindActiveCount < descriptor.maxConcurrency {
                    var taken = queue.remove(at: index)
                    taken.state = .executing
                    return taken
                }
            }
        }

        return nil
    }

    // MARK: - Execution

    /// Start executing a single work item.
    private func startExecution(_ item: KnowledgeWorkItem) {
        guard let descriptor = jobDescriptors[item.jobIdentifier] else {
            #if DEBUG
            print("[KnowledgeRuntime] Unknown job: \(item.jobIdentifier)")
            #endif
            completedCount += 1
            recordTelemetry(item: item, durationMs: 0, success: false)
            updateState()
            return
        }

        let resolution = resolver.resolution(for: descriptor.requiredCapability)
        let executor = resolution.executor
        let startTime = CFAbsoluteTimeGetCurrent()
        let itemId = item.id
        var mutableItem = item

        let task = Task { [weak self] in
            do {
                let output = try await descriptor.execute(
                    input: mutableItem.input,
                    capabilityExecutor: executor
                )

                guard !Task.isCancelled else {
                    await self?.handleCancellation(itemId: itemId)
                    return
                }

                await self?.handleSuccess(
                    itemId: itemId,
                    item: mutableItem,
                    output: output,
                    startTime: startTime
                )
            } catch {
                guard !Task.isCancelled else {
                    await self?.handleCancellation(itemId: itemId)
                    return
                }

                await self?.handleFailure(
                    itemId: itemId,
                    item: &mutableItem,
                    error: error,
                    startTime: startTime
                )
            }
        }

        activeTasks[itemId] = task
    }

    /// Handle successful job completion.
    private func handleSuccess(
        itemId: UUID,
        item: KnowledgeWorkItem,
        output: KnowledgeJobOutput,
        startTime: CFAbsoluteTime
    ) {
        activeTasks.removeValue(forKey: itemId)

        // Persist based on policy.
        switch item.persistencePolicy {
        case .disk, .memory:
            store.store(output, workspaceId: item.input.workspaceId)
        case .none:
            break
        }

        completedCount += 1
        let durationMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        recordTelemetry(item: item, durationMs: durationMs, success: true)
        updateState()

        // Notify listeners that an artifact was generated.
        onArtifactGenerated?(
            item.input.workspaceId,
            item.input.filePath,
            item.jobIdentifier,
            output.data
        )

        #if DEBUG
        print("[KnowledgeRuntime] Completed \(item.jobIdentifier) for \((item.input.filePath as NSString).lastPathComponent) in \(durationMs)ms")
        #endif

        // Try to start more work.
        drainQueue()
    }

    /// Handle job failure with retry logic.
    private func handleFailure(
        itemId: UUID,
        item: inout KnowledgeWorkItem,
        error: Error,
        startTime: CFAbsoluteTime
    ) {
        activeTasks.removeValue(forKey: itemId)
        item.attemptCount += 1

        let durationMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

        switch item.retryPolicy {
        case .retry(let maxAttempts, let backoff) where item.attemptCount < maxAttempts:
            // Re-enqueue with pending state after backoff.
            item.state = .pending

            #if DEBUG
            print("[KnowledgeRuntime] Retrying \(item.jobIdentifier) (attempt \(item.attemptCount)/\(maxAttempts)) after \(backoff)s")
            #endif

            let retryItem = item
            Task {
                try? await Task.sleep(for: .seconds(backoff))
                guard !Task.isCancelled else { return }
                self.queue.append(retryItem)
                self.queue.sort { $0.priority < $1.priority }
                self.drainQueue()
            }

        default:
            // No retry or retries exhausted.
            completedCount += 1
            recordTelemetry(item: item, durationMs: durationMs, success: false)
            updateState()

            #if DEBUG
            print("[KnowledgeRuntime] Failed \(item.jobIdentifier) for \((item.input.filePath as NSString).lastPathComponent): \(error)")
            #endif

            // Try to start more work.
            drainQueue()
        }
    }

    /// Handle task cancellation.
    private func handleCancellation(itemId: UUID) {
        activeTasks.removeValue(forKey: itemId)
        updateState()
    }

    // MARK: - State Updates

    /// Update the observable state based on current queue and active tasks.
    private func updateState() {
        if queue.isEmpty && activeTasks.isEmpty {
            if totalEnqueued > 0 {
                state = .complete(generated: completedCount, cached: cachedCount)
            } else {
                state = .idle
            }
        } else {
            state = .generating(
                completed: completedCount,
                total: totalEnqueued
            )
        }
    }

    // MARK: - Telemetry

    private func recordTelemetry(
        item: KnowledgeWorkItem,
        durationMs: Int,
        success: Bool
    ) {
        let record = KnowledgeJobTelemetry(
            jobIdentifier: item.jobIdentifier,
            filePath: item.input.filePath,
            tier: item.resolvedTier,
            durationMs: durationMs,
            success: success,
            cacheHit: false,
            attemptNumber: item.attemptCount
        )
        telemetry.append(record)
    }

    // MARK: - Helpers

    private func cacheKey(for item: KnowledgeWorkItem) -> KnowledgeCacheKey {
        KnowledgeCacheKey(
            jobIdentifier: item.jobIdentifier,
            filePath: item.input.filePath,
            contentHash: item.input.fileHash
        )
    }
}
