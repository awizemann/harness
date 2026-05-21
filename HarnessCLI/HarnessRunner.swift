//
//  HarnessRunner.swift
//  HarnessCLI
//
//  Constructs the run dependency graph based on `--platform` and drives
//  it end-to-end via `RunCoordinator`. Web and iOS supported today.
//  Exits 0 on `verdict.success`, 1 on any other terminal verdict or
//  thrown error, 130 on cancellation.
//

import AppKit
import Foundation

enum HarnessRunner {

    static func run(_ args: CLIArgs) async -> Int32 {
        // 1. Redirect every per-run path to the CLI's output dir. The
        //    GUI app never sets this override; it stays nil in the
        //    .app target's process space.
        HarnessPaths.runsRootOverride = args.outputDir
        do {
            try FileManager.default.createDirectory(at: args.outputDir, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("Failed to create output directory \(args.outputDir.path): \(error.localizedDescription)\n".utf8))
            return 1
        }

        // 2. Set up credentials. Cloud providers read their key on first
        //    `step(_:)`; the local provider doesn't need a key but does
        //    need an Ollama URL.
        let keychain = EnvKeychain.fromEnvironment()
        let localBaseURL: URL = {
            if let raw = ProcessInfo.processInfo.environment["HARNESS_OLLAMA_URL"],
               let url = URL(string: raw) {
                return url
            }
            return LLMClientFactory.defaultLocalBaseURL
        }()

        // 3. Build the LLM client.
        let llm: any LLMClient = LLMClientFactory.client(
            for: args.provider,
            keychain: keychain,
            localBaseURL: localBaseURL,
            modelNameOverride: args.customModelName
        )

        // 4. Shared infrastructure (used by every platform).
        let runID = UUID()
        let history: any RunHistoryStoring
        do {
            history = try RunHistoryStore.inMemory()
        } catch {
            FileHandle.standardError.write(Data("Failed to construct in-memory history store: \(error.localizedDescription)\n".utf8))
            return 1
        }
        let processRunner = ProcessRunner()
        let toolLocator = ToolLocator(processRunner: processRunner)

        // 5. Per-platform dispatch.
        let request: RunRequest
        let xcodeBuilder: any XcodeBuilding
        let simulatorDriver: any SimulatorDriving
        let platformAdapterOverride: (any PlatformAdapter)?
        switch args.platform {
        case .web:
            let placeholderProject = ProjectRequest(
                path: URL(fileURLWithPath: "/tmp/harness-cli-placeholder"),
                scheme: "harness-cli",
                displayName: "harness-cli"
            )
            let pseudoSim = SimulatorRef(
                udid: "harness-cli-web",
                name: "Web",
                runtime: "Web",
                pointSize: CGSize(width: args.viewportWidth, height: args.viewportHeight),
                scaleFactor: 1.0
            )
            request = RunRequest(
                id: runID,
                name: "cli-run",
                goal: args.goal,
                persona: args.persona,
                applicationID: nil,
                personaID: nil,
                payload: .ad_hoc,
                project: placeholderProject,
                simulator: pseudoSim,
                model: args.model,
                mode: .autonomous,
                stepBudget: args.maxSteps,
                tokenBudget: args.model.defaultTokenBudget,
                platformKindRaw: PlatformKind.web.rawValue,
                macAppBundlePath: nil,
                webStartURL: args.url,
                webViewportWidthPt: args.viewportWidth,
                webViewportHeightPt: args.viewportHeight,
                credentialID: nil
            )
            xcodeBuilder = NoopXcodeBuilder()
            simulatorDriver = NoopSimulatorDriver()
            // Build the web adapter with the same `services` shape the
            // GUI uses, then pass it as the platform override so the
            // factory doesn't try to construct one based on
            // `platformKindRaw`.
            let webServices = PlatformAdapterServices(
                processRunner: processRunner,
                toolLocator: toolLocator,
                xcodeBuilder: xcodeBuilder,
                simulatorDriver: simulatorDriver,
                promptLibrary: PromptLibrary(),
                keychain: keychain,
                runHistory: history
            )
            platformAdapterOverride = WebPlatformAdapter(services: webServices)

        case .iosSimulator:
            // iOS runs use the real `XcodeBuilder` + `SimulatorDriver` +
            // WDA stack. The PlatformAdapterFactory will instantiate
            // `IOSPlatformAdapter` from the `platformKindRaw`; no
            // override needed.
            guard let projectPath = args.iosProjectPath,
                  let scheme = args.iosScheme,
                  let udid = args.iosSimulatorUDID else {
                FileHandle.standardError.write(Data("Missing iOS required flags. See --help.\n".utf8))
                return 2
            }
            // The point size + scale factor of the simulator are
            // resolved by `simctl list devices` in the GUI; in the CLI
            // we let the adapter resolve them at boot time. Build a
            // SimulatorRef with the user-supplied identity and a
            // placeholder size — `IOSPlatformAdapter.prepare` doesn't
            // need a real pointSize until after `boot()`.
            //
            // For now, default to iPhone 17 Pro Max point size
            // (440×956) when not overridden; the run still works on
            // smaller devices because the agent's coordinates flow
            // through WDA which queries the simulator natively.
            let projectURL = URL(fileURLWithPath: projectPath)
            let simRef = SimulatorRef(
                udid: udid,
                name: args.iosSimulatorName ?? "iOS Simulator",
                runtime: args.iosSimulatorRuntime ?? "iOS",
                pointSize: CGSize(width: 440, height: 956),
                scaleFactor: 3.0
            )
            let project = ProjectRequest(
                path: projectURL,
                scheme: scheme,
                displayName: scheme
            )
            request = RunRequest(
                id: runID,
                name: "cli-run",
                goal: args.goal,
                persona: args.persona,
                applicationID: nil,
                personaID: nil,
                payload: .ad_hoc,
                project: project,
                simulator: simRef,
                model: args.model,
                mode: .autonomous,
                stepBudget: args.maxSteps,
                tokenBudget: args.model.defaultTokenBudget,
                platformKindRaw: PlatformKind.iosSimulator.rawValue,
                macAppBundlePath: nil,
                webStartURL: nil,
                webViewportWidthPt: nil,
                webViewportHeightPt: nil,
                credentialID: nil
            )
            // Build the real WDA stack so the iOS adapter can drive
            // input + read the AX tree.
            let wdaBuilder = WDABuilder(
                processRunner: processRunner,
                toolLocator: toolLocator,
                sourceURL: HarnessPaths.wdaSourceURL ?? URL(fileURLWithPath: "/dev/null")
            )
            let wdaRunner = WDARunner(processRunner: processRunner, toolLocator: toolLocator)
            let wdaClient = WDAClient()
            let realDriver = SimulatorDriver(
                processRunner: processRunner,
                toolLocator: toolLocator,
                wdaBuilder: wdaBuilder,
                wdaRunner: wdaRunner,
                wdaClient: wdaClient
            )
            let realBuilder = XcodeBuilder(processRunner: processRunner, toolLocator: toolLocator)
            xcodeBuilder = realBuilder
            simulatorDriver = realDriver
            // No override — let the factory pick IOSPlatformAdapter.
            platformAdapterOverride = nil

        case .macosApp:
            // macOS runs need a `.app` bundle path. The
            // MacOSPlatformAdapter launches the bundle, MacAppDriver
            // drives it via CGEvent + Screen Recording, and the AX
            // probe builds the Set-of-Mark scaffolding. The shared
            // `XcodeBuilder` / `SimulatorDriver` slots in
            // `PlatformAdapterServices` are unused on macOS — pass
            // Noop fakes the same way the web path does.
            guard let bundlePath = args.macAppPath else {
                FileHandle.standardError.write(Data("Missing --app-path. See --help.\n".utf8))
                return 2
            }
            let bundleURL = URL(fileURLWithPath: bundlePath)
            // Synthesise a SimulatorRef so the existing RunRequest
            // shape carries the run's display label / viewport. The
            // real window point size comes from the front-window
            // bounds at capture time; the value here is a placeholder
            // that only feeds events.jsonl + log lines.
            let pseudoSim = SimulatorRef(
                udid: "harness-cli-mac",
                name: bundleURL.deletingPathExtension().lastPathComponent,
                runtime: "macOS",
                pointSize: CGSize(width: 1280, height: 800),
                scaleFactor: 2.0
            )
            let placeholderProject = ProjectRequest(
                path: bundleURL,
                scheme: "harness-cli",
                displayName: pseudoSim.name
            )
            request = RunRequest(
                id: runID,
                name: "cli-run",
                goal: args.goal,
                persona: args.persona,
                applicationID: nil,
                personaID: nil,
                payload: .ad_hoc,
                project: placeholderProject,
                simulator: pseudoSim,
                model: args.model,
                mode: .autonomous,
                stepBudget: args.maxSteps,
                tokenBudget: args.model.defaultTokenBudget,
                platformKindRaw: PlatformKind.macosApp.rawValue,
                macAppBundlePath: bundlePath,
                webStartURL: nil,
                webViewportWidthPt: nil,
                webViewportHeightPt: nil,
                credentialID: nil
            )
            xcodeBuilder = NoopXcodeBuilder()
            simulatorDriver = NoopSimulatorDriver()
            platformAdapterOverride = nil
        }

        // 6. Construct the coordinator.
        let agent = AgentLoop(llm: llm)
        let coordinator = RunCoordinator(
            builder: xcodeBuilder,
            driver: simulatorDriver,
            agent: agent,
            llm: llm,
            history: history,
            toolLocator: toolLocator,
            processRunner: processRunner,
            keychain: keychain,
            platformAdapterOverride: platformAdapterOverride
        )

        // 7. Drive the run. Pretty-print events; exit on terminal event.
        let printer = ConsoleEventPrinter(outputDir: args.outputDir)
        do {
            for try await event in coordinator.run(request) {
                printer.print(event)
                if case .runCompleted(let outcome) = event {
                    return outcome.verdict == .success ? 0 : 1
                }
            }
            // Stream finished without `runCompleted` — treat as error.
            FileHandle.standardError.write(Data("Run ended without emitting runCompleted.\n".utf8))
            return 1
        } catch is CancellationError {
            FileHandle.standardError.write(Data("Run cancelled.\n".utf8))
            return 130
        } catch {
            FileHandle.standardError.write(Data("Run failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
