import SwiftUI

/// Developer-only popover showing the current Profile Intelligence state.
///
/// Displays observation counts, language distribution, mode distribution,
/// and the derived profile. Accessible from a debug button in ContentView.
/// Not gated by `#if DEBUG` here — the call site in ContentView is gated.
struct ProfileIntelligenceInspectorView: View {

    @Environment(AppDependencies.self) private var dependencies
    @State private var profile: UserProfile = .empty
    @State private var observationCount: Int = 0
    @State private var isLoading = true

    // MARK: - WhisperFlow palette (matching ContentView)

    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)
    private let cardBorder = Color(red: 0.91, green: 0.90, blue: 0.88)
    private let textPrimary = Color(red: 0.12, green: 0.12, blue: 0.12)
    private let textSecondary = Color(red: 0.50, green: 0.49, blue: 0.47)
    private let warmBackground = Color(red: 0.98, green: 0.97, blue: 0.95)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(cardBorder)

            if isLoading {
                loadingState
            } else if profile.totalObservationCount == 0 {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        statisticsSection
                        technologySection
                        interactionSection
                        learningSection
                        codingSection
                        projectSection
                        metadataSection
                    }
                    .padding(16)
                }
            }

            Divider().overlay(cardBorder)
            actionsBar
        }
        .frame(width: 380)
        .frame(minHeight: 200, maxHeight: 600)
        .background(warmBackground)
        .task { await loadProfile() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.text.rectangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accentOrange)
            Text("Profile Intelligence")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(textPrimary)
            Spacer()
            if let service = dependencies.profileIntelligenceService {
                Text("\(service.recordedCount) recorded / \(service.failedCount) failed")
                    .font(.system(size: 10))
                    .foregroundStyle(service.failedCount > 0 ? .red : textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Statistics

    private var statisticsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Overview")
            HStack(spacing: 16) {
                statBadge(label: "Observations", value: "\(profile.totalObservationCount)")
                statBadge(label: "Confidence", value: confidenceLabel)
                statBadge(label: "Version", value: "v\(profile.profileVersion)")
            }
        }
    }

    private var confidenceLabel: String {
        let threshold = ProfileIntelligenceConfig.minObservationsForConfidence
        if profile.totalObservationCount >= threshold {
            return "Confident"
        } else {
            return "\(profile.totalObservationCount)/\(threshold)"
        }
    }

    // MARK: - Technology

    private var technologySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Technology")
            if profile.technology.languages.isEmpty {
                emptyRow("No language data")
            } else {
                ForEach(profile.technology.languages, id: \.language) { lf in
                    HStack {
                        Text(lf.language)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(textPrimary)
                        Spacer()
                        Text("\(lf.count)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(textSecondary)
                    }
                }
                if let primary = profile.technology.primaryLanguage {
                    HStack {
                        Text("Primary:")
                            .font(.system(size: 11))
                            .foregroundStyle(textSecondary)
                        Text(primary)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(accentOrange)
                    }
                }
            }
        }
    }

    // MARK: - Interaction

    private var interactionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Interaction")
            if profile.interaction.modeUsage.isEmpty {
                emptyRow("No mode data")
            } else {
                ForEach(profile.interaction.modeUsage, id: \.mode) { mf in
                    HStack {
                        Text(mf.mode)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(textPrimary)
                        Spacer()
                        Text("\(mf.count)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(textSecondary)
                    }
                }
            }
        }
    }

    // MARK: - Learning

    private var learningSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Learning")
            HStack(spacing: 16) {
                statBadge(label: "Files", value: "\(profile.learning.distinctFilesExplored)")
                statBadge(label: "Entities", value: "\(profile.learning.distinctEntitiesExplored)")
            }
            if !profile.learning.frequentLayers.isEmpty {
                HStack(spacing: 4) {
                    Text("Layers:")
                        .font(.system(size: 11))
                        .foregroundStyle(textSecondary)
                    Text(profile.learning.frequentLayers.joined(separator: ", "))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(textPrimary)
                }
            }
            if !profile.learning.frequentFileRoles.isEmpty {
                HStack(spacing: 4) {
                    Text("Roles:")
                        .font(.system(size: 11))
                        .foregroundStyle(textSecondary)
                    Text(profile.learning.frequentFileRoles.joined(separator: ", "))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(textPrimary)
                }
            }
        }
    }

    // MARK: - Coding

    private var codingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Coding")
            HStack(spacing: 16) {
                statBadge(label: "Explanations", value: "\(profile.coding.explanationCount)")
                statBadge(label: "Follow-ups", value: "\(profile.coding.followUpCount)")
                statBadge(label: "Follow-up Rate", value: String(format: "%.0f%%", profile.coding.followUpRate * 100))
            }
        }
    }

    // MARK: - Project

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Project")
            HStack(spacing: 16) {
                statBadge(label: "Workspaces", value: "\(profile.project.distinctWorkspaceCount)")
                statBadge(label: "Source Apps", value: profile.project.sourceApps.joined(separator: ", ").isEmpty ? "—" : profile.project.sourceApps.joined(separator: ", "))
            }
        }
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Metadata")
            if let lastObs = profile.lastObservationDate {
                HStack(spacing: 4) {
                    Text("Last observation:")
                        .font(.system(size: 11))
                        .foregroundStyle(textSecondary)
                    Text(lastObs, style: .relative)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(textPrimary)
                    Text("ago")
                        .font(.system(size: 11))
                        .foregroundStyle(textSecondary)
                }
            }
            if profile.derivedAt != .distantPast {
                HStack(spacing: 4) {
                    Text("Derived:")
                        .font(.system(size: 11))
                        .foregroundStyle(textSecondary)
                    Text(profile.derivedAt, style: .relative)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(textPrimary)
                    Text("ago")
                        .font(.system(size: 11))
                        .foregroundStyle(textSecondary)
                }
            }
        }
    }

    // MARK: - Actions

    private var actionsBar: some View {
        HStack {
            Button("Refresh") {
                Task {
                    dependencies.profileIntelligenceService?.invalidateCache()
                    await loadProfile()
                }
            }
            .font(.system(size: 12, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(accentOrange)

            Spacer()

            Button("Reset Profile") {
                Task {
                    guard let service = dependencies.profileIntelligenceService else { return }
                    try? await service.resetAllData()
                    await loadProfile()
                }
            }
            .font(.system(size: 12, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading profile...")
                .font(.system(size: 12))
                .foregroundStyle(textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.text.rectangle")
                .font(.system(size: 24))
                .foregroundStyle(textSecondary.opacity(0.5))
            Text("No observations yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(textSecondary)
            Text("Use Decode to build your learning profile.")
                .font(.system(size: 11))
                .foregroundStyle(textSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }

    // MARK: - Helpers

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(textSecondary)
            .textCase(.uppercase)
    }

    private func statBadge(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(textPrimary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(textSecondary)
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(textSecondary.opacity(0.7))
    }

    // MARK: - Data Loading

    private func loadProfile() async {
        isLoading = true
        if let service = dependencies.profileIntelligenceService {
            profile = await service.currentProfile()
        }
        isLoading = false
    }
}
