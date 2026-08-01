import SwiftUI

/// The root view of the application.
///
/// Displays a welcome state with guidance to configure the AI provider
/// via the Settings window (Cmd+,).
struct ContentView: View {

    @Environment(AppDependencies.self) private var dependencies
    @State private var showingSession = false
    @State private var showingOnboarding = !OnboardingState.hasCompleted
    @State private var showingMemoryInspector = false
    @AppStorage("dsaModeEnabled") private var dsaModeEnabled = false
    @AppStorage("virtualSessionEnabled") private var virtualSessionEnabled = false
    @AppStorage("enhancedExplanationEnabled") private var enhancedExplanationEnabled = false

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

            // Enhanced Explanation toggle
            HStack(spacing: 10) {
                Toggle("Enhanced Explanation", isOn: $enhancedExplanationEnabled)
                    .toggleStyle(.switch)
                    .tint(accentOrange)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(textPrimary)
                Text("Screen context for richer explanations")
                    .font(.system(size: 11))
                    .foregroundStyle(textSecondary)
                Spacer()
            }
            .padding(.horizontal, 60)

            #if DEBUG
            // Temporary debug UI: show most recent Visual Context
            if enhancedExplanationEnabled {
                EnhancedExplanationDebugView()
                    .padding(.horizontal, 60)
            }
            #endif

            Spacer().frame(height: 12)

            // Permission status
            PermissionStatusView()
                .padding(.horizontal, 60)

            Spacer().frame(height: 20)

            // Session Mode entry point
            Button {
                showingSession = true
            } label: {
                Label("Open Session Mode", systemImage: "doc.text.magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(accentOrange)

            Spacer()
        }
        .sheet(isPresented: $showingSession) {
            if let vm = dependencies.sessionViewModel {
                SessionView(viewModel: vm)
                    .frame(minWidth: 900, minHeight: 600)
            }
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
                showingSession = true
                dependencies.sessionViewModel?.shouldPresentSession = false
            }
        }
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

#if DEBUG
// MARK: - Enhanced Explanation Debug View (temporary)

/// Displays the most recent Visual Context for debugging.
/// **Remove once Enhanced Explanation is verified working.**
///
/// Reads directly from `EnhancedExplanationDebug.shared` which is `@Observable`.
/// SwiftUI tracks property access in `body` and re-renders automatically.
private struct EnhancedExplanationDebugView: View {

    var debug = EnhancedExplanationDebug.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header row with timestamp and latency.
            HStack(spacing: 6) {
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.purple)
                Text("Enhanced Explanation Debug")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.purple)
                Spacer()
                if let ms = debug.lastLatencyMs {
                    Text("\(String(format: "%.0f", ms))ms")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.orange)
                }
                if let ts = debug.lastTimestamp {
                    Text(ts, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("ago")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            // Status: success or failure.
            if let error = debug.lastError {
                Text("FAILED: \(error)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            // Parsed Visual Context items.
            if let vc = debug.lastVisualContext {
                Text("Parsed Visual Context (\(vc.items.count) items):")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary)
                ForEach(Array(vc.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 4) {
                        Text(item.type + ":")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                        Text(item.content)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            // Raw Vision Response (before parsing).
            if let raw = debug.lastRawResponse {
                Divider()
                Text("Raw Vision Response:")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(raw)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(10)
                    .textSelection(.enabled)
            }

            // Empty state.
            if debug.lastVisualContext == nil && debug.lastError == nil {
                Text("No Visual Context captured yet. Use Selection or Screenshot mode with Enhanced Explanation ON.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.purple.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                )
        )
    }
}
#endif

#Preview {
    ContentView()
        .environment(AppDependencies())
}

