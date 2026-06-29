// OutputBatch.swift — ProducerRuntime
// DDS-003: R5 — output collection, provenance stamping, output pipeline
// DDS-001: R4 — output validation

import Foundation
import DIRCore

// MARK: — Raw Pass Output

/// A single raw output record from a pass before provenance stamping.
///
/// DDS-003: The pass returns raw output records with subject, predicate, value,
/// tier, confidence, and grounding references. Raw output does not include
/// provenance (the Pass Runtime stamps it) or unit identifiers (the DIR assigns them).
struct RawOutputRecord: Sendable {
    let subject: UnitSubject
    let predicate: PredicateIdentifier
    let value: TypedValue
    let tier: Tier
    let confidence: Confidence

    /// Grounding references — unit IDs from the input set or
    /// earlier in the same output batch.
    let groundingRefs: [UnitIdentifier]

    /// For inferred output: the inference method used.
    let inferenceMethod: String?

    /// The version stamp (source hashes this output derives from).
    let version: VersionStamp

    init(
        subject: UnitSubject,
        predicate: PredicateIdentifier,
        value: TypedValue,
        tier: Tier,
        confidence: Confidence,
        groundingRefs: [UnitIdentifier],
        inferenceMethod: String? = nil,
        version: VersionStamp
    ) {
        self.subject = subject
        self.predicate = predicate
        self.value = value
        self.tier = tier
        self.confidence = confidence
        self.groundingRefs = groundingRefs
        self.inferenceMethod = inferenceMethod
        self.version = version
    }
}

// MARK: — Output Batch

/// The validated set of unit admissions from a single producer execution.
///
/// DDS-003: Output batch is constructed by the output pipeline after provenance
/// stamping, grounding verification, and tier assignment verification.
/// DDS-001: Submitted to the DIR as a write transaction.
struct OutputBatch: Sendable {
    /// The producer that created this batch.
    let producerIdentity: ProducerIdentity

    /// The scope this batch covers.
    let scopeWindow: ScopeWindowIdentifier

    /// The unit admissions ready for DIR submission.
    let admissions: [UnitAdmission]

    init(
        producerIdentity: ProducerIdentity,
        scopeWindow: ScopeWindowIdentifier,
        admissions: [UnitAdmission]
    ) {
        self.producerIdentity = producerIdentity
        self.scopeWindow = scopeWindow
        self.admissions = admissions
    }

    /// Whether this is an empty batch (pass had nothing to produce).
    /// DDS-003: empty input set produces empty output batch — valid, not a failure.
    var isEmpty: Bool { admissions.isEmpty }
}

// MARK: — Prior Output Summary

/// A summary of a prior output batch for changed output detection.
///
/// DDS-003: Prior output records store comparison keys (subject, predicate,
/// tier, value), not full unit records — estimated ~20 bytes per entry.
struct PriorOutputSummary: Sendable {
    /// The comparison entries from the prior output.
    let entries: Set<OutputComparisonKey>

    init(entries: Set<OutputComparisonKey>) {
        self.entries = entries
    }

    /// Creates a summary from a set of unit admissions.
    init(from admissions: [UnitAdmission]) {
        self.entries = Set(admissions.map { OutputComparisonKey(from: $0) })
    }
}

/// The key used for changed output detection comparison.
///
/// DDS-003 PC-3: Two units are identical when they share the same subject,
/// predicate, tier, and value. A change in confidence alone also constitutes
/// a change.
struct OutputComparisonKey: Hashable, Sendable {
    let subject: UnitSubject
    let predicate: PredicateIdentifier
    let tier: Tier
    let value: TypedValue
    let confidence: Confidence

    init(
        subject: UnitSubject,
        predicate: PredicateIdentifier,
        tier: Tier,
        value: TypedValue,
        confidence: Confidence
    ) {
        self.subject = subject
        self.predicate = predicate
        self.tier = tier
        self.value = value
        self.confidence = confidence
    }

    init(from admission: UnitAdmission) {
        self.subject = admission.subject
        self.predicate = admission.predicate
        self.tier = admission.tier
        self.value = admission.value
        self.confidence = admission.confidence
    }
}

// MARK: — Output Validation

/// Reasons an output batch may be rejected during validation.
///
/// DDS-001 R4 / DDS-003 FM-4: structural validation of output
/// against the producer's declared contract.
enum OutputValidationViolation: Sendable {
    /// Output predicate not in declared output contract.
    case undeclaredPredicate(PredicateIdentifier)
    /// Output tier outside declared tier range.
    case tierOutOfRange(actual: Tier, declared: ClosedRange<Tier>)
    /// Grounding reference points to a unit not in the input set
    /// or earlier in the same batch.
    case invalidGroundingRef(UnitIdentifier)
    /// Composition pass output has invalid containment declarations.
    case invalidContainment(String)
    /// Composition pass output lacks emergent properties (diagnostic warning).
    case noEmergentProperties
}
