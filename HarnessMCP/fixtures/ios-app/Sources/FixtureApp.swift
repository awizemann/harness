//
//  FixtureApp.swift
//  HarnessUITestFixture
//
//  A deliberately tiny SwiftUI app used by the harness-mcp iOS UI-session
//  proof: one accessible button that toggles a visible label. That gives an
//  iOS session something to OBSERVE (a mark over the button), ACT on
//  (tap_mark), and re-observe (the label flips to "Tapped!") — the same
//  observe → act → observe shape the web fixture exercises.
//

import SwiftUI

@main
struct HarnessUITestFixtureApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var tapCount = 0

    var body: some View {
        VStack(spacing: 32) {
            Text(tapCount == 0 ? "Not tapped" : "Tapped \(tapCount)")
                .font(.largeTitle)
                .accessibilityIdentifier("statusLabel")

            // The button's TITLE reflects the count so the state change is
            // visible in the Set-of-Mark table (marks cover interactive
            // elements): "Tap me" → "Tapped 1x" after one tap_mark.
            Button(tapCount == 0 ? "Tap me" : "Tapped \(tapCount)x") {
                tapCount += 1
            }
            .font(.title2)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("tapButton")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
