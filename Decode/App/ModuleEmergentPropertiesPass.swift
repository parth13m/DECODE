// ModuleEmergentPropertiesPass.swift — Decode App
// M4: Module emergent properties — properties of the group that no single file possesses.
// Capability Spec §8.3: "Interaction patterns, internal cohesion, public interface surface,
// architectural role, boundary characteristics."
// DAS-006 CP-4: Composition passes must produce emergent properties.
// DAS-003 I2: T1 units use non-deterministic confidence (.high, .moderate).

import Foundation
import DIRCore
import ProducerRuntime

/// Computes genuinely emergent properties for module entities.
///
/// This pass consumes the outputs of ModuleBoundaryPass (module entities with containment)
/// and CrossFileResolutionPass (resolved cross-file relationships) to derive properties
/// that exist only at the module level — no single file possesses them.
///
/// Emergent properties:
/// - **cohesion**: intra-module vs cross-module relationship ratio
/// - **publicInterface**: entities referenced from outside the module
/// - **interactionProfile**: distribution of intra-module relationship types
/// - **boundaryProfile**: inbound/outbound cross-module relationships by type
/// - **moduleRole**: structural classification (provider/consumer/mixed/isolated)
enum ModuleEmergentPropertiesPass {

    // MARK: - Identity

    static let identity = ProducerIdentity(
        identifier: ProducerIdentifier(name: "module-emergent-properties-pass"),
        version: ProducerVersion(major: 1, minor: 0)
    )

    // MARK: - Predicates

    /// Input predicates read by this pass.
    static let inputPredicates: Set<PredicateIdentifier> = [
        PredicateIdentifier(name: "kind", domain: "structure"),
        PredicateIdentifier(name: "contains", domain: "containment"),
        PredicateIdentifier(name: "calls", domain: "relationship"),
        PredicateIdentifier(name: "conformsTo", domain: "relationship"),
        PredicateIdentifier(name: "inherits", domain: "relationship"),
    ]

    /// Predicates emitted by this pass — emergent module-level properties.
    static let outputPredicates: Set<PredicateIdentifier> = [
        PredicateIdentifier(name: "cohesion", domain: "emergence"),
        PredicateIdentifier(name: "publicInterface", domain: "emergence"),
        PredicateIdentifier(name: "interactionProfile", domain: "emergence"),
        PredicateIdentifier(name: "boundaryProfile", domain: "emergence"),
        PredicateIdentifier(name: "moduleRole", domain: "emergence"),
    ]

    // MARK: - Contract

    /// The pass contract. Reads T0 entities/relationships and T1 module entities
    /// and resolved relationships, produces T1 emergent module properties.
    ///
    /// - Scope: perSystem — must see all modules and all cross-file relationships.
    /// - Composition: false — enriches existing module entities, does not create new ones.
    /// - Dependencies: both ModuleBoundaryPass and CrossFileResolutionPass.
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
            ProducerIdentifier(name: "module-boundary-pass"),
            ProducerIdentifier(name: "cross-file-resolution-pass"),
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

        // --- Phase 1: Build entity → module mapping ---

        // Maps entity qualified name → module name (directory-based).
        var entityToModule: [String: String] = [:]

        for unit in inputSet {
            guard unit.status == .active,
                  unit.tier == .t0,
                  unit.predicate == PredicateIdentifier(name: "kind", domain: "structure"),
                  case .entity(let entityRef) = unit.subject,
                  !entityRef.qualifiedName.hasPrefix("file:"),
                  case .direct(let sourcePos) = unit.grounding
            else { continue }

            let dirPath = (sourcePos.filePath as NSString).deletingLastPathComponent
            let moduleName = (dirPath as NSString).lastPathComponent
            entityToModule[entityRef.qualifiedName] = moduleName
        }

        // --- Phase 2: Identify modules ---

        // Maps module name → (EntityReference, grounding unit ID).
        var modules: [String: ModuleInfo] = [:]

        for unit in inputSet {
            guard unit.status == .active,
                  unit.tier == .t1,
                  unit.predicate == PredicateIdentifier(name: "kind", domain: "structure"),
                  case .entity(let entityRef) = unit.subject,
                  case .string(let kindValue) = unit.value,
                  kindValue == "module"
            else { continue }

            let moduleName = String(entityRef.qualifiedName.dropFirst("module:".count))
            modules[moduleName] = ModuleInfo(
                entityRef: entityRef,
                kindUnitId: unit.id
            )
        }

        guard !modules.isEmpty else { return [] }

        // Initialize per-module accumulators.
        var accumulators: [String: EmergenceAccumulator] = [:]
        for moduleName in modules.keys {
            accumulators[moduleName] = EmergenceAccumulator()
        }

        // --- Phase 3: Count T0 relationships per module by type ---

        let callsPredicate = PredicateIdentifier(name: "calls", domain: "relationship")
        let conformsToPredicate = PredicateIdentifier(name: "conformsTo", domain: "relationship")
        let inheritsPredicate = PredicateIdentifier(name: "inherits", domain: "relationship")

        for unit in inputSet {
            guard unit.status == .active,
                  unit.tier == .t0,
                  isRelationshipPredicate(unit.predicate),
                  case .pair(let pair) = unit.subject
            else { continue }

            // Determine source entity's module.
            guard let sourceModule = entityToModule[pair.source.qualifiedName] else { continue }
            guard accumulators[sourceModule] != nil else { continue }

            // T0 relationships are intra-file → always intra-module.
            if unit.predicate == callsPredicate {
                accumulators[sourceModule]!.internalCalls += 1
            } else if unit.predicate == conformsToPredicate {
                accumulators[sourceModule]!.internalConformsTo += 1
            } else if unit.predicate == inheritsPredicate {
                accumulators[sourceModule]!.internalInherits += 1
            }

            accumulators[sourceModule]!.groundingIds.insert(unit.id)
        }

        // --- Phase 4: Classify T1 cross-file relationships ---

        for unit in inputSet {
            guard unit.status == .active,
                  unit.tier == .t1,
                  isRelationshipPredicate(unit.predicate),
                  case .pair(let pair) = unit.subject
            else { continue }

            let sourceModule = entityToModule[pair.source.qualifiedName]
            let targetModule = entityToModule[pair.target.qualifiedName]

            // Skip if we can't determine modules for both endpoints.
            guard let srcMod = sourceModule else { continue }
            guard let tgtMod = targetModule else { continue }

            if srcMod == tgtMod {
                // Intra-module (cross-file but same module).
                guard accumulators[srcMod] != nil else { continue }
                if unit.predicate == callsPredicate {
                    accumulators[srcMod]!.internalCalls += 1
                } else if unit.predicate == conformsToPredicate {
                    accumulators[srcMod]!.internalConformsTo += 1
                } else if unit.predicate == inheritsPredicate {
                    accumulators[srcMod]!.internalInherits += 1
                }
                accumulators[srcMod]!.groundingIds.insert(unit.id)
            } else {
                // Cross-module: outbound from source module, inbound to target module.
                if accumulators[srcMod] != nil {
                    if unit.predicate == callsPredicate {
                        accumulators[srcMod]!.outboundCalls += 1
                    } else if unit.predicate == conformsToPredicate {
                        accumulators[srcMod]!.outboundConformsTo += 1
                    } else if unit.predicate == inheritsPredicate {
                        accumulators[srcMod]!.outboundInherits += 1
                    }
                    accumulators[srcMod]!.groundingIds.insert(unit.id)
                }

                if accumulators[tgtMod] != nil {
                    if unit.predicate == callsPredicate {
                        accumulators[tgtMod]!.inboundCalls += 1
                    } else if unit.predicate == conformsToPredicate {
                        accumulators[tgtMod]!.inboundConformsTo += 1
                    } else if unit.predicate == inheritsPredicate {
                        accumulators[tgtMod]!.inboundInherits += 1
                    }
                    // Track public interface: target entity is externally referenced.
                    accumulators[tgtMod]!.externallyReferencedEntities.insert(pair.target.qualifiedName)
                    accumulators[tgtMod]!.groundingIds.insert(unit.id)
                }
            }
        }

        // --- Phase 5: Emit emergent property units ---

        var outputs: [PassOutput] = []
        let version = VersionStamp(singleSource: ContentHash(of: Data()))

        for (moduleName, moduleInfo) in modules {
            guard let acc = accumulators[moduleName] else { continue }

            let moduleRef = moduleInfo.entityRef
            var groundingIds = Array(acc.groundingIds)
            groundingIds.append(moduleInfo.kindUnitId)

            // 1. Cohesion
            let internalTotal = acc.internalCalls + acc.internalConformsTo + acc.internalInherits
            let externalTotal = acc.outboundCalls + acc.outboundConformsTo + acc.outboundInherits
            let total = internalTotal + externalTotal
            let ratio: Double = total > 0 ? Double(internalTotal) / Double(total) : 1.0

            outputs.append(PassOutput(
                subject: .entity(moduleRef),
                predicate: PredicateIdentifier(name: "cohesion", domain: "emergence"),
                value: .structured([
                    "internal": .integer(Int64(internalTotal)),
                    "external": .integer(Int64(externalTotal)),
                    "ratio": .float(ratio),
                ]),
                tier: .t1,
                confidence: .high,
                groundingRefs: groundingIds,
                version: version
            ))

            // 2. Public Interface
            let sortedPublicEntities = acc.externallyReferencedEntities.sorted()
            outputs.append(PassOutput(
                subject: .entity(moduleRef),
                predicate: PredicateIdentifier(name: "publicInterface", domain: "emergence"),
                value: .structured([
                    "count": .integer(Int64(sortedPublicEntities.count)),
                    "entities": .string(sortedPublicEntities.joined(separator: ", ")),
                ]),
                tier: .t1,
                confidence: .high,
                groundingRefs: groundingIds,
                version: version
            ))

            // 3. Interaction Profile
            outputs.append(PassOutput(
                subject: .entity(moduleRef),
                predicate: PredicateIdentifier(name: "interactionProfile", domain: "emergence"),
                value: .structured([
                    "calls": .integer(Int64(acc.internalCalls)),
                    "conformsTo": .integer(Int64(acc.internalConformsTo)),
                    "inherits": .integer(Int64(acc.internalInherits)),
                ]),
                tier: .t1,
                confidence: .high,
                groundingRefs: groundingIds,
                version: version
            ))

            // 4. Boundary Profile
            outputs.append(PassOutput(
                subject: .entity(moduleRef),
                predicate: PredicateIdentifier(name: "boundaryProfile", domain: "emergence"),
                value: .structured([
                    "inboundCalls": .integer(Int64(acc.inboundCalls)),
                    "outboundCalls": .integer(Int64(acc.outboundCalls)),
                    "inboundConformsTo": .integer(Int64(acc.inboundConformsTo)),
                    "outboundConformsTo": .integer(Int64(acc.outboundConformsTo)),
                    "inboundInherits": .integer(Int64(acc.inboundInherits)),
                    "outboundInherits": .integer(Int64(acc.outboundInherits)),
                ]),
                tier: .t1,
                confidence: .high,
                groundingRefs: groundingIds,
                version: version
            ))

            // 5. Module Role
            let totalInbound = acc.inboundCalls + acc.inboundConformsTo + acc.inboundInherits
            let totalOutbound = acc.outboundCalls + acc.outboundConformsTo + acc.outboundInherits
            let role = classifyModuleRole(inbound: totalInbound, outbound: totalOutbound)

            outputs.append(PassOutput(
                subject: .entity(moduleRef),
                predicate: PredicateIdentifier(name: "moduleRole", domain: "emergence"),
                value: .string(role),
                tier: .t1,
                confidence: role == "isolated" ? .high : .moderate,
                groundingRefs: groundingIds,
                version: version
            ))
        }

        return outputs
    }

    // MARK: - Private Types

    /// Identifies a module entity for output emission.
    private struct ModuleInfo {
        let entityRef: EntityReference
        let kindUnitId: UnitIdentifier
    }

    /// Per-module accumulator for emergent property computation.
    private struct EmergenceAccumulator {
        // Intra-module relationship counts by type.
        var internalCalls: Int = 0
        var internalConformsTo: Int = 0
        var internalInherits: Int = 0

        // Cross-module inbound counts by type.
        var inboundCalls: Int = 0
        var inboundConformsTo: Int = 0
        var inboundInherits: Int = 0

        // Cross-module outbound counts by type.
        var outboundCalls: Int = 0
        var outboundConformsTo: Int = 0
        var outboundInherits: Int = 0

        // Entities in this module that are targets of cross-module relationships.
        var externallyReferencedEntities: Set<String> = []

        // Grounding evidence.
        var groundingIds: Set<UnitIdentifier> = []
    }

    // MARK: - Helpers

    /// Classifies a module's structural role based on cross-module relationship direction.
    ///
    /// - `isolated`: no cross-module relationships
    /// - `provider`: predominantly inbound (inbound >= 2 * outbound, or outbound == 0)
    /// - `consumer`: predominantly outbound (outbound >= 2 * inbound, or inbound == 0)
    /// - `mixed`: both inbound and outbound without clear dominance
    static func classifyModuleRole(inbound: Int, outbound: Int) -> String {
        let total = inbound + outbound
        guard total > 0 else { return "isolated" }

        if outbound == 0 { return "provider" }
        if inbound == 0 { return "consumer" }
        if inbound >= 2 * outbound { return "provider" }
        if outbound >= 2 * inbound { return "consumer" }
        return "mixed"
    }

    /// Whether a predicate is a relationship predicate relevant to emergence.
    private static func isRelationshipPredicate(_ predicate: PredicateIdentifier) -> Bool {
        predicate == PredicateIdentifier(name: "calls", domain: "relationship")
        || predicate == PredicateIdentifier(name: "conformsTo", domain: "relationship")
        || predicate == PredicateIdentifier(name: "inherits", domain: "relationship")
    }
}
