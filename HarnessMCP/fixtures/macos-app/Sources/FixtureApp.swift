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
//     own name still beats anything the probe would infer;
//   * (WB-23) a list of selectable rows and an echo line that renders what
//     is typed and what is selected — so "the tap FOCUSED the right field"
//     and "the tap SELECTED the row" are assertable from `page_text`,
//     rather than inferred from a screenshot;
//   * (WB-23) two icon-only buttons with no name of any kind — the local
//     stand-in for the traffic lights, so the synthesized-label
//     discriminator has a real collision to resolve;
//   * (WB-23) an echo of `HARNESS_FIXTURE_MODE` and of the launch
//     arguments, which is how the W26 env / launch_args passthrough is
//     proven to reach the launched process at all.
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
                .frame(width: 620, height: 900)
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
    @State private var selectedProject: Project.ID?
    // WB-25 — the sidebar band's own state.
    @State private var filterText = ""
    @State private var showArchived = false
    @State private var addedProject = false

    /// W26 — what the LAUNCH handed this process. Read once, rendered as
    /// plain text, so a smoke can assert the passthrough landed without
    /// reading the app's internals: if the env var never arrived, the line
    /// says `mode=default` and the assertion fails for the right reason.
    private let launchMode = ProcessInfo.processInfo.environment["HARNESS_FIXTURE_MODE"] ?? "default"
    private let launchArgs = CommandLine.arguments.dropFirst().joined(separator: " ")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Harness Mac Fixture")
                .font(.title)
            Text("Fixture ready — no server configured")
            Text("mode=\(launchMode) args=[\(launchArgs)]")
            // The echo line: what the last focus-then-type actually put
            // where. `port` is here too, unchanged at 22 unless something
            // typed into the wrong field — which is the failure this whole
            // ticket is about.
            Text("echo host=[\(host)] port=[\(port)] project=[\(selectedProjectName)]")
            // WB-25 — the sidebar band's own echo, so "the toggle below the
            // list is marked" can be followed by "and tapping it did something".
            Text("echo archived=[\(showArchived)] added=[\(addedProject)] filter=[\(filterText)]")

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

            // WB-23: rows. `tap_mark` on one must SELECT it — AXPress on an
            // AXRow is the no-op that left "setting up a project" blocked.
            //
            // WB-25: and the band AROUND the list. Scarf's Projects sidebar is
            // exactly this column — a filter field above a `List`, an add
            // button and an archived toggle below it — and the whole band was
            // missing from the mark table while the rows came through. Every
            // control here is deliberately `.caption`-sized and unadorned,
            // because that is what produced the sub-16pt AX rects (the filter
            // field measured 138×15, the add button 11×11, the toggle 12×11)
            // that the old `minimumMarkExtent` silently dropped. Keep them
            // small: sizing them comfortably would make this fixture pass
            // without testing anything.
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    TextField("Filter projects", text: $filterText)
                        .accessibilityLabel("Filter projects")
                        .textFieldStyle(.plain)
                        .font(.system(size: 9))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)

                Divider()

                List(Self.projects, selection: $selectedProject) { project in
                    Text(project.name)
                }
                .frame(height: 110)

                Divider()

                HStack(spacing: 8) {
                    Button {
                        addedProject = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add a project")

                    Toggle(isOn: $showArchived) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 8))
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show archived projects")

                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            }
            .frame(width: 260)

            // WB-23: two controls nothing can name — no title, no
            // description, no help, no caption, and nothing adjacent to
            // borrow. Both synthesize to `unlabelled button`, which is the
            // collision the W15 discriminator has to break.
            HStack(spacing: 24) {
                Button { } label: { Circle().fill(.red).frame(width: 18, height: 18) }
                Button { } label: { Circle().fill(.green).frame(width: 18, height: 18) }
            }
            .buttonStyle(.plain)

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

/// One selectable row. Deliberately plain: a name and nothing else, so what
/// the probe reads off the row is the row's own text.
struct Project: Identifiable, Hashable {
    let id: String
    var name: String { id }
}

extension FixtureView {
    static let projects = [Project(id: "Ridgeline"), Project(id: "Tidewater"), Project(id: "Bellwether")]

    /// The selected row's name, or `none`. Rendered into the echo line so a
    /// smoke can assert the selection landed on the row it asked for.
    var selectedProjectName: String { selectedProject ?? "none" }
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
