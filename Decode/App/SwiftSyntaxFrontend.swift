// SwiftSyntaxFrontend.swift — Decode App
// IAG-004 §18: First production producer — bridges SwiftSyntaxParser
// to the ProducerRuntime via FrontendOutput.

import Foundation
import DIRCore
import ProducerRuntime

// MARK: - Shared Conversion (DetailedParseResult → FrontendOutput)

/// Converts a `DetailedParseResult` into DIR-compatible `FrontendOutput` records.
///
/// Shared by `SwiftSyntaxFrontend` and `TreeSitterFrontend` — both produce
/// the same output predicates from the same `DetailedParseResult` structure.
/// Only the parser and source formats differ.
enum FrontendOutputConversion {

    /// The set of output predicates emitted by all deterministic frontends.
    static let outputPredicates: Set<PredicateIdentifier> = [
        // Entity predicates
        PredicateIdentifier(name: "kind", domain: "structure"),
        PredicateIdentifier(name: "signature", domain: "structure"),
        PredicateIdentifier(name: "startLine", domain: "structure"),
        PredicateIdentifier(name: "endLine", domain: "structure"),
        PredicateIdentifier(name: "parentEntity", domain: "structure"),
        // Import predicates
        PredicateIdentifier(name: "imports", domain: "dependency"),
        // Relationship predicates
        PredicateIdentifier(name: "calls", domain: "relationship"),
        PredicateIdentifier(name: "conformsTo", domain: "relationship"),
        PredicateIdentifier(name: "inherits", domain: "relationship"),
        PredicateIdentifier(name: "owns", domain: "relationship"),
        // Containment predicates (DAS-004 CONT-3: File → entity containment)
        PredicateIdentifier(name: "contains", domain: "containment"),
    ]

    /// Converts a `DetailedParseResult` into `[FrontendOutput]` records at T0.
    ///
    /// - Parameters:
    ///   - result: The parse result from either SwiftSyntaxParser or TreeSitterParser.
    ///   - fileName: The file name (used for file-level import entity).
    ///   - version: The version stamp derived from the file's content hash.
    ///   - filePath: The absolute file path for source grounding (DAS-002 I-GND-1).
    /// - Returns: Array of FrontendOutput records ready for ProducerRuntime.
    static func convert(
        result: DetailedParseResult,
        fileName: String,
        version: VersionStamp,
        filePath: String
    ) -> [FrontendOutput] {
        var outputs: [FrontendOutput] = []
        outputs.reserveCapacity(result.entities.count * 5 + result.imports.count + result.relationships.count)

        // Build stableId → entity name mapping for relationship resolution.
        let entityNameByStableId = Dictionary(
            result.entities.map { ($0.entity.stableId, $0.entity.name) },
            uniquingKeysWith: { first, _ in first }
        )

        // --- Entities ---
        // Deduplicate entities by qualified name to avoid supersession key
        // conflicts (e.g., file defines the same class name twice).
        var seenEntityNames: Set<String> = []
        for entity in result.entities {
            let qualifiedName = qualifiedEntityName(entity: entity, allEntities: result.entities)
            guard seenEntityNames.insert(qualifiedName).inserted else { continue }
            let entityRef = EntityReference(qualifiedName: qualifiedName)
            let subject = UnitSubject.entity(entityRef)

            // kind
            outputs.append(FrontendOutput(
                subject: subject,
                predicate: PredicateIdentifier(name: "kind", domain: "structure"),
                value: .string(entity.entity.entityType.rawValue),
                tier: .t0,
                confidence: .deterministic,
                version: version,
                sourceFilePath: filePath,
                sourceStartLine: entity.startLine,
                sourceEndLine: entity.endLine
            ))

            // signature
            if !entity.signature.isEmpty {
                outputs.append(FrontendOutput(
                    subject: subject,
                    predicate: PredicateIdentifier(name: "signature", domain: "structure"),
                    value: .string(entity.signature),
                    tier: .t0,
                    confidence: .deterministic,
                    version: version,
                    sourceFilePath: filePath,
                    sourceStartLine: entity.startLine,
                    sourceEndLine: entity.endLine
                ))
            }

            // startLine
            outputs.append(FrontendOutput(
                subject: subject,
                predicate: PredicateIdentifier(name: "startLine", domain: "structure"),
                value: .integer(Int64(entity.startLine)),
                tier: .t0,
                confidence: .deterministic,
                version: version,
                sourceFilePath: filePath,
                sourceStartLine: entity.startLine,
                sourceEndLine: entity.endLine
            ))

            // endLine
            outputs.append(FrontendOutput(
                subject: subject,
                predicate: PredicateIdentifier(name: "endLine", domain: "structure"),
                value: .integer(Int64(entity.endLine)),
                tier: .t0,
                confidence: .deterministic,
                version: version,
                sourceFilePath: filePath,
                sourceStartLine: entity.startLine,
                sourceEndLine: entity.endLine
            ))

            // parentEntity (if nested)
            if let parentId = entity.parentStableId,
               let parentName = entityNameByStableId[parentId] {
                outputs.append(FrontendOutput(
                    subject: subject,
                    predicate: PredicateIdentifier(name: "parentEntity", domain: "structure"),
                    value: .reference(EntityReference(qualifiedName: parentName)),
                    tier: .t0,
                    confidence: .deterministic,
                    version: version,
                    sourceFilePath: filePath,
                    sourceStartLine: entity.startLine,
                    sourceEndLine: entity.endLine
                ))
            }
        }

        // --- File → Entity Containment (DAS-004 CONT-3) ---
        // Every entity declared in this file gets a deterministic T0
        // contains(File → Entity) relationship. This mirrors syntactic
        // declaration structure — below the file boundary, containment
        // is populated by source parsers.
        // Uses seenEntityNames from above to avoid duplicate containment entries.
        let fileEntityRef = EntityReference(qualifiedName: "file:\(fileName)")
        var seenContainmentNames: Set<String> = []
        for entity in result.entities {
            let qualifiedName = qualifiedEntityName(entity: entity, allEntities: result.entities)
            guard seenContainmentNames.insert(qualifiedName).inserted else { continue }
            let entityRef = EntityReference(qualifiedName: qualifiedName)

            outputs.append(FrontendOutput(
                subject: .pair(EntityPair(source: fileEntityRef, target: entityRef)),
                predicate: PredicateIdentifier(name: "contains", domain: "containment"),
                value: .boolean(true),
                tier: .t0,
                confidence: .deterministic,
                version: version,
                sourceFilePath: filePath
            ))
        }

        // --- Imports ---
        // All imports are combined into a single unit to avoid supersession
        // key conflicts (same subject + predicate + tier = same key).
        let fileSubject = UnitSubject.entity(fileEntityRef)

        if !result.imports.isEmpty {
            let importLines = result.imports.map { imp -> String in
                if imp.importedSymbols.isEmpty {
                    return imp.moduleName
                } else {
                    return "\(imp.moduleName).\(imp.importedSymbols.joined(separator: ", "))"
                }
            }
            let combinedValue = importLines.joined(separator: "\n")

            outputs.append(FrontendOutput(
                subject: fileSubject,
                predicate: PredicateIdentifier(name: "imports", domain: "dependency"),
                value: .string(combinedValue),
                tier: .t0,
                confidence: .deterministic,
                version: version,
                sourceFilePath: filePath
            ))
        }

        // --- Relationships ---
        // Deduplicate relationships to avoid supersession key conflicts
        // (e.g., multiple calls to print() from the same function produce
        // the same pair(caller→callee) + calls key).
        var seenRelationshipKeys: Set<String> = []
        for rel in result.relationships {
            let sourceName = entityNameByStableId[rel.sourceEntity] ?? rel.sourceEntity
            let predicate: PredicateIdentifier
            switch rel.kind {
            case .calls:
                predicate = PredicateIdentifier(name: "calls", domain: "relationship")
            case .conformsTo:
                predicate = PredicateIdentifier(name: "conformsTo", domain: "relationship")
            case .inherits:
                predicate = PredicateIdentifier(name: "inherits", domain: "relationship")
            case .owns:
                predicate = PredicateIdentifier(name: "owns", domain: "relationship")
            }

            let dedupeKey = "\(sourceName)|\(rel.targetName)|\(predicate.name)"
            guard seenRelationshipKeys.insert(dedupeKey).inserted else { continue }

            outputs.append(FrontendOutput(
                subject: .pair(EntityPair(
                    source: EntityReference(qualifiedName: sourceName),
                    target: EntityReference(qualifiedName: rel.targetName)
                )),
                predicate: predicate,
                value: .boolean(true),
                tier: .t0,
                confidence: .deterministic,
                version: version,
                sourceFilePath: filePath
            ))
        }

        return outputs
    }

    /// Builds a qualified name for an entity, including parent type if nested.
    ///
    /// Top-level: `"ClassName"`. Nested: `"ClassName.MethodName"`.
    static func qualifiedEntityName(
        entity: ParsedEntity,
        allEntities: [ParsedEntity]
    ) -> String {
        guard let parentId = entity.parentStableId else {
            return entity.entity.name
        }
        if let parent = allEntities.first(where: { $0.entity.stableId == parentId }) {
            return "\(parent.entity.name).\(entity.entity.name)"
        }
        return entity.entity.name
    }
}

// MARK: - SwiftSyntax Frontend

/// The contract and handler for the SwiftSyntax frontend producer.
///
/// All Swift source files are handled by this frontend. It delegates to
/// `SwiftSyntaxParser.parseAllFacts` and converts the result into DIR-compatible
/// `FrontendOutput` records at T0 (deterministic extraction).
enum SwiftSyntaxFrontend {

    /// Producer identity for the SwiftSyntax frontend.
    static let identity = ProducerIdentity(
        identifier: ProducerIdentifier(name: "swift-syntax-frontend"),
        version: ProducerVersion(major: 1, minor: 0)
    )

    /// The frontend contract for registration with ProducerRuntime.
    static let contract = FrontendContract(
        identity: identity,
        sourceFormats: ["swift"],
        outputContract: OutputContract(
            predicates: FrontendOutputConversion.outputPredicates,
            tierRange: .t0 ... .t0
        )
    )

    /// The frontend handler that parses a Swift file and produces FrontendOutput records.
    static let handler: @Sendable (
        _ filePath: String,
        _ identity: ProducerIdentity,
        _ outputContract: OutputContract
    ) async throws -> [FrontendOutput] = { filePath, _, _ in
        let url = URL(fileURLWithPath: filePath)
        let data = try Data(contentsOf: url)
        guard let source = String(data: data, encoding: .utf8) else {
            return []
        }

        let contentHash = ContentHash(of: data)
        let version = VersionStamp(singleSource: contentHash)
        let fileName = url.lastPathComponent

        let parser = SwiftSyntaxParser()
        let result = parser.parseAllFacts(source: source, fileName: fileName)

        return FrontendOutputConversion.convert(
            result: result,
            fileName: fileName,
            version: version,
            filePath: filePath
        )
    }
}
