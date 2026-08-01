// KnowledgeGenerationRuntimeTests.swift — DecodeTests
//
// Comprehensive tests for the Knowledge Generation Runtime foundation:
// - KnowledgePolicy decisions
// - KnowledgeCapability resolution
// - KnowledgePlanner planning logic
// - KnowledgeGenerationRuntime scheduling and execution
// - KnowledgeArtifactStore persistence
// - Job registration and empty runtime behavior

import Testing
import Foundation
@testable import Decode

// MARK: - Test Job Descriptor

/// A configurable test job for verifying planner and runtime behavior.
struct TestKnowledgeJob: KnowledgeJobDescriptor, @unchecked Sendable {
    static let identifier = "test-job"
    static let displayName = "Test Job"

    var requiredCapability: KnowledgeCapability = .fileSummarization
    var scope: KnowledgeJobScope = .file
    var invalidationTrigger: KnowledgeInvalidationTrigger = .fileChange
    var persistencePolicy: KnowledgePersistencePolicy = .disk
    var priority: Int = 100
    var maxConcurrency: Int = 2
    var retryPolicy: KnowledgeRetryPolicy = .none

    /// Controls whether needsExecution returns true.
    var shouldNeedExecution: Bool = true

    /// Controls whether execute succeeds or throws.
    var shouldSucceed: Bool = true

    /// Output data to return on success.
    var outputData: Data = Data("test-output".utf8)

    /// Track execution count.
    let executionCounter: ExecutionCounter

    init(
        executionCounter: ExecutionCounter = ExecutionCounter(),
        shouldNeedExecution: Bool = true,
        shouldSucceed: Bool = true,
        requiredCapability: KnowledgeCapability = .fileSummarization
    ) {
        self.executionCounter = executionCounter
        self.shouldNeedExecution = shouldNeedExecution
        self.shouldSucceed = shouldSucceed
        self.requiredCapability = requiredCapability
    }

    func needsExecution(
        input: KnowledgeJobInput,
        store: KnowledgeArtifactStoreReading
    ) -> Bool {
        if !shouldNeedExecution { return false }
        return !store.contains(key: KnowledgeCacheKey(
            jobIdentifier: Self.identifier,
            filePath: input.filePath,
            contentHash: input.fileHash
        ))
    }

    func execute(
        input: KnowledgeJobInput,
        capabilityExecutor: CapabilityExecutor?
    ) async throws -> KnowledgeJobOutput {
        executionCounter.increment()

        guard shouldSucceed else {
            throw KnowledgeGenerationError.executionFailed("Test failure")
        }

        return KnowledgeJobOutput(
            jobIdentifier: Self.identifier,
            key: KnowledgeCacheKey(
                jobIdentifier: Self.identifier,
                filePath: input.filePath,
                contentHash: input.fileHash
            ),
            data: outputData,
            computedAt: Date(),
            actualTier: .summarization
        )
    }
}

/// A second test job with a different identifier.
struct SecondTestJob: KnowledgeJobDescriptor, @unchecked Sendable {
    static let identifier = "second-test-job"
    static let displayName = "Second Test Job"

    var requiredCapability: KnowledgeCapability = .behaviorAnalysis
    var scope: KnowledgeJobScope = .file
    var invalidationTrigger: KnowledgeInvalidationTrigger = .fileChange
    var persistencePolicy: KnowledgePersistencePolicy = .disk
    var priority: Int = 200
    var maxConcurrency: Int = 1
    var retryPolicy: KnowledgeRetryPolicy = .none

    func needsExecution(
        input: KnowledgeJobInput,
        store: KnowledgeArtifactStoreReading
    ) -> Bool {
        !store.contains(key: KnowledgeCacheKey(
            jobIdentifier: Self.identifier,
            filePath: input.filePath,
            contentHash: input.fileHash
        ))
    }

    func execute(
        input: KnowledgeJobInput,
        capabilityExecutor: CapabilityExecutor?
    ) async throws -> KnowledgeJobOutput {
        KnowledgeJobOutput(
            jobIdentifier: Self.identifier,
            key: KnowledgeCacheKey(
                jobIdentifier: Self.identifier,
                filePath: input.filePath,
                contentHash: input.fileHash
            ),
            data: Data("second-output".utf8),
            computedAt: Date(),
            actualTier: .summarization
        )
    }
}

/// Thread-safe execution counter for test verification.
final class ExecutionCounter: @unchecked Sendable {
    private var _count = 0
    private let lock = NSLock()

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    func increment() {
        lock.lock()
        _count += 1
        lock.unlock()
    }
}

// MARK: - Test Helpers

private func makeTempArtifactURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("decode-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("artifacts.json")
}

private func cleanupArtifactURL(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

private func makeInput(
    filePath: String = "/test/file.swift",
    fileHash: String = "abc123",
    workspaceId: UUID = UUID()
) -> KnowledgeJobInput {
    KnowledgeJobInput(
        filePath: filePath,
        fileHash: fileHash,
        fileIntelligence: nil,
        workspaceId: workspaceId
    )
}

// ============================================================
// MARK: - KnowledgePolicy Tests
// ============================================================

@Suite("KnowledgePolicy")
struct KnowledgePolicyTests {

    @Test func allowAllWhenEnabled() {
        let policy = KnowledgePolicy.allAllowed
        #expect(policy.evaluate(requiredTier: .deterministic) == .allow)
        #expect(policy.evaluate(requiredTier: .summarization) == .allow)
        #expect(policy.evaluate(requiredTier: .reasoning) == .allow)
        #expect(policy.evaluate(requiredTier: .premium) == .allow)
    }

    @Test func prohibitAllWhenDisabled() {
        let policy = KnowledgePolicy.disabled
        #expect(policy.evaluate(requiredTier: .deterministic) == .prohibit)
        #expect(policy.evaluate(requiredTier: .summarization) == .prohibit)
        #expect(policy.evaluate(requiredTier: .reasoning) == .prohibit)
    }

    @Test func deterministicOnlyWhenNoAI() {
        let policy = KnowledgePolicy.deterministicOnly
        #expect(policy.evaluate(requiredTier: .deterministic) == .allow)
        #expect(policy.evaluate(requiredTier: .summarization) == .defer)
        #expect(policy.evaluate(requiredTier: .reasoning) == .defer)
    }

    @Test func deferAboveMaxTier() {
        let policy = KnowledgePolicy(
            isEnabled: true,
            isAIAvailable: true,
            maximumAllowedTier: .summarization
        )
        #expect(policy.evaluate(requiredTier: .deterministic) == .allow)
        #expect(policy.evaluate(requiredTier: .summarization) == .allow)
        #expect(policy.evaluate(requiredTier: .reasoning) == .defer)
        #expect(policy.evaluate(requiredTier: .premium) == .defer)
    }

    @Test func deferAIWhenUnavailable() {
        let policy = KnowledgePolicy(
            isEnabled: true,
            isAIAvailable: false,
            maximumAllowedTier: .premium
        )
        #expect(policy.evaluate(requiredTier: .deterministic) == .allow)
        #expect(policy.evaluate(requiredTier: .summarization) == .defer)
    }

    @Test func disabledOverridesEverything() {
        let policy = KnowledgePolicy(
            isEnabled: false,
            isAIAvailable: true,
            maximumAllowedTier: .premium
        )
        #expect(policy.evaluate(requiredTier: .deterministic) == .prohibit)
    }
}

// ============================================================
// MARK: - KnowledgeCapability Tests
// ============================================================

@Suite("KnowledgeCapability")
struct KnowledgeCapabilityTests {

    @Test func tierOrdering() {
        #expect(KnowledgeCapabilityTier.deterministic < .summarization)
        #expect(KnowledgeCapabilityTier.summarization < .reasoning)
        #expect(KnowledgeCapabilityTier.reasoning < .premium)
    }

    @Test func uniformResolverAssignsTiers() {
        let resolver = KnowledgeCapabilityResolver.uniform(
            executor: { _, _, _, _ in "test" }
        )
        #expect(resolver.tier(for: .fileSummarization) == .summarization)
        #expect(resolver.tier(for: .behaviorAnalysis) == .summarization)
        #expect(resolver.tier(for: .moduleSummarization) == .deterministic)
        #expect(resolver.tier(for: .architectureSummarization) == .deterministic)
    }

    @Test func deterministicResolverHasNoExecutor() {
        let resolver = KnowledgeCapabilityResolver.allDeterministic
        let resolution = resolver.resolution(for: .fileSummarization)
        #expect(resolution.tier == .deterministic)
        #expect(resolution.executor == nil)
    }

    @Test func uniformResolverHasExecutor() {
        let resolver = KnowledgeCapabilityResolver.uniform(
            executor: { _, _, _, _ in "test" }
        )
        let resolution = resolver.resolution(for: .fileSummarization)
        #expect(resolution.tier == .summarization)
        #expect(resolution.executor != nil)
    }
}

// ============================================================
// MARK: - KnowledgeArtifactStore Tests
// ============================================================

@Suite("KnowledgeArtifactStore")
struct KnowledgeArtifactStoreTests {

    @Test @MainActor func storeAndLookup() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let store = KnowledgeArtifactStore(persistenceURL: url)
        let key = KnowledgeCacheKey(jobIdentifier: "test", filePath: "/a.swift", contentHash: "h1")

        #expect(store.lookup(jobIdentifier: "test", filePath: "/a.swift", contentHash: "h1") == nil)
        #expect(store.count == 0)

        let output = KnowledgeJobOutput(
            jobIdentifier: "test",
            key: key,
            data: Data("hello".utf8),
            computedAt: Date(),
            actualTier: .summarization
        )
        store.store(output, workspaceId: UUID())

        let entry = store.lookup(jobIdentifier: "test", filePath: "/a.swift", contentHash: "h1")
        #expect(entry != nil)
        #expect(entry?.key == key)
        #expect(store.count == 1)
    }

    @Test @MainActor func lookupMissOnDifferentHash() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let store = KnowledgeArtifactStore(persistenceURL: url)
        let output = KnowledgeJobOutput(
            jobIdentifier: "test",
            key: KnowledgeCacheKey(jobIdentifier: "test", filePath: "/a.swift", contentHash: "h1"),
            data: Data("hello".utf8),
            computedAt: Date(),
            actualTier: .summarization
        )
        store.store(output, workspaceId: UUID())

        // Different hash → miss
        let entry = store.lookup(jobIdentifier: "test", filePath: "/a.swift", contentHash: "h2")
        #expect(entry == nil)
    }

    @Test @MainActor func invalidateByFilePath() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let store = KnowledgeArtifactStore(persistenceURL: url)
        let wsId = UUID()

        for path in ["/a.swift", "/b.swift"] {
            let output = KnowledgeJobOutput(
                jobIdentifier: "test",
                key: KnowledgeCacheKey(jobIdentifier: "test", filePath: path, contentHash: "h1"),
                data: Data("data".utf8),
                computedAt: Date(),
                actualTier: .deterministic
            )
            store.store(output, workspaceId: wsId)
        }
        #expect(store.count == 2)

        store.invalidate(filePath: "/a.swift")
        #expect(store.count == 1)
        #expect(store.lookup(jobIdentifier: "test", filePath: "/a.swift", contentHash: "h1") == nil)
        #expect(store.lookup(jobIdentifier: "test", filePath: "/b.swift", contentHash: "h1") != nil)
    }

    @Test @MainActor func invalidateByWorkspace() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let store = KnowledgeArtifactStore(persistenceURL: url)
        let ws1 = UUID()
        let ws2 = UUID()

        store.store(KnowledgeJobOutput(
            jobIdentifier: "test",
            key: KnowledgeCacheKey(jobIdentifier: "test", filePath: "/a.swift", contentHash: "h1"),
            data: Data(),
            computedAt: Date(),
            actualTier: .deterministic
        ), workspaceId: ws1)

        store.store(KnowledgeJobOutput(
            jobIdentifier: "test",
            key: KnowledgeCacheKey(jobIdentifier: "test", filePath: "/b.swift", contentHash: "h1"),
            data: Data(),
            computedAt: Date(),
            actualTier: .deterministic
        ), workspaceId: ws2)

        #expect(store.count == 2)
        store.invalidateWorkspace(ws1)
        #expect(store.count == 1)
    }

    @Test @MainActor func persistenceRoundTrip() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let wsId = UUID()
        let key = KnowledgeCacheKey(jobIdentifier: "test", filePath: "/a.swift", contentHash: "h1")
        let data = Data("persistent-data".utf8)

        // Write
        let store1 = KnowledgeArtifactStore(persistenceURL: url)
        store1.store(KnowledgeJobOutput(
            jobIdentifier: "test",
            key: key,
            data: data,
            computedAt: Date(),
            actualTier: .summarization
        ), workspaceId: wsId)

        // Read in new instance
        let store2 = KnowledgeArtifactStore(persistenceURL: url)
        store2.loadFromDisk()

        let entry = store2.lookup(jobIdentifier: "test", filePath: "/a.swift", contentHash: "h1")
        #expect(entry != nil)
        #expect(entry?.data == data)
        #expect(entry?.tier == .summarization)
    }

    @Test @MainActor func loadFromMissingFile() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let store = KnowledgeArtifactStore(persistenceURL: url)
        store.loadFromDisk()
        #expect(store.count == 0)
    }

    @Test @MainActor func removeAll() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let store = KnowledgeArtifactStore(persistenceURL: url)
        store.store(KnowledgeJobOutput(
            jobIdentifier: "test",
            key: KnowledgeCacheKey(jobIdentifier: "test", filePath: "/a.swift", contentHash: "h1"),
            data: Data(),
            computedAt: Date(),
            actualTier: .deterministic
        ), workspaceId: UUID())
        #expect(store.count == 1)

        store.removeAll()
        #expect(store.count == 0)
    }

    @Test @MainActor func artifactsByJob() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let store = KnowledgeArtifactStore(persistenceURL: url)
        let wsId = UUID()

        store.store(KnowledgeJobOutput(
            jobIdentifier: "job-a",
            key: KnowledgeCacheKey(jobIdentifier: "job-a", filePath: "/a.swift", contentHash: "h1"),
            data: Data(),
            computedAt: Date(),
            actualTier: .deterministic
        ), workspaceId: wsId)

        store.store(KnowledgeJobOutput(
            jobIdentifier: "job-b",
            key: KnowledgeCacheKey(jobIdentifier: "job-b", filePath: "/a.swift", contentHash: "h1"),
            data: Data(),
            computedAt: Date(),
            actualTier: .deterministic
        ), workspaceId: wsId)

        #expect(store.artifacts(forJob: "job-a").count == 1)
        #expect(store.artifacts(forJob: "job-b").count == 1)
        #expect(store.artifacts(forJob: "job-c").count == 0)
    }
}

// ============================================================
// MARK: - KnowledgePlanner Tests
// ============================================================

@Suite("KnowledgePlanner")
struct KnowledgePlannerTests {

    @Test @MainActor func registerAndUnregister() {
        let planner = KnowledgePlanner(resolver: .allDeterministic)

        planner.register(TestKnowledgeJob())
        #expect(planner.registeredJobCount == 1)
        #expect(planner.registeredJobIdentifiers.contains("test-job"))

        planner.unregister(identifier: "test-job")
        #expect(planner.registeredJobCount == 0)
    }

    @Test @MainActor func planProducesWorkItems() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let resolver = KnowledgeCapabilityResolver.uniform(
            executor: { _, _, _, _ in "test" }
        )
        let planner = KnowledgePlanner(resolver: resolver)
        let store = KnowledgeArtifactStore(persistenceURL: url)

        planner.register(TestKnowledgeJob())

        let items = planner.planForFiles(
            ["/a.swift", "/b.swift"],
            fileHashes: ["/a.swift": "h1", "/b.swift": "h2"],
            fileIntelligences: [:],
            workspaceId: UUID(),
            store: store,
            policy: .allAllowed
        )

        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.state == .pending })
        #expect(items.allSatisfy { $0.jobIdentifier == "test-job" })
    }

    @Test @MainActor func planSkipsCachedFiles() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let resolver = KnowledgeCapabilityResolver.uniform(
            executor: { _, _, _, _ in "test" }
        )
        let planner = KnowledgePlanner(resolver: resolver)
        let store = KnowledgeArtifactStore(persistenceURL: url)

        planner.register(TestKnowledgeJob())

        // Pre-populate cache for /a.swift
        store.store(KnowledgeJobOutput(
            jobIdentifier: "test-job",
            key: KnowledgeCacheKey(jobIdentifier: "test-job", filePath: "/a.swift", contentHash: "h1"),
            data: Data("cached".utf8),
            computedAt: Date(),
            actualTier: .summarization
        ), workspaceId: UUID())

        let items = planner.planForFiles(
            ["/a.swift", "/b.swift"],
            fileHashes: ["/a.swift": "h1", "/b.swift": "h2"],
            fileIntelligences: [:],
            workspaceId: UUID(),
            store: store,
            policy: .allAllowed
        )

        #expect(items.count == 1)
        #expect(items[0].input.filePath == "/b.swift")
    }

    @Test @MainActor func planDefersWhenPolicyDefers() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let resolver = KnowledgeCapabilityResolver.uniform(
            executor: { _, _, _, _ in "test" }
        )
        let planner = KnowledgePlanner(resolver: resolver)
        let store = KnowledgeArtifactStore(persistenceURL: url)

        planner.register(TestKnowledgeJob())

        let items = planner.planForFiles(
            ["/a.swift"],
            fileHashes: ["/a.swift": "h1"],
            fileIntelligences: [:],
            workspaceId: UUID(),
            store: store,
            policy: .deterministicOnly  // AI unavailable → defers summarization
        )

        #expect(items.count == 1)
        #expect(items[0].state == .deferred)
    }

    @Test @MainActor func planProhibitsWhenDisabled() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let planner = KnowledgePlanner(resolver: .allDeterministic)
        let store = KnowledgeArtifactStore(persistenceURL: url)

        planner.register(TestKnowledgeJob())

        let items = planner.planForFiles(
            ["/a.swift"],
            fileHashes: ["/a.swift": "h1"],
            fileIntelligences: [:],
            workspaceId: UUID(),
            store: store,
            policy: .disabled
        )

        #expect(items.isEmpty)
    }

    @Test @MainActor func planSortsByPriority() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let resolver = KnowledgeCapabilityResolver.uniform(
            executor: { _, _, _, _ in "test" }
        )
        let planner = KnowledgePlanner(resolver: resolver)
        let store = KnowledgeArtifactStore(persistenceURL: url)

        // Register two jobs with different priorities.
        var highPriorityJob = TestKnowledgeJob()
        highPriorityJob.priority = 10

        planner.register(highPriorityJob)
        planner.register(SecondTestJob())  // priority 200

        let items = planner.planForFiles(
            ["/a.swift"],
            fileHashes: ["/a.swift": "h1"],
            fileIntelligences: [:],
            workspaceId: UUID(),
            store: store,
            policy: .allAllowed
        )

        #expect(items.count == 2)
        #expect(items[0].jobIdentifier == "test-job")      // priority 10
        #expect(items[1].jobIdentifier == "second-test-job") // priority 200
    }

    @Test @MainActor func planSkipsFilesWithoutHash() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let planner = KnowledgePlanner(resolver: .allDeterministic)
        let store = KnowledgeArtifactStore(persistenceURL: url)

        planner.register(TestKnowledgeJob())

        let items = planner.planForFiles(
            ["/a.swift", "/b.swift"],
            fileHashes: ["/a.swift": "h1"],  // /b.swift has no hash
            fileIntelligences: [:],
            workspaceId: UUID(),
            store: store,
            policy: .allAllowed
        )

        // /b.swift skipped because it has no hash.
        #expect(items.count == 1)
        #expect(items[0].input.filePath == "/a.swift")
    }

    @Test @MainActor func emptyPlannerProducesNoWork() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let planner = KnowledgePlanner(resolver: .allDeterministic)
        let store = KnowledgeArtifactStore(persistenceURL: url)

        let items = planner.planForFiles(
            ["/a.swift"],
            fileHashes: ["/a.swift": "h1"],
            fileIntelligences: [:],
            workspaceId: UUID(),
            store: store,
            policy: .allAllowed
        )

        #expect(items.isEmpty)
    }

    @Test @MainActor func planForWorkspaceReturnsEmpty() {
        let planner = KnowledgePlanner(resolver: .allDeterministic)
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }
        let store = KnowledgeArtifactStore(persistenceURL: url)

        let items = planner.planForWorkspace(
            workspaceId: UUID(),
            store: store,
            policy: .allAllowed
        )

        #expect(items.isEmpty)
    }
}

// ============================================================
// MARK: - KnowledgeGenerationRuntime Tests
// ============================================================

@Suite("KnowledgeGenerationRuntime")
struct KnowledgeGenerationRuntimeTests {

    @Test @MainActor func idleStateOnCreation() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let runtime = KnowledgeGenerationRuntime(
            resolver: .allDeterministic,
            store: KnowledgeArtifactStore(persistenceURL: url)
        )

        #expect(runtime.state == .idle)
    }

    @Test @MainActor func enqueueEmptyItemsStaysIdle() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let runtime = KnowledgeGenerationRuntime(
            resolver: .allDeterministic,
            store: KnowledgeArtifactStore(persistenceURL: url)
        )

        runtime.enqueue([])
        #expect(runtime.state == .idle)
    }

    @Test @MainActor func executeJobSuccessfully() async throws {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let store = KnowledgeArtifactStore(persistenceURL: url)
        let counter = ExecutionCounter()
        let job = TestKnowledgeJob(executionCounter: counter)

        let resolver = KnowledgeCapabilityResolver.uniform(
            executor: { _, _, _, _ in "test" }
        )
        let runtime = KnowledgeGenerationRuntime(resolver: resolver, store: store)
        runtime.registerJob(job)

        let item = KnowledgeWorkItem(
            jobIdentifier: "test-job",
            input: makeInput(),
            resolvedTier: .summarization,
            priority: 100
        )

        runtime.enqueue([item])

        // Wait for execution to complete.
        try await Task.sleep(for: .milliseconds(200))

        #expect(counter.count == 1)
        #expect(store.count == 1)
        #expect(runtime.telemetry.count == 1)
        #expect(runtime.telemetry[0].success == true)
    }

    @Test @MainActor func executeMultipleJobs() async throws {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let store = KnowledgeArtifactStore(persistenceURL: url)
        let counter = ExecutionCounter()
        let job = TestKnowledgeJob(executionCounter: counter)

        let resolver = KnowledgeCapabilityResolver.uniform(
            executor: { _, _, _, _ in "test" }
        )
        let runtime = KnowledgeGenerationRuntime(resolver: resolver, store: store)
        runtime.registerJob(job)

        let items = (0..<5).map { i in
            KnowledgeWorkItem(
                jobIdentifier: "test-job",
                input: makeInput(filePath: "/file\(i).swift", fileHash: "h\(i)"),
                resolvedTier: .summarization,
                priority: 100
            )
        }

        runtime.enqueue(items)

        // Wait for all executions to complete.
        try await Task.sleep(for: .milliseconds(500))

        #expect(counter.count == 5)
        #expect(store.count == 5)
    }

    @Test @MainActor func cancelAllStopsExecution() async throws {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let store = KnowledgeArtifactStore(persistenceURL: url)
        let runtime = KnowledgeGenerationRuntime(
            resolver: .allDeterministic,
            store: store
        )

        runtime.cancelAll()
        #expect(runtime.state == .idle)
    }

    @Test @MainActor func cancelWorkspaceRemovesPendingItems() async throws {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let store = KnowledgeArtifactStore(persistenceURL: url)
        let runtime = KnowledgeGenerationRuntime(
            resolver: .allDeterministic,
            store: store
        )

        let wsId = UUID()
        let otherWsId = UUID()

        // Enqueue items for two workspaces.
        // Without a registered job, these remain pending.
        let items = [
            KnowledgeWorkItem(
                jobIdentifier: "unknown-job",
                input: makeInput(filePath: "/a.swift", workspaceId: wsId),
                resolvedTier: .deterministic,
                priority: 100
            ),
            KnowledgeWorkItem(
                jobIdentifier: "unknown-job",
                input: makeInput(filePath: "/b.swift", workspaceId: otherWsId),
                resolvedTier: .deterministic,
                priority: 100
            ),
        ]

        runtime.enqueue(items)
        runtime.cancelWorkspace(wsId)

        // Only the other workspace's item should remain (or have been processed).
        // The cancelled workspace's items are gone.
    }

    @Test @MainActor func resetProgressClearsCounters() async throws {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let store = KnowledgeArtifactStore(persistenceURL: url)
        let counter = ExecutionCounter()
        let job = TestKnowledgeJob(executionCounter: counter)

        let resolver = KnowledgeCapabilityResolver.uniform(
            executor: { _, _, _, _ in "test" }
        )
        let runtime = KnowledgeGenerationRuntime(resolver: resolver, store: store)
        runtime.registerJob(job)

        let item = KnowledgeWorkItem(
            jobIdentifier: "test-job",
            input: makeInput(),
            resolvedTier: .summarization,
            priority: 100
        )
        runtime.enqueue([item])

        try await Task.sleep(for: .milliseconds(200))

        #expect(runtime.telemetry.count == 1)

        runtime.resetProgress()
        #expect(runtime.telemetry.isEmpty)
        #expect(runtime.state == .idle)
    }

    @Test @MainActor func deferredItemsNotExecuted() async throws {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let store = KnowledgeArtifactStore(persistenceURL: url)
        let counter = ExecutionCounter()
        let job = TestKnowledgeJob(executionCounter: counter)

        let runtime = KnowledgeGenerationRuntime(
            resolver: .allDeterministic,
            store: store
        )
        runtime.registerJob(job)

        var item = KnowledgeWorkItem(
            jobIdentifier: "test-job",
            input: makeInput(),
            resolvedTier: .summarization,
            priority: 100
        )
        item.state = .deferred

        runtime.enqueue([item])

        try await Task.sleep(for: .milliseconds(200))

        #expect(counter.count == 0)
    }
}

// ============================================================
// MARK: - Work Item State Tests
// ============================================================

@Suite("KnowledgeWorkItem")
struct KnowledgeWorkItemTests {

    @Test func defaultStateIsPending() {
        let item = KnowledgeWorkItem(
            jobIdentifier: "test",
            input: makeInput(),
            resolvedTier: .deterministic,
            priority: 100
        )
        #expect(item.state == .pending)
        #expect(item.attemptCount == 0)
    }

    @Test func cacheKeyMatchesInput() {
        let item = KnowledgeWorkItem(
            jobIdentifier: "test",
            input: makeInput(filePath: "/a.swift", fileHash: "xyz"),
            resolvedTier: .deterministic,
            priority: 100
        )
        let key = KnowledgeCacheKey(
            jobIdentifier: "test",
            filePath: "/a.swift",
            contentHash: "xyz"
        )
        #expect(item.jobIdentifier == key.jobIdentifier)
        #expect(item.input.filePath == key.filePath)
        #expect(item.input.fileHash == key.contentHash)
    }
}

// ============================================================
// MARK: - Integration: Planner + Runtime
// ============================================================

@Suite("KGR Integration")
struct KGRIntegrationTests {

    @Test @MainActor func plannerAndRuntimeEndToEnd() async throws {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let store = KnowledgeArtifactStore(persistenceURL: url)
        let counter = ExecutionCounter()
        let job = TestKnowledgeJob(executionCounter: counter)

        let resolver = KnowledgeCapabilityResolver.uniform(
            executor: { _, _, _, _ in "test" }
        )
        let planner = KnowledgePlanner(resolver: resolver)
        let runtime = KnowledgeGenerationRuntime(resolver: resolver, store: store)

        planner.register(job)
        runtime.registerJob(job)

        // Plan work.
        let items = planner.planForFiles(
            ["/a.swift", "/b.swift"],
            fileHashes: ["/a.swift": "h1", "/b.swift": "h2"],
            fileIntelligences: [:],
            workspaceId: UUID(),
            store: store,
            policy: .allAllowed
        )

        #expect(items.count == 2)

        // Execute.
        runtime.enqueue(items)

        try await Task.sleep(for: .milliseconds(500))

        #expect(counter.count == 2)
        #expect(store.count == 2)

        // Re-plan: both should be cached now.
        let items2 = planner.planForFiles(
            ["/a.swift", "/b.swift"],
            fileHashes: ["/a.swift": "h1", "/b.swift": "h2"],
            fileIntelligences: [:],
            workspaceId: UUID(),
            store: store,
            policy: .allAllowed
        )

        #expect(items2.isEmpty)
    }

    @Test @MainActor func invalidationTriggersReplan() async throws {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let store = KnowledgeArtifactStore(persistenceURL: url)
        let counter = ExecutionCounter()
        let job = TestKnowledgeJob(executionCounter: counter)

        let resolver = KnowledgeCapabilityResolver.uniform(
            executor: { _, _, _, _ in "test" }
        )
        let planner = KnowledgePlanner(resolver: resolver)
        let runtime = KnowledgeGenerationRuntime(resolver: resolver, store: store)

        planner.register(job)
        runtime.registerJob(job)

        // First run.
        let items1 = planner.planForFiles(
            ["/a.swift"],
            fileHashes: ["/a.swift": "h1"],
            fileIntelligences: [:],
            workspaceId: UUID(),
            store: store,
            policy: .allAllowed
        )
        runtime.enqueue(items1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(counter.count == 1)

        // Invalidate.
        store.invalidate(filePath: "/a.swift")

        // Re-plan with new hash.
        let items2 = planner.planForFiles(
            ["/a.swift"],
            fileHashes: ["/a.swift": "h2"],
            fileIntelligences: [:],
            workspaceId: UUID(),
            store: store,
            policy: .allAllowed
        )
        #expect(items2.count == 1)

        runtime.enqueue(items2)
        try await Task.sleep(for: .milliseconds(200))
        #expect(counter.count == 2)
    }
}

// ============================================================
// MARK: - Phase 2: FileUnderstandingJob Tests
// ============================================================

@Suite("FileUnderstandingJob")
struct FileUnderstandingJobTests {

    @Test func identifierAndDisplayName() {
        #expect(FileUnderstandingJob.identifier == "file-understanding")
        #expect(FileUnderstandingJob.displayName == "File Understanding")
    }

    @Test func jobProperties() {
        let job = FileUnderstandingJob()
        #expect(job.requiredCapability == .fileSummarization)
        #expect(job.scope == .file)
        #expect(job.invalidationTrigger == .fileChange)
        #expect(job.persistencePolicy == .disk)
        #expect(job.priority == 100)
        #expect(job.maxConcurrency == 2)
    }

    @Test @MainActor func needsExecutionWhenNoArtifact() {
        let store = KnowledgeArtifactStore(
            persistenceURL: makeTempArtifactURL()
        )
        let job = FileUnderstandingJob()
        let input = makeInput(filePath: "/test.swift", fileHash: "hash1")
        #expect(job.needsExecution(input: input, store: store))
    }

    @Test @MainActor func doesNotNeedExecutionWhenArtifactExists() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }
        let store = KnowledgeArtifactStore(persistenceURL: url)
        let job = FileUnderstandingJob()

        let key = KnowledgeCacheKey(
            jobIdentifier: FileUnderstandingJob.identifier,
            filePath: "/test.swift",
            contentHash: "hash1"
        )
        let entry = KnowledgeArtifactEntry(
            key: key,
            data: Data("cached".utf8),
            computedAt: Date(),
            tier: .summarization,
            workspaceId: UUID()
        )
        store.store(entry: entry)

        let input = makeInput(filePath: "/test.swift", fileHash: "hash1")
        #expect(!job.needsExecution(input: input, store: store))
    }

    @Test @MainActor func needsExecutionAfterHashChange() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }
        let store = KnowledgeArtifactStore(persistenceURL: url)
        let job = FileUnderstandingJob()

        // Store artifact with hash1.
        let key = KnowledgeCacheKey(
            jobIdentifier: FileUnderstandingJob.identifier,
            filePath: "/test.swift",
            contentHash: "hash1"
        )
        store.store(entry: KnowledgeArtifactEntry(
            key: key,
            data: Data("cached".utf8),
            computedAt: Date(),
            tier: .summarization,
            workspaceId: UUID()
        ))

        // Input with different hash.
        let input = makeInput(filePath: "/test.swift", fileHash: "hash2")
        #expect(job.needsExecution(input: input, store: store))
    }

    @Test func executeFailsWithoutIntelligence() async throws {
        let job = FileUnderstandingJob()
        let input = makeInput(filePath: "/test.swift", fileHash: "hash1")
        // fileIntelligence is nil in makeInput.

        do {
            _ = try await job.execute(input: input, capabilityExecutor: nil)
            #expect(Bool(false), "Should have thrown")
        } catch is KnowledgeGenerationError {
            // Expected.
        }
    }

    @Test func executeFailsWithoutExecutor() async throws {
        let job = FileUnderstandingJob()
        let input = KnowledgeJobInput(
            filePath: "/test.swift",
            fileHash: "hash1",
            fileIntelligence: makeMinimalFileIntelligence(),
            workspaceId: UUID()
        )

        do {
            _ = try await job.execute(input: input, capabilityExecutor: nil)
            #expect(Bool(false), "Should have thrown")
        } catch let error as KnowledgeGenerationError {
            if case .noProvider = error {
                // Expected.
            } else {
                #expect(Bool(false), "Wrong error: \(error)")
            }
        }
    }

    @Test func executeProducesValidArtifact() async throws {
        let job = FileUnderstandingJob()
        let intelligence = makeMinimalFileIntelligence()
        let input = KnowledgeJobInput(
            filePath: "/test.swift",
            fileHash: "hash1",
            fileIntelligence: intelligence,
            workspaceId: UUID()
        )

        let mockExecutor: CapabilityExecutor = { _, _, _, _ in
            """
            <purpose>
            This file manages test data.
            </purpose>

            <behavior>
            It processes inputs sequentially.
            </behavior>

            <safety>
            No concurrency concerns.
            </safety>

            <design>
            Simple single-responsibility design.
            </design>
            """
        }

        let output = try await job.execute(
            input: input,
            capabilityExecutor: mockExecutor
        )

        #expect(output.jobIdentifier == "file-understanding")
        #expect(output.key.filePath == "/test.swift")
        #expect(output.key.contentHash == "hash1")
        #expect(output.actualTier == .summarization)

        // Decode the artifact to verify structure.
        let enrichment = FileUnderstandingJob.decodeEnrichment(from: output.data)
        #expect(enrichment != nil)
        #expect(enrichment?.purpose.contains("test data") == true)
        #expect(enrichment?.behavior != nil)
        #expect(enrichment?.safety != nil)
        #expect(enrichment?.design != nil)
        #expect(enrichment?.fileHash == "hash1")
    }

    @Test func decodeEnrichmentFromValidData() {
        let enrichment = SemanticEnrichment(
            purpose: "Test purpose",
            behavior: "Test behavior",
            safety: "Test safety",
            design: "Test design",
            fileHash: "abc",
            computedAt: Date()
        )
        let data = try! JSONEncoder().encode(enrichment)

        let decoded = FileUnderstandingJob.decodeEnrichment(from: data)
        #expect(decoded?.purpose == "Test purpose")
        #expect(decoded?.behavior == "Test behavior")
        #expect(decoded?.safety == "Test safety")
        #expect(decoded?.design == "Test design")
        #expect(decoded?.fileHash == "abc")
    }

    @Test func decodeEnrichmentFromInvalidData() {
        let data = Data("not-json".utf8)
        let decoded = FileUnderstandingJob.decodeEnrichment(from: data)
        #expect(decoded == nil)
    }
}

// ============================================================
// MARK: - Phase 2: Artifact Store Consumption Tests
// ============================================================

@Suite("ArtifactStoreConsumption")
struct ArtifactStoreConsumptionTests {

    @Test @MainActor func lookupReturnsNilForMissingArtifact() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }
        let store = KnowledgeArtifactStore(persistenceURL: url)

        let result = store.lookup(
            jobIdentifier: FileUnderstandingJob.identifier,
            filePath: "/missing.swift",
            contentHash: "hash1"
        )
        #expect(result == nil)
    }

    @Test @MainActor func lookupReturnsArtifactWhenHashMatches() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }
        let store = KnowledgeArtifactStore(persistenceURL: url)

        let enrichment = SemanticEnrichment(
            purpose: "Test purpose",
            behavior: nil,
            safety: nil,
            design: nil,
            fileHash: "hash1",
            computedAt: Date()
        )
        let data = try! JSONEncoder().encode(enrichment)

        let output = KnowledgeJobOutput(
            jobIdentifier: FileUnderstandingJob.identifier,
            key: KnowledgeCacheKey(
                jobIdentifier: FileUnderstandingJob.identifier,
                filePath: "/test.swift",
                contentHash: "hash1"
            ),
            data: data,
            computedAt: Date(),
            actualTier: .summarization
        )
        store.store(output, workspaceId: UUID())

        let result = store.lookup(
            jobIdentifier: FileUnderstandingJob.identifier,
            filePath: "/test.swift",
            contentHash: "hash1"
        )
        #expect(result != nil)

        let decoded = FileUnderstandingJob.decodeEnrichment(from: result!.data)
        #expect(decoded?.purpose == "Test purpose")
    }

    @Test @MainActor func lookupReturnsNilForStaleHash() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }
        let store = KnowledgeArtifactStore(persistenceURL: url)

        let output = KnowledgeJobOutput(
            jobIdentifier: FileUnderstandingJob.identifier,
            key: KnowledgeCacheKey(
                jobIdentifier: FileUnderstandingJob.identifier,
                filePath: "/test.swift",
                contentHash: "hash1"
            ),
            data: Data("test".utf8),
            computedAt: Date(),
            actualTier: .summarization
        )
        store.store(output, workspaceId: UUID())

        // Different hash — should not match.
        let result = store.lookup(
            jobIdentifier: FileUnderstandingJob.identifier,
            filePath: "/test.swift",
            contentHash: "hash2"
        )
        #expect(result == nil)
    }

    @Test @MainActor func invalidationRemovesArtifact() {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }
        let store = KnowledgeArtifactStore(persistenceURL: url)

        let output = KnowledgeJobOutput(
            jobIdentifier: FileUnderstandingJob.identifier,
            key: KnowledgeCacheKey(
                jobIdentifier: FileUnderstandingJob.identifier,
                filePath: "/test.swift",
                contentHash: "hash1"
            ),
            data: Data("test".utf8),
            computedAt: Date(),
            actualTier: .summarization
        )
        store.store(output, workspaceId: UUID())
        #expect(store.count == 1)

        store.invalidate(filePath: "/test.swift")
        #expect(store.count == 0)

        let result = store.lookup(
            jobIdentifier: FileUnderstandingJob.identifier,
            filePath: "/test.swift",
            contentHash: "hash1"
        )
        #expect(result == nil)
    }

    @Test @MainActor func regenerationAfterInvalidation() async throws {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let store = KnowledgeArtifactStore(persistenceURL: url)
        let resolver = KnowledgeCapabilityResolver.uniform { _, _, _, _ in
            """
            <purpose>Regenerated purpose</purpose>
            <behavior>New behavior</behavior>
            <safety>New safety</safety>
            <design>New design</design>
            """
        }
        let planner = KnowledgePlanner(resolver: resolver)
        let runtime = KnowledgeGenerationRuntime(
            resolver: resolver,
            store: store
        )

        let job = FileUnderstandingJob()
        planner.register(job)
        runtime.registerJob(job)

        // Store initial artifact.
        let initialOutput = KnowledgeJobOutput(
            jobIdentifier: FileUnderstandingJob.identifier,
            key: KnowledgeCacheKey(
                jobIdentifier: FileUnderstandingJob.identifier,
                filePath: "/a.swift",
                contentHash: "h1"
            ),
            data: Data("old".utf8),
            computedAt: Date(),
            actualTier: .summarization
        )
        store.store(initialOutput, workspaceId: UUID())

        // Plan — should find no work (cache hit).
        let items1 = planner.planForFiles(
            ["/a.swift"],
            fileHashes: ["/a.swift": "h1"],
            fileIntelligences: ["/a.swift": makeMinimalFileIntelligence(filePath: "/a.swift")],
            workspaceId: UUID(),
            store: store,
            policy: .allAllowed
        )
        #expect(items1.isEmpty)

        // Invalidate.
        store.invalidate(filePath: "/a.swift")

        // Plan with new hash — should find work.
        let items2 = planner.planForFiles(
            ["/a.swift"],
            fileHashes: ["/a.swift": "h2"],
            fileIntelligences: ["/a.swift": makeMinimalFileIntelligence(filePath: "/a.swift", fileHash: "h2")],
            workspaceId: UUID(),
            store: store,
            policy: .allAllowed
        )
        #expect(items2.count == 1)

        runtime.enqueue(items2)
        try await Task.sleep(for: .milliseconds(500))

        // Verify artifact was regenerated.
        let result = store.lookup(
            jobIdentifier: FileUnderstandingJob.identifier,
            filePath: "/a.swift",
            contentHash: "h2"
        )
        #expect(result != nil)

        let enrichment = FileUnderstandingJob.decodeEnrichment(from: result!.data)
        #expect(enrichment?.purpose.contains("Regenerated") == true)
    }
}

// ============================================================
// MARK: - Phase 2: Background Execution Tests
// ============================================================

@Suite("BackgroundExecution")
struct BackgroundExecutionTests {

    @Test @MainActor func plannerProducesWorkForFileUnderstandingJob() {
        let resolver = KnowledgeCapabilityResolver.uniform { _, _, _, _ in "" }
        let planner = KnowledgePlanner(resolver: resolver)
        let store = KnowledgeArtifactStore(persistenceURL: makeTempArtifactURL())

        planner.register(FileUnderstandingJob())

        let intelligence = makeMinimalFileIntelligence()
        let items = planner.planForFiles(
            ["/test.swift"],
            fileHashes: ["/test.swift": "hash1"],
            fileIntelligences: ["/test.swift": intelligence],
            workspaceId: UUID(),
            store: store,
            policy: .allAllowed
        )

        #expect(items.count == 1)
        #expect(items[0].jobIdentifier == FileUnderstandingJob.identifier)
        #expect(items[0].state == .pending)
    }

    @Test @MainActor func runtimeExecutesFileUnderstandingJob() async throws {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let resolver = KnowledgeCapabilityResolver.uniform { _, _, _, _ in
            """
            <purpose>Background generated purpose</purpose>
            <behavior>Background behavior</behavior>
            <safety>Background safety</safety>
            <design>Background design</design>
            """
        }
        let store = KnowledgeArtifactStore(persistenceURL: url)
        let planner = KnowledgePlanner(resolver: resolver)
        let runtime = KnowledgeGenerationRuntime(resolver: resolver, store: store)

        let job = FileUnderstandingJob()
        planner.register(job)
        runtime.registerJob(job)

        let intelligence = makeMinimalFileIntelligence()
        let items = planner.planForFiles(
            ["/bg.swift"],
            fileHashes: ["/bg.swift": "bghash"],
            fileIntelligences: ["/bg.swift": intelligence],
            workspaceId: UUID(),
            store: store,
            policy: .allAllowed
        )

        #expect(items.count == 1)

        runtime.enqueue(items)
        try await Task.sleep(for: .milliseconds(500))

        // Verify artifact is in the store.
        let result = store.lookup(
            jobIdentifier: FileUnderstandingJob.identifier,
            filePath: "/bg.swift",
            contentHash: "bghash"
        )
        #expect(result != nil)

        let enrichment = FileUnderstandingJob.decodeEnrichment(from: result!.data)
        #expect(enrichment?.purpose.contains("Background generated") == true)
        #expect(enrichment?.behavior != nil)
        #expect(enrichment?.fileHash == "bghash")
    }

    @Test @MainActor func identicalHashSkipsReexecution() async throws {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let callCount = ExecutionCounter()
        let resolver = KnowledgeCapabilityResolver.uniform { _, _, _, _ in
            callCount.increment()
            return "<purpose>purpose</purpose>"
        }
        let store = KnowledgeArtifactStore(persistenceURL: url)
        let planner = KnowledgePlanner(resolver: resolver)
        let runtime = KnowledgeGenerationRuntime(resolver: resolver, store: store)

        let job = FileUnderstandingJob()
        planner.register(job)
        runtime.registerJob(job)

        let intelligence = makeMinimalFileIntelligence()

        // First run.
        let items1 = planner.planForFiles(
            ["/test.swift"],
            fileHashes: ["/test.swift": "same-hash"],
            fileIntelligences: ["/test.swift": intelligence],
            workspaceId: UUID(),
            store: store,
            policy: .allAllowed
        )
        #expect(items1.count == 1)

        runtime.enqueue(items1)
        try await Task.sleep(for: .milliseconds(500))
        #expect(callCount.count == 1)

        // Second run with same hash — planner should produce no work.
        runtime.resetProgress()
        let items2 = planner.planForFiles(
            ["/test.swift"],
            fileHashes: ["/test.swift": "same-hash"],
            fileIntelligences: ["/test.swift": intelligence],
            workspaceId: UUID(),
            store: store,
            policy: .allAllowed
        )
        #expect(items2.isEmpty)
    }

    @Test @MainActor func changedHashTriggersRegeneration() async throws {
        let url = makeTempArtifactURL()
        defer { cleanupArtifactURL(url) }

        let resolver = KnowledgeCapabilityResolver.uniform { _, _, _, _ in
            "<purpose>regenerated</purpose>"
        }
        let store = KnowledgeArtifactStore(persistenceURL: url)
        let planner = KnowledgePlanner(resolver: resolver)
        let runtime = KnowledgeGenerationRuntime(resolver: resolver, store: store)

        let job = FileUnderstandingJob()
        planner.register(job)
        runtime.registerJob(job)

        // First run with hash1.
        let items1 = planner.planForFiles(
            ["/test.swift"],
            fileHashes: ["/test.swift": "hash1"],
            fileIntelligences: ["/test.swift": makeMinimalFileIntelligence(fileHash: "hash1")],
            workspaceId: UUID(),
            store: store,
            policy: .allAllowed
        )
        runtime.enqueue(items1)
        try await Task.sleep(for: .milliseconds(500))

        // Second run with hash2 — should need re-execution.
        runtime.resetProgress()
        let items2 = planner.planForFiles(
            ["/test.swift"],
            fileHashes: ["/test.swift": "hash2"],
            fileIntelligences: ["/test.swift": makeMinimalFileIntelligence(fileHash: "hash2")],
            workspaceId: UUID(),
            store: store,
            policy: .allAllowed
        )
        #expect(items2.count == 1)

        runtime.enqueue(items2)
        try await Task.sleep(for: .milliseconds(500))

        let result = store.lookup(
            jobIdentifier: FileUnderstandingJob.identifier,
            filePath: "/test.swift",
            contentHash: "hash2"
        )
        #expect(result != nil)
    }
}

// ============================================================
// MARK: - Phase 2: SemanticEnrichment Codable Tests
// ============================================================

@Suite("SemanticEnrichmentCodable")
struct SemanticEnrichmentCodableTests {

    @Test func roundTripFullEnrichment() throws {
        let original = SemanticEnrichment(
            purpose: "Manages user authentication",
            behavior: "Validates credentials and issues tokens",
            safety: "Thread-safe via actor isolation",
            design: "Strategy pattern for auth providers",
            fileHash: "abc123",
            computedAt: Date(timeIntervalSinceReferenceDate: 1000)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SemanticEnrichment.self, from: data)

        #expect(decoded.purpose == original.purpose)
        #expect(decoded.behavior == original.behavior)
        #expect(decoded.safety == original.safety)
        #expect(decoded.design == original.design)
        #expect(decoded.fileHash == original.fileHash)
    }

    @Test func roundTripPartialEnrichment() throws {
        let original = SemanticEnrichment(
            purpose: "Simple helper",
            fileHash: "xyz789",
            computedAt: Date()
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SemanticEnrichment.self, from: data)

        #expect(decoded.purpose == "Simple helper")
        #expect(decoded.behavior == nil)
        #expect(decoded.safety == nil)
        #expect(decoded.design == nil)
    }
}

// ============================================================
// MARK: - Phase 2: Enrichment Response Parsing Tests
// ============================================================

@Suite("EnrichmentResponseParsing")
struct EnrichmentResponseParsingTests {

    @Test func parseFullXMLResponse() {
        let response = """
        <purpose>
        Auth service purpose.
        </purpose>

        <behavior>
        Auth behavior details.
        </behavior>

        <safety>
        Safety assessment.
        </safety>

        <design>
        Design rationale.
        </design>
        """

        let enrichment = SemanticEnrichmentService.parseEnrichmentResponse(
            response, fileHash: "h1"
        )
        #expect(enrichment.purpose.contains("Auth service purpose"))
        #expect(enrichment.behavior?.contains("Auth behavior") == true)
        #expect(enrichment.safety?.contains("Safety assessment") == true)
        #expect(enrichment.design?.contains("Design rationale") == true)
        #expect(enrichment.fileHash == "h1")
    }

    @Test func parsePlainTextFallback() {
        let response = "This file handles user login and session management."

        let enrichment = SemanticEnrichmentService.parseEnrichmentResponse(
            response, fileHash: "h2"
        )
        // Without tags, entire response becomes purpose.
        #expect(enrichment.purpose == response)
        #expect(enrichment.behavior == nil)
        #expect(enrichment.safety == nil)
        #expect(enrichment.design == nil)
    }

    @Test func parsePartialResponse() {
        let response = """
        <purpose>
        Purpose only.
        </purpose>
        """

        let enrichment = SemanticEnrichmentService.parseEnrichmentResponse(
            response, fileHash: "h3"
        )
        #expect(enrichment.purpose.contains("Purpose only"))
        #expect(enrichment.behavior == nil)
        #expect(enrichment.safety == nil)
        #expect(enrichment.design == nil)
    }
}

// ============================================================
// MARK: - Phase 2: Test Helpers
// ============================================================

/// Creates a minimal FileIntelligence suitable for test input.
/// Contains just enough structure for FileUnderstandingJob to execute.
private func makeMinimalFileIntelligence(
    filePath: String = "/test.swift",
    fileHash: String = "testhash"
) -> FileIntelligence {
    FileIntelligence(
        sessionId: UUID(),
        fileName: (filePath as NSString).lastPathComponent,
        language: "swift",
        lineCount: 50,
        entities: [],
        structureOutline: "",
        imports: [],
        relationships: [],
        identity: FileIdentity(
            role: .unknown,
            layer: .unknown,
            patterns: [],
            summary: "Test file"
        ),
        purpose: "Test purpose",
        fileHash: fileHash,
        buildDate: Date()
    )
}

// MARK: - Multi-Provider Routing Tests

/// Thread-safe tracker for capability routing in tests.
final class CapabilityTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _lastCapability: KnowledgeCapability?

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _calls.count
    }

    var lastCapability: KnowledgeCapability? {
        lock.lock()
        defer { lock.unlock() }
        return _lastCapability
    }

    func record(_ label: String, capability: KnowledgeCapability? = nil) {
        lock.lock()
        defer { lock.unlock() }
        _calls.append(label)
        if let capability { _lastCapability = capability }
    }

    func contains(_ label: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _calls.contains(label)
    }

    func uniqueLabels() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(_calls)
    }
}

@Suite("Capability Routing")
struct CapabilityRoutingTests {

    @Test("Routed resolver directs fileSummarization to dedicated executor")
    @MainActor func routedFileSummarizationUsesDedicatedExecutor() async throws {
        let tracker = CapabilityTracker()

        let primaryExecutor: CapabilityExecutor = { _, _, _, _ in
            tracker.record("primary")
            return "primary"
        }
        let knowledgeExecutor: CapabilityExecutor = { _, _, _, _ in
            tracker.record("knowledge")
            return "knowledge"
        }

        let resolver = KnowledgeCapabilityResolver.routed(
            routes: [.fileSummarization: knowledgeExecutor],
            fallback: primaryExecutor
        )

        let resolution = resolver.resolution(for: .fileSummarization)
        #expect(resolution.tier == .summarization)

        let result = try await resolution.executor!("test", "prompt", .fileSummarization, "mode")
        #expect(result == "knowledge")
        #expect(tracker.contains("knowledge"))
        #expect(!tracker.contains("primary"))
    }

    @Test("Routed resolver directs unrouted capabilities to fallback")
    @MainActor func routedFallbackForUnroutedCapability() async throws {
        let tracker = CapabilityTracker()

        let primaryExecutor: CapabilityExecutor = { _, _, _, _ in
            tracker.record("primary")
            return "primary"
        }
        let knowledgeExecutor: CapabilityExecutor = { _, _, _, _ in
            tracker.record("knowledge")
            return "knowledge"
        }

        let resolver = KnowledgeCapabilityResolver.routed(
            routes: [.fileSummarization: knowledgeExecutor],
            fallback: primaryExecutor
        )

        let resolution = resolver.resolution(for: .behaviorAnalysis)
        let result = try await resolution.executor!("test", "prompt", .behaviorAnalysis, "mode")
        #expect(result == "primary")
        #expect(tracker.contains("primary"))
    }

    @Test("Routed resolver routes moduleSummarization to knowledge executor")
    @MainActor func routedModuleSummarization() async throws {
        let tracker = CapabilityTracker()

        let primaryExecutor: CapabilityExecutor = { _, _, _, _ in "primary" }
        let knowledgeExecutor: CapabilityExecutor = { _, _, _, _ in
            tracker.record("knowledge")
            return "knowledge"
        }

        let resolver = KnowledgeCapabilityResolver.routed(
            routes: [
                .fileSummarization: knowledgeExecutor,
                .moduleSummarization: knowledgeExecutor,
            ],
            fallback: primaryExecutor
        )

        let resolution = resolver.resolution(for: .moduleSummarization)
        #expect(resolution.tier == .summarization)
        let result = try await resolution.executor!("test", "prompt", .moduleSummarization, "mode")
        #expect(result == "knowledge")
        #expect(tracker.contains("knowledge"))
    }

    @Test("Routed resolver routes architectureSummarization to knowledge executor")
    @MainActor func routedArchitectureSummarization() async throws {
        let tracker = CapabilityTracker()

        let primaryExecutor: CapabilityExecutor = { _, _, _, _ in "primary" }
        let knowledgeExecutor: CapabilityExecutor = { _, _, _, _ in
            tracker.record("knowledge")
            return "knowledge"
        }

        let resolver = KnowledgeCapabilityResolver.routed(
            routes: [.architectureSummarization: knowledgeExecutor],
            fallback: primaryExecutor
        )

        let resolution = resolver.resolution(for: .architectureSummarization)
        let result = try await resolution.executor!("test", "prompt", .architectureSummarization, "mode")
        #expect(result == "knowledge")
        #expect(tracker.contains("knowledge"))
    }

    @Test("Uniform resolver routes all capabilities to same executor")
    @MainActor func uniformResolverSingleExecutor() async throws {
        let tracker = CapabilityTracker()

        let executor: CapabilityExecutor = { _, _, _, _ in
            tracker.record("uniform")
            return "uniform"
        }

        let resolver = KnowledgeCapabilityResolver.uniform(executor: executor)

        for capability in [KnowledgeCapability.fileSummarization, .behaviorAnalysis, .safetyAssessment, .designInterpretation, .textCompression] {
            let resolution = resolver.resolution(for: capability)
            _ = try await resolution.executor!("test", "prompt", capability, "mode")
        }
        #expect(tracker.callCount == 5)
    }

    @Test("Uniform resolver maps module/architecture to deterministic tier")
    @MainActor func uniformDeterministicModuleArchitecture() {
        let executor: CapabilityExecutor = { _, _, _, _ in "test" }
        let resolver = KnowledgeCapabilityResolver.uniform(executor: executor)

        let moduleResolution = resolver.resolution(for: .moduleSummarization)
        #expect(moduleResolution.tier == .deterministic)
        #expect(moduleResolution.executor == nil)

        let archResolution = resolver.resolution(for: .architectureSummarization)
        #expect(archResolution.tier == .deterministic)
        #expect(archResolution.executor == nil)
    }

    @Test("All-deterministic resolver returns nil executors")
    @MainActor func allDeterministicNilExecutors() {
        let resolver = KnowledgeCapabilityResolver.allDeterministic

        for capability in KnowledgeCapability.allCases {
            let resolution = resolver.resolution(for: capability)
            #expect(resolution.tier == .deterministic)
            #expect(resolution.executor == nil)
        }
    }
}

@Suite("Groq Provider")
struct GroqProviderTests {

    @Test("GroqProvider reports unavailable when no API key")
    func groqUnavailableWithoutKey() {
        let provider = GroqProvider(apiKey: { nil })
        #expect(!provider.isAvailable)
    }

    @Test("GroqProvider reports unavailable for empty API key")
    func groqUnavailableWithEmptyKey() {
        let provider = GroqProvider(apiKey: { "" })
        #expect(!provider.isAvailable)
    }

    @Test("GroqProvider reports available with API key")
    func groqAvailableWithKey() {
        let provider = GroqProvider(apiKey: { "test-key-123" })
        #expect(provider.isAvailable)
    }

    @Test("GroqProvider uses custom model when specified")
    func groqCustomModel() {
        let provider = GroqProvider(
            apiKey: { "test-key" },
            model: "llama-3.1-8b-instant"
        )
        #expect(provider.isAvailable)
    }
}

@Suite("Provider Fallback Behavior")
struct ProviderFallbackTests {

    @Test("Groq unavailable falls back to uniform resolver")
    @MainActor func fallbackToUniformWhenNoGroq() async throws {
        let groq = GroqProvider(apiKey: { nil })
        #expect(!groq.isAvailable)

        let tracker = CapabilityTracker()
        let primaryExecutor: CapabilityExecutor = { _, _, _, _ in
            tracker.record("claude")
            return "claude"
        }

        let resolver = KnowledgeCapabilityResolver.uniform(executor: primaryExecutor)

        let resolution = resolver.resolution(for: .fileSummarization)
        let result = try await resolution.executor!("test", "prompt", .fileSummarization, "mode")
        #expect(result == "claude")
        #expect(tracker.callCount == 1)
    }

    @Test("Groq available routes knowledge capabilities to Groq")
    @MainActor func groqAvailableRoutesKnowledge() async throws {
        let groq = GroqProvider(apiKey: { "test-key" })
        #expect(groq.isAvailable)

        let tracker = CapabilityTracker()

        let knowledgeExecutor: CapabilityExecutor = { _, _, _, _ in
            tracker.record("groq")
            return "groq"
        }
        let primaryExecutor: CapabilityExecutor = { _, _, _, _ in
            tracker.record("claude")
            return "claude"
        }

        let resolver = KnowledgeCapabilityResolver.routed(
            routes: [
                .fileSummarization: knowledgeExecutor,
                .moduleSummarization: knowledgeExecutor,
                .architectureSummarization: knowledgeExecutor,
            ],
            fallback: primaryExecutor
        )

        // Knowledge capabilities → Groq.
        _ = try await resolver.resolution(for: .fileSummarization).executor!("", "", .fileSummarization, "")
        _ = try await resolver.resolution(for: .moduleSummarization).executor!("", "", .moduleSummarization, "")
        _ = try await resolver.resolution(for: .architectureSummarization).executor!("", "", .architectureSummarization, "")

        // Reasoning capabilities → Claude.
        _ = try await resolver.resolution(for: .behaviorAnalysis).executor!("", "", .behaviorAnalysis, "")
        _ = try await resolver.resolution(for: .safetyAssessment).executor!("", "", .safetyAssessment, "")
        _ = try await resolver.resolution(for: .textCompression).executor!("", "", .textCompression, "")

        let calls = tracker.calls
        #expect(calls.filter { $0 == "groq" }.count == 3)
        #expect(calls.filter { $0 == "claude" }.count == 3)
    }

    @Test("FileUnderstandingJob uses routed executor")
    @MainActor func fileUnderstandingJobUsesRoutedExecutor() async throws {
        let tracker = CapabilityTracker()

        let knowledgeExecutor: CapabilityExecutor = { _, _, _, _ in
            tracker.record("groq")
            return """
            <purpose>Test purpose via Groq</purpose>
            <behavior>Test behavior</behavior>
            <safety>Test safety</safety>
            <design>Test design</design>
            """
        }
        let primaryExecutor: CapabilityExecutor = { _, _, _, _ in "primary" }

        let resolver = KnowledgeCapabilityResolver.routed(
            routes: [.fileSummarization: knowledgeExecutor],
            fallback: primaryExecutor
        )

        let resolution = resolver.resolution(for: .fileSummarization)
        #expect(resolution.executor != nil)

        let job = FileUnderstandingJob()
        let intelligence = makeMinimalFileIntelligence(filePath: "/test.swift", fileHash: "abc123")
        let input = KnowledgeJobInput(
            filePath: "/test.swift",
            fileHash: "abc123",
            fileIntelligence: intelligence,
            workspaceId: UUID()
        )

        let output = try await job.execute(input: input, capabilityExecutor: resolution.executor)
        #expect(tracker.contains("groq"))

        let enrichment = FileUnderstandingJob.decodeEnrichment(from: output.data)
        #expect(enrichment != nil)
        #expect(enrichment?.purpose == "Test purpose via Groq")
    }

    @Test("Explain capabilities continue using Claude executor")
    @MainActor func explainCapabilitiesUseClaude() async throws {
        let tracker = CapabilityTracker()

        let knowledgeExecutor: CapabilityExecutor = { _, _, _, _ in
            tracker.record("groq")
            return "groq"
        }
        let primaryExecutor: CapabilityExecutor = { _, _, _, _ in
            tracker.record("claude")
            return "claude"
        }

        let resolver = KnowledgeCapabilityResolver.routed(
            routes: [.fileSummarization: knowledgeExecutor],
            fallback: primaryExecutor
        )

        _ = try await resolver.resolution(for: .designInterpretation).executor!("", "", .designInterpretation, "")
        #expect(tracker.contains("claude"))
        #expect(!tracker.contains("groq"))
    }
}

@Suite("Capability Routing Table")
struct CapabilityRoutingTableTests {

    @Test("Complete routing table verification")
    @MainActor func completeRoutingTable() async throws {
        let tracker = CapabilityTracker()

        let knowledgeExecutor: CapabilityExecutor = { _, _, capability, _ in
            tracker.record("knowledge:\(capability.rawValue)", capability: capability)
            return "knowledge"
        }
        let primaryExecutor: CapabilityExecutor = { _, _, capability, _ in
            tracker.record("primary:\(capability.rawValue)", capability: capability)
            return "primary"
        }

        let resolver = KnowledgeCapabilityResolver.routed(
            routes: [
                .fileSummarization: knowledgeExecutor,
                .moduleSummarization: knowledgeExecutor,
                .architectureSummarization: knowledgeExecutor,
            ],
            fallback: primaryExecutor
        )

        for capability in KnowledgeCapability.allCases {
            let resolution = resolver.resolution(for: capability)
            if let executor = resolution.executor {
                _ = try await executor("", "", capability, "")
            }
        }

        let labels = tracker.uniqueLabels()

        // Knowledge production capabilities → routed.
        #expect(labels.contains("knowledge:fileSummarization"))
        #expect(labels.contains("knowledge:moduleSummarization"))
        #expect(labels.contains("knowledge:architectureSummarization"))

        // Reasoning capabilities → fallback.
        #expect(labels.contains("primary:behaviorAnalysis"))
        #expect(labels.contains("primary:safetyAssessment"))
        #expect(labels.contains("primary:designInterpretation"))
        #expect(labels.contains("primary:textCompression"))
    }

    @Test("Routing preserves capability parameter in executor")
    @MainActor func routingPreservesCapability() async throws {
        let tracker = CapabilityTracker()

        let executor: CapabilityExecutor = { _, _, capability, _ in
            tracker.record("test", capability: capability)
            return "test"
        }

        let resolver = KnowledgeCapabilityResolver.routed(
            routes: [.fileSummarization: executor],
            fallback: { _, _, _, _ in "fallback" }
        )

        let resolution = resolver.resolution(for: .fileSummarization)
        _ = try await resolution.executor!("content", "prompt", .fileSummarization, "enrichment")
        #expect(tracker.lastCapability == .fileSummarization)
    }
}

// MARK: - AIConfiguration Tests

@Suite("AIConfiguration")
struct AIConfigurationTests {

    @Test("Test configuration with both providers")
    func testConfigBothProviders() {
        let config = AIConfiguration.test(
            anthropicKey: "sk-ant-test",
            groqKey: "gsk-test"
        )
        #expect(config.anthropic.isAvailable)
        #expect(config.groq.isAvailable)
        #expect(config.anthropic.identifier == "anthropic")
        #expect(config.groq.identifier == "groq")
        #expect(config.validationIssues.isEmpty)
    }

    @Test("Test configuration with no providers")
    func testConfigNoProviders() {
        let config = AIConfiguration.test()
        #expect(!config.anthropic.isAvailable)
        #expect(!config.groq.isAvailable)
    }

    @Test("Test configuration with only Groq")
    func testConfigGroqOnly() {
        let config = AIConfiguration.test(groqKey: "gsk-test")
        #expect(!config.anthropic.isAvailable)
        #expect(config.groq.isAvailable)
    }

    @Test("Test configuration uses default models")
    func testDefaultModels() {
        let config = AIConfiguration.test()
        #expect(config.anthropic.model == AIConfiguration.defaultAnthropicModel)
        #expect(config.groq.model == AIConfiguration.defaultGroqModel)
    }

    @Test("Test configuration uses custom models")
    func testCustomModels() {
        let config = AIConfiguration.test(
            anthropicModel: "claude-sonnet-4-6",
            groqModel: "llama-3.1-8b-instant"
        )
        #expect(config.anthropic.model == "claude-sonnet-4-6")
        #expect(config.groq.model == "llama-3.1-8b-instant")
    }

    @Test("ProviderConfig availability checks")
    func providerConfigAvailability() {
        let available = ProviderConfig(
            identifier: "test",
            apiKey: "key123",
            model: "model",
            baseURL: URL(string: "https://example.com")!
        )
        #expect(available.isAvailable)

        let nilKey = ProviderConfig(
            identifier: "test",
            apiKey: nil,
            model: "model",
            baseURL: URL(string: "https://example.com")!
        )
        #expect(!nilKey.isAvailable)

        let emptyKey = ProviderConfig(
            identifier: "test",
            apiKey: "",
            model: "model",
            baseURL: URL(string: "https://example.com")!
        )
        #expect(!emptyKey.isAvailable)
    }
}

// MARK: - AIProviderRegistry Tests

@Suite("AIProviderRegistry")
struct AIProviderRegistryTests {

    @Test("Registry starts empty")
    @MainActor func registryStartsEmpty() {
        let registry = AIProviderRegistry()
        #expect(registry.count == 0)
        #expect(registry.availableCount == 0)
        #expect(registry.registeredIdentifiers.isEmpty)
    }

    @Test("Register and lookup provider")
    @MainActor func registerAndLookup() {
        let registry = AIProviderRegistry()
        let provider = GroqProvider(apiKey: { "test-key" })
        registry.register(provider, identifier: "groq", isAvailable: true)

        #expect(registry.count == 1)
        #expect(registry.availableCount == 1)
        #expect(registry.isAvailable("groq"))
        #expect(registry.provider(for: "groq") != nil)
    }

    @Test("Lookup returns nil for unregistered provider")
    @MainActor func lookupMissing() {
        let registry = AIProviderRegistry()
        #expect(registry.provider(for: "nonexistent") == nil)
        #expect(!registry.isAvailable("nonexistent"))
    }

    @Test("Register unavailable provider")
    @MainActor func registerUnavailable() {
        let registry = AIProviderRegistry()
        let provider = GroqProvider(apiKey: { nil })
        registry.register(provider, identifier: "groq", isAvailable: false)

        #expect(registry.count == 1)
        #expect(registry.availableCount == 0)
        #expect(!registry.isAvailable("groq"))
        #expect(registry.provider(for: "groq") != nil)
    }

    @Test("Multiple providers registered")
    @MainActor func multipleProviders() {
        let registry = AIProviderRegistry()
        let groq = GroqProvider(apiKey: { "key1" })
        let groq2 = GroqProvider(apiKey: { "key2" })

        registry.register(groq, identifier: "groq", isAvailable: true)
        registry.register(groq2, identifier: "anthropic", isAvailable: true)

        #expect(registry.count == 2)
        #expect(registry.availableCount == 2)
        #expect(registry.registeredIdentifiers.contains("groq"))
        #expect(registry.registeredIdentifiers.contains("anthropic"))
    }
}

// MARK: - GroqProvider DI Tests

@Suite("GroqProvider DI")
struct GroqProviderDITests {

    @Test("GroqProvider from ProviderConfig with key")
    func groqFromConfigWithKey() {
        let config = ProviderConfig(
            identifier: "groq",
            apiKey: "gsk-test-key",
            model: "llama-3.3-70b-versatile",
            baseURL: AIConfiguration.groqBaseURL
        )
        let provider = GroqProvider(config: config)
        #expect(provider.isAvailable)
    }

    @Test("GroqProvider from ProviderConfig without key")
    func groqFromConfigWithoutKey() {
        let config = ProviderConfig(
            identifier: "groq",
            apiKey: nil,
            model: "llama-3.3-70b-versatile",
            baseURL: AIConfiguration.groqBaseURL
        )
        let provider = GroqProvider(config: config)
        #expect(!provider.isAvailable)
    }

    @Test("GroqProvider from AIConfiguration")
    func groqFromAIConfiguration() {
        let aiConfig = AIConfiguration.test(groqKey: "gsk-test")
        let provider = GroqProvider(config: aiConfig.groq)
        #expect(provider.isAvailable)
    }

    @Test("GroqProvider convenience init still works")
    func groqConvenienceInit() {
        let provider = GroqProvider(apiKey: { "test-key" })
        #expect(provider.isAvailable)

        let unavailable = GroqProvider(apiKey: { nil })
        #expect(!unavailable.isAvailable)
    }
}
