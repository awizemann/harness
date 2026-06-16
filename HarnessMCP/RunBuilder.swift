//
//  RunBuilder.swift
//  HarnessMCP
//
//  Constructs a (`RunRequest`, `RunCoordinator`) pair for a `start_run`
//  tool call, dispatching on the target platform. This is the MCP-side
//  analogue of `HarnessCLI/HarnessRunner.swift`'s per-platform `switch`;
//  it deliberately keeps the CLI untouched (a future cleanup could factor
//  a single shared `RunRequestBuilder` used by both tool targets).
//
//  Web is the zero-setup path (no Xcode, no extra permissions). iOS spins
//  up the real WebDriverAgent stack; macOS drives a pre-built `.app`
//  (and will trigger per-binary Screen-Recording / Accessibility prompts
//  the first time, same as the CLI).
//

import CoreGraphics
import Foundation

enum RunBuilder {

    /// Resolved inputs for one run. Field order matches the synthesized
    /// memberwise initializer used by `ToolHandlers.startRun`.
    struct Params {
        var platform: PlatformKind
        var goal: String
        /// The persona's prompt text — fed into the `{{PERSONA}}` slot via
        /// `RunRequest.persona`. Resolved from `persona_id` or passed raw.
        var personaPrompt: String
        var personaID: UUID?
        var applicationID: UUID?
        var model: AgentModel
        var stepBudget: Int?
        var tokenBudget: Int?
        var credentialID: UUID?
        // Web
        var webURL: String?
        var viewportW: Int
        var viewportH: Int
        // iOS
        var iosProjectPath: String?
        var iosScheme: String?
        var iosSimulatorUDID: String?
        var iosSimulatorName: String?
        var iosSimulatorRuntime: String?
        // macOS
        var macAppPath: String?
    }

    static func build(_ p: Params, container: MCPContainer) throws -> (RunRequest, RunCoordinator) {
        let runID = UUID()
        let keychain = container.keychain
        let llm: any LLMClient = LLMClientFactory.client(
            for: p.model.provider,
            keychain: keychain,
            localBaseURL: container.localBaseURL,
            modelNameOverride: nil
        )
        let processRunner = ProcessRunner()
        let toolLocator = ToolLocator(processRunner: processRunner)
        let history = container.history
        let tokenBudget = p.tokenBudget ?? p.model.defaultTokenBudget
        let stepBudget = p.stepBudget ?? 40

        let request: RunRequest
        let xcodeBuilder: any XcodeBuilding
        let simulatorDriver: any SimulatorDriving
        let platformAdapterOverride: (any PlatformAdapter)?

        switch p.platform {
        case .web:
            guard let url = p.webURL, !url.isEmpty else {
                throw MCPToolError.missingArgument("web_url")
            }
            let placeholderProject = ProjectRequest(
                path: URL(fileURLWithPath: "/tmp/harness-mcp-placeholder"),
                scheme: "harness-mcp",
                displayName: "harness-mcp"
            )
            let pseudoSim = SimulatorRef(
                udid: "harness-mcp-web",
                name: "Web",
                runtime: "Web",
                pointSize: CGSize(width: p.viewportW, height: p.viewportH),
                scaleFactor: 1.0
            )
            request = RunRequest(
                id: runID,
                name: "mcp-run",
                goal: p.goal,
                persona: p.personaPrompt,
                applicationID: p.applicationID,
                personaID: p.personaID,
                payload: .ad_hoc,
                project: placeholderProject,
                simulator: pseudoSim,
                model: p.model,
                mode: .autonomous,
                stepBudget: stepBudget,
                tokenBudget: tokenBudget,
                platformKindRaw: PlatformKind.web.rawValue,
                macAppBundlePath: nil,
                webStartURL: url,
                webViewportWidthPt: p.viewportW,
                webViewportHeightPt: p.viewportH,
                credentialID: p.credentialID
            )
            xcodeBuilder = NoopXcodeBuilder()
            simulatorDriver = NoopSimulatorDriver()
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
            guard let projectPath = p.iosProjectPath,
                  let scheme = p.iosScheme,
                  let udid = p.iosSimulatorUDID else {
                throw MCPToolError.message("iOS runs require ios_project_path, ios_scheme, and ios_simulator_udid (or an application_id whose Application carries them).")
            }
            let simRef = SimulatorRef(
                udid: udid,
                name: p.iosSimulatorName ?? "iOS Simulator",
                runtime: p.iosSimulatorRuntime ?? "iOS",
                pointSize: CGSize(width: 440, height: 956),
                scaleFactor: 3.0
            )
            let project = ProjectRequest(
                path: URL(fileURLWithPath: projectPath),
                scheme: scheme,
                displayName: scheme
            )
            request = RunRequest(
                id: runID,
                name: "mcp-run",
                goal: p.goal,
                persona: p.personaPrompt,
                applicationID: p.applicationID,
                personaID: p.personaID,
                payload: .ad_hoc,
                project: project,
                simulator: simRef,
                model: p.model,
                mode: .autonomous,
                stepBudget: stepBudget,
                tokenBudget: tokenBudget,
                platformKindRaw: PlatformKind.iosSimulator.rawValue,
                macAppBundlePath: nil,
                webStartURL: nil,
                webViewportWidthPt: nil,
                webViewportHeightPt: nil,
                credentialID: p.credentialID
            )
            let wdaBuilder = WDABuilder(
                processRunner: processRunner,
                toolLocator: toolLocator,
                sourceURL: HarnessPaths.wdaSourceURL ?? URL(fileURLWithPath: "/dev/null")
            )
            let wdaRunner = WDARunner(processRunner: processRunner, toolLocator: toolLocator)
            let wdaClient = WDAClient()
            simulatorDriver = SimulatorDriver(
                processRunner: processRunner,
                toolLocator: toolLocator,
                wdaBuilder: wdaBuilder,
                wdaRunner: wdaRunner,
                wdaClient: wdaClient
            )
            xcodeBuilder = XcodeBuilder(processRunner: processRunner, toolLocator: toolLocator)
            platformAdapterOverride = nil

        case .macosApp:
            guard let bundlePath = p.macAppPath, !bundlePath.isEmpty else {
                throw MCPToolError.missingArgument("mac_app_path")
            }
            let bundleURL = URL(fileURLWithPath: bundlePath)
            let pseudoSim = SimulatorRef(
                udid: "harness-mcp-mac",
                name: bundleURL.deletingPathExtension().lastPathComponent,
                runtime: "macOS",
                pointSize: CGSize(width: 1280, height: 800),
                scaleFactor: 2.0
            )
            let placeholderProject = ProjectRequest(
                path: bundleURL,
                scheme: "harness-mcp",
                displayName: pseudoSim.name
            )
            request = RunRequest(
                id: runID,
                name: "mcp-run",
                goal: p.goal,
                persona: p.personaPrompt,
                applicationID: p.applicationID,
                personaID: p.personaID,
                payload: .ad_hoc,
                project: placeholderProject,
                simulator: pseudoSim,
                model: p.model,
                mode: .autonomous,
                stepBudget: stepBudget,
                tokenBudget: tokenBudget,
                platformKindRaw: PlatformKind.macosApp.rawValue,
                macAppBundlePath: bundlePath,
                webStartURL: nil,
                webViewportWidthPt: nil,
                webViewportHeightPt: nil,
                credentialID: p.credentialID
            )
            xcodeBuilder = NoopXcodeBuilder()
            simulatorDriver = NoopSimulatorDriver()
            platformAdapterOverride = nil
        }

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
        return (request, coordinator)
    }
}
