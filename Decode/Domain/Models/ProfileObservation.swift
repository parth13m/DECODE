// ProfileObservation.swift — Decode Domain
//
// A single recorded observation of user behavior, used as the source of truth
// for Profile Intelligence. Observations are append-only and immutable once
// stored. The UserProfile is derived from querying accumulated observations.
//
// Fields are flattened from InsightContext for database queryability, plus
// additional metadata (mode, observationType, isFollowUp, schemaVersion).

import Foundation

// MARK: - ProfileObservation

/// An immutable record of a single user interaction event.
///
/// Created at coordinator completion points (the same locations where
/// VirtualSessionManager records insights). Stored in the GRDB database
/// as the source of truth for profile derivation.
struct ProfileObservation: Codable, Sendable, Equatable, Identifiable {

    let id: UUID
    let timestamp: Date

    /// The type of observation event.
    let observationType: ProfileObservationType

    /// The Decode mode that produced this observation.
    let mode: String

    /// Whether this observation was from a follow-up question.
    let isFollowUp: Bool

    /// Schema version for future-proof migrations. Starts at 1.
    let schemaVersion: Int

    // MARK: - Flattened InsightContext Fields

    let filePath: String?
    let fileName: String?
    let entityName: String?
    let entityType: String?
    let moduleName: String?
    let layer: String?
    let fileRole: String?
    let language: String?
    let sourceApp: String?
    let workspaceID: String?

    /// Current schema version for new observations.
    static var currentSchemaVersion: Int { ProfileIntelligenceConfig.currentSchemaVersion }

    /// Creates an observation from an InsightContext and additional metadata.
    ///
    /// This is the primary construction path — reuses the existing InsightContext
    /// built by coordinators rather than duplicating context extraction.
    init(
        context: InsightContext,
        mode: String,
        observationType: ProfileObservationType,
        isFollowUp: Bool
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.observationType = observationType
        self.mode = mode
        self.isFollowUp = isFollowUp
        self.schemaVersion = Self.currentSchemaVersion
        self.filePath = context.filePath
        self.fileName = context.fileName
        self.entityName = context.entityName
        self.entityType = context.entityType
        self.moduleName = context.moduleName
        self.layer = context.layer
        self.fileRole = context.fileRole
        self.language = context.language
        self.sourceApp = context.sourceApp
        self.workspaceID = context.workspaceID?.uuidString
    }

    /// Memberwise initializer for testing and database reconstruction.
    init(
        id: UUID,
        timestamp: Date,
        observationType: ProfileObservationType,
        mode: String,
        isFollowUp: Bool,
        schemaVersion: Int,
        filePath: String?,
        fileName: String?,
        entityName: String?,
        entityType: String?,
        moduleName: String?,
        layer: String?,
        fileRole: String?,
        language: String?,
        sourceApp: String?,
        workspaceID: String?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.observationType = observationType
        self.mode = mode
        self.isFollowUp = isFollowUp
        self.schemaVersion = schemaVersion
        self.filePath = filePath
        self.fileName = fileName
        self.entityName = entityName
        self.entityType = entityType
        self.moduleName = moduleName
        self.layer = layer
        self.fileRole = fileRole
        self.language = language
        self.sourceApp = sourceApp
        self.workspaceID = workspaceID
    }
}

// MARK: - ProfileObservationType

/// The type of user interaction event being recorded.
enum ProfileObservationType: String, Codable, Sendable, Equatable {
    /// An explanation was delivered to the user.
    case explanation

    /// A follow-up question was asked and answered.
    case followUp = "follow_up"
}
