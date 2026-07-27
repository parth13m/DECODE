// CrossFileResolutionPass.swift — Decode App
// M1: Cross-file entity resolution composition pass.
// Capability Spec §8.1: "Resolution confidence varies. An exact match on a
// unique name is high confidence. A match on a common name is lower confidence."
// DAS-005: Relationships are atomic units with paired-entity subjects.
// DAS-003 I2: T1 units use non-deterministic confidence (.high, .moderate, .low).

import Foundation
import DIRCore
import ProducerRuntime

/// Resolves symbolic relationship targets to qualified cross-file entity references.
///
/// T0 frontends produce relationship units with symbolic target names (e.g., "resolve",
/// "Sendable") that may reference entities in other files. This pass builds an entity
/// registry from all T0 `kind:structure` units and resolves each `calls`, `conformsTo`,
/// and `inherits` relationship target to its qualified cross-file entity, producing
/// T1 relationship units with the same canonical predicates.
///
/// - T0 relationships remain immutable ground truth (intra-file, symbolic targets).
/// - T1 relationships are resolved cross-file references with qualified targets.
/// - `owns` relationships are skipped (intra-file by definition).
/// - Targets with 4+ cross-file candidates are skipped (too ambiguous).
enum CrossFileResolutionPass {

    // MARK: - Identity

    static let identity = ProducerIdentity(
        identifier: ProducerIdentifier(name: "cross-file-resolution-pass"),
        version: ProducerVersion(major: 1, minor: 0)
    )

    // MARK: - Predicates

    /// Input predicates read by this pass.
    static let inputPredicates: Set<PredicateIdentifier> = [
        PredicateIdentifier(name: "kind", domain: "structure"),
        PredicateIdentifier(name: "calls", domain: "relationship"),
        PredicateIdentifier(name: "conformsTo", domain: "relationship"),
        PredicateIdentifier(name: "inherits", domain: "relationship"),
    ]

    /// Predicates emitted by this pass — same canonical names at T1.
    static let outputPredicates: Set<PredicateIdentifier> = [
        PredicateIdentifier(name: "calls", domain: "relationship"),
        PredicateIdentifier(name: "conformsTo", domain: "relationship"),
        PredicateIdentifier(name: "inherits", domain: "relationship"),
    ]

    // MARK: - Contract

    /// The pass contract. Reads T0 entity and relationship predicates, produces
    /// T1 resolved relationship units with qualified cross-file targets.
    ///
    /// - Scope: perSystem — must see all entities to resolve cross-file references.
    /// - Composition: false — does not create new entities, only resolved relationships.
    /// - Dependencies: both frontends must have run first.
    static let contract = PassContract(
        identity: identity,
        inputContract: InputContract(
            predicates: inputPredicates,
            tiers: [.t0]
        ),
        outputContract: OutputContract(
            predicates: outputPredicates,
            tierRange: .t1 ... .t1
        ),
        scope: .perSystem,
        executionStrategy: .deterministic,
        isComposition: false,
        isIdempotent: true,
        dependencies: [
            ProducerIdentifier(name: "swift-syntax-frontend"),
            ProducerIdentifier(name: "tree-sitter-frontend"),
        ]
    )

    // MARK: - Handler

    /// The pass execution handler.
    ///
    /// Phase 1: Builds an entity registry from T0 `kind:structure` units, keyed
    ///          by simple (unqualified) name for fuzzy matching.
    /// Phase 2: For each T0 relationship unit (calls/conformsTo/inherits), resolves
    ///          the symbolic target to cross-file entity candidates.
    /// Phase 3: Emits T1 relationship units with qualified targets, confidence based
    ///          on candidate count, and grounding refs to the source T0 units.
    static let handler: @Sendable (
        _ inputSet: [AtomicUnit],
        _ scopeWindow: ScopeWindow,
        _ passIdentity: ProducerIdentity,
        _ outputContract: OutputContract,
        _ existingScopeEntity: EntityReference?
    ) async throws -> [PassOutput] = { inputSet, _, _, _, _ in

        // --- Phase 1: Build entity registry ---

        // Maps simple (unqualified) name → all entities with that name.
        var entityRegistry: [String: [EntityEntry]] = [:]
        // Maps qualified name → file path for source entity file lookup.
        var entityFilePaths: [String: String] = [:]

        for unit in inputSet {
            guard unit.status == .active,
                  unit.tier == .t0,
                  unit.predicate == PredicateIdentifier(name: "kind", domain: "structure"),
                  case .entity(let entityRef) = unit.subject,
                  !entityRef.qualifiedName.hasPrefix("file:"),
                  case .direct(let sourcePos) = unit.grounding
            else { continue }

            let qualifiedName = entityRef.qualifiedName
            let simple = simpleName(from: qualifiedName)
            let filePath = sourcePos.filePath

            let entry = EntityEntry(
                qualifiedName: qualifiedName,
                unitId: unit.id,
                filePath: filePath
            )

            entityRegistry[simple, default: []].append(entry)
            entityFilePaths[qualifiedName] = filePath
        }

        // --- Phase 2 & 3: Resolve relationships and emit T1 units ---

        var outputs: [PassOutput] = []
        let version = VersionStamp(singleSource: ContentHash(of: Data()))

        for unit in inputSet {
            guard unit.status == .active,
                  unit.tier == .t0,
                  isResolvablePredicate(unit.predicate),
                  case .pair(let pair) = unit.subject
            else { continue }

            let sourceQualifiedName = pair.source.qualifiedName
            let targetSymbolicName = pair.target.qualifiedName

            // Determine source file from entity registry or unit grounding.
            let sourceFile: String?
            if let path = entityFilePaths[sourceQualifiedName] {
                sourceFile = path
            } else if case .direct(let sourcePos) = unit.grounding {
                sourceFile = sourcePos.filePath
            } else {
                sourceFile = nil
            }

            // Look up target by simple name.
            let targetSimple = simpleName(from: targetSymbolicName)
            guard let candidates = entityRegistry[targetSimple] else { continue }

            // Filter to cross-file candidates only.
            let crossFileCandidates: [EntityEntry]
            if let sourceFile = sourceFile {
                crossFileCandidates = candidates.filter { $0.filePath != sourceFile }
            } else {
                crossFileCandidates = candidates
            }

            guard !crossFileCandidates.isEmpty else { continue }

            // Skip too-ambiguous targets (4+ candidates).
            guard crossFileCandidates.count <= 3 else { continue }

            // Confidence: unique match → high, ambiguous (2-3) → low.
            let confidence: Confidence = crossFileCandidates.count == 1 ? .high : .low

            for candidate in crossFileCandidates {
                outputs.append(PassOutput(
                    subject: .pair(EntityPair(
                        source: EntityReference(qualifiedName: sourceQualifiedName),
                        target: EntityReference(qualifiedName: candidate.qualifiedName)
                    )),
                    predicate: unit.predicate,
                    value: .boolean(true),
                    tier: .t1,
                    confidence: confidence,
                    groundingRefs: [unit.id, candidate.unitId],
                    version: version
                ))
            }
        }

        return outputs
    }

    // MARK: - Private Types

    /// Registry entry for an entity discovered in T0 kind:structure units.
    private struct EntityEntry {
        let qualifiedName: String
        let unitId: UnitIdentifier
        let filePath: String
    }

    // MARK: - Helpers

    /// Extracts the simple (unqualified) name from a possibly qualified name.
    ///
    /// `"ClassName.methodName"` → `"methodName"`, `"ClassName"` → `"ClassName"`.
    static func simpleName(from qualifiedName: String) -> String {
        if let dotIndex = qualifiedName.lastIndex(of: ".") {
            return String(qualifiedName[qualifiedName.index(after: dotIndex)...])
        }
        return qualifiedName
    }

    /// Whether a predicate is a resolvable relationship predicate (excludes `owns`).
    private static func isResolvablePredicate(_ predicate: PredicateIdentifier) -> Bool {
        predicate == PredicateIdentifier(name: "calls", domain: "relationship")
        || predicate == PredicateIdentifier(name: "conformsTo", domain: "relationship")
        || predicate == PredicateIdentifier(name: "inherits", domain: "relationship")
    }
}
