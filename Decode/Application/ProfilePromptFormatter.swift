// ProfilePromptFormatter.swift — Decode Application
//
// Converts a UserProfile into a compact, advisory prompt section for
// Selection and Screenshot mode explanations.
//
// Design principles:
// - Advisory, not authoritative — the current user request always dominates.
// - Confidence-gated — only includes dimensions above the confidence threshold.
// - Compact — targets 100–250 tokens. Never dumps raw statistics.
// - Empty-safe — returns nil when the profile has nothing useful to contribute.

import Foundation

/// Formats a ``UserProfile`` into a concise prompt section suitable for
/// injection into Selection and Screenshot mode system prompts.
///
/// Returns `nil` when the profile is empty, below confidence threshold,
/// or has no information that would meaningfully improve explanations.
enum ProfilePromptFormatter {

    /// Format the profile into an advisory prompt section.
    ///
    /// Returns `nil` if the profile has insufficient observations or
    /// no confident dimensions — callers should skip injection entirely.
    static func format(_ profile: UserProfile) -> String? {
        let threshold = ProfileIntelligenceConfig.minObservationsForConfidence
        guard profile.totalObservationCount >= threshold else { return nil }

        var sections: [String] = []

        if let tech = technologySection(profile.technology) {
            sections.append(tech)
        }
        if let learning = learningSection(profile.learning) {
            sections.append(learning)
        }
        if let interaction = interactionSection(profile.interaction) {
            sections.append(interaction)
        }
        if let preference = preferenceSection(profile.preference, coding: profile.coding) {
            sections.append(preference)
        }

        guard !sections.isEmpty else { return nil }

        let body = sections.joined(separator: "\n")

        return """
            [User Profile Context]
            The following is derived from the user's previous interactions. \
            Use it as background context to tailor your explanation, but always \
            prioritise the user's current request.
            \(body)
            """
    }

    // MARK: - Section Builders

    private static func technologySection(_ tech: TechnologyProfile) -> String? {
        guard let primary = tech.primaryLanguage else { return nil }

        var line = "- The user appears most familiar with \(primary)."
        if tech.languages.count > 1 {
            let others = tech.languages
                .dropFirst()
                .prefix(3)
                .map(\.language)
            line += " They also work with \(others.joined(separator: ", "))."
        }
        line += " When appropriate, prefer terminology and examples from these languages, while following the current request."
        return line
    }

    private static func learningSection(_ learning: LearningProfile) -> String? {
        guard !learning.frequentLayers.isEmpty || !learning.frequentEntityTypes.isEmpty else {
            return nil
        }

        var parts: [String] = []

        if !learning.frequentEntityTypes.isEmpty {
            let types = learning.frequentEntityTypes.prefix(3).joined(separator: ", ")
            parts.append("frequently explores \(types)")
        }

        if !learning.frequentLayers.isEmpty {
            let layers = learning.frequentLayers.prefix(3).joined(separator: ", ")
            parts.append("often works in the \(layers) layer\(learning.frequentLayers.count > 1 ? "s" : "")")
        }

        guard !parts.isEmpty else { return nil }
        return "- The user \(parts.joined(separator: " and "))."
    }

    private static func interactionSection(_ interaction: InteractionProfile) -> String? {
        guard let primaryMode = interaction.primaryMode else { return nil }
        return "- The user frequently uses \(primaryMode) mode when exploring code."
    }

    private static func preferenceSection(_ preference: PreferenceProfile, coding: CodingProfile) -> String? {
        var parts: [String] = []

        if preference.averageFollowUpsPerSession > 0.5 {
            parts.append("tends to ask follow-up questions, suggesting they value depth over brevity")
        } else if coding.explanationCount >= ProfileIntelligenceConfig.minObservationsForConfidence
                    && preference.averageFollowUpsPerSession < 0.1 {
            parts.append("rarely asks follow-ups, suggesting they prefer concise, self-contained explanations")
        }

        guard !parts.isEmpty else { return nil }
        return "- The user \(parts.joined(separator: " and "))."
    }
}
