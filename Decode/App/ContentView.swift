import SwiftUI

/// Navigation page within the main window.
private enum AppPage: Hashable {
    case home
    case notes
    case sessionMode
    case profile
}

/// The root view of the application.
///
/// Displays a welcome state with guidance to configure the AI provider
/// via the Settings window (Cmd+,).
struct ContentView: View {

    @Environment(AppDependencies.self) private var dependencies
    @State private var selectedPage: AppPage = .home
    @State private var showingOnboarding = !OnboardingState.hasCompleted
    @State private var showingMemoryInspector = false
    @State private var showingProfileInspector = false
    @AppStorage("dsaModeEnabled") private var dsaModeEnabled = false
    @AppStorage("virtualSessionEnabled") private var virtualSessionEnabled = false

    // MARK: - WhisperFlow-inspired palette

    private let warmBackground = Color(red: 0.98, green: 0.97, blue: 0.95)
    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)
    private let cardBorder = Color(red: 0.91, green: 0.90, blue: 0.88)
    private let textPrimary = Color(red: 0.12, green: 0.12, blue: 0.12)
    private let textSecondary = Color(red: 0.50, green: 0.49, blue: 0.47)

    var body: some View {
        Group {
            switch dependencies.authService.state {
            case .authenticating:
                authLoadingView
            case .needsInvite, .error:
                InviteCodeView()
                    .environment(dependencies)
            case .disabled:
                disabledView
            case .offline:
                offlineView
            case .authenticated:
                authenticatedContent
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .background(warmBackground)
        .background(WindowCloseButtonFix())
    }

    // MARK: - Authenticated Content

    private var authenticatedContent: some View {
        HStack(spacing: 0) {
            // Custom sidebar
            VStack(spacing: 0) {
                // Logo
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(accentOrange.opacity(0.15))
                            .frame(width: 28, height: 28)
                        Text("D")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(accentOrange)
                    }
                    Text("Decode")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 24)

                // Nav items
                VStack(spacing: 4) {
                    sidebarItem("Home", icon: "house", page: .home)
                    sidebarItem("Notes", icon: "bookmark", page: .notes)
                    sidebarItem("Session Mode", icon: "doc.text.magnifyingglass", page: .sessionMode)
                    sidebarItem("Profile", icon: "person.crop.circle", page: .profile)
                }
                .padding(.horizontal, 10)

                Spacer()
            }
            .frame(width: 170)
            .background(Color(red: 0.955, green: 0.945, blue: 0.93))

            Divider()
                .overlay(cardBorder)

            // Detail
            Group {
                switch selectedPage {
                case .home:
                    homeContent
                case .notes:
                    NotesView()
                        .environment(dependencies)
                case .sessionMode:
                    if let vm = dependencies.sessionViewModel {
                        SessionView(viewModel: vm)
                    }
                case .profile:
                    ProfileView()
                        .environment(dependencies)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView(onOpenSettings: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            })
        }
        .onReceive(NotificationCenter.default.publisher(for: .showOnboarding)) { _ in
            showingOnboarding = true
        }
        .onChange(of: dependencies.sessionViewModel?.shouldPresentSession) { _, newValue in
            if newValue == true {
                selectedPage = .sessionMode
                dependencies.sessionViewModel?.shouldPresentSession = false
            }
        }
    }

    // MARK: - Home Page

    private var homeContent: some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer()

                    // App identity
            VStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(accentOrange.opacity(0.12))
                        .frame(width: 76, height: 76)
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(accentOrange)
                }

                VStack(spacing: 6) {
                    Text("Decode")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(textPrimary)
                    Text("Developer AI Companion")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(textSecondary)
                }
            }

            Spacer().frame(height: 32)

            // Status card
            VStack(spacing: 14) {
                if !dependencies.isConfigured {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Connecting to Decode Gateway...")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(textSecondary)
                    }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(red: 0.30, green: 0.69, blue: 0.31))
                        Text("AI provider configured")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(textPrimary)
                    }

                    Divider()
                        .overlay(cardBorder)

                    VStack(spacing: 8) {
                        hotkeyRow(key: "\u{2303}\u{2303}", action: "Explain selected text")
                        hotkeyRow(key: "\u{2325}\u{2325}", action: "Screenshot & explain")
                        hotkeyRow(key: "\u{21E7}\u{21E7}", action: "Ask with session context")
                        hotkeyRow(key: "\u{2303}\u{21E7}O", action: "Open session file")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(cardBorder, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.03), radius: 6, y: 2)
            )
            .padding(.horizontal, 60)

            Spacer().frame(height: 12)

            // DSA Mode toggle
            HStack(spacing: 10) {
                Toggle("DSA Mode", isOn: $dsaModeEnabled)
                    .toggleStyle(.switch)
                    .tint(accentOrange)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(textPrimary)
                Text("Algorithms & Interview Prep")
                    .font(.system(size: 11))
                    .foregroundStyle(textSecondary)
                Spacer()
            }
            .padding(.horizontal, 60)

            // Virtual Session toggle
            HStack(spacing: 10) {
                Toggle("Virtual Session", isOn: $virtualSessionEnabled)
                    .toggleStyle(.switch)
                    .tint(accentOrange)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(textPrimary)
                Text("Remember investigation context")
                    .font(.system(size: 11))
                    .foregroundStyle(textSecondary)
                Spacer()
                if virtualSessionEnabled {
                    Button {
                        showingMemoryInspector.toggle()
                    } label: {
                        Text("View Memory")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(accentOrange)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingMemoryInspector) {
                        VirtualSessionInspectorView()
                            .environment(dependencies)
                    }
                }
            }
            .padding(.horizontal, 60)
            .onChange(of: virtualSessionEnabled) { _, newValue in
                dependencies.virtualSessionManager.handleToggleChanged(enabled: newValue)
            }

            #if DEBUG
            // Profile Intelligence inspector
            if dependencies.profileIntelligenceService != nil {
                HStack(spacing: 10) {
                    Button {
                        showingProfileInspector.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "person.text.rectangle")
                                .font(.system(size: 11))
                            Text("Profile Inspector")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(accentOrange)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingProfileInspector) {
                        ProfileIntelligenceInspectorView()
                            .environment(dependencies)
                    }
                    Spacer()
                }
                .padding(.horizontal, 60)
            }
            #endif

            Spacer().frame(height: 12)

            // Permission status
            PermissionStatusView()
                .padding(.horizontal, 60)

            Spacer()
                }
                .frame(minHeight: geo.size.height)
            }
        }
        .background(warmBackground)
    }

    // MARK: - Sidebar Item

    private func sidebarItem(_ title: String, icon: String, page: AppPage) -> some View {
        let isSelected = selectedPage == page

        return Button {
            selectedPage = page
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? accentOrange : textSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? textPrimary : textSecondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? accentOrange.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Auth State Views

    private var authLoadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Verifying account...")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(textSecondary)
        }
    }

    private var disabledView: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.red.opacity(0.10))
                    .frame(width: 76, height: 76)
                Image(systemName: "person.crop.circle.badge.xmark")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.red)
            }

            VStack(spacing: 8) {
                Text("Account Disabled")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(textPrimary)

                Text("Contact Decode support if you believe this is a mistake.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var offlineView: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(accentOrange.opacity(0.12))
                    .frame(width: 76, height: 76)
                Image(systemName: "wifi.slash")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(accentOrange)
            }

            VStack(spacing: 8) {
                Text("Unable to Verify Account")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(textPrimary)

                Text("Check your internet connection.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(textSecondary)
            }

            Button {
                Task {
                    await dependencies.authService.retryValidation()
                }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(accentOrange)
        }
    }

    // MARK: - Hotkey Badge

    private func hotkeyRow(key: String, action: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(textPrimary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(red: 0.94, green: 0.93, blue: 0.91))
                )
            Text(action)
                .font(.system(size: 12))
                .foregroundStyle(textSecondary)
            Spacer()
        }
    }
}

/// Workaround for SwiftUI WindowGroup close button not responding.
///
/// SwiftUI's internal window delegate can block `performClose:` by returning
/// `false` from `windowShouldClose:`. This rewires the standard close button
/// to call `close()` directly, bypassing the delegate check.
private struct WindowCloseButtonFix: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = CloseButtonFixView()
        DispatchQueue.main.async {
            view.installFix()
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
private final class CloseButtonFixView: NSView {

    func installFix() {
        guard let window = self.window,
              let closeButton = window.standardWindowButton(.closeButton)
        else { return }

        closeButton.target = self
        closeButton.action = #selector(handleClose(_:))
    }

    @objc func handleClose(_ sender: Any?) {
        window?.close()
    }
}

// MARK: - Permission Status

/// Displays the status of required macOS permissions with actionable guidance.
///
/// Checks Accessibility (via `AXIsProcessTrusted()`), Input Monitoring
/// (via `CGPreflightListenEventAccess()`), and Screen Recording
/// (via `CGPreflightScreenCaptureAccess()`) independently.
private struct PermissionStatusView: View {

    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var inputMonitoringGranted = CGPreflightListenEventAccess()
    @State private var screenRecordingGranted = CGPreflightScreenCaptureAccess()

    private let textSecondary = Color(red: 0.50, green: 0.49, blue: 0.47)
    private let cardBorder = Color(red: 0.91, green: 0.90, blue: 0.88)

    /// Timer-driven refresh so status updates after the user grants permissions
    /// in System Settings without restarting the app.
    private let refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        let allGranted = accessibilityGranted && inputMonitoringGranted && screenRecordingGranted

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: allGranted ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(allGranted ? Color(red: 0.30, green: 0.69, blue: 0.31) : .orange)
                Text("Permissions")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.12))
                Spacer()
                if !allGranted {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
                        )
                    }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }

            permissionRow(
                name: "Accessibility",
                granted: accessibilityGranted,
                hint: "Required for text capture. Grant in Privacy & Security \u{2192} Accessibility."
            )
            permissionRow(
                name: "Input Monitoring",
                granted: inputMonitoringGranted,
                hint: "Required for hotkeys. Grant in Privacy & Security \u{2192} Input Monitoring."
            )
            permissionRow(
                name: "Screen Recording",
                granted: screenRecordingGranted,
                hint: "Required for Screenshot Mode. Grant in Privacy & Security \u{2192} Screen Recording."
            )

            if !allGranted {
                Text("Restart Decode after granting permissions.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(textSecondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(cardBorder, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.02), radius: 4, y: 1)
        )
        .onReceive(refreshTimer) { _ in
            accessibilityGranted = AXIsProcessTrusted()
            inputMonitoringGranted = CGPreflightListenEventAccess()
            screenRecordingGranted = CGPreflightScreenCaptureAccess()
        }
    }

    private func permissionRow(name: String, granted: Bool, hint: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(granted ? Color(red: 0.30, green: 0.69, blue: 0.31) : .red)
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.12))
            if !granted {
                Text("— \(hint)")
                    .font(.system(size: 10))
                    .foregroundStyle(textSecondary)
            }
            Spacer()
        }
    }
}

#Preview {
    ContentView()
        .environment(AppDependencies())
}

