// ModuleBoundaryPass.swift — Decode App
// PI-001: Directory-based module boundary detection composition pass.
// PI-002: Deterministic module enrichment — emergent properties from constituent files.
// Capability Spec §8.2: "The simplest and most deterministic source is project structure."
// DAS-006 CP-1: Composition passes create scope-level entities when they do not already exist.
// DAS-006 CP-4: Composition passes must produce emergent properties.
// DAS-004: Module entity — "A cohesive grouping of files that together serve a related purpose."

import Foundation
import DIRCore
import ProducerRuntime

/// Directory-based module boundary detection with deterministic enrichment.
///
/// Groups files by their containing directory and creates one Module entity per directory.
/// This is a T1 deterministic composition pass with per-system scope: it reads all
/// T0 entity predicates (produced by frontends) and creates Module entities
/// with containment relationships and emergent structural properties.
///
/// PI-001: Module entity creation (kind, name, path, fileCount, contains).
/// PI-002: Deterministic enrichment (entityCount, typeCount, functionCount,
///         importCount, relationshipCount, languageDistribution,
///         entityKindDistribution, externalImports).
enum ModuleBoundaryPass {

    // MARK: - Identity

    static let identity = ProducerIdentity(
        identifier: ProducerIdentifier(name: "module-boundary-pass"),
        version: ProducerVersion(major: 1, minor: 1)
    )

    // MARK: - Predicates

    /// Input predicates read by this pass.
    static let inputPredicates: Set<PredicateIdentifier> = [
        PredicateIdentifier(name: "kind", domain: "structure"),
        PredicateIdentifier(name: "imports", domain: "dependency"),
        PredicateIdentifier(name: "calls", domain: "relationship"),
        PredicateIdentifier(name: "conformsTo", domain: "relationship"),
        PredicateIdentifier(name: "inherits", domain: "relationship"),
        PredicateIdentifier(name: "owns", domain: "relationship"),
    ]

    /// Predicates emitted by this pass.
    static let outputPredicates: Set<PredicateIdentifier> = [
        // PI-001: Core module identity
        PredicateIdentifier(name: "kind", domain: "structure"),
        PredicateIdentifier(name: "name", domain: "structure"),
        PredicateIdentifier(name: "path", domain: "structure"),
        PredicateIdentifier(name: "fileCount", domain: "composition"),
        PredicateIdentifier(name: "contains", domain: "containment"),
        // PI-002: Deterministic enrichment
        PredicateIdentifier(name: "entityCount", domain: "composition"),
        PredicateIdentifier(name: "typeCount", domain: "composition"),
        PredicateIdentifier(name: "functionCount", domain: "composition"),
        PredicateIdentifier(name: "importCount", domain: "composition"),
        PredicateIdentifier(name: "relationshipCount", domain: "composition"),
        PredicateIdentifier(name: "languageDistribution", domain: "composition"),
        PredicateIdentifier(name: "entityKindDistribution", domain: "composition"),
        PredicateIdentifier(name: "externalImports", domain: "composition"),
    ]

    // MARK: - Contract

    /// The pass contract. Reads T0 predicates from frontends, produces T1 module entities.
    ///
    /// - Scope: perSystem — must see all files to determine all module boundaries.
    /// - Composition: true — creates Module entities (DAS-006 CP-1).
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
        isComposition: true,
        isIdempotent: true,
        dependencies: [
            ProducerIdentifier(name: "swift-syntax-frontend"),
            ProducerIdentifier(name: "tree-sitter-frontend"),
        ]
    )

    // MARK: - Handler

    /// The pass execution handler.
    ///
    /// Groups input entities by their directory path (derived from grounding chains)
    /// and creates Module entities with emergent properties for each directory group.
    static let handler: @Sendable (
        _ inputSet: [AtomicUnit],
        _ scopeWindow: ScopeWindow,
        _ passIdentity: ProducerIdentity,
        _ outputContract: OutputContract,
        _ existingScopeEntity: EntityReference?
    ) async throws -> [PassOutput] = { inputSet, _, passIdentity, _, _ in

        // Accumulator per directory — gathers all data needed for enrichment.
        var modules: [String: ModuleAccumulator] = [:]

        for unit in inputSet {
            guard unit.status == .active else { continue }

            // Extract directory from grounding chain.
            guard let dirPath = extractDirectoryPath(from: unit) else { continue }

            // Ensure accumulator exists for this directory.
            if modules[dirPath] == nil {
                modules[dirPath] = ModuleAccumulator()
            }

            // Route unit to appropriate accumulator bucket.
            if unit.predicate == PredicateIdentifier(name: "kind", domain: "structure") {
                guard case .entity(let entityRef) = unit.subject else { continue }

                let qn = entityRef.qualifiedName
                if qn.hasPrefix("file:") {
                    // File-level entity.
                    modules[dirPath]!.fileRefs.insert(entityRef)
                    // Extract file extension for language distribution (count each file once).
                    let fileName = String(qn.dropFirst(5)) // Remove "file:" prefix
                    if modules[dirPath]!.countedFileNames.insert(fileName).inserted {
                        let ext = (fileName as NSString).pathExtension
                        if !ext.isEmpty {
                            modules[dirPath]!.extensionCounts[ext, default: 0] += 1
                        }
                    }
                } else {
                    // Code entity (class, struct, function, etc.)
                    modules[dirPath]!.entityCount += 1
                    if case .string(let kindValue) = unit.value {
                        modules[dirPath]!.entityKindCounts[kindValue, default: 0] += 1
                        if isTypeKind(kindValue) {
                            modules[dirPath]!.typeCount += 1
                        } else if isFunctionKind(kindValue) {
                            modules[dirPath]!.functionCount += 1
                        }
                    }
                    // Also register as a file reference via the source file.
                    if case .direct(let sourcePos) = unit.grounding {
                        let fileName = (sourcePos.filePath as NSString).lastPathComponent
                        let fileRef = EntityReference(qualifiedName: "file:\(fileName)")
                        modules[dirPath]!.fileRefs.insert(fileRef)
                        // Language distribution (count each file once).
                        if modules[dirPath]!.countedFileNames.insert(fileName).inserted {
                            let ext = (sourcePos.filePath as NSString).pathExtension
                            if !ext.isEmpty {
                                modules[dirPath]!.extensionCounts[ext, default: 0] += 1
                            }
                        }
                    }
                }

                // Track grounding for this entity.
                modules[dirPath]!.groundingIds.insert(unit.id)

            } else if unit.predicate == PredicateIdentifier(name: "imports", domain: "dependency") {
                if case .string(let importValue) = unit.value {
                    modules[dirPath]!.uniqueImports.insert(importValue)
                }
                modules[dirPath]!.groundingIds.insert(unit.id)

            } else if isRelationshipPredicate(unit.predicate) {
                modules[dirPath]!.relationshipCount += 1
                modules[dirPath]!.groundingIds.insert(unit.id)
            }
        }

        // Build output from accumulators.
        guard !modules.isEmpty else { return [] }

        var outputs: [PassOutput] = []
        let compositionVersion = VersionStamp(singleSource: ContentHash(of: Data()))

        for (dirPath, accumulator) in modules {
            // Skip directories with no file entities (only relationships from unknown sources).
            guard !accumulator.fileRefs.isEmpty else { continue }

            let moduleName = (dirPath as NSString).lastPathComponent
            let moduleRef = EntityReference(qualifiedName: "module:\(moduleName)")
            let groundingIds = Array(accumulator.groundingIds)

            // --- PI-001: Core module identity ---

            // kind = "module"
            outputs.append(PassOutput(
                subject: .entity(moduleRef),
                predicate: PredicateIdentifier(name: "kind", domain: "structure"),
                value: .string("module"),
                tier: .t1,
                confidence: .high,
                groundingRefs: groundingIds,
                version: compositionVersion
            ))

            // name = directory name
            outputs.append(PassOutput(
                subject: .entity(moduleRef),
                predicate: PredicateIdentifier(name: "name", domain: "structure"),
                value: .string(moduleName),
                tier: .t1,
                confidence: .high,
                groundingRefs: groundingIds,
                version: compositionVersion
            ))

            // path = directory path
            outputs.append(PassOutput(
                subject: .entity(moduleRef),
                predicate: PredicateIdentifier(name: "path", domain: "structure"),
                value: .string(dirPath),
                tier: .t1,
                confidence: .high,
                groundingRefs: groundingIds,
                version: compositionVersion
            ))

            // fileCount
            outputs.append(PassOutput(
                subject: .entity(moduleRef),
                predicate: PredicateIdentifier(name: "fileCount", domain: "composition"),
                value: .integer(Int64(accumulator.fileRefs.count)),
                tier: .t1,
                confidence: .high,
                groundingRefs: groundingIds,
                version: compositionVersion
            ))

            // Containment relationships (one per file).
            for fileRef in accumulator.fileRefs {
                outputs.append(PassOutput(
                    subject: .pair(EntityPair(source: moduleRef, target: fileRef)),
                    predicate: PredicateIdentifier(name: "contains", domain: "containment"),
                    value: .boolean(true),
                    tier: .t1,
                    confidence: .high,
                    groundingRefs: groundingIds,
                    version: compositionVersion
                ))
            }

            // --- PI-002: Deterministic enrichment ---

            // entityCount — total non-file entities in the module.
            outputs.append(PassOutput(
                subject: .entity(moduleRef),
                predicate: PredicateIdentifier(name: "entityCount", domain: "composition"),
                value: .integer(Int64(accumulator.entityCount)),
                tier: .t1,
                confidence: .high,
                groundingRefs: groundingIds,
                version: compositionVersion
            ))

            // typeCount — class, struct, enum, protocol entities.
            outputs.append(PassOutput(
                subject: .entity(moduleRef),
                predicate: PredicateIdentifier(name: "typeCount", domain: "composition"),
                value: .integer(Int64(accumulator.typeCount)),
                tier: .t1,
                confidence: .high,
                groundingRefs: groundingIds,
                version: compositionVersion
            ))

            // functionCount — function and method entities.
            outputs.append(PassOutput(
                subject: .entity(moduleRef),
                predicate: PredicateIdentifier(name: "functionCount", domain: "composition"),
                value: .integer(Int64(accumulator.functionCount)),
                tier: .t1,
                confidence: .high,
                groundingRefs: groundingIds,
                version: compositionVersion
            ))

            // importCount — number of unique imports across all files.
            outputs.append(PassOutput(
                subject: .entity(moduleRef),
                predicate: PredicateIdentifier(name: "importCount", domain: "composition"),
                value: .integer(Int64(accumulator.uniqueImports.count)),
                tier: .t1,
                confidence: .high,
                groundingRefs: groundingIds,
                version: compositionVersion
            ))

            // relationshipCount — total relationship predicates within the module.
            outputs.append(PassOutput(
                subject: .entity(moduleRef),
                predicate: PredicateIdentifier(name: "relationshipCount", domain: "composition"),
                value: .integer(Int64(accumulator.relationshipCount)),
                tier: .t1,
                confidence: .high,
                groundingRefs: groundingIds,
                version: compositionVersion
            ))

            // languageDistribution — file extension → count.
            // Deduplicated: only count each file extension once per unique file.
            if !accumulator.extensionCounts.isEmpty {
                var langMap: [String: TypedValue] = [:]
                for (ext, count) in accumulator.extensionCounts {
                    langMap[ext] = .integer(Int64(count))
                }
                outputs.append(PassOutput(
                    subject: .entity(moduleRef),
                    predicate: PredicateIdentifier(name: "languageDistribution", domain: "composition"),
                    value: .structured(langMap),
                    tier: .t1,
                    confidence: .high,
                    groundingRefs: groundingIds,
                    version: compositionVersion
                ))
            }

            // entityKindDistribution — entity kind → count.
            if !accumulator.entityKindCounts.isEmpty {
                var kindMap: [String: TypedValue] = [:]
                for (kind, count) in accumulator.entityKindCounts {
                    kindMap[kind] = .integer(Int64(count))
                }
                outputs.append(PassOutput(
                    subject: .entity(moduleRef),
                    predicate: PredicateIdentifier(name: "entityKindDistribution", domain: "composition"),
                    value: .structured(kindMap),
                    tier: .t1,
                    confidence: .high,
                    groundingRefs: groundingIds,
                    version: compositionVersion
                ))
            }

            // externalImports — one predicate per unique import (module dependency surface).
            for importValue in accumulator.uniqueImports.sorted() {
                outputs.append(PassOutput(
                    subject: .entity(moduleRef),
                    predicate: PredicateIdentifier(name: "externalImports", domain: "composition"),
                    value: .string(importValue),
                    tier: .t1,
                    confidence: .high,
                    groundingRefs: groundingIds,
                    version: compositionVersion
                ))
            }
        }

        return outputs
    }

    // MARK: - Accumulator

    /// Per-directory accumulator that gathers data for module enrichment in a single pass.
    private struct ModuleAccumulator {
        var fileRefs: Set<EntityReference> = []
        var groundingIds: Set<UnitIdentifier> = []
        var entityCount: Int = 0
        var typeCount: Int = 0
        var functionCount: Int = 0
        var uniqueImports: Set<String> = []
        var relationshipCount: Int = 0
        /// Tracks file names already counted for language distribution to avoid double-counting.
        var countedFileNames: Set<String> = []
        var extensionCounts: [String: Int] = [:]
        var entityKindCounts: [String: Int] = [:]
    }

    // MARK: - Helpers

    /// Extracts the directory path from a unit's grounding chain.
    static func directoryPath(from filePath: String) -> String {
        (filePath as NSString).deletingLastPathComponent
    }

    /// Extracts the directory path from a unit's grounding chain, if available.
    private static func extractDirectoryPath(from unit: AtomicUnit) -> String? {
        if case .direct(let sourcePos) = unit.grounding {
            return directoryPath(from: sourcePos.filePath)
        }
        return nil
    }

    /// Whether an entity kind represents a type (class, struct, enum, protocol).
    private static func isTypeKind(_ kind: String) -> Bool {
        kind == "class" || kind == "struct" || kind == "enum" || kind == "protocol"
    }

    /// Whether an entity kind represents a function-like entity (function, method).
    private static func isFunctionKind(_ kind: String) -> Bool {
        kind == "function" || kind == "method"
    }

    /// Whether a predicate is a relationship predicate.
    private static func isRelationshipPredicate(_ predicate: PredicateIdentifier) -> Bool {
        predicate == PredicateIdentifier(name: "calls", domain: "relationship")
        || predicate == PredicateIdentifier(name: "conformsTo", domain: "relationship")
        || predicate == PredicateIdentifier(name: "inherits", domain: "relationship")
        || predicate == PredicateIdentifier(name: "owns", domain: "relationship")
    }
}
