// ReasoningEngineSupport.swift — Decode Application
// Shared knowledge extraction and claim generation for ReasoningEngine implementations.
// Used by ExplainReasoningEngine and ImproveReasoningEngine.

import Foundation
import ConsumerRuntime
import ContextAssembly
import DIRCore

/// Structured knowledge extracted from context frame units.
///
/// Shared across reasoning engines — the extraction logic is purpose-independent.
/// Each engine uses the same knowledge but constructs different prompts and
/// interprets responses differently.
struct ExtractedKnowledge: Sendable {
    /// Entity names discovered in units (ordered, deduplicated).
    let entityNames: [String]

    /// Per-entity knowledge: entity qualified name → [(predicate, value text, unit ID)].
    let entityFacts: [String: [(predicate: String, value: String, unitId: UnitIdentifier)]]

    /// Relationship facts: [(source, predicate, target, unit ID)].
    let relationships: [(source: String, predicate: String, target: String, unitId: UnitIdentifier)]

    /// All unit IDs present in the context frame.
    let allUnitIds: [UnitIdentifier]

    /// Detected language (from unit predicates if available).
    let detectedLanguage: String?
}

/// Shared utilities for reasoning engine implementations.
///
/// Provides knowledge extraction from ContextFrame units and grounded claim
/// generation. Both operations are purpose-independent — every reasoning engine
/// needs to extract structured knowledge and produce grounded claims.
enum ReasoningEngineSupport {

    // MARK: - Knowledge Extraction

    /// Extracts structured knowledge from context frame units.
    ///
    /// Iterates over all units, categorizing them as entity facts or relationship facts.
    /// Entity names are deduplicated and ordered by first appearance.
    static func extractKnowledge(from units: [ContextUnit]) -> ExtractedKnowledge {
        var entityNames: [String] = []
        var entityFacts: [String: [(predicate: String, value: String, unitId: UnitIdentifier)]] = [:]
        var relationships: [(source: String, predicate: String, target: String, unitId: UnitIdentifier)] = []
        var allUnitIds: [UnitIdentifier] = []
        var detectedLanguage: String?
        var seenEntities = Set<String>()

        for contextUnit in units {
            let unit = contextUnit.annotatedUnit.unit
            allUnitIds.append(unit.id)

            switch unit.subject {
            case .entity(let ref):
                let name = ref.qualifiedName
                if !seenEntities.contains(name) {
                    seenEntities.insert(name)
                    entityNames.append(name)
                }
                let valueText = textRepresentation(of: unit.value)
                entityFacts[name, default: []].append((
                    predicate: unit.predicate.name,
                    value: valueText,
                    unitId: unit.id
                ))

                if unit.predicate.name == "language" || unit.predicate.name == "sourceLanguage" {
                    detectedLanguage = valueText
                }

            case .pair(let pair):
                relationships.append((
                    source: pair.source.qualifiedName,
                    predicate: unit.predicate.name,
                    target: pair.target.qualifiedName,
                    unitId: unit.id
                ))
            }
        }

        return ExtractedKnowledge(
            entityNames: entityNames,
            entityFacts: entityFacts,
            relationships: relationships,
            allUnitIds: allUnitIds,
            detectedLanguage: detectedLanguage
        )
    }

    /// Converts a TypedValue to a human-readable text representation.
    static func textRepresentation(of value: TypedValue) -> String {
        switch value {
        case .string(let s): return s
        case .text(let t): return t
        case .integer(let i): return String(i)
        case .boolean(let b): return b ? "true" : "false"
        case .float(let f): return String(f)
        case .enumerated(let e): return e
        case .reference(let ref): return ref.qualifiedName
        case .structured(let dict):
            return dict.map { "\($0.key): \(textRepresentation(of: $0.value))" }
                .joined(separator: ", ")
        }
    }

    // MARK: - Claim Generation

    /// Builds grounded claims from extracted knowledge.
    ///
    /// DDS-009 UC-1, GP-1: Every claim must reference at least one context frame unit.
    /// Strategy: one claim per entity with all its supporting unit IDs as grounding references,
    /// plus one claim per relationship.
    static func buildClaims(
        from knowledge: ExtractedKnowledge,
        allUnits: [ContextUnit]
    ) -> [UnderstandingClaim] {
        var claims: [UnderstandingClaim] = []

        for entityName in knowledge.entityNames {
            guard let facts = knowledge.entityFacts[entityName] else { continue }
            let unitIds = facts.map { $0.unitId }
            guard !unitIds.isEmpty else { continue }

            let maxTier = unitIds.compactMap { id -> Tier? in
                allUnits.first { $0.annotatedUnit.unit.id == id }?
                    .annotatedUnit.unit.tier
            }.max() ?? .t0

            let claimType: ClaimType
            let confidence: Confidence
            switch maxTier {
            case .t0:
                claimType = .factual
                confidence = .deterministic
            case .t1:
                claimType = .derived
                confidence = .high
            case .t2:
                claimType = .interpretive
                confidence = .high
            }

            let factSummary = facts.map { "\($0.predicate): \($0.value)" }
                .joined(separator: "; ")

            claims.append(UnderstandingClaim(
                content: "Entity \(entityName): \(factSummary)",
                claimType: claimType,
                confidence: confidence,
                groundingReferences: unitIds
            ))
        }

        for rel in knowledge.relationships {
            claims.append(UnderstandingClaim(
                content: "\(rel.source) \(rel.predicate) \(rel.target)",
                claimType: .factual,
                confidence: .deterministic,
                groundingReferences: [rel.unitId]
            ))
        }

        if claims.isEmpty && !knowledge.allUnitIds.isEmpty {
            claims.append(UnderstandingClaim(
                content: "Analysis derived from \(knowledge.allUnitIds.count) context frame units.",
                claimType: .interpretive,
                confidence: .moderate,
                groundingReferences: knowledge.allUnitIds
            ))
        }

        return claims
    }
}
