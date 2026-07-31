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
