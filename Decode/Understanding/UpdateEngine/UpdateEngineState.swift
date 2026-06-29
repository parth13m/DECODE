// UpdateEngineState.swift — UpdateEngine
// DDS-007: 5-state lifecycle model
// Created → Reconciling → Idle ↔ Processing → Quiescing → Terminated

import Foundation

/// The lifecycle state of the Update Engine.
///
/// DDS-007 State Model:
/// - Created: Constructed, dependencies available, reconciliation not started.
/// - Reconciling: Processing reconciliation and/or producer upgrades at startup.
/// - Idle: No change set being processed. DIR consistent at committed epoch.
/// - Processing: Change set going through synchronous pipeline.
/// - Quiescing: Shutdown in progress.
/// - Terminated: Destroyed.
public enum UpdateEngineState: String, Hashable, Sendable {
    case created
    case reconciling
    case idle
    case processing
    case quiescing
    case terminated

    /// Returns whether a transition from this state to the target is valid.
    ///
    /// DDS-007 Lifecycle transitions:
    /// - Created → Reconciling
    /// - Reconciling → Idle
    /// - Idle → Processing
    /// - Processing → Idle
    /// - Idle → Quiescing
    /// - Processing → Quiescing
    /// - Quiescing → Terminated
    public func canTransition(to target: UpdateEngineState) -> Bool {
        switch (self, target) {
        case (.created, .reconciling),
             (.reconciling, .idle),
             (.idle, .processing),
             (.processing, .idle),
             (.idle, .quiescing),
             (.processing, .quiescing),
             (.quiescing, .terminated):
            return true
        default:
            return false
        }
    }
}
