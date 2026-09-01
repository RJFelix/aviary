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
    /// Preallocated session/Work/run identities. Nil preserves legacy call sites; callers that
    /// are about to launch should resolve this once, before starting a provider or runtime host.
    public var identity: SessionWorkIdentity?
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
        extraArguments: [String] = [],
        identity: SessionWorkIdentity? = nil
    ) {
        self.cwd = cwd
        self.provider = provider
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.resume = resume
        self.identity = identity
        self.persistSession = persistSession
        self.noContextFiles = noContextFiles
        self.recordPayloads = recordPayloads
        self.wireLogPath = wireLogPath
        self.environmentOverrides = environmentOverrides
        self.extraArguments = extraArguments
    }

    /// Resolve the identity once at the launch boundary.
    ///
    /// A supplied identity wins. A legacy resume recovers the Work fields from its session
    /// header when present, or receives a deterministic legacy Work identity; fresh runs use the
    /// durable host id for this AgentHome. The returned value should be passed unchanged through
    /// every core object in the run. This is allocation, not a launch registry: concurrent
    /// resumes still require the session controller/service layer to coordinate writers.
    public func resolvedIdentity(home: AgentHome) -> SessionWorkIdentity {
        if let identity { return identity }
        if let resume,
           let recovered = SessionWriter.recoverIdentity(home: home, sessionID: resume)
        {
            return recovered
        }
        return SessionWorkIdentity.allocate(
            workHostID: home.workHostID,
            sessionID: resume ?? SessionWriter.newSessionID())
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
