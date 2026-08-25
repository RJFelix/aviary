import Foundation

/// What a run was asked to be.
///
/// Outlived the harness. It began as the argument list for the fork's CLI, but every engine
/// needs the same handful of facts — where to run, which model, whether to resume, whether to
/// record the wire — and the views read it without caring which engine is behind them.
public struct RunConfiguration: Sendable, Hashable {
    public var cwd: String
    public var provider: String?
    public var model: String?
    public var thinkingLevel: String?
    /// Session id or path to resume. Nil starts fresh.
    public var resume: String?
    public var persistSession: Bool = true
    /// Skip AGENTS.md / CLAUDE.md discovery.
    public var noContextFiles: Bool = false
    /// Record every provider request payload, so the run can show exactly what was sent.
    ///
    /// Off by default and never implicit: recording writes your full system prompt and
    /// conversation to a file on disk.
    public var recordPayloads: Bool = false
    /// Where the wire log goes when `recordPayloads` is on.
    public var wireLogPath: String?
    /// Extra environment for the engine process, merged over the captured shell environment.
    public var environmentOverrides: [String: String] = [:]
    public var extraArguments: [String] = []

    public init(
        cwd: String,
        provider: String? = nil,
        model: String? = nil,
        thinkingLevel: String? = nil,
        resume: String? = nil,
        persistSession: Bool = true,
        noContextFiles: Bool = false,
        recordPayloads: Bool = false,
        wireLogPath: String? = nil,
        environmentOverrides: [String: String] = [:],
        extraArguments: [String] = []
    ) {
        self.cwd = cwd
        self.provider = provider
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.resume = resume
        self.persistSession = persistSession
        self.noContextFiles = noContextFiles
        self.recordPayloads = recordPayloads
        self.wireLogPath = wireLogPath
        self.environmentOverrides = environmentOverrides
        self.extraArguments = extraArguments
    }

    func arguments(engine: EngineLocation) -> [String] {
        var a = engine.leadingArguments + ["--mode", "rpc", "--cwd", cwd]
        if let provider { a += ["--provider", provider] }
        if let model { a += ["--model", model] }
        if let thinkingLevel { a += ["--thinking", thinkingLevel] }
        if let resume { a += ["--resume", resume] }
        if !persistSession { a.append("--no-session") }
        if noContextFiles { a.append("-nc") }
        // The recorder is a harness extension, loaded per run. Nothing is recorded unless
        // both the extension and its destination are present.
        if recordPayloads, wireLogPath != nil,
           let ext = EngineLocator.wireLogExtension()
        {
            a += ["-e", ext.path]
        }
        a += extraArguments
        return a
    }
}

/// An event from a live run: either a protocol event or a reply to one of our commands.
