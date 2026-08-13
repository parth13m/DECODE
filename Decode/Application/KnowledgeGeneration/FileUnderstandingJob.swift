// FileUnderstandingJob.swift — Knowledge Generation Runtime
//
// The first production Knowledge Job: generates comprehensive
// File Understanding (purpose, behavior, safety, design) for
// source files via the Semantic Enrichment Pipeline.
//
// Reuses SemanticEnrichmentService's prompt construction and response
// parsing — no reasoning logic is duplicated.
//
// Input: FileIntelligence (deterministic facts from AST parse)
// Output: SemanticEnrichment encoded as JSON Data
// Trigger: After indexing completes or file workspace is created/reparsed

import Foundation

// MARK: - File Understanding Job

/// Produces comprehensive semantic understanding for a single source file.
///
/// This is the KGR's first production job. It wraps the existing Semantic
/// Enrichment Pipeline — the same prompt, the same parsing, the same output
/// — but executes proactively after indexing instead of reactively on first
/// user question.
///
/// ## Execution
/// 1. Receives `FileIntelligence` via `KnowledgeJobInput`
/// 2. Builds structured facts summary (entity signatures, relationships, imports)
/// 3. Calls the capability executor (routed to the AI provider)
/// 4. Parses the XML-tagged response into `SemanticEnrichment`
/// 5. Encodes as JSON `Data` for artifact store persistence
///
/// ## Cache
/// The artifact store key is (job-identifier, file-path, content-hash).
/// A file with the same hash never triggers re-execution.
struct FileUnderstandingJob: KnowledgeJobDescriptor, Sendable {

    static let identifier = "file-understanding"
    static let displayName = "File Understanding"

    let requiredCapability: KnowledgeCapability = .fileSummarization
    let scope: KnowledgeJobScope = .file
    let invalidationTrigger: KnowledgeInvalidationTrigger = .fileChange
    let persistencePolicy: KnowledgePersistencePolicy = .disk
    let priority: Int = 100
    let maxConcurrency: Int = 2
    let retryPolicy: KnowledgeRetryPolicy = .retry(maxAttempts: 2, backoff: 5.0)

    // MARK: - Cache Check

    func needsExecution(
        input: KnowledgeJobInput,
        store: KnowledgeArtifactStoreReading
    ) -> Bool {
        let key = KnowledgeCacheKey(
            jobIdentifier: Self.identifier,
            filePath: input.filePath,
            contentHash: input.fileHash
        )
        return !store.contains(key: key)
    }

    // MARK: - Execution

    func execute(
        input: KnowledgeJobInput,
        capabilityExecutor: CapabilityExecutor?
    ) async throws -> KnowledgeJobOutput {
        guard let intelligence = input.fileIntelligence else {
            throw KnowledgeGenerationError.executionFailed(
                "No file intelligence available for \(input.filePath)"
            )
        }

        guard let executor = capabilityExecutor else {
            throw KnowledgeGenerationError.noProvider
        }

        // Reuse SemanticEnrichmentService's prompt construction.
        let systemPrompt = SemanticEnrichmentService.buildEnrichmentPrompt()
        let userMessage = SemanticEnrichmentService.buildFactsSummary(
            intelligence: intelligence
        )

        let response = try await executor(
            userMessage,
            systemPrompt,
            .fileSummarization,
            "enrichment_kgr"
        )

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KnowledgeGenerationError.executionFailed(
                "Empty response from AI provider for \(input.filePath)"
            )
        }

        // Reuse SemanticEnrichmentService's response parsing.
        let enrichment = SemanticEnrichmentService.parseEnrichmentResponse(
            trimmed,
            fileHash: input.fileHash
        )

        let data = try JSONEncoder().encode(enrichment)

        let key = KnowledgeCacheKey(
            jobIdentifier: Self.identifier,
            filePath: input.filePath,
            contentHash: input.fileHash
        )

        return KnowledgeJobOutput(
            jobIdentifier: Self.identifier,
            key: key,
            data: data,
            computedAt: Date(),
            actualTier: .summarization
        )
    }

    // MARK: - Artifact Decoding

    /// Decode a SemanticEnrichment from artifact store data.
    ///
    /// Used by SessionQuestionCoordinator to consume cached artifacts.
    /// Returns `nil` if decoding fails (corrupt data, schema change).
    static func decodeEnrichment(from data: Data) -> SemanticEnrichment? {
        try? JSONDecoder().decode(SemanticEnrichment.self, from: data)
    }
}
