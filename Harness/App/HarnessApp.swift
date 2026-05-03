//
//  HarnessApp.swift
//  Harness
//
//  Application entry point. Phase 1: minimal shell; the real RootView, AppCoordinator,
//  and AppState land in Phase 3 alongside the feature modules.
//

import SwiftUI

@main
struct HarnessApp: App {

    var body: some Scene {
        WindowGroup {
            RootScaffoldView()
                .frame(minWidth: 920, minHeight: 600)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { /* New Run wired in Phase 3 */ }
        }
    }
}

/// Placeholder root view for Phase 1. Renders a one-screen "we're here, services
/// are wired" panel so the app shell builds + launches without leaning on the
/// HarnessDesign primitives yet (those compose into real screens in Phase 3).
private struct RootScaffoldView: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("Harness")
                .font(.system(size: 42, weight: .semibold, design: .default))
                .foregroundStyle(.primary)

            Text("Phase 1 — services scaffolding")
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(
                "Goal input, live mirror, step feed, run history and replay all land in Phase 3. " +
                "Today this shell exists so the underlying services (ProcessRunner, ToolLocator, " +
                "XcodeBuilder, SimulatorDriver, ClaudeClient) can be exercised from the test target."
            )
            .font(.body)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 560)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thickMaterial)
    }
}

#Preview {
    RootScaffoldView()
        .frame(width: 960, height: 600)
}
