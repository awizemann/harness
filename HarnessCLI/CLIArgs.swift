//
//  CLIArgs.swift
//  HarnessCLI
//
//  Hand-rolled flag parser. swift-argument-parser would add a Package.swift
//  + a dependency resolve to every fresh-clone build for a v1 internal tool
//  with ~10 flags; the hand-roll trades a few dozen lines for zero extra
//  dependency surface and faster cold-start. If the flag count climbs past
//  ~15 or we add subcommands, swap to swift-argument-parser.
//

import Foundation

struct CLIArgs: Sendable {
    var platform: PlatformKind
    var goal: String
    var persona: String
    var provider: ModelProvider
    var model: AgentModel
    /// Raw model tag passed to the local server when `--provider local
    /// --model custom-local`. Honoured only by Ollama path.
    var customModelName: String?
    var maxSteps: Int
    var outputDir: URL
    var deterministic: Bool

    // Web-specific
    var url: String
    var viewportWidth: Int
    var viewportHeight: Int

    // iOS-specific
    /// Path to the `.xcodeproj` (or `.xcworkspace`) the run will build.
    var iosProjectPath: String?
    /// Xcodebuild scheme to build + launch.
    var iosScheme: String?
    /// Simulator UDID. Required for iOS runs today — name+runtime
    /// resolution via `simctl list` is a future-want; in the meantime
    /// users grab the UDID from the GUI's Application detail or
    /// `xcrun simctl list devices --json | jq`.
    var iosSimulatorUDID: String?
    /// Display name for logs / events.jsonl (e.g. "iPhone 17 Pro Max").
    var iosSimulatorName: String?
    /// Runtime label for logs / events.jsonl (e.g. "iOS 26.2").
    var iosSimulatorRuntime: String?

    /// Default viewport. Matches the GUI's `LiveWebMirror` initial canvas
    /// so a CLI run against the same URL produces ~the same layout as a
    /// GUI run before the user resizes anything.
    static let defaultViewportWidth = 1280
    static let defaultViewportHeight = 880
    static let defaultMaxSteps = 20

    static func parse(_ argv: [String]) throws -> CLIArgs {
        var platformRaw: String?
        var url: String?
        var goal: String?
        var persona: String?
        var providerRaw: String?
        var modelRaw: String?
        var maxSteps: Int?
        var outputDirPath: String?
        var viewportWidth: Int?
        var viewportHeight: Int?
        var deterministic = false
        var iosProjectPath: String?
        var iosScheme: String?
        var iosSimulatorUDID: String?
        var iosSimulatorName: String?
        var iosSimulatorRuntime: String?

        var i = 1
        while i < argv.count {
            let arg = argv[i]
            switch arg {
            case "--help", "-h":
                throw CLIArgsError.helpRequested
            case "--platform":
                platformRaw = try Self.consumeValue(arg, argv: argv, i: &i)
            case "--url":
                url = try Self.consumeValue(arg, argv: argv, i: &i)
            case "--goal":
                goal = try Self.consumeValue(arg, argv: argv, i: &i)
            case "--persona":
                persona = try Self.consumeValue(arg, argv: argv, i: &i)
            case "--provider":
                providerRaw = try Self.consumeValue(arg, argv: argv, i: &i)
            case "--model":
                modelRaw = try Self.consumeValue(arg, argv: argv, i: &i)
            case "--max-steps":
                let raw = try Self.consumeValue(arg, argv: argv, i: &i)
                guard let parsed = Int(raw), parsed > 0 else {
                    throw CLIArgsError.invalidValue(flag: arg, value: raw, reason: "must be a positive integer")
                }
                maxSteps = parsed
            case "--output":
                outputDirPath = try Self.consumeValue(arg, argv: argv, i: &i)
            case "--viewport-width":
                let raw = try Self.consumeValue(arg, argv: argv, i: &i)
                guard let parsed = Int(raw), parsed > 0 else {
                    throw CLIArgsError.invalidValue(flag: arg, value: raw, reason: "must be a positive integer")
                }
                viewportWidth = parsed
            case "--viewport-height":
                let raw = try Self.consumeValue(arg, argv: argv, i: &i)
                guard let parsed = Int(raw), parsed > 0 else {
                    throw CLIArgsError.invalidValue(flag: arg, value: raw, reason: "must be a positive integer")
                }
                viewportHeight = parsed
            case "--deterministic":
                deterministic = true
                i += 1
            case "--project-path":
                iosProjectPath = try Self.consumeValue(arg, argv: argv, i: &i)
            case "--scheme":
                iosScheme = try Self.consumeValue(arg, argv: argv, i: &i)
            case "--simulator-udid":
                iosSimulatorUDID = try Self.consumeValue(arg, argv: argv, i: &i)
            case "--simulator-name":
                iosSimulatorName = try Self.consumeValue(arg, argv: argv, i: &i)
            case "--simulator-runtime":
                iosSimulatorRuntime = try Self.consumeValue(arg, argv: argv, i: &i)
            default:
                throw CLIArgsError.unknownFlag(arg)
            }
        }

        let platform: PlatformKind = try {
            guard let platformRaw else { return PlatformKind.web }
            // Accept human-friendly aliases alongside the enum
            // rawValues. The GUI persists `ios_simulator` /
            // `macos_app` / `web` in SwiftData, but on the command
            // line "ios" and "macos" are nicer to type.
            switch platformRaw.lowercased() {
            case "web":
                return .web
            case "ios", "ios_simulator", "iossimulator":
                return .iosSimulator
            case "macos", "macos_app", "macosapp":
                return .macosApp
            default:
                throw CLIArgsError.invalidValue(
                    flag: "--platform",
                    value: platformRaw,
                    reason: "must be one of: web|ios|macos"
                )
            }
        }()

        // Per-platform required-flag gates.
        switch platform {
        case .web:
            guard url != nil else { throw CLIArgsError.missingRequired("--url (required when --platform web)") }
        case .iosSimulator:
            guard iosProjectPath != nil else { throw CLIArgsError.missingRequired("--project-path (required when --platform ios)") }
            guard iosScheme != nil else { throw CLIArgsError.missingRequired("--scheme (required when --platform ios)") }
            guard iosSimulatorUDID != nil else { throw CLIArgsError.missingRequired("--simulator-udid (required when --platform ios)") }
        case .macosApp:
            throw CLIArgsError.invalidValue(flag: "--platform", value: "macos", reason: "macOS CLI runs are not yet supported; use --platform web or ios.")
        }

        guard let goal else { throw CLIArgsError.missingRequired("--goal") }
        guard let providerRaw else { throw CLIArgsError.missingRequired("--provider") }
        guard let modelRaw else { throw CLIArgsError.missingRequired("--model") }

        guard let provider = ModelProvider(rawValue: providerRaw) else {
            let allowed = ModelProvider.allCases.map(\.rawValue).joined(separator: "|")
            throw CLIArgsError.invalidValue(
                flag: "--provider",
                value: providerRaw,
                reason: "must be one of: \(allowed)"
            )
        }

        // Resolve `--model`. We accept either an `AgentModel` rawValue
        // (e.g. `qwen3-vl:8b`, `claude-opus-4-7`) or an arbitrary string
        // when `--provider local`, in which case we map to `.customLocal`
        // and pass the raw tag to OllamaClient via `modelNameOverride`.
        let model: AgentModel
        let customModelName: String?
        if let known = AgentModel(rawValue: modelRaw) {
            model = known
            customModelName = (known == .customLocal) ? modelRaw : nil
        } else if provider == .local {
            // Unknown tag against local — let Ollama figure it out.
            model = .customLocal
            customModelName = modelRaw
        } else {
            throw CLIArgsError.invalidValue(
                flag: "--model",
                value: modelRaw,
                reason: "not a known AgentModel rawValue (e.g. opus47/claude-opus-4-7, sonnet46/claude-sonnet-4-6, qwen3-vl:8b)"
            )
        }

        // Validate model.provider matches --provider so the user can't say
        // `--provider anthropic --model gpt-5-mini`.
        if model != .customLocal && model.provider != provider {
            throw CLIArgsError.invalidValue(
                flag: "--model",
                value: modelRaw,
                reason: "model belongs to provider '\(model.provider.rawValue)' but you passed --provider \(provider.rawValue)"
            )
        }

        // Resolve persona. We accept literal text for v1; preset-name
        // lookup against persona-defaults.md is a follow-up.
        let resolvedPersona = persona ?? "A curious first-time user who reads labels but doesn't have the manual."

        // Resolve output directory. Default: ./runs/<timestamp>/.
        let resolvedOutputDir: URL = {
            if let outputDirPath {
                if outputDirPath.hasPrefix("/") {
                    return URL(fileURLWithPath: outputDirPath, isDirectory: true)
                } else {
                    let cwd = FileManager.default.currentDirectoryPath
                    return URL(fileURLWithPath: outputDirPath, isDirectory: true, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).absoluteURL
                }
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let stamp = formatter.string(from: Date())
            let cwd = FileManager.default.currentDirectoryPath
            return URL(fileURLWithPath: cwd, isDirectory: true)
                .appendingPathComponent("runs", isDirectory: true)
                .appendingPathComponent(stamp, isDirectory: true)
        }()

        return CLIArgs(
            platform: platform,
            goal: goal,
            persona: resolvedPersona,
            provider: provider,
            model: model,
            customModelName: customModelName,
            maxSteps: maxSteps ?? Self.defaultMaxSteps,
            outputDir: resolvedOutputDir,
            deterministic: deterministic,
            url: url ?? "",
            viewportWidth: viewportWidth ?? Self.defaultViewportWidth,
            viewportHeight: viewportHeight ?? Self.defaultViewportHeight,
            iosProjectPath: iosProjectPath,
            iosScheme: iosScheme,
            iosSimulatorUDID: iosSimulatorUDID,
            iosSimulatorName: iosSimulatorName,
            iosSimulatorRuntime: iosSimulatorRuntime
        )
    }

    private static func consumeValue(_ flag: String, argv: [String], i: inout Int) throws -> String {
        guard i + 1 < argv.count else {
            throw CLIArgsError.missingValue(flag)
        }
        let value = argv[i + 1]
        i += 2
        return value
    }

    static let usage: String = """
        harness-cli — drive a single run end-to-end without launching the Harness Mac app.

        Required for every run:
          --goal <TEXT>                        Agent goal (plain language)
          --provider anthropic|openai|google|local
          --model <RAW>                        AgentModel rawValue, e.g.
                                                 claude-opus-4-7, claude-sonnet-4-6,
                                                 gpt-5-mini, gemini-2.5-flash,
                                                 qwen3-vl:8b, gemma4:9b, llama3.2-vision:11b
                                                 (Any tag when --provider local maps to customLocal.)
          --platform web|ios                   Run target (default: web). macOS not yet supported.

        Required for --platform web:
          --url <URL>                          Target web app URL

        Required for --platform ios:
          --project-path <PATH>                Path to the .xcodeproj (or .xcworkspace)
          --scheme <NAME>                      Xcodebuild scheme to build + launch
          --simulator-udid <UDID>              Simulator UDID (xcrun simctl list devices --json)

        Optional:
          --persona <TEXT>                     Persona description (default: curious first-time user)
          --max-steps <N>                      Step budget (default: \(Self.defaultMaxSteps))
          --output <DIR>                       Output directory (default: ./runs/<timestamp>/)
          --viewport-width <PT>                Web CSS-pixel width (default: \(Self.defaultViewportWidth))
          --viewport-height <PT>               Web CSS-pixel height (default: \(Self.defaultViewportHeight))
          --simulator-name <NAME>              iOS — human-readable label for logs (e.g. "iPhone 17 Pro Max")
          --simulator-runtime <LABEL>          iOS — runtime label for logs (e.g. "iOS 26.2")
          --deterministic                      temperature=0 (advisory — provider-dependent)

        Credentials (env vars; otherwise falls back to macOS Keychain entries
        written by the GUI app, with a one-time access prompt):
          ANTHROPIC_API_KEY
          OPENAI_API_KEY
          GOOGLE_API_KEY
          HARNESS_OLLAMA_URL (default: http://127.0.0.1:11434)

        Dev-time diagnostics:
          HARNESS_DUMP_MARKED=1                Write step-NNN.marked.png next to each
                                                unmarked PNG + log click/tap_mark resolution
                                                to stderr.

        Output: events.jsonl + step-NNN.png + meta.json under --output.
        """
}

enum CLIArgsError: Error, LocalizedError {
    case helpRequested
    case unknownFlag(String)
    case missingRequired(String)
    case missingValue(String)
    case invalidValue(flag: String, value: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .helpRequested:
            return "Help"
        case .unknownFlag(let flag):
            return "Unknown flag: \(flag)"
        case .missingRequired(let flag):
            return "Missing required flag: \(flag)"
        case .missingValue(let flag):
            return "Missing value for \(flag)"
        case .invalidValue(let flag, let value, let reason):
            return "Invalid value for \(flag): \"\(value)\" — \(reason)"
        }
    }
}
