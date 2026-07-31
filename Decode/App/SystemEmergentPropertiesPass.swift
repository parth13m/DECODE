// SystemEmergentPropertiesPass.swift — Decode App
// M9: System emergent properties — properties of the architecture that no single module possesses.
// Capability Spec §9.1: "The System entity carries properties that no individual module possesses:
// architecture style, dependency direction, cross-cutting patterns, module interaction map,
// technology distribution."
// DAS-006 CP-2: Composition passes enrich scope-level entities when they already exist.
// DAS-006 CP-4: Composition passes must produce emergence.
// DAS-001 P4: Composition produces emergence.

import Foundation
import DIRCore
import ProducerRuntime

/// Computes genuinely emergent properties for the system entity.
///
/// This pass consumes the outputs of SystemCompositionPass (system entity with containment),
/// ModuleEmergentPropertiesPass (module-level emergent properties), and
/// CrossFileResolutionPass (resolved cross-file relationships) to derive properties
/// that exist only at the system level — no single module possesses them.
///
/// Emergent properties:
/// - **architectureStyle**: structural classification (layered, hub_and_spoke, modular, etc.)
/// - **dependencyDirection**: directed module dependency graph with layer detection
/// - **crossCuttingPatterns**: entities and patterns spanning ≥3 module boundaries
/// - **moduleInteractionMap**: typed interaction matrix between modules
/// - **technologyDistribution**: system-wide technology profile with primary language
enum SystemEmergentPropertiesPass {

    // MARK: - Identity

    static let identity = ProducerIdentity(
        identifier: ProducerIdentifier(name: "system-emergent-properties-pass"),
        version: ProducerVersion(major: 1, minor: 0)
    )

    // MARK: - Predicates

    /// Input predicates read by this pass.
    static let inputPredicates: Set<PredicateIdentifier> = [
        // From M4 (ModuleEmergentPropertiesPass):
        PredicateIdentifier(name: "cohesion", domain: "emergence"),
        PredicateIdentifier(name: "publicInterface", domain: "emergence"),
        PredicateIdentifier(name: "interactionProfile", domain: "emergence"),
        PredicateIdentifier(name: "boundaryProfile", domain: "emergence"),
        PredicateIdentifier(name: "moduleRole", domain: "emergence"),
        // From M8 (SystemCompositionPass) and ModuleBoundaryPass:
        PredicateIdentifier(name: "kind", domain: "structure"),
        PredicateIdentifier(name: "contains", domain: "containment"),
        PredicateIdentifier(name: "languageDistribution", domain: "composition"),
        // From M1 (CrossFileResolutionPass):
        PredicateIdentifier(name: "calls", domain: "relationship"),
        PredicateIdentifier(name: "conformsTo", domain: "relationship"),
        PredicateIdentifier(name: "inherits", domain: "relationship"),
    ]

    /// Predicates emitted by this pass — emergent system-level properties.
    static let outputPredicates: Set<PredicateIdentifier> = [
        PredicateIdentifier(name: "architectureStyle", domain: "emergence"),
        PredicateIdentifier(name: "dependencyDirection", domain: "emergence"),
        PredicateIdentifier(name: "crossCuttingPatterns", domain: "emergence"),
        PredicateIdentifier(name: "moduleInteractionMap", domain: "emergence"),
        PredicateIdentifier(name: "technologyDistribution", domain: "emergence"),
    ]

    // MARK: - Contract

    /// The pass contract. Reads T0/T1 entities and relationships plus T1 module/system
    /// predicates, produces T1 system-level emergent properties.
    ///
    /// - Scope: perSystem — must see all modules and relationships.
    /// - Composition: false — enriches the existing system entity (DAS-006 CP-2).
    /// - Dependencies: SystemCompositionPass and ModuleEmergentPropertiesPass.
    static let contract = PassContract(
        identity: identity,
        inputContract: InputContract(
            predicates: inputPredicates,
            tiers: [.t0, .t1]
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
            ProducerIdentifier(name: "system-composition-pass"),
            ProducerIdentifier(name: "module-emergent-properties-pass"),
        ]
    )

    // MARK: - Handler

    static let handler: @Sendable (
        _ inputSet: [AtomicUnit],
        _ scopeWindow: ScopeWindow,
        _ passIdentity: ProducerIdentity,
        _ outputContract: OutputContract,
        _ existingScopeEntity: EntityReference?
    ) async throws -> [PassOutput] = { inputSet, _, _, _, _ in

        // --- Phase 1: Identify system entity and modules ---

        var systemRef: EntityReference?
        var systemKindUnitId: UnitIdentifier?

        // Maps module name → (EntityReference, kindUnitId)
        var modules: [String: ModuleInfo] = [:]

        // Maps entity qualified name → module name (for entity→module resolution)
        var entityToModule: [String: String] = [:]

        for unit in inputSet {
            guard unit.status == .active else { continue }

            if unit.predicate == PredicateIdentifier(name: "kind", domain: "structure") {
                if case .entity(let ref) = unit.subject,
                   case .string(let kindValue) = unit.value {
                    if kindValue == "system" && unit.tier == .t1 {
                        systemRef = ref
                        systemKindUnitId = unit.id
                    } else if kindValue == "module" && unit.tier == .t1 {
                        let moduleName = String(ref.qualifiedName.dropFirst("module:".count))
                        modules[moduleName] = ModuleInfo(
                            entityRef: ref,
                            kindUnitId: unit.id
                        )
                    } else if unit.tier == .t0,
                              !ref.qualifiedName.hasPrefix("file:"),
                              case .direct(let sourcePos) = unit.grounding {
                        // Build entity→module mapping from T0 entities (same as M4).
                        let dirPath = (sourcePos.filePath as NSString).deletingLastPathComponent
                        let moduleName = (dirPath as NSString).lastPathComponent
                        entityToModule[ref.qualifiedName] = moduleName
                    }
                }
            }
        }

        guard let systemRef, let systemKindUnitId else { return [] }
        guard !modules.isEmpty else { return [] }

        // --- Phase 2: Build module interaction map from cross-module relationships ---

        // Key: "sourceModule→targetModule", Value: per-type counts
        var interactions: [String: InteractionCounts] = [:]
        // Track which target entities are referenced by which source modules
        var entitySourceModules: [String: Set<String>] = [:]
        // Track relationship type per (target entity, source module) for cross-cutting classification
        var entityRelTypes: [String: Set<String>] = [:]
        var relationshipGroundingIds: Set<UnitIdentifier> = []

        let callsPred = PredicateIdentifier(name: "calls", domain: "relationship")
        let conformsToPred = PredicateIdentifier(name: "conformsTo", domain: "relationship")
        let inheritsPred = PredicateIdentifier(name: "inherits", domain: "relationship")

        for unit in inputSet {
            guard unit.status == .active,
                  unit.tier == .t1,
                  isRelationshipPredicate(unit.predicate),
                  case .pair(let pair) = unit.subject
            else { continue }

            guard let srcMod = entityToModule[pair.source.qualifiedName],
                  let tgtMod = entityToModule[pair.target.qualifiedName]
            else { continue }

            // Only cross-module relationships contribute to system-level properties.
            guard srcMod != tgtMod else { continue }
            guard modules[srcMod] != nil, modules[tgtMod] != nil else { continue }

            let key = "\(srcMod)→\(tgtMod)"
            if interactions[key] == nil {
                interactions[key] = InteractionCounts()
            }

            if unit.predicate == callsPred {
                interactions[key]!.calls += 1
            } else if unit.predicate == conformsToPred {
                interactions[key]!.conformsTo += 1
            } else if unit.predicate == inheritsPred {
                interactions[key]!.inherits += 1
            }

            // Track cross-cutting: which modules reference this target entity
            entitySourceModules[pair.target.qualifiedName, default: []].insert(srcMod)
            if unit.predicate == callsPred {
                entityRelTypes[pair.target.qualifiedName, default: []].insert("calls")
            } else if unit.predicate == conformsToPred {
                entityRelTypes[pair.target.qualifiedName, default: []].insert("conformsTo")
            } else if unit.predicate == inheritsPred {
                entityRelTypes[pair.target.qualifiedName, default: []].insert("inherits")
            }

            relationshipGroundingIds.insert(unit.id)
        }

        // --- Phase 3: Collect module emergent properties ---

        var moduleRoles: [String: String] = [:]
        var moduleLangDists: [String: [String: Int]] = [:]
        var emergenceGroundingIds: Set<UnitIdentifier> = []

        for unit in inputSet {
            guard unit.status == .active,
                  unit.tier == .t1,
                  case .entity(let ref) = unit.subject,
                  ref.qualifiedName.hasPrefix("module:")
            else { continue }

            let moduleName = String(ref.qualifiedName.dropFirst("module:".count))
            guard modules[moduleName] != nil else { continue }

            switch unit.predicate {
            case PredicateIdentifier(name: "moduleRole", domain: "emergence"):
                if case .string(let role) = unit.value {
                    moduleRoles[moduleName] = role
                }
                emergenceGroundingIds.insert(unit.id)

            case PredicateIdentifier(name: "languageDistribution", domain: "composition"):
                if case .structured(let langMap) = unit.value {
                    var dist: [String: Int] = [:]
                    for (ext, tv) in langMap {
                        if case .integer(let count) = tv {
                            dist[ext] = Int(count)
                        }
                    }
                    moduleLangDists[moduleName] = dist
                }
                emergenceGroundingIds.insert(unit.id)

            case PredicateIdentifier(name: "cohesion", domain: "emergence"),
                 PredicateIdentifier(name: "publicInterface", domain: "emergence"),
                 PredicateIdentifier(name: "interactionProfile", domain: "emergence"),
                 PredicateIdentifier(name: "boundaryProfile", domain: "emergence"):
                emergenceGroundingIds.insert(unit.id)

            default:
                break
            }
        }

        // --- Phase 4: Compute emergent properties ---

        // 4a. Module interaction map
        let interactionMap = computeModuleInteractionMap(interactions)

        // 4b. Dependency direction (uses interaction map)
        let depDirection = computeDependencyDirection(
            interactions: interactions,
            moduleNames: Array(modules.keys).sorted()
        )

        // 4c. Cross-cutting patterns
        let crossCutting = computeCrossCuttingPatterns(
            entitySourceModules: entitySourceModules,
            entityRelTypes: entityRelTypes
        )

        // 4d. Technology distribution
        let techDist = computeTechnologyDistribution(moduleLangDists)

        // 4e. Architecture style (uses dependency direction results)
        let archStyle = computeArchitectureStyle(
            depDirection: depDirection,
            interactions: interactions,
            moduleCount: modules.count
        )

        // --- Phase 5: Emit outputs ---

        var outputs: [PassOutput] = []
        let version = VersionStamp(singleSource: ContentHash(of: Data()))

        // Combine all grounding: system kind unit + module emergence + relationships
        var allGroundingIds: Set<UnitIdentifier> = [systemKindUnitId]
        allGroundingIds.formUnion(emergenceGroundingIds)
        allGroundingIds.formUnion(relationshipGroundingIds)
        allGroundingIds.formUnion(modules.values.map { $0.kindUnitId })
        let groundingIds = Array(allGroundingIds)

        // 1. moduleInteractionMap — deterministic, .high
        outputs.append(PassOutput(
            subject: .entity(systemRef),
            predicate: PredicateIdentifier(name: "moduleInteractionMap", domain: "emergence"),
            value: interactionMap,
            tier: .t1,
            confidence: .high,
            groundingRefs: groundingIds,
            version: version
        ))

        // 2. dependencyDirection — deterministic, .high
        outputs.append(PassOutput(
            subject: .entity(systemRef),
            predicate: PredicateIdentifier(name: "dependencyDirection", domain: "emergence"),
            value: depDirection.value,
            tier: .t1,
            confidence: .high,
            groundingRefs: groundingIds,
            version: version
        ))

        // 3. crossCuttingPatterns — heuristic, .moderate
        outputs.append(PassOutput(
            subject: .entity(systemRef),
            predicate: PredicateIdentifier(name: "crossCuttingPatterns", domain: "emergence"),
            value: crossCutting,
            tier: .t1,
            confidence: .moderate,
            groundingRefs: groundingIds,
            version: version
        ))

        // 4. technologyDistribution — deterministic, .high
        outputs.append(PassOutput(
            subject: .entity(systemRef),
            predicate: PredicateIdentifier(name: "technologyDistribution", domain: "emergence"),
            value: techDist,
            tier: .t1,
            confidence: .high,
            groundingRefs: groundingIds,
            version: version
        ))

        // 5. architectureStyle — heuristic, .moderate
        outputs.append(PassOutput(
            subject: .entity(systemRef),
            predicate: PredicateIdentifier(name: "architectureStyle", domain: "emergence"),
            value: archStyle,
            tier: .t1,
            confidence: .moderate,
            groundingRefs: groundingIds,
            version: version
        ))

        return outputs
    }

    // MARK: - Computation: Module Interaction Map

    /// Computes the module interaction map from cross-module relationship counts.
    ///
    /// Returns a structured value: keys are "srcModule→tgtModule" strings,
    /// values are structured counts by relationship type.
    static func computeModuleInteractionMap(
        _ interactions: [String: InteractionCounts]
    ) -> TypedValue {
        var map: [String: TypedValue] = [:]
        for (key, counts) in interactions.sorted(by: { $0.key < $1.key }) {
            map[key] = .structured([
                "calls": .integer(Int64(counts.calls)),
                "conformsTo": .integer(Int64(counts.conformsTo)),
                "inherits": .integer(Int64(counts.inherits)),
            ])
        }
        map["edgeCount"] = .integer(Int64(interactions.count))
        return .structured(map)
    }

    // MARK: - Computation: Dependency Direction

    /// Result of dependency direction computation, used by architecture style classification.
    struct DependencyDirectionResult {
        let value: TypedValue
        let layerCount: Int
        let hasCycles: Bool
        let violationCount: Int
        let totalEdges: Int
    }

    /// Computes the dependency direction graph with layer detection.
    ///
    /// Uses topological sort to assign depth to each module. Modules with zero
    /// outbound dependencies are at depth 0 (leaf layer). Cycles are detected
    /// and marked.
    static func computeDependencyDirection(
        interactions: [String: InteractionCounts],
        moduleNames: [String]
    ) -> DependencyDirectionResult {
        // Build adjacency: source depends on target (source → target = dependency).
        var dependsOn: [String: Set<String>] = [:]
        for name in moduleNames {
            dependsOn[name] = []
        }
        for (key, _) in interactions {
            let parts = key.split(separator: "→", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let src = String(parts[0])
            let tgt = String(parts[1])
            if dependsOn[src] != nil {
                dependsOn[src]!.insert(tgt)
            }
        }

        // Topological sort via Kahn's algorithm to detect cycles and assign layers.
        // "Depth" here means: leaf modules (no outbound dependencies) are depth 0,
        // modules depending only on depth-0 are depth 1, etc.
        var depths: [String: Int] = [:]
        var remaining = dependsOn
        var assigned: Set<String> = []
        var currentDepth = 0

        while assigned.count < moduleNames.count {
            // Find modules whose remaining dependencies are all already assigned.
            var batch: [String] = []
            for name in moduleNames where !assigned.contains(name) {
                let deps = remaining[name] ?? []
                if deps.isSubset(of: assigned) {
                    batch.append(name)
                }
            }

            if batch.isEmpty {
                // Cycle detected: remaining unassigned modules form a cycle.
                for name in moduleNames where !assigned.contains(name) {
                    depths[name] = -1
                }
                break
            }

            for name in batch {
                depths[name] = currentDepth
                assigned.insert(name)
            }
            currentDepth += 1
        }

        let hasCycles = depths.values.contains(-1)
        let maxDepth = depths.values.filter { $0 >= 0 }.max() ?? 0
        let layerCount = hasCycles ? (maxDepth + 1) : (depths.isEmpty ? 0 : maxDepth + 1)

        // Detect violations: an edge from a lower depth to a higher depth.
        // A module at depth 2 depending on a module at depth 3 is a violation
        // (higher layers should not be depended upon by lower layers).
        var violations: [(String, String)] = []
        for (key, _) in interactions {
            let parts = key.split(separator: "→", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let src = String(parts[0])
            let tgt = String(parts[1])
            let srcDepth = depths[src] ?? -1
            let tgtDepth = depths[tgt] ?? -1
            // A violation is when the target is at a higher depth than the source.
            // In a layered arch: high depth depends on low depth. So src.depth > tgt.depth is normal.
            // tgt.depth > src.depth means lower layer depends on higher layer = violation.
            if srcDepth >= 0 && tgtDepth >= 0 && tgtDepth > srcDepth {
                violations.append((src, tgt))
            }
        }

        // Build layers array.
        var layerModules: [Int: [String]] = [:]
        for (name, depth) in depths {
            layerModules[depth, default: []].append(name)
        }
        // Sort modules within each layer for determinism.
        for key in layerModules.keys {
            layerModules[key]?.sort()
        }

        var layersArray: [TypedValue] = []
        for depth in (layerModules.keys.sorted()) {
            if let mods = layerModules[depth] {
                layersArray.append(.structured([
                    "depth": .integer(Int64(depth)),
                    "modules": .string(mods.joined(separator: ",")),
                ]))
            }
        }

        let violationStrings = violations.sorted(by: { "\($0.0)→\($0.1)" < "\($1.0)→\($1.1)" })
            .map { "\($0.0)→\($0.1)" }

        var resultMap: [String: TypedValue] = [
            "layerCount": .integer(Int64(layerCount)),
            "hasCycles": .boolean(hasCycles),
            "violationCount": .integer(Int64(violations.count)),
        ]
        if !violationStrings.isEmpty {
            resultMap["violations"] = .string(violationStrings.joined(separator: ","))
        }
        // Encode layers as a string representation for structured value compatibility.
        var layerEntries: [String] = []
        for depth in layerModules.keys.sorted() {
            if let mods = layerModules[depth] {
                layerEntries.append("d\(depth):\(mods.joined(separator: ","))")
            }
        }
        resultMap["layers"] = .string(layerEntries.joined(separator: ";"))

        return DependencyDirectionResult(
            value: .structured(resultMap),
            layerCount: layerCount,
            hasCycles: hasCycles,
            violationCount: violations.count,
            totalEdges: interactions.count
        )
    }

    // MARK: - Computation: Cross-Cutting Patterns

    /// Minimum number of distinct source modules referencing an entity
    /// for it to be considered cross-cutting.
    static let crossCuttingThreshold = 3

    /// Computes cross-cutting patterns from entity reference distribution.
    static func computeCrossCuttingPatterns(
        entitySourceModules: [String: Set<String>],
        entityRelTypes: [String: Set<String>]
    ) -> TypedValue {
        // Find entities referenced by >= threshold distinct source modules.
        var crossCutting: [(entity: String, moduleCount: Int, classification: String)] = []

        for (entity, sourceMods) in entitySourceModules {
            guard sourceMods.count >= crossCuttingThreshold else { continue }

            let relTypes = entityRelTypes[entity] ?? []
            let classification: String
            if relTypes == ["conformsTo"] {
                classification = "protocol_boundary"
            } else if relTypes == ["calls"] {
                classification = "shared_service"
            } else if relTypes == ["inherits"] {
                classification = "shared_base"
            } else {
                classification = "shared_dependency"
            }

            crossCutting.append((entity, sourceMods.count, classification))
        }

        // Sort for determinism: by module count descending, then entity name ascending.
        crossCutting.sort { a, b in
            if a.moduleCount != b.moduleCount { return a.moduleCount > b.moduleCount }
            return a.entity < b.entity
        }

        let patternStrings = crossCutting.map { "\($0.entity)(\($0.classification),\($0.moduleCount)modules)" }

        return .structured([
            "count": .integer(Int64(crossCutting.count)),
            "patterns": .string(patternStrings.joined(separator: ";")),
            "threshold": .integer(Int64(crossCuttingThreshold)),
        ])
    }

    // MARK: - Computation: Technology Distribution

    /// Computes system-wide technology distribution from module language distributions.
    static func computeTechnologyDistribution(
        _ moduleLangDists: [String: [String: Int]]
    ) -> TypedValue {
        var systemDist: [String: Int] = [:]
        for (_, langDist) in moduleLangDists {
            for (ext, count) in langDist {
                systemDist[ext, default: 0] += count
            }
        }

        // Primary language: highest count, lexicographic tiebreaker.
        let primaryLanguage: String
        if systemDist.isEmpty {
            primaryLanguage = "unknown"
        } else {
            let maxCount = systemDist.values.max() ?? 0
            let candidates = systemDist.filter { $0.value == maxCount }.keys.sorted()
            primaryLanguage = candidates.first ?? "unknown"
        }

        var resultMap: [String: TypedValue] = [
            "primaryLanguage": .string(primaryLanguage),
            "languageCount": .integer(Int64(systemDist.count)),
        ]
        // Include per-language counts.
        for (ext, count) in systemDist.sorted(by: { $0.key < $1.key }) {
            resultMap[ext] = .integer(Int64(count))
        }

        return .structured(resultMap)
    }

    // MARK: - Computation: Architecture Style

    /// Computes the architecture style classification from dependency direction results.
    static func computeArchitectureStyle(
        depDirection: DependencyDirectionResult,
        interactions: [String: InteractionCounts],
        moduleCount: Int
    ) -> TypedValue {
        let style: String
        let evidence: String

        if moduleCount <= 1 {
            style = "isolated"
            evidence = "single module system"
        } else if depDirection.hasCycles {
            style = "entangled"
            evidence = "cyclic dependencies detected"
        } else if depDirection.layerCount >= 3 && depDirection.violationCount == 0 {
            style = "layered"
            evidence = "\(depDirection.layerCount) distinct layers, 0 violations"
        } else if depDirection.layerCount >= 3 && depDirection.totalEdges > 0 {
            let violationRatio = Double(depDirection.violationCount) / Double(depDirection.totalEdges)
            if violationRatio <= 0.2 {
                style = "layered_with_violations"
                evidence = "\(depDirection.layerCount) layers, \(depDirection.violationCount) violations (\(Int(violationRatio * 100))% of edges)"
            } else {
                style = "mixed"
                evidence = "\(depDirection.layerCount) layers but \(depDirection.violationCount) violations (\(Int(violationRatio * 100))% of edges)"
            }
        } else if isHubAndSpoke(interactions: interactions, moduleCount: moduleCount) {
            style = "hub_and_spoke"
            evidence = "central module receives ≥50% of inbound edges"
        } else if depDirection.totalEdges > 0 {
            style = "modular"
            evidence = "peer modules with cross-module dependencies"
        } else {
            style = "isolated"
            evidence = "no cross-module dependencies"
        }

        return .structured([
            "style": .string(style),
            "evidence": .string(evidence),
        ])
    }

    /// Detects hub-and-spoke pattern: one module receives ≥50% of all inbound edges.
    private static func isHubAndSpoke(
        interactions: [String: InteractionCounts],
        moduleCount: Int
    ) -> Bool {
        guard moduleCount >= 3 else { return false }

        var inboundCounts: [String: Int] = [:]
        for (key, counts) in interactions {
            let parts = key.split(separator: "→", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let tgt = String(parts[1])
            inboundCounts[tgt, default: 0] += counts.calls + counts.conformsTo + counts.inherits
        }

        let totalInbound = inboundCounts.values.reduce(0, +)
        guard totalInbound > 0 else { return false }

        let maxInbound = inboundCounts.values.max() ?? 0
        return Double(maxInbound) >= Double(totalInbound) * 0.5
    }

    // MARK: - Internal Types

    private struct ModuleInfo {
        let entityRef: EntityReference
        let kindUnitId: UnitIdentifier
    }

    /// Per-edge interaction counts between two modules.
    struct InteractionCounts {
        var calls: Int = 0
        var conformsTo: Int = 0
        var inherits: Int = 0

        var total: Int { calls + conformsTo + inherits }
    }

    // MARK: - Helpers

    /// Whether a predicate is a relationship predicate relevant to system emergence.
    private static func isRelationshipPredicate(_ predicate: PredicateIdentifier) -> Bool {
        predicate == PredicateIdentifier(name: "calls", domain: "relationship")
        || predicate == PredicateIdentifier(name: "conformsTo", domain: "relationship")
        || predicate == PredicateIdentifier(name: "inherits", domain: "relationship")
    }
}
