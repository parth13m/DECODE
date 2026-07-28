// BenchmarkTypes.swift — Decode Application
// E1-01: Benchmark Suite — Types for pipeline-level benchmarking.
//
// Extends the Evaluation Framework with types that evaluate Decode's full
// understanding pipeline: file processing → retrieval → assembly → consumer.
// Benchmarks compare structural evidence, not explanation text.

import Foundation
import ConsumerRuntime
import ContextAssembly
import RetrievalRuntime
import DIRCore

// MARK: - Benchmark Definition

/// A canonical benchmark case that exercises the full understanding pipeline.
///
/// Each benchmark specifies a project (source files), a question (entity to explain),
/// and structural expectations (entities, relationships, observations, grounding).
/// The benchmark runner processes the files, queries the pipeline, and compares
/// the structural evidence against expectations.
struct BenchmarkCase: Sendable {
    /// Stable identifier (e.g., "swift-class-with-protocol").
    let id: String

    /// Human-readable name.
    let name: String

    /// What capability this benchmark validates.
    let description: String

    /// Classification for grouping.
    let category: BenchmarkCategory

    /// Source files to process through the write pipeline.
    let sourceFiles: [BenchmarkSourceFile]

    /// The entity to query (the "question").
    let queryEntity: String

    /// The consumer purpose for the query.
    let purpose: String

    /// Structural expectations for the pipeline output.
    let expectations: BenchmarkExpectations
}

/// A source file to be processed through the pipeline.
struct BenchmarkSourceFile: Sendable {
    /// File name with extension (determines which frontend processes it).
    let fileName: String

    /// File content.
    let content: String
}

/// Categories for organizing benchmarks.
enum BenchmarkCategory: String, Codable, Sendable, CaseIterable {
    case entityDiscovery
    case relationshipResolution
    case crossFileResolution
    case moduleContext
    case contextAssembly
    case edgeCase
}

/// Structural expectations for a benchmark — what the pipeline should produce.
///
/// All fields are optional. Only specified expectations are checked.
/// Expectations compare structural evidence, never explanation text.
struct BenchmarkExpectations: Sendable {
    /// Entity names that must appear in the evidence.
    let expectedEntities: [String]

    /// Relationship predicates that must appear (source, predicate, target).
    let expectedRelationships: [ExpectedRelationship]

    /// Predicates that must appear for the query entity.
    let expectedPredicates: [String]

    /// Minimum number of evidence units retrieved.
    let minEvidenceCount: Int?

    /// Maximum number of evidence units (detects over-retrieval).
    let maxEvidenceCount: Int?

    /// Expected evidence stages present.
    let expectedStages: Set<String>?

    /// Expected tiers present.
    let expectedTiers: Set<String>?

    /// Minimum grounding coverage.
    let minGroundingCoverage: Double?

    /// Expected completeness.
    let expectedCompleteness: CompletenessAssessment?

    /// Whether the pipeline must produce a non-empty Understanding.
    let requireSuccess: Bool

    init(
        expectedEntities: [String] = [],
        expectedRelationships: [ExpectedRelationship] = [],
        expectedPredicates: [String] = [],
        minEvidenceCount: Int? = nil,
        maxEvidenceCount: Int? = nil,
        expectedStages: Set<String>? = nil,
        expectedTiers: Set<String>? = nil,
        minGroundingCoverage: Double? = nil,
        expectedCompleteness: CompletenessAssessment? = nil,
        requireSuccess: Bool = true
    ) {
        self.expectedEntities = expectedEntities
        self.expectedRelationships = expectedRelationships
        self.expectedPredicates = expectedPredicates
        self.minEvidenceCount = minEvidenceCount
        self.maxEvidenceCount = maxEvidenceCount
        self.expectedStages = expectedStages
        self.expectedTiers = expectedTiers
        self.minGroundingCoverage = minGroundingCoverage
        self.expectedCompleteness = expectedCompleteness
        self.requireSuccess = requireSuccess
    }
}

/// An expected relationship in the evidence.
struct ExpectedRelationship: Sendable {
    let source: String
    let predicate: String
    let target: String
}

// MARK: - Benchmark Metrics

/// Extended metrics captured from a full pipeline benchmark run.
///
/// Includes per-stage latency, evidence precision/recall, compression,
/// and prompt size — dimensions not available at the reasoning engine level.
struct BenchmarkMetrics: Codable, Sendable, Equatable {
    // MARK: Latency (seconds)

    /// Time to process source files through the write pipeline.
    let retrievalLatency: TimeInterval

    /// Time for context assembly.
    let contextAssemblyLatency: TimeInterval

    /// Time for consumer reasoning.
    let reasoningLatency: TimeInterval

    /// Total end-to-end latency.
    let totalLatency: TimeInterval

    // MARK: Evidence

    /// Total evidence units retrieved.
    let evidenceUnitCount: Int

    /// Evidence units selected into the context frame.
    let contextUnitCount: Int

    /// Evidence units not used in the context frame.
    let unusedEvidence: Int

    /// Compression ratio: contextUnitCount / evidenceUnitCount.
    let compressionRatio: Double

    /// Per-stage evidence counts.
    let evidenceByStage: [String: Int]

    /// Per-tier evidence counts.
    let evidenceByTier: [String: Int]

    // MARK: Precision and Recall

    /// Fraction of expected entities found in evidence.
    let entityRecall: Double

    /// Expected entities that were found.
    let foundEntities: [String]

    /// Expected entities that were missing.
    let missingEntities: [String]

    /// Fraction of expected relationships found.
    let relationshipRecall: Double

    /// Expected relationships that were found.
    let foundRelationships: [String]

    /// Expected relationships that were missing.
    let missingRelationships: [String]

    /// Fraction of expected predicates found for the query entity.
    let predicateRecall: Double

    /// Expected predicates that were found.
    let foundPredicates: [String]

    /// Expected predicates that were missing.
    let missingPredicates: [String]

    // MARK: Context Quality

    /// Grounding coverage from the Understanding metadata.
    let groundingCoverage: Double

    /// Total claims produced.
    let totalClaims: Int

    /// Claim type distribution.
    let claimTypeDistribution: [String: Int]

    /// Completeness assessment.
    let completeness: String

    /// Degradation level.
    let degradationLevel: String

    /// Budget utilization.
    let budgetUtilization: Double

    // MARK: Size

    /// Prompt size (characters sent to reasoning engine).
    let contentLength: Int

    /// Per-stratum unit counts in the context frame.
    let stratumDistribution: [String: Int]

    // MARK: Engine

    /// Engine identifier used.
    let engineIdentifier: String

    /// Engine version used.
    let engineVersion: String
}

// MARK: - Benchmark Result

/// The outcome of a single benchmark case.
struct BenchmarkResult: Codable, Sendable {
    /// The benchmark case identifier.
    let caseId: String

    /// The benchmark case name.
    let caseName: String

    /// The benchmark category.
    let category: String

    /// When this benchmark was run.
    let timestamp: Date

    /// Whether the pipeline produced an Understanding.
    let success: Bool

    /// Captured metrics (nil if pipeline failed before producing output).
    let metrics: BenchmarkMetrics?

    /// Structural expectation violations.
    let violations: [ExpectationViolation]

    /// Error description if the pipeline failed.
    let error: String?

    /// The pipeline stage where failure occurred (nil if success).
    let failureStage: String?
}

// MARK: - Benchmark Report

/// A complete benchmark run report with both machine-readable and
/// human-readable output.
struct BenchmarkReport: Codable, Sendable {
    /// Unique identifier for this run.
    let runId: String

    /// When this run was executed.
    let timestamp: Date

    /// Engine version used.
    let engineVersion: String

    /// Individual benchmark results.
    let results: [BenchmarkResult]

    /// Aggregated summary.
    let summary: BenchmarkSummary

    /// Comparison against baseline (nil if no baseline provided).
    let comparison: BaselineComparison?
}

/// Aggregated metrics across all benchmarks.
struct BenchmarkSummary: Codable, Sendable {
    /// Total benchmark cases.
    let totalCases: Int

    /// Cases where pipeline produced Understanding.
    let succeeded: Int

    /// Cases where pipeline failed.
    let failed: Int

    /// Cases with all structural expectations met.
    let expectationsMet: Int

    /// Cases with at least one expectation violation.
    let expectationsViolated: Int

    // MARK: Averages

    let averageEntityRecall: Double
    let averageRelationshipRecall: Double
    let averagePredicateRecall: Double
    let averageGroundingCoverage: Double
    let averageEvidenceCount: Double
    let averageContextUnitCount: Double
    let averageCompressionRatio: Double
    let averageRetrievalLatency: TimeInterval
    let averageAssemblyLatency: TimeInterval
    let averageReasoningLatency: TimeInterval
    let averageTotalLatency: TimeInterval
    let averageBudgetUtilization: Double
    let averageContentLength: Double

    /// Completeness distribution.
    let completenessDistribution: [String: Int]

    /// Total missing entities across all cases.
    let totalMissingEntities: Int

    /// Total missing relationships across all cases.
    let totalMissingRelationships: Int

    /// Per-category scores (category rawValue → average entity recall).
    let categoryScores: [String: CategoryScore]
}

/// Score summary for a single benchmark category.
struct CategoryScore: Codable, Sendable {
    /// Number of cases in this category.
    let caseCount: Int

    /// Cases that succeeded.
    let succeeded: Int

    /// Cases with all expectations met.
    let expectationsMet: Int

    /// Average entity recall across cases in this category.
    let averageEntityRecall: Double

    /// Average relationship recall.
    let averageRelationshipRecall: Double

    /// Average grounding coverage.
    let averageGroundingCoverage: Double

    /// Composite score: weighted average of entity recall (40%), relationship recall (30%),
    /// grounding coverage (20%), and success rate (10%).
    var compositeScore: Double {
        let successRate = caseCount > 0 ? Double(succeeded) / Double(caseCount) : 0
        return averageEntityRecall * 0.4
             + averageRelationshipRecall * 0.3
             + averageGroundingCoverage * 0.2
             + successRate * 0.1
    }
}

// MARK: - Benchmark Comparison Thresholds

/// Thresholds for benchmark regression detection.
///
/// Extends ComparisonThresholds with pipeline-specific metrics.
struct BenchmarkThresholds: Sendable {
    /// Maximum allowed decrease in entity recall.
    let entityRecallThreshold: Double

    /// Maximum allowed decrease in relationship recall.
    let relationshipRecallThreshold: Double

    /// Maximum allowed decrease in predicate recall.
    let predicateRecallThreshold: Double

    /// Maximum allowed decrease in grounding coverage.
    let groundingCoverageThreshold: Double

    /// Maximum allowed increase in total latency (fractional).
    let latencyThreshold: Double

    /// Maximum allowed decrease in compression ratio.
    let compressionThreshold: Double

    /// Maximum allowed decrease in budget utilization.
    let budgetUtilizationThreshold: Double

    static let `default` = BenchmarkThresholds(
        entityRecallThreshold: 0.1,
        relationshipRecallThreshold: 0.1,
        predicateRecallThreshold: 0.1,
        groundingCoverageThreshold: 0.1,
        latencyThreshold: 0.5,
        compressionThreshold: 0.15,
        budgetUtilizationThreshold: 0.15
    )
}
