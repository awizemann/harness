//
//  FixtureApp.swift
//  HarnessMacFixture
//
//  A deliberately PLAIN SwiftUI app whose only job is to reproduce, on this
//  machine, the accessibility shapes the macOS mark probe has to survive.
//  Nothing here sets `.accessibilityLabel` on a field, and that is the whole
//  point: an app that already labelled everything would prove nothing.
//
//  What it exposes, and which finding each shape belongs to:
//
//   * a form of `Text` + `TextField` rows with NO accessibility labels — the
//     shape that made every Scarf form flow unauthorable (W19). The probe
//     must recover "Host", "Port", "Identity file" from the sibling text;
//   * a `Menu` with three items — opened, the AX graph offers the menu
//     through more than one path, and every item used to be marked twice
//     (W21);
//   * plain body text, so `page_text` has something real to sweep (W20);
//   * a sheet, so the front-frame scoping and the coordinate space of the
//     reported rects can be checked against a live overlay (W24);
//   * one field that DOES carry `.accessibilityLabel`, to prove the app's
//     own name still beats anything the probe would infer.
//
//  Built by `build-fixture.sh` into `HarnessMacFixture.app`; driven by
//  `MacAXLiveProbeTests`, which is skipped unless that app exists.
//

import SwiftUI

@main
struct HarnessMacFixtureApp: App {
    var body: some Scene {
        WindowGroup("Harness Mac Fixture") {
            FixtureView()
                .frame(width: 620, height: 520)
        }
        .windowResizability(.contentSize)
    }
}

struct FixtureView: View {
    @State private var host = ""
    @State private var port = "22"
    @State private var identityFile = ""
    @State private var nickname = ""
    @State private var secret = ""
    @State private var showingSheet = false
    @State private var selectedServer = "none"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Harness Mac Fixture")
                .font(.title)
            Text("Fixture ready — no server configured")

            // W19: label on the left, field on the right, no AX label set.
            VStack(alignment: .leading, spacing: 8) {
                LabeledRow(label: "Host", text: $host)
                LabeledRow(label: "Port", text: $port)
                LabeledRow(label: "Identity file", text: $identityFile)
            }

            // The app's OWN name must win over any inference.
            HStack(spacing: 10) {
                Text("Nickname")
                    .frame(width: 90, alignment: .leading)
                TextField("", text: $nickname)
                    .frame(width: 220)
                    .accessibilityLabel("Server nickname")
            }

            // A secure field: its contents must never become a label.
            HStack(spacing: 10) {
                Text("Passphrase")
                    .frame(width: 90, alignment: .leading)
                SecureField("", text: $secret)
                    .frame(width: 220)
            }

            // W21: a menu whose items used to be marked twice.
            Menu("Servers") {
                Button("Open in new window") { selectedServer = "new-window" }
                Button("ScarfBox") { selectedServer = "scarfbox" }
                Button("Manage Servers…") { selectedServer = "manage" }
            }
            .frame(width: 160)

            // W24: an overlay whose frame must own the mark table.
            Button("Add server") { showingSheet = true }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showingSheet) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add a remote server")
                    .font(.headline)
                LabeledRow(label: "Server name", text: $nickname)
                Button("Cancel") { showingSheet = false }
            }
            .padding(24)
            .frame(width: 420, height: 220)
        }
    }
}

/// The exact shape under test: a `Text` and a `TextField` side by side, with
/// no accessibility relationship declared between them. A human reads the
/// label; the AX tree, by itself, does not.
struct LabeledRow: View {
    let label: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .frame(width: 90, alignment: .leading)
            TextField("", text: $text)
                .frame(width: 220)
        }
    }
}
