import SwiftUI

/// Settings interface showing account status and backend connection.
///
/// With the platform transition to the Decode Gateway, users no longer
/// manage API keys or select providers. This view shows:
/// - Authentication status
/// - Backend connection state
/// - User ID
struct SettingsView: View {

    @Environment(AppDependencies.self) private var dependencies

    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)
    private let activeGreen = Color(red: 0.30, green: 0.69, blue: 0.31)

    var body: some View {
        Form {
            accountSection
            connectionSection
            aboutSection
        }
        .formStyle(.grouped)
        .tint(accentOrange)
        .preferredColorScheme(.light)
        .frame(minWidth: 450, idealWidth: 500, maxWidth: 600)
        .frame(minHeight: 300)
    }

    // MARK: - Account

    private var accountSection: some View {
        Section("Account") {
            HStack {
                Label {
                    Text(authStatusText)
                        .font(.body)
                } icon: {
                    Image(systemName: authStatusIcon)
                        .foregroundStyle(authStatusColor)
                }

                Spacer()

                authStatusBadge
            }

            if let userId = UserDefaults.standard.string(forKey: "decodeAuthenticatedUserID") {
                HStack {
                    Text("User ID")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(userId.prefix(8)) + "...")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if dependencies.authService.state == .authenticated {
                Button("Sign Out", role: .destructive) {
                    dependencies.authService.signOut()
                    dependencies.rebuildAIProvider()
                }
            }
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section("AI Service") {
            HStack {
                Label {
                    Text("Decode Gateway")
                        .font(.body)
                } icon: {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if dependencies.isConfigured {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(activeGreen)
                        .font(.caption)
                } else {
                    Label("Not Connected", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            HStack {
                Text("Model")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Claude Sonnet 4")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Auth Status Helpers

    private var authStatusText: String {
        switch dependencies.authService.state {
        case .authenticated: "Connected"
        case .authenticating: "Verifying..."
        case .needsInvite: "Not Connected"
        case .disabled: "Account Disabled"
        case .offline: "Offline"
        case .error: "Connection Error"
        }
    }

    private var authStatusIcon: String {
        switch dependencies.authService.state {
        case .authenticated: "person.crop.circle.badge.checkmark"
        case .authenticating: "arrow.triangle.2.circlepath"
        case .needsInvite: "person.crop.circle.badge.questionmark"
        case .disabled: "person.crop.circle.badge.xmark"
        case .offline: "wifi.slash"
        case .error: "exclamationmark.triangle"
        }
    }

    private var authStatusColor: Color {
        switch dependencies.authService.state {
        case .authenticated: activeGreen
        case .authenticating: .orange
        case .needsInvite: .secondary
        case .disabled: .red
        case .offline: .orange
        case .error: .red
        }
    }

    @ViewBuilder
    private var authStatusBadge: some View {
        switch dependencies.authService.state {
        case .authenticated:
            Label("Active", systemImage: "checkmark.circle.fill")
                .foregroundStyle(activeGreen)
                .font(.caption)
        case .disabled:
            Label("Disabled", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        case .offline:
            Button("Retry") {
                Task {
                    await dependencies.authService.retryValidation()
                    dependencies.rebuildAIProvider()
                }
            }
            .font(.caption)
        default:
            EmptyView()
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppDependencies())
        .frame(width: 500, height: 400)
}
