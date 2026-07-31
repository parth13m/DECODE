// KnowledgePlanner.swift — Knowledge Generation Runtime
//
// Decides WHICH knowledge generation jobs need to run.
// Does NOT execute them — that's the runtime's responsibility.
//
// The planner is stateless: it evaluates the current state of the
// artifact store and registered jobs to produce work items. Calling
// it twice with the same inputs produces the same work items (minus
// what the first call already completed). No race conditions.
//
// Flow:
//   planForFiles(paths) → for each file × each job:
//     1. Policy check (is this tier allowed?)
//     2. Cache check (does valid output exist?)
//     3. If needed, create KnowledgeWorkItem
//     4. Sort by priority
//   → return [KnowledgeWorkItem]

import Foundation

// MARK: - Knowledge Planner

/// Determines which knowledge generation jobs need to run.
///
/// Registered job descriptors are evaluated against current artifact store
/// state and policy constraints. The planner emits work items for the
/// runtime to schedule — it never executes work itself.
///
/// ## Thread Safety
/// `@MainActor` isolated, matching the coordinator pattern. Job descriptors
/// are `Sendable` — registered once at startup, read during planning.
@MainActor
final class KnowledgePlanner {

    // MARK: - State

    /// Registered job descriptors, keyed by identifier.
    private var registeredJobs: [String: any KnowledgeJobDescriptor] = [:]

    /// The capability resolver for determining execution tiers.
    private let resolver: KnowledgeCapabilityResolver

    // MARK: - Init

    /// Creates a planner with the given capability resolver.
    init(resolver: KnowledgeCapabilityResolver) {
        self.resolver = resolver
    }

    // MARK: - Registration

    /// Register a job descriptor.
    ///
    /// Called once at startup per job type. Duplicate registrations
    /// for the same identifier replace the previous descriptor.
    func register(_ descriptor: any KnowledgeJobDescriptor) {
        let identifier = type(of: descriptor).identifier
        registeredJobs[identifier] = descriptor

        #if DEBUG
        print("[KnowledgePlanner] Registered job: \(type(of: descriptor).displayName) (\(identifier))")
        #endif
    }

    /// Unregister a job descriptor. Returns the removed descriptor, if any.
    @discardableResult
    func unregister(identifier: String) -> (any KnowledgeJobDescriptor)? {
        registeredJobs.removeValue(forKey: identifier)
    }

    /// All currently registered job identifiers.
    var registeredJobIdentifiers: [String] {
        Array(registeredJobs.keys)
    }

    /// The number of registered jobs.
    var registeredJobCount: Int {
        registeredJobs.count
    }

    // MARK: - Planning (File Scope)

    /// Plan work for a set of files.
    ///
    /// Evaluates all file-scoped registered jobs against each file.
    /// Respects the policy: work above the allowed tier is deferred
    /// or prohibited. Skips jobs whose cached output is still valid.
    ///
    /// - Parameters:
    ///   - filePaths: The files to plan work for.
    ///   - fileHashes: Content hashes for each file path.
    ///   - fileIntelligences: Parsed file intelligence for each path (may be partial).
    ///   - workspaceId: The workspace that owns these files.
    ///   - store: Read-only artifact store for cache checks.
    ///   - policy: Current knowledge policy for tier decisions.
    /// - Returns: Prioritized work items ready for the runtime.
    func planForFiles(
        _ filePaths: [String],
        fileHashes: [String: String],
        fileIntelligences: [String: FileIntelligence],
        workspaceId: UUID,
        store: KnowledgeArtifactStoreReading,
        policy: KnowledgePolicy
    ) -> [KnowledgeWorkItem] {
        var workItems: [KnowledgeWorkItem] = []

        let fileScopedJobs = registeredJobs.values.filter { $0.scope == .file }

        for filePath in filePaths {
            guard let fileHash = fileHashes[filePath] else { continue }

            let input = KnowledgeJobInput(
                filePath: filePath,
                fileHash: fileHash,
                fileIntelligence: fileIntelligences[filePath],
                workspaceId: workspaceId
            )

            for job in fileScopedJobs {
                let resolution = resolver.resolution(for: job.requiredCapability)

                // Policy check.
                let decision = policy.evaluate(requiredTier: resolution.tier)
                switch decision {
                case .prohibit:
                    continue
                case .defer:
                    // Create a deferred work item — saved but not executed.
                    if job.needsExecution(input: input, store: store) {
                        var item = makeWorkItem(
                            job: job,
                            input: input,
                            resolvedTier: resolution.tier
                        )
                        item.state = .deferred
                        workItems.append(item)
                    }
                    continue
                case .allow:
                    break
                }

                // Cache check.
                guard job.needsExecution(input: input, store: store) else {
                    continue
                }

                let item = makeWorkItem(
                    job: job,
                    input: input,
                    resolvedTier: resolution.tier
                )
                workItems.append(item)
            }
        }

        // Sort by priority (lower = higher priority).
        workItems.sort { $0.priority < $1.priority }

        #if DEBUG
        let pending = workItems.filter { $0.state == .pending }.count
        let deferred = workItems.filter { $0.state == .deferred }.count
        if !workItems.isEmpty {
            print("[KnowledgePlanner] Planned \(pending) pending + \(deferred) deferred items for \(filePaths.count) files")
        }
        #endif

        return workItems
    }

    // MARK: - Planning (Module/System Scope)

    /// Plan work for module-scoped and system-scoped jobs.
    ///
    /// Called after indexing completes. Evaluates non-file-scoped jobs
    /// against the workspace state.
    ///
    /// Phase 1: No module/system jobs registered, so this returns empty.
    /// The API exists for Phase 2 forward compatibility.
    func planForWorkspace(
        workspaceId: UUID,
        store: KnowledgeArtifactStoreReading,
        policy: KnowledgePolicy
    ) -> [KnowledgeWorkItem] {
        // Phase 1: no module/system-scoped jobs. Return empty.
        // Phase 2 will iterate registeredJobs.values.filter { $0.scope != .file }
        // and create work items for module/system scope.
        return []
    }

    // MARK: - Private

    private func makeWorkItem(
        job: any KnowledgeJobDescriptor,
        input: KnowledgeJobInput,
        resolvedTier: KnowledgeCapabilityTier
    ) -> KnowledgeWorkItem {
        KnowledgeWorkItem(
            jobIdentifier: type(of: job).identifier,
            input: input,
            resolvedTier: resolvedTier,
            priority: job.priority,
            retryPolicy: job.retryPolicy,
            persistencePolicy: job.persistencePolicy
        )
    }
}
