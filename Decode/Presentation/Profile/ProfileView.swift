// ProfileView.swift — Decode Presentation
//
// The Profile page — a first-class sidebar page showing account information
// and what Decode has learned about the user through Profile Intelligence.
//
// This view is a pure consumer of existing systems:
// - AuthService for account metadata
// - ProfileIntelligenceService for the derived UserProfile

import SwiftUI

/// Profile page displayed in the main window detail area.
///
/// Sections:
/// 1. **Account** — name, email, status, activation date, app version, sign out
/// 2. **Decode Intelligence** — human-readable summaries from the derived UserProfile
struct ProfileView: View {

    @Environment(AppDependencies.self) private var dependencies
    @State private var viewModel: ProfileViewModel?

    // MARK: - Decode palette

    private let warmBackground = Color(red: 0.98, green: 0.97, blue: 0.95)
    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)
    private let cardBorder = Color(red: 0.91, green: 0.90, blue: 0.88)
    private let textPrimary = Color(red: 0.12, green: 0.12, blue: 0.12)
    private let textSecondary = Color(red: 0.50, green: 0.49, blue: 0.47)
    private let activeGreen = Color(red: 0.30, green: 0.69, blue: 0.31)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let vm = viewModel {
                    accountSection(vm)
                    decodeIntelligenceSection(vm)
                } else {
                    loadingView
                }
            }
            .padding(32)
        }
        .background(warmBackground)
        .task {
            let vm = ProfileViewModel(
                authService: dependencies.authService,
                profileService: dependencies.profileIntelligenceService
            )
            viewModel = vm
            await vm.load()
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.regular)
            Text("Loading profile...")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Account Section

    private func accountSection(_ vm: ProfileViewModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Account", icon: "person.crop.circle")

            card {
                VStack(alignment: .leading, spacing: 14) {
                    // Name / identity
                    accountRow(label: "Name", value: vm.accountInfo?.name)
                    accountRow(label: "Email", value: vm.accountInfo?.email)

                    Divider().overlay(cardBorder)

                    // Status
                    HStack {
                        Text("Status")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(textSecondary)
                        Spacer()
                        statusBadge(vm.accountInfo?.status)
                    }

                    // Activation date
                    if let activatedAt = vm.accountInfo?.activatedAt {
                        HStack {
                            Text("Activated")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(textSecondary)
                            Spacer()
                            Text(activatedAt, style: .date)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(textPrimary)
                        }
                    }

                    Divider().overlay(cardBorder)

                    // App info
                    HStack {
                        Text("Decode")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(textSecondary)
                        Spacer()
                        Text("v\(vm.appVersion) (\(vm.buildNumber))")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(textSecondary)
                    }

                    Divider().overlay(cardBorder)

                    // Sign out
                    HStack {
                        Spacer()
                        Button("Sign Out") {
                            vm.signOut()
                            dependencies.rebuildAIProvider()
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func accountRow(label: String, value: String?) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(textSecondary)
            Spacer()
            if let value, !value.isEmpty {
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(textPrimary)
                    .textSelection(.enabled)
            } else {
                Text("Not set")
                    .font(.system(size: 12))
                    .foregroundStyle(textSecondary.opacity(0.6))
                    .italic()
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: String?) -> some View {
        let displayStatus = status ?? "unknown"
        let isActive = displayStatus == "active"

        HStack(spacing: 5) {
            Circle()
                .fill(isActive ? activeGreen : Color.orange)
                .frame(width: 7, height: 7)
            Text(displayStatus.capitalized)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? activeGreen : .orange)
        }
    }

    // MARK: - Decode Intelligence Section

    private func decodeIntelligenceSection(_ vm: ProfileViewModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("What Decode has learned about you", icon: "sparkles")

            if vm.isLoadingProfile {
                card {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading...")
                            .font(.system(size: 12))
                            .foregroundStyle(textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                }
            } else if vm.profile.totalObservationCount < ProfileIntelligenceConfig.minObservationsForConfidence {
                intelligenceEmptyState(vm)
            } else {
                intelligenceContent(vm)
            }
        }
    }

    private func intelligenceEmptyState(_ vm: ProfileViewModel) -> some View {
        card {
            VStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 28))
                    .foregroundStyle(accentOrange.opacity(0.5))

                Text("Decode is still learning how you work")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(textPrimary)

                if vm.profile.totalObservationCount > 0 {
                    Text("\(vm.profile.totalObservationCount) of \(ProfileIntelligenceConfig.minObservationsForConfidence) interactions needed")
                        .font(.system(size: 11))
                        .foregroundStyle(textSecondary)
                } else {
                    Text("Use Decode to explain, follow up, and improve code to build your profile.")
                        .font(.system(size: 11))
                        .foregroundStyle(textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private func intelligenceContent(_ vm: ProfileViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Languages
            if !vm.profile.technology.languages.isEmpty {
                insightCard(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: "Primary Languages"
                ) {
                    languagesContent(vm.profile.technology)
                }
            }

            // Exploration areas
            if !vm.profile.learning.frequentEntityTypes.isEmpty
                || !vm.profile.learning.frequentLayers.isEmpty {
                insightCard(
                    icon: "map",
                    title: "Code Exploration"
                ) {
                    explorationContent(vm.profile.learning)
                }
            }

            // Interaction style
            if let primaryMode = vm.profile.interaction.primaryMode {
                insightCard(
                    icon: "hand.tap",
                    title: "Interaction Style"
                ) {
                    interactionContent(primaryMode, vm.profile)
                }
            }

            // Learning depth
            if vm.profile.coding.explanationCount > 0 {
                insightCard(
                    icon: "book",
                    title: "Learning Behavior"
                ) {
                    learningContent(vm.profile)
                }
            }

            // Exploration breadth
            if vm.profile.learning.distinctFilesExplored > 0 {
                insightCard(
                    icon: "rectangle.3.group",
                    title: "Exploration Breadth"
                ) {
                    breadthContent(vm.profile.learning)
                }
            }
        }
    }

    // MARK: - Intelligence Cards

    private func languagesContent(_ tech: TechnologyProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(tech.languages.prefix(5), id: \.language) { lang in
                HStack(spacing: 8) {
                    Text(lang.language)
                        .font(.system(size: 12, weight: lang.language == tech.primaryLanguage ? .semibold : .medium))
                        .foregroundStyle(lang.language == tech.primaryLanguage ? accentOrange : textPrimary)

                    if lang.language == tech.primaryLanguage {
                        Text("primary")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(accentOrange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(accentOrange.opacity(0.1))
                            )
                    }

                    Spacer()

                    frequencyBar(count: lang.count, maxCount: tech.languages.first?.count ?? 1)
                }
            }
        }
    }

    private func explorationContent(_ learning: LearningProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !learning.frequentEntityTypes.isEmpty {
                insightRow(
                    label: "Common code elements",
                    value: learning.frequentEntityTypes.prefix(3).joined(separator: ", ")
                )
            }
            if !learning.frequentLayers.isEmpty {
                insightRow(
                    label: "Architecture layers",
                    value: learning.frequentLayers.prefix(3).joined(separator: ", ")
                )
            }
            if !learning.frequentFileRoles.isEmpty {
                insightRow(
                    label: "File roles",
                    value: learning.frequentFileRoles.prefix(3).joined(separator: ", ")
                )
            }
        }
    }

    private func interactionContent(_ primaryMode: String, _ profile: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: modeIcon(primaryMode))
                    .font(.system(size: 11))
                    .foregroundStyle(accentOrange)
                Text("You prefer \(modeDisplayName(primaryMode))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(textPrimary)
            }

            if profile.interaction.modeUsage.count > 1 {
                HStack(spacing: 12) {
                    ForEach(profile.interaction.modeUsage.prefix(3), id: \.mode) { mode in
                        HStack(spacing: 4) {
                            Text(modeDisplayName(mode.mode))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(textSecondary)
                            Text("\(mode.count)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(textPrimary)
                        }
                    }
                }
            }
        }
    }

    private func learningContent(_ profile: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let followUpRate = profile.coding.followUpRate

            if followUpRate > 0.3 {
                Text("You tend to dive deep with follow-up questions")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(textPrimary)
            } else if followUpRate > 0.1 {
                Text("You occasionally ask follow-up questions for clarity")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(textPrimary)
            } else {
                Text("You prefer concise, self-contained explanations")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(textPrimary)
            }

            HStack(spacing: 16) {
                miniStat(label: "Explanations", value: "\(profile.coding.explanationCount)")
                miniStat(label: "Follow-ups", value: "\(profile.coding.followUpCount)")
            }
        }
    }

    private func breadthContent(_ learning: LearningProfile) -> some View {
        HStack(spacing: 20) {
            miniStat(label: "Files explored", value: "\(learning.distinctFilesExplored)")
            miniStat(label: "Entities explored", value: "\(learning.distinctEntitiesExplored)")
        }
    }

    // MARK: - Reusable Components

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accentOrange)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(textPrimary)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(cardBorder, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.03), radius: 6, y: 2)
        )
    }

    private func insightCard<Content: View>(
        icon: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accentOrange)
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(textSecondary)
                        .textCase(.uppercase)
                }

                content()
            }
        }
    }

    private func insightRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(textSecondary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(textPrimary)
        }
    }

    private func frequencyBar(count: Int, maxCount: Int) -> some View {
        let fraction = maxCount > 0 ? CGFloat(count) / CGFloat(maxCount) : 0

        return HStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(cardBorder)
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(accentOrange.opacity(0.6))
                        .frame(width: geometry.size.width * fraction, height: 4)
                }
            }
            .frame(width: 60, height: 4)

            Text("\(count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(textSecondary)
        }
    }

    private func miniStat(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(textPrimary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(textSecondary)
        }
    }

    // MARK: - Helpers

    private func modeDisplayName(_ mode: String) -> String {
        switch mode {
        case "selection": "Selection Mode"
        case "session": "Session Mode"
        case "screenshot": "Screenshot Mode"
        default: mode.capitalized
        }
    }

    private func modeIcon(_ mode: String) -> String {
        switch mode {
        case "selection": "text.cursor"
        case "session": "doc.text.magnifyingglass"
        case "screenshot": "camera.viewfinder"
        default: "questionmark.circle"
        }
    }
}
