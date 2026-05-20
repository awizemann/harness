//
//  HarnessRunner.swift
//  HarnessCLI
//
//  The actual driver. Constructs a `WebPlatformAdapter`, plumbs the
//  CLI's flags into a `RunRequest`, hands the bundle to
//  `RunCoordinator`, and pretty-prints the `RunEvent` stream until the
//  run completes or fails. Exits 0 on `.success`, 1 on any other
//  terminal verdict or thrown error.
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

        // 4. Construct the RunRequest. Web platform; `project` is a
        //    placeholder (web doesn't xcodebuild anything).
        let runID = UUID()
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
        let request = RunRequest(
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

        // 5. Construct the in-memory history store (throwaway — runs
        //    don't show up in any GUI). RunCoordinator demands a
        //    non-nil store; the in-memory variant fits.
        let history: any RunHistoryStoring
        do {
            history = try RunHistoryStore.inMemory()
        } catch {
            FileHandle.standardError.write(Data("Failed to construct in-memory history store: \(error.localizedDescription)\n".utf8))
            return 1
        }

        // 6. Construct the platform adapter directly (bypassing the
        //    iOS/MacOS factory branches we don't need on web). Real
        //    ProcessRunner / ToolLocator are harmless here — the web
        //    adapter never invokes them, but they're required slots in
        //    `PlatformAdapterServices`.
        let processRunner = ProcessRunner()
        let toolLocator = ToolLocator(processRunner: processRunner)
        let services = PlatformAdapterServices(
            processRunner: processRunner,
            toolLocator: toolLocator,
            xcodeBuilder: NoopXcodeBuilder(),
            simulatorDriver: NoopSimulatorDriver(),
            promptLibrary: PromptLibrary(),
            keychain: keychain,
            runHistory: history
        )
        let webAdapter = WebPlatformAdapter(services: services)

        // 7. Construct the coordinator.
        let agent = AgentLoop(llm: llm)
        let coordinator = RunCoordinator(
            builder: NoopXcodeBuilder(),
            driver: NoopSimulatorDriver(),
            agent: agent,
            llm: llm,
            history: history,
            platformAdapterOverride: webAdapter
        )

        // 8. Drive the run. Pretty-print events; exit on terminal event.
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
