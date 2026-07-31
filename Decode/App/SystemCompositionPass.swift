// SystemCompositionPass.swift — Decode App
// M8: System entity creation via module → system composition.
// Capability Spec §9.1: "A System entity represents the entire codebase (DAS-004)."
// DAS-006 CP-1: Composition passes create scope-level entities when they do not already exist.
// DAS-006 CP-3: The pass must place System in the containment tree.
// DAS-004: System entity — the top-level Logical Software entity.

import Foundation
import DIRCore
import ProducerRuntime

/// Module → System composition pass.
///
/// Reads all T1 module entities (produced by ModuleBoundaryPass) and creates
/// a single System entity representing the entire analyzed codebase. Establishes
/// System → Module containment relationships and carries structural metadata
/// aggregated from constituent modules.
///
/// This is a T1 deterministic composition pass with per-system scope.
/// It produces the root of the containment tree: System → Module → File → Entity.
///
/// The system entity name is deterministically derived from the common root
/// directory of all module paths.
enum SystemCompositionPass {

    // MARK: - Identity

    static let identity = ProducerIdentity(
        identifier: ProducerIdentifier(name: "system-composition-pass"),
        version: ProducerVersion(major: 1, minor: 0)
    )

    // MARK: - Predicates

    /// Input predicates read by this pass.
    static let inputPredicates: Set<PredicateIdentifier> = [
        PredicateIdentifier(name: "kind", domain: "structure"),
        PredicateIdentifier(name: "name", domain: "structure"),
        PredicateIdentifier(name: "path", domain: "structure"),
        PredicateIdentifier(name: "fileCount", domain: "composition"),
        PredicateIdentifier(name: "entityCount", domain: "composition"),
        PredicateIdentifier(name: "languageDistribution", domain: "composition"),
    ]

    /// Predicates emitted by this pass.
    static let outputPredicates: Set<PredicateIdentifier> = [
        PredicateIdentifier(name: "kind", domain: "structure"),
        PredicateIdentifier(name: "name", domain: "structure"),
        PredicateIdentifier(name: "path", domain: "structure"),
        PredicateIdentifier(name: "moduleCount", domain: "composition"),
        PredicateIdentifier(name: "totalFileCount", domain: "composition"),
        PredicateIdentifier(name: "totalEntityCount", domain: "composition"),
        PredicateIdentifier(name: "languageDistribution", domain: "composition"),
        PredicateIdentifier(name: "contains", domain: "containment"),
    ]

    // MARK: - Contract

    /// The pass contract. Reads T1 module predicates, produces T1 system entity.
    ///
    /// - Scope: perSystem — must see all modules to compose the system entity.
    /// - Composition: true — creates System entity (DAS-006 CP-1).
    /// - Dependencies: ModuleBoundaryPass must have run first.
    static let contract = PassContract(
        identity: identity,
        inputContract: InputContract(
            predicates: inputPredicates,
            tiers: [.t1]
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
            ProducerIdentifier(name: "module-boundary-pass"),
        ]
    )

    // MARK: - Handler

    /// The pass execution handler.
    ///
    /// Discovers all module entities from T1 input, aggregates their structural
    /// metadata, derives a system name from the common root directory, and
    /// produces a single system entity with containment relationships to all modules.
    static let handler: @Sendable (
        _ inputSet: [AtomicUnit],
        _ scopeWindow: ScopeWindow,
        _ passIdentity: ProducerIdentity,
        _ outputContract: OutputContract,
        _ existingScopeEntity: EntityReference?
    ) async throws -> [PassOutput] = { inputSet, _, _, _, _ in

        // --- Phase 1: Discover module entities ---

        // Maps module qualified name → module info (EntityReference + kind unit ID).
        var modules: [String: ModuleInfo] = [:]

        for unit in inputSet {
            guard unit.status == .active,
                  unit.tier == .t1,
                  unit.predicate == PredicateIdentifier(name: "kind", domain: "structure"),
                  case .entity(let entityRef) = unit.subject,
                  case .string(let kindValue) = unit.value,
                  kindValue == "module"
            else { continue }

            modules[entityRef.qualifiedName] = ModuleInfo(
                entityRef: entityRef,
                kindUnitId: unit.id
            )
        }

        guard !modules.isEmpty else { return [] }

        // --- Phase 2: Collect module metadata ---

        var accumulator = SystemAccumulator()
        accumulator.moduleRefs = modules.values.map { $0.entityRef }
        accumulator.groundingIds = Set(modules.values.map { $0.kindUnitId })

        for unit in inputSet {
            guard unit.status == .active,
                  unit.tier == .t1,
                  case .entity(let entityRef) = unit.subject,
                  modules[entityRef.qualifiedName] != nil
            else { continue }

            switch unit.predicate {
            case PredicateIdentifier(name: "path", domain: "structure"):
                if case .string(let path) = unit.value {
                    accumulator.modulePaths.append(path)
                }
                accumulator.groundingIds.insert(unit.id)

            case PredicateIdentifier(name: "fileCount", domain: "composition"):
                if case .integer(let count) = unit.value {
                    accumulator.totalFileCount += Int(count)
                }
                accumulator.groundingIds.insert(unit.id)

            case PredicateIdentifier(name: "entityCount", domain: "composition"):
                if case .integer(let count) = unit.value {
                    accumulator.totalEntityCount += Int(count)
                }
                accumulator.groundingIds.insert(unit.id)

            case PredicateIdentifier(name: "languageDistribution", domain: "composition"):
                if case .structured(let langMap) = unit.value {
                    for (ext, value) in langMap {
                        if case .integer(let count) = value {
                            accumulator.languageCounts[ext, default: 0] += Int(count)
                        }
                    }
                }
                accumulator.groundingIds.insert(unit.id)

            default:
                break
            }
        }

        // --- Phase 3: Derive system identity ---

        let systemName = deriveSystemName(from: accumulator.modulePaths)
        let systemPath = commonRootPath(from: accumulator.modulePaths)
        let systemRef = EntityReference(qualifiedName: "system:\(systemName)")

        // --- Phase 4: Emit outputs ---

        var outputs: [PassOutput] = []
        let version = VersionStamp(singleSource: ContentHash(of: Data()))
        let groundingIds = Array(accumulator.groundingIds)

        // kind = "system"
        outputs.append(PassOutput(
            subject: .entity(systemRef),
            predicate: PredicateIdentifier(name: "kind", domain: "structure"),
            value: .string("system"),
            tier: .t1,
            confidence: .high,
            groundingRefs: groundingIds,
            version: version
        ))

        // name = system name
        outputs.append(PassOutput(
            subject: .entity(systemRef),
            predicate: PredicateIdentifier(name: "name", domain: "structure"),
            value: .string(systemName),
            tier: .t1,
            confidence: .high,
            groundingRefs: groundingIds,
            version: version
        ))

        // path = common root path
        outputs.append(PassOutput(
            subject: .entity(systemRef),
            predicate: PredicateIdentifier(name: "path", domain: "structure"),
            value: .string(systemPath),
            tier: .t1,
            confidence: .high,
            groundingRefs: groundingIds,
            version: version
        ))

        // moduleCount
        outputs.append(PassOutput(
            subject: .entity(systemRef),
            predicate: PredicateIdentifier(name: "moduleCount", domain: "composition"),
            value: .integer(Int64(modules.count)),
            tier: .t1,
            confidence: .high,
            groundingRefs: groundingIds,
            version: version
        ))

        // totalFileCount
        outputs.append(PassOutput(
            subject: .entity(systemRef),
            predicate: PredicateIdentifier(name: "totalFileCount", domain: "composition"),
            value: .integer(Int64(accumulator.totalFileCount)),
            tier: .t1,
            confidence: .high,
            groundingRefs: groundingIds,
            version: version
        ))

        // totalEntityCount
        outputs.append(PassOutput(
            subject: .entity(systemRef),
            predicate: PredicateIdentifier(name: "totalEntityCount", domain: "composition"),
            value: .integer(Int64(accumulator.totalEntityCount)),
            tier: .t1,
            confidence: .high,
            groundingRefs: groundingIds,
            version: version
        ))

        // languageDistribution — merged across all modules.
        if !accumulator.languageCounts.isEmpty {
            var langMap: [String: TypedValue] = [:]
            for (ext, count) in accumulator.languageCounts {
                langMap[ext] = .integer(Int64(count))
            }
            outputs.append(PassOutput(
                subject: .entity(systemRef),
                predicate: PredicateIdentifier(name: "languageDistribution", domain: "composition"),
                value: .structured(langMap),
                tier: .t1,
                confidence: .high,
                groundingRefs: groundingIds,
                version: version
            ))
        }

        // Containment relationships (one per module: System → Module).
        for moduleInfo in modules.values {
            outputs.append(PassOutput(
                subject: .pair(EntityPair(source: systemRef, target: moduleInfo.entityRef)),
                predicate: PredicateIdentifier(name: "contains", domain: "containment"),
                value: .boolean(true),
                tier: .t1,
                confidence: .high,
                groundingRefs: groundingIds,
                version: version
            ))
        }

        return outputs
    }

    // MARK: - Internal Types

    private struct ModuleInfo {
        let entityRef: EntityReference
        let kindUnitId: UnitIdentifier
    }

    private struct SystemAccumulator {
        var moduleRefs: [EntityReference] = []
        var modulePaths: [String] = []
        var totalFileCount: Int = 0
        var totalEntityCount: Int = 0
        var languageCounts: [String: Int] = [:]
        var groundingIds: Set<UnitIdentifier> = []
    }

    // MARK: - System Naming

    /// Derives the system name from the common root of all module paths.
    ///
    /// Algorithm: find the longest common path prefix, then extract the last
    /// path component. Falls back to "system" if paths are empty or the
    /// common prefix is the filesystem root.
    static func deriveSystemName(from modulePaths: [String]) -> String {
        let root = commonRootPath(from: modulePaths)
        guard !root.isEmpty, root != "/" else { return "system" }
        let name = (root as NSString).lastPathComponent
        guard !name.isEmpty else { return "system" }
        return name
    }

    /// Computes the longest common directory prefix from a set of paths.
    ///
    /// Returns the deepest directory that is a prefix of all provided paths.
    /// Returns an empty string if paths is empty.
    static func commonRootPath(from paths: [String]) -> String {
        guard let first = paths.first else { return "" }
        guard paths.count > 1 else {
            // Single module: system root is the parent of the module's path.
            return (first as NSString).deletingLastPathComponent
        }

        let components = paths.map { ($0 as NSString).pathComponents }
        let minLength = components.map(\.count).min() ?? 0

        var commonComponents: [String] = []
        for i in 0..<minLength {
            let component = components[0][i]
            if components.allSatisfy({ $0[i] == component }) {
                commonComponents.append(component)
            } else {
                break
            }
        }

        guard !commonComponents.isEmpty else { return "" }

        // NSString.pathComponents includes "/" as the first component for absolute paths.
        // Join them back into a proper path.
        if commonComponents.first == "/" {
            if commonComponents.count == 1 {
                return "/"
            }
            return "/" + commonComponents.dropFirst().joined(separator: "/")
        }
        return commonComponents.joined(separator: "/")
    }
}
