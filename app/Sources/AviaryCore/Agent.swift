import Foundation

/// The agent loop, in-house.
///
/// Send the conversation and the tool schema; stream back text, thinking and tool calls;
/// execute the calls in the runtime host; append the results; go again until the model stops
/// asking for tools. That is the whole of it — the loop is small, and everything interesting
/// lives in the three things it composes: a `ChatProvider`, a `RuntimeHost`, and a
/// `SessionWriter` producing files Aviary already knows how to render.
///
/// Written as an actor with a callback rather than returning a value, because a run is watched
/// while it happens. The same events drive a live view and a test.
public actor Agent {
    /// Cancellation scopes implemented by this engine. The loop observes the request at safe
    /// boundaries; it does not expose provider-stream or current-action interruption.
    public static let supportedCancellationScopes: Set<SessionCancellationScope> = [.agentLoop]
    /// The single capability declaration shared by the in-house driver and its controller.
    public static let inHouseCommandCapabilities = SessionCommandCapabilities(
        supportsSteering: true,
        supportsQueuedFollowUps: true,
        cancellationScopes: supportedCancellationScopes)

    // MARK: Configuration

    public struct Configuration: Sendable {
        public var model: ModelSpec
        public var cwd: String
        public var systemPrompt: String
        /// A ceiling on model round trips per prompt. Not a budget — a stop, so a tool-calling
        /// loop that never converges cannot spend indefinitely while nobody is watching.
        public var maxIterations: Int
        public var maxTokens: Int?
        public var reasoningEffort: String?
        /// Compact when the conversation passes this share of the model's context window.
        ///
        /// 0.7 rather than something closer to 1.0 because compaction itself needs headroom:
        /// summarising requires sending what is being summarised, and a run that waits until
        /// it is nearly full cannot afford the call that would save it.
        public var compactAtContextShare: Double = 0.7
        /// How long to hold a finished run open for work it dispatched with `.notify()`.
        /// Generous on purpose: the case this exists for is a test suite.
        public var dispatchedWorkTimeout: TimeInterval = 900
        /// How deep sub-agents may nest. A ceiling rather than a budget — recursion with no
        /// floor is the one failure mode that can spend without bound while nobody watches.
        public var maxDepth: Int = 3
        public var depth: Int = 0
        /// A budget and a finishing condition. Nil means the only limit is `maxIterations`,
        /// which the agent cannot see and therefore cannot plan against.
        public var goal: Goal?
        /// Prior turns to continue from, replayed by `SessionResume`. Carried in the
        /// configuration rather than set afterwards so it cannot be supplied too late — the
        /// history has to be in place before the first model call, and a `seed()` method
        /// callable at any time is a bug waiting for a refactor.
        ///
        /// Must not contain a system message; the agent builds its own from the current skills
        /// and context files, which is the point of resuming rather than replaying.
        public var resumedHistory: [ChatMessage] = []

        public init(
            model: ModelSpec, cwd: String, systemPrompt: String,
            maxIterations: Int = 40, maxTokens: Int? = nil, reasoningEffort: String? = nil,
            compactAtContextShare: Double = 0.7, maxDepth: Int = 3, depth: Int = 0,
            goal: Goal? = nil, resumedHistory: [ChatMessage] = []
        ) {
            self.model = model
            self.cwd = cwd
            self.systemPrompt = systemPrompt
            self.maxIterations = maxIterations
            self.maxTokens = maxTokens
            self.reasoningEffort = reasoningEffort
            self.compactAtContextShare = compactAtContextShare
            self.maxDepth = maxDepth
            self.depth = depth
            self.goal = goal
            self.resumedHistory = resumedHistory
        }
    }

    public enum Event: Sendable {
        case started(session: String)
        /// The user input was durably appended. The id is the writer's canonical entry id,
        /// not a provider request id, so callers can prove startup delivery and reconcile it.
        case inputCommitted(id: String)
        /// A queued message was taken up. Emitted so a UI can stop showing it as pending.
        case steered(String)
        case textDelta(String)
        case thinkingDelta(String)
        case toolStarted(id: String, name: String, arguments: JSONValue)
        case toolFinished(id: String, name: String, output: String, isError: Bool)
        /// One assistant message is durable. The entry id lets a live projection retain its
        /// streaming row until the parser has observed exactly that committed message.
        case turnFinished(messageID: String, usage: Usage?, stopReason: String?)
        case compacted(before: Int, after: Int, summary: String)
        case goalExhausted(String)
        case childStarted(id: String, name: String, prompt: String)
        case childFinished(id: String, name: String, answer: String, isError: Bool)
        /// The agent put an image in front of itself.
        case imageAttached(path: String, width: Int, height: Int)
        /// The run will answer its next turn with a different model.
        case modelChanged(provider: String, model: String)
        /// The run would have finished, but is holding for work it asked to be told about.
        case awaitingDispatched(count: Int)
        /// The loop stopped. `reason` is why, in words, because "it stopped" is never enough
        /// to act on.
        case finished(reason: String)
        case failed(String)
    }

    /// Terminal result of one admitted prompt. Events remain the presentation stream; this
    /// value is the command owner's non-racy acknowledgement path.
    public enum SendOutcome: Sendable, Equatable {
        case completed
        case cancelled
        case failed(String)
    }

    public typealias Observer = @Sendable (Event) -> Void
    public typealias InputDeliveryObserver = @Sendable (SessionCommandDelivery) async -> Void

    // MARK: State

    /// Both `var` so a run can change model without being torn down. The conversation, the
    /// interpreter and its variables are the expensive things here; the model answering the
    /// next turn is not, and rebuilding a session to swap it would throw away the first to
    /// change the second.
    private var provider: ChatProvider
    private let host: RuntimeHost
    private let writer: SessionWriter
    /// The canonical Session/Work producer for native runs. The legacy writer remains an
    /// explicit presentation adapter until every reader consumes Timeline v2 directly.
    private let nativeJournal: RunJournalBundle?
    private var config: Configuration
    private let hostSession: String
    private var messages: [ChatMessage] = []
    private var observer: Observer?
    private var cancelled = false
    /// A cancellation can arrive in the hand-off window after the driver admits a turn but
    /// before `send` has entered this actor. Preserve it for that next send instead of losing
    /// it when the normal per-send reset runs.
    private var cancelNextSend = false
    private var activeSendCount = 0
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    /// The prompt that opened the run, kept for memory provenance.
    private var firstPrompt: String?
    /// Messages to inject before the next model call, and after the run finishes.
    ///
    /// Two queues because they answer different questions. Steering is "change course now" and
    /// lands at the next turn boundary — not mid-turn, because a tool call already in flight
    /// has to be answered before the model can be told anything. A follow-up is "and then do
    /// this", and waits for the run to settle.
    private struct QueuedInput: Sendable {
        let text: String
        let onDelivery: InputDeliveryObserver?
    }
    private var pendingSteering: [QueuedInput] = []
    private var pendingFollowUps: [QueuedInput] = []

    public private(set) var totalUsage = Usage()
    /// The last input-token count the provider reported. The cheapest available measure of
    /// how full the context is, and an exact one — unlike counting characters.
    private var lastInputTokens = 0
    private var compactions = 0
    /// How a child reports back to its parent, and who to notify.
    private var spawnDelegate: SpawnDelegate?
    private var peerDelegate: PeerDelegate?
    private var selfDelegate: SelfDelegate?
    /// Tasks the agent asked to be told about and stopped waiting for.
    private var dispatchedCount = 0
    /// MCP servers whose tools this run may call, keyed by the namespaced tool name the model
    /// sees. Namespaced because two servers may both offer `search`, and a bare name would
    /// make that collision silent.
    private var mcpTools: [String: (client: MCPClient, tool: MCPClient.Tool)] = [:]
    /// Images the cell asked to look at, waiting for the end of the tool call that queued them.
    private var pendingImages: [(image: AttachedImage, note: String?)] = []
    /// Where `remember` writes and `recall` reads. Absent means the run has no memory, which
    /// is a legitimate configuration rather than an error.
    private var memory: MemoryStore?
    /// Where `artifact` writes. Installed by whoever knows the agent home, which the loop does
    /// not; every real caller installs one, so an absent store means a harness in a test.
    private var artifacts: ArtifactStore?
    /// Where request payloads go, when a run is recording them. Off unless asked for: it writes
    /// the full system prompt and conversation to disk, which should never be implicit.
    private var wireLogURL: URL?
    /// Whether any hooks are loaded. Checked so a run with none pays nothing for the feature.
    private var hooksEnabled = false
    /// Once the append-only journal is unhealthy, continuing would create effects with no
    /// durable antecedent. Keep the failure local and fail closed at every effect boundary.
    private var journalFailureDetail: String?

    public init(
        provider: ChatProvider, host: RuntimeHost, writer: SessionWriter,
        hostSession: String, config: Configuration,
        nativeJournal: RunJournalBundle? = nil
    ) {
        self.provider = provider
        self.host = host
        self.writer = writer
        self.nativeJournal = nativeJournal
        self.hostSession = hostSession
        self.config = config
        // A defensive filter rather than a precondition: a stale system prompt from a previous
        // run would silently override the one just built, and the failure would look like the
        // agent ignoring its own configuration.
        self.messages = [.system(config.systemPrompt)]
            + config.resumedHistory.filter { $0.role != .system }
    }

    public func observe(_ observer: Observer?) {
        self.observer = observer
    }

    /// One sub-agent, as the parent sees it while it is still going.
    public struct ChildStatus: Sendable, Hashable {
        public var id: String
        public var name: String
        /// `running`, `done`, or `failed`.
        public var state: String
        /// Present once it has finished.
        public var answer: String?

        public init(id: String, name: String, state: String, answer: String?) {
            self.id = id
            self.name = name
            self.state = state
            self.answer = answer
        }

        public var payload: JSONValue {
            var out: [String: JSONValue] = [
                "id": .string(id), "name": .string(name), "state": .string(state),
            ]
            if let answer { out["answer"] = .string(answer) }
            return .object(out)
        }
    }

    /// Somebody who can run a child agent. Injected rather than built in, so a caller decides
    /// what a sub-agent costs, where it writes, and whether it is allowed at all.
    ///
    /// Non-blocking only, deliberately. There used to be a blocking variant beside this one,
    /// and it was the wrong shape for this product: the agent is *writing Python*, not calling
    /// a sub-agent tool, so waiting is something its script should decide rather than
    /// something the primitive decides for it. `spawn()` hands Python a
    /// `concurrent.futures.Future`, and `.result()` is how you wait — which also brings
    /// `wait()`, `as_completed()` and every other stdlib idiom for free, none of which a
    /// blocking call could have offered.
    public protocol SpawnDelegate: Sendable {
        /// The admission result is explicit: only `.running` means the runner created the
        /// background task. `.refused` is a real, explainable outcome rather than an id that
        /// makes the model believe a child exists when admission was closed.
        func startBackground(
            prompt: String, name: String?, model: String?, depth: Int
        ) async -> SpawnStartResult

        /// Every child this run has started, finished or not. Polled by the Future's own
        /// thread rather than by the agent, so it is not in the namespace.
        func children() async -> [ChildStatus]
    }

    public enum SpawnStartResult: Hashable, Sendable {
        case running(childID: String, name: String)
        case refused(name: String, reason: String)
    }

    /// Somebody who can put a message into *this* run's own conversation.
    ///
    /// Separate from the agent's own queue because of the case that matters: a shell command
    /// that outlives the turn that started it. By the time it finishes the loop may have
    /// exited, and a message queued on an agent that is no longer looping is a message nobody
    /// reads. The app can restart the run; the agent cannot restart itself.
    public protocol SelfDelegate: Sendable {
        func deliverToSelf(
            sessionID: String, text: String, from sourceSessionID: String
        ) async -> Bool
    }

    public func setSelfDelegate(_ delegate: SelfDelegate?) {
        selfDelegate = delegate
    }

    public func setSpawnDelegate(_ delegate: SpawnDelegate?) {
        spawnDelegate = delegate
    }

    /// One other run Aviary is holding.
    public struct Peer: Sendable, Hashable {
        public var session: String
        public var title: String
        public var model: String
        public var working: Bool
        public var engine: String

        public init(
            session: String, title: String, model: String, working: Bool, engine: String
        ) {
            self.session = session
            self.title = title
            self.model = model
            self.working = working
            self.engine = engine
        }

        public var payload: JSONValue {
            .object([
                "session": .string(session), "title": .string(title),
                "model": .string(model), "working": .bool(working),
                "engine": .string(engine),
            ])
        }
    }

    /// Somebody who knows what else is running and can deliver a message to it.
    ///
    /// Injected for the same reason spawning is: only the app knows what runs exist, and an
    /// agent that could enumerate them for itself would be reaching out of its own session.
    ///
    /// Note what this is *not*. The harness had a daemon holding many sessions, so an agent
    /// could message a parent or a sibling mid-flight. Aviary's `spawn()` blocks — a parent is
    /// suspended while its child runs, so the two never act at once and there is no sibling to
    /// talk to. What genuinely runs concurrently here is separate top-level runs, and that is
    /// what these peers are.
    public protocol PeerDelegate: Sendable {
        func peers(excluding sessionID: String) async -> [Peer]
        func deliver(to peer: String, text: String, from sessionID: String) async
            -> (session: String, error: String?)
    }

    public func setPeerDelegate(_ delegate: PeerDelegate?) {
        peerDelegate = delegate
    }

    /// How many peers there were when the tool description was last built.
    ///
    /// Cached rather than awaited inside `activeTools`, which is not async. Refreshed at each
    /// turn boundary, so a run that opens beside this one is describable by the next request
    /// rather than the next session.
    private var peerCount = 0

    /// Offer this run a set of MCP tools.
    public func addMCPTools(_ tools: [MCPClient.Tool], from client: MCPClient) {
        for tool in tools { mcpTools[tool.qualifiedName] = (client, tool) }
    }

    /// Answer the next turn with a different model.
    ///
    /// Takes effect at the next model call, not mid-turn: a tool call in flight has to be
    /// answered before anything else can happen, and swapping between a call and its result
    /// produces a conversation the provider rejects. The same reason steering lands at a turn
    /// boundary.
    ///
    /// History carries over untouched. That is the point — the model is being changed
    /// *because* of what the conversation has established, so starting again would defeat it.
    @discardableResult
    public func switchModel(to model: ModelSpec, provider newProvider: ChatProvider) async -> Bool {
        guard await requireJournal("model switch") else { return false }
        if let nativeJournal {
            do {
                _ = try await nativeJournal.changeModel(model.qualifiedID)
            } catch {
                latchNativeJournalFailure("the model switch", error)
                return false
            }
        }

        // Once Timeline v2 has accepted the change it is the authority for the effective model.
        // Apply the in-memory state before updating the legacy presentation so a projection
        // failure cannot leave canonical history claiming a model that the live Agent never
        // adopted. The run will fail closed at the next effect boundary if that projection is
        // unavailable, but the accepted change itself remains truthful.
        provider = newProvider
        config.model = model
        config.maxTokens = model.maxTokens
        do {
            try await writer.appendModelChange(model)
        } catch {
            journalFailureDetail = "Could not record the model switch: \(error.localizedDescription)"
            emit(.modelChanged(provider: model.providerID, model: model.id))
            emit(.failed(journalFailureDetail!))
            return nativeJournal != nil
        }
        emit(.modelChanged(provider: model.providerID, model: model.id))
        return true
    }

    public func setMemory(_ store: MemoryStore?) {
        memory = store
    }

    public func setArtifacts(_ store: ArtifactStore?) {
        artifacts = store
    }

    /// Record every request payload, so the run can show where its input tokens went.
    public func recordPayloads(to url: URL?) {
        wireLogURL = url
    }

    public func enableHooks(_ enabled: Bool) {
        hooksEnabled = enabled
    }

    /// Serve a request from the runtime. Wire this to `RuntimeHost.onCallback`.
    ///
    /// Answers with an `error` key rather than throwing, always: the agent asked a question in
    /// code and is blocked on the reply, so a refusal it can read beats a hang it cannot.
    public func serveCallback(kind: String, payload: JSONValue) async -> JSONValue {
        guard await requireJournal("callback \(kind)") else {
            return .object(["error": .string(
                journalFailureDetail ?? "The session journal is unavailable; stop this run.")])
        }
        switch kind {
        case "children":
            guard let delegate = spawnDelegate else {
                return .object(["error": .string("Sub-agents are not enabled for this run.")])
            }
            return .array(await delegate.children().map(\.payload))

        case "agents":
            guard let peerDelegate else {
                return .object(["error": .string("This run has no peers to list.")])
            }
            let found = await peerDelegate.peers(excluding: writer.sessionID)
            return .array(found.map(\.payload))

        case "message":
            guard let peerDelegate else {
                return .object(["error": .string("This run cannot message other runs.")])
            }
            guard let to = payload["to"]?.stringValue, !to.isEmpty else {
                return .object(["error": .string("message() needs a `to`.")])
            }
            guard let text = payload["text"]?.stringValue,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .object(["error": .string("message() needs some text.")])
            }
            let permit = await beginNativeAction(
                kind: .peerDelivery, intent: "Deliver a message to a peer", target: to)
            do { try requireNativePermit(permit, for: "peer delivery") }
            catch { return .object(["error": .string(error.localizedDescription)]) }
            let outcome = await peerDelegate.deliver(
                to: to, text: text, from: writer.sessionID)
            guard await finishNativeAction(
                permit, state: outcome.error == nil ? .succeeded : .failed,
                retrySafety: .unsafe, failureKind: outcome.error == nil ? nil : .task) else {
                return .object(["error": .string(
                    journalFailureDetail ?? "The peer-delivery outcome could not be recorded.")])
            }
            if let error = outcome.error { return .object(["error": .string(error)]) }
            return .object([
                "delivered": .bool(true), "session": .string(outcome.session),
            ])

        case "dispatched":
            // `.notify()` announcing itself, so the loop knows not to finish on a promise.
            dispatchedCount += 1
            return .object(["ok": .bool(true)])

        case "notify":
            guard let raw = payload["text"]?.stringValue,
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return .object(["error": .string("notify() needs some text.")]) }
            // Bounded here as well as in the prelude, because this is where the law actually
            // lives: nothing unbounded enters a conversation. A message costs a model call and
            // then becomes permanent context, re-sent on every later turn, so an unbounded one
            // is a bill that keeps arriving. The prelude's limit keeps a megabyte off the
            // callback channel; this one is what makes the guarantee true whatever calls it.
            let text = Self.bounded(raw)
            // Every exit after accepting the callback settles the matching dispatched promise,
            // including a journal-permit failure. Otherwise an unavailable journal can strand
            // the agent forever waiting on a notification it correctly refused to deliver.
            defer { dispatchedCount = max(0, dispatchedCount - 1) }
            let permit = await beginNativeAction(
                kind: .selfDelivery, intent: "Deliver a notification to this session",
                target: writer.sessionID)
            do { try requireNativePermit(permit, for: "self delivery") }
            catch { return .object(["error": .string(error.localizedDescription)]) }
            var deliveryError: String?
            let delivered: Bool
            if let selfDelegate {
                delivered = await selfDelegate.deliverToSelf(
                    sessionID: writer.sessionID, text: text, from: writer.sessionID)
            } else {
                // No app behind this run — a CLI session. A follow-up still lands, as long as
                // the loop is alive to take it.
                delivered = queueFollowUp(text)
            }
            guard await finishNativeAction(
                permit, state: delivered ? .succeeded : .failed,
                retrySafety: .unsafe, failureKind: delivered ? nil : .task) else {
                return .object(["error": .string(
                    journalFailureDetail ?? "The self-delivery outcome could not be recorded.")])
            }
            if !delivered {
                deliveryError = "The session did not accept the notification."
            }
            if let deliveryError {
                return .object(["delivered": .bool(false), "error": .string(deliveryError)])
            }
            return .object(["delivered": .bool(true)])

        case "search", "read_url":
            guard let key = WebSearch.configuredKey() else {
                return .object(["error": .string(
                    "No \(WebSearch.keyVariable) in the environment, so web access is off.")])
            }
            let web = WebSearch(apiKey: key)
            if kind == "search" {
                let queries = (payload["queries"]?.arrayValue ?? [])
                    .compactMap(\.stringValue)
                let objective = payload["objective"]?.stringValue
                guard !(objective ?? "").isEmpty || !queries.isEmpty else {
                    return .object(["error": .string(
                        "search() needs an objective, or some queries.")])
                }
                let permit = await beginNativeAction(
                    kind: .webSearch, intent: "Search the web", target: "web.search")
                do { try requireNativePermit(permit, for: "web search") }
                catch { return .object(["error": .string(error.localizedDescription)]) }
                do {
                    let result = try await web.search(
                        objective: objective,
                        // The objective doubles as the query when none is given: the API wants
                        // at least one, and asking the model for both every time is friction
                        // for a distinction it does not always have.
                        queries: queries.isEmpty ? [objective ?? ""] : queries,
                        mode: payload["mode"]?.stringValue ?? WebSearch.defaultMode,
                        maxResults: payload["n"]?.intValue,
                        maxCharsPerResult: payload["max_chars"]?.intValue,
                        includeDomains: (payload["include"]?.arrayValue ?? [])
                            .compactMap(\.stringValue),
                        excludeDomains: (payload["exclude"]?.arrayValue ?? [])
                            .compactMap(\.stringValue),
                        afterDate: payload["after"]?.stringValue)
                        guard await finishNativeAction(
                            permit, state: .succeeded, retrySafety: .unsafe) else {
                            return .object(["error": .string(
                                journalFailureDetail ?? "The web-search outcome could not be recorded.")])
                        }
                        return result
                    } catch {
                        _ = await finishNativeAction(
                            permit, state: .failed, retrySafety: .unsafe,
                            failureKind: .infrastructure)
                        return .object(["error": .string(error.localizedDescription)])
                }
            }
            let urls = (payload["urls"]?.arrayValue ?? []).compactMap(\.stringValue)
            guard !urls.isEmpty else {
                return .object(["error": .string("read_url() needs at least one URL.")])
            }
            let permit = await beginNativeAction(
                kind: .webExtract, intent: "Extract content from web pages", target: "web.extract")
            do { try requireNativePermit(permit, for: "web extraction") }
            catch { return .object(["error": .string(error.localizedDescription)]) }
            do {
                let result = try await web.extract(
                    urls: urls, objective: payload["objective"]?.stringValue,
                    queries: (payload["queries"]?.arrayValue ?? []).compactMap(\.stringValue),
                    full: payload["full"]?.boolValue ?? false)
                guard await finishNativeAction(
                    permit, state: .succeeded, retrySafety: .unsafe) else {
                    return .object(["error": .string(
                        journalFailureDetail ?? "The web-extract outcome could not be recorded.")])
                }
                return result
            } catch {
                _ = await finishNativeAction(
                    permit, state: .failed, retrySafety: .unsafe,
                    failureKind: .infrastructure)
                return .object(["error": .string(error.localizedDescription)])
            }

        case "attach_image":
            guard config.model.supportsImages else {
                return .object(["error": .string(
                    "\(config.model.id) does not accept images. Describe what you need from "
                        + "the file instead, or switch the run to a vision model.")])
            }
            guard let path = payload["path"]?.stringValue, !path.isEmpty else {
                return .object(["error": .string("attach_image() needs a path.")])
            }
            let permit = await beginNativeAction(
                kind: .imageRead, intent: "Read an image for the model", target: path)
            do { try requireNativePermit(permit, for: "image read") }
            catch { return .object(["error": .string(error.localizedDescription)]) }
            do {
                let image = try AttachedImage.read(path: path)
                guard await finishNativeAction(
                    permit, state: .succeeded, retrySafety: .safe) else {
                    return .object(["error": .string(
                        journalFailureDetail ?? "The image-read outcome could not be recorded.")])
                }
                // Queued rather than returned: an image has to reach the model as a content
                // block in the conversation, and a tool result is text. The loop drains this
                // straight after the result that produced it, so the picture arrives with the
                // reasoning that asked for it rather than a turn later.
                pendingImages.append((image, payload["note"]?.stringValue))
                return image.summary
            } catch {
                _ = await finishNativeAction(
                    permit, state: .failed, retrySafety: .safe, failureKind: .task)
                return .object(["error": .string(error.localizedDescription)])
            }

        case "spawn":
            guard await requireJournal("child start") else {
                return .object(["error": .string(
                    journalFailureDetail ?? "The session journal is unavailable; stop this run.")])
            }
            guard let delegate = spawnDelegate else {
                return .object(["error": .string("Sub-agents are not enabled for this run.")])
            }
            guard config.depth < config.maxDepth else {
                return .object(["error": .string(
                    "Already at the maximum sub-agent depth (\(config.maxDepth)). Do this work "
                        + "yourself rather than delegating it.")])
            }
            let prompt = payload["prompt"]?.stringValue ?? ""
            guard !prompt.isEmpty else {
                return .object(["error": .string("spawn() needs a prompt.")])
            }
            if let rejection = Self.childModelRejection(
                requested: payload["model"]?.stringValue, parent: config.model)
            {
                return .object(["error": .string(rejection)])
            }
            let name = payload["name"]?.stringValue
            // Always non-blocking. Waiting is `.result()` on the Future the prelude hands
            // back, which is Python's business rather than this callback's.
            let permit = await beginNativeAction(
                kind: .child, intent: "Start a child agent", target: name ?? "child",
                metadata: ["depth": .number(Double(config.depth + 1))])
            do { try requireNativePermit(permit, for: "child start") }
            catch { return .object(["error": .string(error.localizedDescription)]) }
            let started = await delegate.startBackground(
                prompt: prompt, name: name,
                model: payload["model"]?.stringValue, depth: config.depth + 1)
            switch started {
            case .running(let childID, let childName):
                guard await finishNativeAction(
                    permit, state: .succeeded, retrySafety: .unsafe) else {
                    return .object(["error": .string(
                        journalFailureDetail ?? "The child-start outcome could not be recorded.")])
                }
                return .object([
                    "id": .string(childID), "name": .string(childName),
                    "state": .string("running"),
                ])
            case .refused(let refusedName, let reason):
                let detail = "Child \(refusedName.debugDescription) was not started: \(reason)"
                guard await finishNativeAction(
                    permit, state: .canceled, retrySafety: .safe,
                    failureKind: .policy) else {
                    return .object(["error": .string(
                        journalFailureDetail ?? "The refused child-start outcome could not be recorded.")])
                }
                return .object([
                    "name": .string(refusedName), "state": .string("refused"),
                    "error": .string(detail),
                ])
            }

        case "remember":
            guard let memory else {
                return .object(["error": .string("This run has no memory store.")])
            }
            let text = (payload["text"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return .object(["error": .string("remember() needs some text.")])
            }
            let scope = MemoryScope(rawValue: payload["scope"]?.stringValue ?? "project")
                ?? .project
            var expiresAt: Date?
            if let days = payload["days"]?.intValue, days > 0 {
                expiresAt = Date().addingTimeInterval(Double(days) * 86_400)
            }
            let entry = MemoryEntry(
                id: MemoryStore.newID(), scope: scope, text: text,
                tags: (payload["tags"]?.arrayValue ?? []).compactMap { $0.stringValue },
                createdAt: Date(), updatedAt: Date(), expiresAt: expiresAt,
                sessionID: writer.sessionID,
                // Provenance, because the harness recorded none and "why does it think that?"
                // was unanswerable. The prompt that produced the belief is the answer.
                provenance: firstPrompt)
            let permit = await beginNativeAction(
                kind: .memory, intent: "Write a memory entry", target: scope.rawValue)
            do { try requireNativePermit(permit, for: "memory write") }
            catch { return .object(["error": .string(error.localizedDescription)]) }
            do {
                try memory.append(entry, sessionID: writer.sessionID)
                guard await finishNativeAction(
                    permit, state: .succeeded, retrySafety: .unsafe) else {
                    return .object(["error": .string(
                        journalFailureDetail ?? "The memory-write outcome could not be recorded.")])
                }
                // Recorded in the transcript too, so a reader sees the agent deciding to
                // believe something at the moment it decided.
                guard await appendJournalNote(
                    "Remembered (\(scope.rawValue)): \(text)", customType: "aviary.memory")
                else {
                    return .object(["error": .string(
                        journalFailureDetail ?? "The memory note could not be recorded.")])
                }
                return .object(["id": .string(entry.id), "scope": .string(scope.rawValue)])
            } catch {
                _ = await finishNativeAction(
                    permit, state: .failed, retrySafety: .unsafe, failureKind: .infrastructure)
                return .object(["error": .string(error.localizedDescription)])
            }

        case "recall":
            guard let memory else {
                return .object(["error": .string("This run has no memory store.")])
            }
            let query = payload["query"]?.stringValue ?? ""
            let all = memory.load(sessionID: writer.sessionID)
            let terms = SkillGate.terms(in: query)
            let hits = terms.isEmpty ? all : all.filter { entry in
                let haystack = SkillGate.terms(
                    in: entry.text + " " + entry.tags.joined(separator: " "))
                return !terms.intersection(haystack).isEmpty
            }
            return .object(["memories": .array(hits.prefix(20).map { entry in
                .object([
                    "id": .string(entry.id),
                    "text": .string(entry.text),
                    "scope": .string(entry.scope.rawValue),
                    "tags": .array(entry.tags.map { .string($0) }),
                ])
            })])

        case "artifact":
            guard let artifacts else {
                return .object(["error": .string(
                    "This run has nowhere to write artifacts.")])
            }
            let permit = await beginNativeAction(
                kind: .artifact, intent: "Write an artifact", target: payload["title"]?.stringValue)
            do { try requireNativePermit(permit, for: "artifact write") }
            catch { return .object(["error": .string(error.localizedDescription)]) }
            do {
                let written = try artifacts.write(
                    text: payload["text"]?.stringValue ?? "",
                    title: payload["title"]?.stringValue,
                    format: payload["format"]?.stringValue ?? "md")
                guard await finishNativeAction(
                    permit, state: .succeeded, retrySafety: .unsafe) else {
                    return .object(["error": .string(
                        journalFailureDetail ?? "The artifact-write outcome could not be recorded.")])
                }
                // Recorded in the transcript as well as returned, because the return value is
                // read once by the model and the transcript is what a person opens tomorrow.
                guard await appendJournalNote(
                    written.note.text, customType: ArtifactNote.customType)
                else {
                    return .object(["error": .string(
                        journalFailureDetail ?? "The artifact note could not be recorded.")])
                }
                return written.payload
            } catch {
                _ = await finishNativeAction(
                    permit, state: .failed, retrySafety: .unsafe, failureKind: .infrastructure)
                return .object(["error": .string(error.localizedDescription)])
            }

        case "conversation":
            // The agent reading its own history, programmatically. Useful on its own — it can
            // grep what it already tried instead of re-deriving it — and it is what lets a
            // child be handed exactly the slice of context it needs rather than all or none.
            let limit = payload["limit"]?.intValue ?? 40
            let recent = messages.suffix(max(1, limit))
            return .object(["messages": .array(recent.map { message in
                .object([
                    "role": .string(message.role.rawValue),
                    "text": .string(message.plainText),
                    "toolCalls": .array(message.toolCalls.map { .string($0.name) }),
                ])
            })])

        default:
            return .object(["error": .string("Aviary does not serve \(kind) requests.")])
        }
    }

    /// This runner currently owns one already-resolved provider. Accept naming that same model,
    /// but reject a different child route explicitly instead of silently running the parent model.
    static func childModelRejection(requested: String?, parent: ModelSpec) -> String? {
        guard let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requested.isEmpty,
              requested != parent.id,
              requested != parent.qualifiedID
        else { return nil }
        return "This run cannot route a child to \(requested). Omit model to use "
            + "\(parent.qualifiedID), or start that child from a run configured for the requested model."
    }

    public func cancel() {
        cancelled = true
    }

    /// Request the narrow cancellation scope this agent can actually provide.
    ///
    /// The agent checks this flag at model/action boundaries and after a provider returns. It
    /// cannot interrupt a provider stream or an already-running Python action, so those scopes
    /// remain explicit unsupported capabilities at the driver/controller boundary.
    @discardableResult
    public func requestCancellation(_ scope: SessionCancellationScope) -> Bool {
        guard Self.supportedCancellationScopes.contains(scope) else { return false }
        if activeSendCount > 0 { cancelled = true }
        else if firstPrompt == nil { cancelNextSend = true }
        else { return false }
        return true
    }

    /// Wait until all currently admitted sends have returned. A request in the pre-entry handoff
    /// window also waits for that next send to observe the preserved cancellation flag. This is
    /// deliberately separate from `cancel()`: a cancellation request may only stop before the
    /// next tool action, and the driver must not close the writer or runtime while a
    /// cancellation-insensitive model call is still unwinding.
    public func waitUntilQuiescent() async {
        guard activeSendCount > 0 || cancelNextSend else { return }
        await withCheckedContinuation { continuation in
            quiescenceWaiters.append(continuation)
        }
    }

    private func finishSend() {
        activeSendCount = max(0, activeSendCount - 1)
        guard activeSendCount == 0 else { return }
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Change course at the next turn boundary.
    ///
    /// Queued rather than applied immediately: a tool call in flight must be answered before
    /// the model can be told anything, and injecting a message between a call and its result
    /// produces a conversation the provider rejects.
    @discardableResult
    public func steer(
        _ text: String, onInputDelivery: InputDeliveryObserver? = nil
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A freshly prepared CLI agent may stage input before its first send. After a turn has
        // ever run, accepting while quiescent would strand the message until some unrelated
        // future send, so only an active generation may accept it.
        let hasConsumer = activeSendCount > 0 || firstPrompt == nil
        guard !trimmed.isEmpty, hasConsumer, !cancelled else { return false }
        pendingSteering.append(QueuedInput(text: trimmed, onDelivery: onInputDelivery))
        return true
    }

    /// Queue a prompt for after this run settles.
    @discardableResult
    public func queueFollowUp(
        _ text: String, onInputDelivery: InputDeliveryObserver? = nil
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasConsumer = activeSendCount > 0 || firstPrompt == nil
        guard !trimmed.isEmpty, hasConsumer, !cancelled else { return false }
        pendingFollowUps.append(QueuedInput(text: trimmed, onDelivery: onInputDelivery))
        return true
    }

    public var queued: (steering: [String], followUps: [String]) {
        (pendingSteering.map(\.text), pendingFollowUps.map(\.text))
    }

    /// The conversation so far, for a caller that wants to fork or inspect it.
    public var conversation: [ChatMessage] { messages }

    /// The last thing the agent said. For a sub-agent this is the entire deliverable — the
    /// parent never sees the transcript — which is why the child prompt insists the final
    /// message carry the answer rather than an announcement that it finished.
    public var lastAssistantText: String {
        for message in messages.reversed() where message.role == .assistant {
            let text = message.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return ""
    }

    // MARK: The tool surface

    /// One tool, deliberately.
    ///
    /// The measured reason: across 5,574 real cells the agent used this environment as glue
    /// over `git`, `grep` and the filesystem — `subprocess` was the top import by 4x and two
    /// cells in total touched pandas. A menu of file and search tools would be a menu of
    /// things `sh()` already does, at the cost of a bigger schema on every request.
    /// The tool schema, which must describe *everything* the runtime can do.
    ///
    /// Rendered from `Builtins`, not written here. It used to be written here *and* again in
    /// `ClaudeCodeKernel`, which is how a description drifts from the namespace it describes —
    /// and a capability the model is not told about does not exist. `spawn()` proved it: in the
    /// namespace, absent from this text, and a real run spent twenty turns grepping the
    /// codebase for it before giving up.
    public static func tools(
        cwd: String, canSpawn: Bool = false, spawnBudget: Int = 0, hasMemory: Bool = false,
        supportsImages: Bool = false, peerCount: Int = 0, hasWeb: Bool = false
    ) -> [ChatTool] {
        let description = Builtins.description(Builtins.Context(
            cwd: cwd, hasMemory: hasMemory, canSpawn: canSpawn, spawnBudget: spawnBudget,
            supportsImages: supportsImages, peerCount: peerCount, hasWeb: hasWeb))
        return [ChatTool(
            name: "python",
            description: description,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object([
                        "type": .string("string"),
                        "description": .string("Python source to execute."),
                    ]),
                ]),
                "required": .array([.string("code")]),
            ]))]
    }

    /// The tools this run actually offers, given its depth and whether spawning is wired up.
    private var activeTools: [ChatTool] {
        var tools = Self.tools(
            cwd: config.cwd,
            canSpawn: spawnDelegate != nil && config.depth < config.maxDepth,
            spawnBudget: max(0, config.maxDepth - config.depth),
            hasMemory: memory != nil,
            supportsImages: config.model.supportsImages,
            peerCount: peerCount,
            hasWeb: WebSearch.configuredKey() != nil)
        // MCP tools are declared individually rather than behind one dispatcher, because a
        // model picks a tool by reading its schema and a single `call_mcp(name, args)` hides
        // every schema behind a string.
        for (qualified, entry) in mcpTools.sorted(by: { $0.key < $1.key }) {
            tools.append(ChatTool(
                name: qualified,
                description: entry.tool.description.isEmpty
                    ? "Tool `\(entry.tool.name)` from the \(entry.tool.server) MCP server."
                    : entry.tool.description,
                parameters: entry.tool.schema))
        }
        return tools
    }

    // MARK: Running

    /// Record a terminal state for readers that reopen the session after this send returns.
    /// Failure/cancellation is not guaranteed to have an assistant row, so this marker is a
    /// separate durable projection rather than a synthetic transcript message.
    private func recordOutcome(
        _ state: TranscriptOutcome.State, detail: String? = nil
    ) async {
        do {
            _ = try await writer.appendOutcome(state: state, detail: detail.map(Self.bounded))
        } catch {
            if journalFailureDetail == nil {
                journalFailureDetail = "Could not record the terminal session outcome: "
                    + error.localizedDescription
                emit(.failed(journalFailureDetail!))
            }
        }
    }

    /// Check the journal immediately before a model, tool, callback, or child effect. The
    /// writer's health is deliberately authoritative; a successful earlier append is not a
    /// promise that the next fsync will succeed.
    private func requireJournal(_ effect: String) async -> Bool {
        guard journalFailureDetail == nil else { return false }
        guard case .healthy = await writer.writerHealth else {
            journalFailureDetail = "The legacy session projection became unavailable before \(effect)."
            emit(.failed(journalFailureDetail!))
            return false
        }
        if let nativeJournal {
            guard case .healthy = await nativeJournal.status.health else {
                journalFailureDetail = "The canonical Session/Work journal became unavailable before \(effect)."
                emit(.failed(journalFailureDetail!))
                return false
            }
        }
        return true
    }

    private struct NativeJournalFailure: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    private func latchNativeJournalFailure(_ operation: String, _ error: Error) {
        guard journalFailureDetail == nil else { return }
        journalFailureDetail = "Could not record \(operation) in the canonical Work journal: "
            + error.localizedDescription
        emit(.failed(journalFailureDetail!))
    }

    private func beginNativeAction(
        kind: ActionKind, intent: String, target: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) async -> EffectPermit? {
        guard let nativeJournal else { return nil }
        do {
            return try await nativeJournal.beginAction(
                kind: kind, intent: intent, target: target, scope: "run", metadata: metadata)
        } catch {
            latchNativeJournalFailure("the \(kind.rawValue) action start", error)
            return nil
        }
    }

    private func finishNativeAction(
        _ permit: EffectPermit?, state: ActionExecutionState,
        retrySafety: ActionRetrySafety, failureKind: ActionFailureKind? = nil
    ) async -> Bool {
        guard let nativeJournal else { return true }
        guard let permit else { return false }
        do {
            _ = try await nativeJournal.finishAction(
                permit, state: state, retrySafety: retrySafety, failureKind: failureKind)
            return true
        } catch {
            latchNativeJournalFailure("the \(permit.kind.rawValue) action outcome", error)
            return false
        }
    }

    /// Bracket one admitted user instruction with the canonical turn lifecycle. The helper
    /// awaits the terminal record before `send` returns; an asynchronous `defer` would let the
    /// launcher publish Run completion while the turn was still active on disk.
    private func withNativeTurn(
        _ operation: () async -> SendOutcome
    ) async -> SendOutcome {
        guard let nativeJournal else { return await operation() }
        let turn = TurnRef(UUID().uuidString.lowercased())
        do {
            _ = try await nativeJournal.startTurn(turn)
        } catch {
            latchNativeJournalFailure("the turn start", error)
            return .failed(journalFailureDetail ?? error.localizedDescription)
        }

        let outcome = await operation()
        switch outcome {
        case .completed:
            break
        case .cancelled:
            await refusePendingInputs(reason: "the active turn was canceled before delivery")
        case .failed(let detail):
            await refusePendingInputs(reason: "the active turn failed before delivery: \(detail)")
        }
        do {
            _ = try await nativeJournal.finishTurn(turn)
        } catch {
            latchNativeJournalFailure("the turn outcome", error)
            return .failed(journalFailureDetail ?? error.localizedDescription)
        }
        return outcome
    }

    private func refusePendingInputs(reason: String) async {
        let queued = pendingSteering + pendingFollowUps
        pendingSteering.removeAll()
        pendingFollowUps.removeAll()
        for input in queued {
            await input.onDelivery?(.notDelivered(reason: reason))
        }
    }

    private func requireNativePermit(_ permit: EffectPermit?, for effect: String) throws {
        guard nativeJournal == nil || permit != nil else {
            throw NativeJournalFailure(
                detail: journalFailureDetail
                    ?? "The canonical Work journal refused the \(effect) effect.")
        }
    }

    /// Notes are themselves a crossing into the durable session. A failed hook or artifact
    /// annotation must not be treated as cosmetic: continuing to the next runtime effect would
    /// leave an unrecorded action in the transcript.
    private func appendJournalNote(_ text: String, customType: String = "aviary.note") async -> Bool {
        do {
            try await writer.appendNote(text, customType: customType)
            return true
        } catch {
            journalFailureDetail = "Could not record a session note: \(error.localizedDescription)"
            emit(.failed(journalFailureDetail!))
            return false
        }
    }

    /// Send a prompt and run until the model stops calling tools.
    @discardableResult
    public func send(
        _ prompt: String,
        onInputDelivery: InputDeliveryObserver? = nil
    ) async -> SendOutcome {
        activeSendCount += 1
        defer { finishSend() }
        guard await requireJournal("user input") else {
            await onInputDelivery?(.notDelivered(reason: journalFailureDetail!))
            return .failed(journalFailureDetail!)
        }
        guard !Task.isCancelled else {
            await recordOutcome(.cancelled, detail: "cancelled before the input was recorded")
            await onInputDelivery?(.notDelivered(reason: "cancelled before the input was recorded"))
            emit(.finished(reason: "cancelled"))
            return .cancelled
        }
        if cancelNextSend {
            cancelNextSend = false
            await recordOutcome(.cancelled, detail: "cancelled before the input was recorded")
            await onInputDelivery?(.notDelivered(reason: "cancelled before the input was recorded"))
            emit(.finished(reason: "cancelled"))
            return .cancelled
        }
        cancelled = false
        emit(.started(session: writer.sessionID))
        if firstPrompt == nil { firstPrompt = prompt }
        let inputID: String
        do {
            inputID = try await writer.appendUser(prompt)
        } catch {
            let detail = "Could not record the user message: \(error.localizedDescription)"
            await recordOutcome(.failed, detail: detail)
            await onInputDelivery?(.notDelivered(reason: detail))
            emit(.failed(detail))
            return .failed(detail)
        }
        await onInputDelivery?(.delivered(referenceID: inputID))
        guard await requireJournal("the first model call after input delivery") else {
            return .failed(journalFailureDetail!)
        }
        emit(.inputCommitted(id: inputID))
        messages.append(.user(prompt))

        return await withNativeTurn {
            var iterations = 0
            while iterations < config.maxIterations {
            if cancelled || Task.isCancelled {
                _ = await appendJournalNote("Stopped at your request.")
                await recordOutcome(.cancelled, detail: "Stopped at your request.")
                emit(.finished(reason: "cancelled"))
                return .cancelled
            }
            iterations += 1

            // Refreshed per model call, so a run that opens beside this one is describable by
            // the next request. Cheap: the app already holds the list.
            if let peerDelegate {
                peerCount = await peerDelegate.peers(excluding: writer.sessionID).count
            }

            // The budget is checked before spending more of it, and the stop is recorded —
            // an agent that ran out of allowance and one that finished must not look alike.
            if let goal = config.goal {
                let status = goal.status(spent: totalUsage.totalTokens)
                if status.isFinished, let note = goal.exhaustionNote(status) {
                    guard await appendJournalNote(note, customType: "aviary.goal") else {
                        return .failed(journalFailureDetail ?? "The goal outcome could not be recorded.")
                    }
                    emit(.goalExhausted(note))
                    emit(.finished(reason: "goal budget"))
                    return .completed
                }
            }

            // Steering lands here, between turns, where the conversation is well-formed.
            if !pendingSteering.isEmpty {
                let messagesToInject = pendingSteering
                pendingSteering.removeAll()
                for (index, queuedInput) in messagesToInject.enumerated() {
                    let text = queuedInput.text
                    if cancelled || Task.isCancelled {
                        let reason = "the active turn was canceled before steering delivery"
                        for refused in messagesToInject[index...] {
                            await refused.onDelivery?(.notDelivered(reason: reason))
                        }
                        await recordOutcome(.cancelled, detail: "Stopped at your request.")
                        emit(.finished(reason: "cancelled"))
                        return .cancelled
                    }
                    do {
                        let inputID = try await writer.appendUser(text)
                        await queuedInput.onDelivery?(.delivered(referenceID: inputID))
                    } catch {
                        let detail =
                            "Could not record steering input: \(error.localizedDescription)"
                        for refused in messagesToInject[index...] {
                            await refused.onDelivery?(.notDelivered(reason: detail))
                        }
                        await recordOutcome(.failed, detail: detail)
                        emit(.failed(detail))
                        return .failed(detail)
                    }
                    guard await requireJournal("the model call after steering delivery") else {
                        return .failed(journalFailureDetail!)
                    }
                    messages.append(.user(text))
                    emit(.steered(text))
                }
            }

            // Before the call, not after: compaction needs room to run, and discovering the
            // window is full at the moment of sending is discovering it too late.
            guard await requireJournal("model call") else {
                return .failed(journalFailureDetail!)
            }
            await compactIfNeeded()
            guard await requireJournal("model call") else {
                return .failed(journalFailureDetail!)
            }

            let turn: Turn
            do {
                turn = try await runTurn()
            } catch {
                if cancelled || Task.isCancelled {
                    _ = await appendJournalNote("Stopped at your request.")
                    await recordOutcome(.cancelled, detail: "Stopped at your request.")
                    emit(.finished(reason: "cancelled"))
                    return .cancelled
                }
                let detail = error.localizedDescription
                _ = await appendJournalNote("The model call failed: \(detail)")
                await recordOutcome(.failed, detail: detail)
                emit(.failed(detail))
                return .failed(detail)
            }

            // A provider can ignore task cancellation. Once it returns, honor the durable
            // cancellation flag before recording output or beginning any tool action.
            if cancelled || Task.isCancelled {
                _ = await appendJournalNote("Stopped at your request.")
                await recordOutcome(.cancelled, detail: "Stopped at your request.")
                emit(.finished(reason: "cancelled"))
                return .cancelled
            }

            let messageID: String
            do {
                if let nativeJournal, !turn.text.isEmpty {
                    _ = try await nativeJournal.commitAssistantMessage(turn.text)
                }
                messageID = try await writer.appendAssistant(
                    text: turn.text, thinking: turn.thinking, toolCalls: turn.toolCalls,
                    usage: turn.usage, stopReason: turn.stopReason)
            } catch {
                let detail = "Could not record the assistant message: \(error.localizedDescription)"
                await recordOutcome(.failed, detail: detail)
                emit(.failed(detail))
                return .failed(detail)
            }
            if let usage = turn.usage {
                totalUsage += usage
                if usage.input > 0 { lastInputTokens = usage.input + usage.cacheRead }
            }
            emit(.turnFinished(
                messageID: messageID, usage: turn.usage, stopReason: turn.stopReason))

            var assistantContent: [ChatContent] = []
            if !turn.text.isEmpty { assistantContent.append(.text(turn.text)) }
            for call in turn.toolCalls {
                assistantContent.append(
                    .toolCall(id: call.id, name: call.name, arguments: call.arguments))
            }
            messages.append(ChatMessage(role: .assistant, content: assistantContent))

            if turn.toolCalls.isEmpty {
                // Nothing more to do this turn — but a queued message means the run is not
                // actually over, so continue rather than making the caller start again.
                if !pendingSteering.isEmpty { continue }
                // Work the agent dispatched with .notify() and then stopped waiting for. It
                // asked to be told later, so finishing now would be finishing on a promise —
                // the first live test of this ended the run two seconds before the shell
                // command it had asked to hear about produced its answer.
                //
                // Waited for *before* the follow-up is taken, not after. The other order costs
                // a whole model call: the loop would re-ask with an unchanged conversation,
                // get the same answer, and only then notice the message waiting.
                _ = await waitForDispatchedWork()
                if cancelled || Task.isCancelled {
                    _ = await appendJournalNote("Stopped at your request.")
                    await recordOutcome(.cancelled, detail: "Stopped at your request.")
                    emit(.finished(reason: "cancelled"))
                    return .cancelled
                }
                if let next = pendingFollowUps.first {
                    pendingFollowUps.removeFirst()
                    do {
                        let inputID = try await writer.appendUser(next.text)
                        await next.onDelivery?(.delivered(referenceID: inputID))
                    } catch {
                        let detail =
                            "Could not record queued input: \(error.localizedDescription)"
                        await next.onDelivery?(.notDelivered(reason: detail))
                        await recordOutcome(.failed, detail: detail)
                        emit(.failed(detail))
                        return .failed(detail)
                    }
                    guard await requireJournal("the model call after follow-up delivery") else {
                        return .failed(journalFailureDetail!)
                    }
                    messages.append(.user(next.text))
                    emit(.steered(next.text))
                    continue
                }
                if !pendingSteering.isEmpty { continue }
                emit(.finished(reason: turn.stopReason ?? "stopped"))
                return .completed
            }

            for call in turn.toolCalls {
                if cancelled || Task.isCancelled {
                    _ = await appendJournalNote("Stopped before the next tool action.")
                    await recordOutcome(.cancelled, detail: "Stopped before the next tool action.")
                    emit(.finished(reason: "cancelled"))
                    return .cancelled
                }
                guard await requireJournal("tool \(call.name)") else {
                    return .failed(journalFailureDetail!)
                }
                emit(.toolStarted(id: call.id, name: call.name, arguments: call.arguments))
                let (output, isError) = await execute(call)
                do {
                    try await writer.appendToolResult(
                        id: call.id, name: call.name, text: output, isError: isError)
                } catch {
                    journalFailureDetail = "Could not record the tool result: \(error.localizedDescription)"
                    emit(.failed(journalFailureDetail!))
                    return .failed(journalFailureDetail!)
                }
                emit(.toolFinished(id: call.id, name: call.name, output: output, isError: isError))
                messages.append(ChatMessage(role: .tool, content: [
                    .toolResult(id: call.id, name: call.name, text: output, isError: isError),
                ]))
                guard await drainPendingImages() else {
                    return .failed(
                        journalFailureDetail ?? "An attached image could not be recorded.")
                }
            }
        }

        // Hitting the ceiling is a real outcome, not a silent stop: the transcript says so,
        // because a run that quietly stopped looks identical to one that finished.
            let note = "Stopped after \(config.maxIterations) model calls without finishing. "
                + "Raise maxIterations, or narrow the task."
            _ = await appendJournalNote(note)
            emit(.finished(reason: "iteration limit"))
            return .completed
        }
    }

    /// The most a single delivered message may add to a conversation.
    ///
    /// Generous enough for a test summary or a stack trace, far short of a log file.
    static let notifyLimit = 4000

    static func bounded(_ text: String) -> String {
        guard text.count > notifyLimit else { return text }
        let head = String(text.prefix(notifyLimit))
        return head + "\n\n[truncated by Aviary: \(text.count) characters in total]"
    }

    /// Hold the run open while work it asked to be told about is still going.
    ///
    /// Returns true when something arrived, so the loop can take it. Bounded, because a
    /// dispatched command that never ends must not turn a finished run into a hung one — and
    /// the bound is generous because the case this exists for is a test suite.
    private func waitForDispatchedWork() async -> Bool {
        guard dispatchedCount > 0 else { return false }
        emit(.awaitingDispatched(count: dispatchedCount))
        let deadline = Date().addingTimeInterval(config.dispatchedWorkTimeout)
        while Date() < deadline, !cancelled {
            if !pendingSteering.isEmpty || !pendingFollowUps.isEmpty { return true }
            if dispatchedCount == 0 { return !pendingFollowUps.isEmpty }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if dispatchedCount > 0 {
            _ = await appendJournalNote(
                "Stopped waiting for \(dispatchedCount) dispatched task(s) that had not "
                    + "reported back.")
        }
        return !pendingFollowUps.isEmpty || !pendingSteering.isEmpty
    }

    /// Move anything `attach_image` queued into the conversation.
    ///
    /// A user message rather than part of the tool result, because that is the one shape all
    /// three providers accept: Anthropic allows images inside a tool result, the OpenAI
    /// completions shape does not, and a capability that works on two routes out of three is
    /// worse than one that works everywhere.
    private func drainPendingImages() async -> Bool {
        guard !pendingImages.isEmpty else { return true }
        let queued = pendingImages
        pendingImages.removeAll()
        for (image, note) in queued {
            var content: [ChatContent] = []
            let caption = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            content.append(.text(caption.map { "\($0)\n\n" } ?? ""
                + "[\(image.path) — \(image.width)×\(image.height)]"))
            content.append(.image(mimeType: image.mimeType, base64: image.base64))
            messages.append(ChatMessage(role: .user, content: content))
            do {
                try await writer.appendImage(
                    mimeType: image.mimeType, base64: image.base64,
                    path: image.path, note: caption)
            } catch {
                journalFailureDetail = "Could not record an attached image: "
                    + error.localizedDescription
                emit(.failed(journalFailureDetail!))
                return false
            }
            emit(.imageAttached(path: image.path, width: image.width, height: image.height))
        }
        return true
    }

    // MARK: Compaction

    /// Summarise the middle of the conversation when it approaches the context window.
    ///
    /// Keeps the system prompt, the first user message (the task, which is what everything
    /// else is in service of) and the most recent exchanges verbatim; replaces the span
    /// between them with a summary. Nothing is lost from the *transcript* — the file keeps
    /// every entry and records a `compaction` marker — so the model forgets while the record
    /// does not, and a reader can still see what was dropped.
    private func compactIfNeeded() async {
        guard let window = config.model.contextWindow, window > 0 else { return }
        let threshold = Int(Double(window) * config.compactAtContextShare)
        guard lastInputTokens > threshold else { return }
        // Needs enough middle to be worth summarising: system + task + a few recent turns.
        guard messages.count > 8 else { return }

        let keepRecent = 4
        let head = messages.prefix(2)                       // system, first task
        let middle = messages.dropFirst(2).dropLast(keepRecent)
        let tail = messages.suffix(keepRecent)
        guard middle.count >= 2 else { return }

        let transcriptText = middle.map { message -> String in
            var line = "\(message.role.rawValue.uppercased()): \(message.plainText)"
            let calls = message.toolCalls
            if !calls.isEmpty {
                line += "\n  ran: " + calls.map { call in
                    (call.arguments["code"]?.stringValue ?? call.name)
                        .split(separator: "\n").first.map(String.init) ?? call.name
                }.joined(separator: "; ")
            }
            return line
        }.joined(separator: "\n\n")

        let ask = ChatRequest(
            model: config.model.id,
            messages: [
                .system("You compress an agent's working transcript so it can keep going. "
                    + "Write a dense factual summary: what was attempted, what was learned, "
                    + "what is established fact about this codebase, what failed and why, and "
                    + "what remains. Keep file paths, commands, identifiers and numbers "
                    + "exactly. Omit pleasantries and narration. No preamble."),
                .user("Summarise this span of work:\n\n"
                    + String(transcriptText.prefix(60_000))),
            ])

        var summary = ""
        let permit = await beginNativeAction(
            kind: .compactionProvider, intent: "Compact the conversation with the provider",
            target: config.model.qualifiedID)
        do { try requireNativePermit(permit, for: "compaction provider") }
        catch { return }
        do {
            for try await event in provider.stream(ask) {
                if case .textDelta(let t) = event { summary += t }
            }
        } catch {
            guard await finishNativeAction(
                permit, state: error is CancellationError ? .canceled : .failed,
                retrySafety: .unknown,
                failureKind: error is CancellationError ? .cancellation : .infrastructure) else {
                return
            }
            // A failed compaction must not end the run: the next model call may still fit,
            // and if it does not, the provider's own error is a clearer thing to show than a
            // summariser's.
            _ = await appendJournalNote(
                "Could not compact the conversation: \(error.localizedDescription)")
            return
        }
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            _ = await finishNativeAction(
                permit, state: .failed, retrySafety: .unsafe, failureKind: .task)
            return
        }
        guard await finishNativeAction(permit, state: .succeeded, retrySafety: .unsafe) else {
            return
        }

        let before = lastInputTokens
        if let nativeJournal {
            do {
                _ = try await nativeJournal.commitCompaction(
                    summary: summary, tokensBefore: before, droppedMessages: middle.count)
            } catch {
                latchNativeJournalFailure("the context compaction", error)
                return
            }
        }
        messages = Array(head)
            + [ChatMessage(role: .user, content: [.text(
                "[Earlier work, compacted]\n\n" + summary)])]
            + Array(tail)
        compactions += 1
        lastInputTokens = 0
        do {
            try await writer.appendCompaction(
                summary: summary, tokensBefore: before, droppedMessages: middle.count)
        } catch {
            journalFailureDetail = "Could not record the legacy compaction projection: "
                + error.localizedDescription
            emit(.compacted(before: before, after: messages.count, summary: summary))
            emit(.failed(journalFailureDetail!))
            return
        }
        emit(.compacted(before: before, after: messages.count, summary: summary))
    }

    // MARK: One turn

    private struct Turn {
        var text = ""
        var thinking = ""
        var toolCalls: [(id: String, name: String, arguments: JSONValue)] = []
        var usage: Usage?
        var stopReason: String?
    }

    private func runTurn() async throws -> Turn {
        var messagesForTurn = messages
        if let goal = config.goal, let first = messagesForTurn.first, first.role == .system {
            // Refreshed every turn rather than stated once: the remaining budget is the part
            // that changes, and a stale number is worse than none.
            messagesForTurn[0] = .system(
                first.plainText + "\n\n" + goal.briefing(spent: totalUsage.totalTokens))
        }
        let request = ChatRequest(
            model: config.model.id,
            messages: messagesForTurn,
            tools: activeTools,
            maxTokens: config.maxTokens,
            reasoningEffort: config.reasoningEffort)

        let permit = await beginNativeAction(
            kind: .provider, intent: "Request the next agent response",
            target: config.model.qualifiedID)
        try requireNativePermit(permit, for: "provider")
        var turn = Turn()
        var streamFailure: Error?
        do {
            for try await event in provider.stream(request) {
                switch event {
                case .textDelta(let t):
                    turn.text += t
                    emit(.textDelta(t))
                case .thinkingDelta(let t):
                    turn.thinking += t
                    emit(.thinkingDelta(t))
                case .toolCall(let id, let name, let arguments):
                    turn.toolCalls.append((id: id, name: name, arguments: arguments))
                case .requestBody(let payload):
                    record(payload)
                case .usage(let u):
                    // Priced here rather than at display time, so the transcript carries dollars
                    // and every screen that reads it agrees without re-deriving them.
                    turn.usage = config.model.priced(u)
                case .done(let reason):
                    turn.stopReason = reason
                }
            }
        } catch {
            streamFailure = error
        }
        if let streamFailure {
            let recorded = await finishNativeAction(
                permit, state: .indeterminateEffect,
                retrySafety: .unsafe, failureKind: .indeterminateEffect)
            guard recorded else {
                throw NativeJournalFailure(
                    detail: journalFailureDetail ?? "The provider outcome could not be recorded.")
            }
            throw streamFailure
        }
        guard await finishNativeAction(permit, state: .succeeded, retrySafety: .unsafe) else {
            throw NativeJournalFailure(
                detail: journalFailureDetail ?? "The provider outcome could not be recorded.")
        }
        return turn
    }

    /// Exposed for tests: dispatching a tool call is worth asserting directly, and driving a
    /// whole model round trip to reach it would test the fixture more than the dispatch.
    public func executeForTesting(
        id: String, name: String, arguments: JSONValue
    ) async -> (String, Bool) {
        await execute((id: id, name: name, arguments: arguments))
    }

    private func execute(
        _ call: (id: String, name: String, arguments: JSONValue)
    ) async -> (String, Bool) {
        guard await requireJournal("tool \(call.name)") else {
            return (journalFailureDetail ?? "The session journal is unavailable; stop this run.", true)
        }
        if call.name != "python" {
            if let entry = mcpTools[call.name] {
                let permit = await beginNativeAction(
                    kind: .mcp, intent: "Call an MCP tool", target: call.name,
                    metadata: ["server": .string(entry.tool.server)])
                do { try requireNativePermit(permit, for: "MCP tool") }
                catch { return (error.localizedDescription, true) }
                do {
                    let result = try await entry.client.callTool(
                        entry.tool.name, arguments: call.arguments)
                    var text = result.text
                    if !result.images.isEmpty {
                        if config.model.supportsImages {
                            // The same queue `attach_image` uses, drained by the loop right
                            // after this tool result — so a tool that answers with a
                            // screenshot answers with the screenshot, not with a note saying
                            // one existed.
                            for image in result.images {
                                pendingImages.append((image, "From \(call.name)."))
                            }
                            let plural = result.images.count == 1 ? "image" : "images"
                            text += (text.isEmpty ? "" : "\n")
                                + "[\(result.images.count) \(plural) attached below]"
                        } else {
                            // Degraded honestly rather than dropped: this model cannot see it,
                            // and an agent that thinks it has been shown something it has not
                            // will answer confidently about a picture it never received.
                            text += (text.isEmpty ? "" : "\n")
                                + "[\(result.images.count) image(s) returned, which "
                                + "\(config.model.id) cannot read]"
                        }
                    }
                    let recorded = await finishNativeAction(
                        permit, state: result.isError ? .failed : .succeeded,
                        retrySafety: .unknown,
                        failureKind: result.isError ? .task : nil)
                    guard recorded else {
                        return (journalFailureDetail ?? "The MCP outcome could not be recorded.", true)
                    }
                    return (text, result.isError)
                } catch {
                    let recorded = await finishNativeAction(
                        permit, state: .indeterminateEffect, retrySafety: .unsafe,
                        failureKind: .indeterminateEffect)
                    if !recorded {
                        return (journalFailureDetail ?? "The MCP outcome could not be recorded.", true)
                    }
                    return ("The \(entry.tool.server) MCP server failed: "
                        + error.localizedDescription, true)
                }
            }
            // Answered rather than thrown: a model inventing a tool name is a thing to tell
            // it about, not a reason to end the run.
            let available = (["python"] + mcpTools.keys.sorted()).joined(separator: ", ")
            return ("No tool named \(call.name). Available: \(available).", true)
        }
        guard var code = call.arguments["code"]?.stringValue, !code.isEmpty else {
            return ("The `python` tool needs a non-empty `code` argument.", true)
        }
        // A hook may block this call or rewrite it. Hooks mediate calls Aviary dispatches, but
        // they are not a security boundary: Python can perform file, process, socket, and
        // network effects directly. Aviary intentionally accepts that no-sandbox contract here.
        if hooksEnabled {
            let permit = await beginNativeAction(
                kind: .hook, intent: "Invoke the before-tool hook", target: hostSession,
                metadata: ["event": .string("before_tool")])
            do { try requireNativePermit(permit, for: "hook") }
            catch { return (error.localizedDescription, true) }
            let decision: JSONValue?
            do {
                decision = try await host.callHook("before_tool", payload: .object([
                    "name": .string(call.name),
                    "code": .string(code),
                    "session": .string(hostSession),
                ]))
            } catch {
                let recorded = await finishNativeAction(
                    permit, state: .indeterminateEffect, retrySafety: .unsafe,
                    failureKind: .indeterminateEffect)
                guard recorded else {
                    return (journalFailureDetail ?? "The hook outcome could not be recorded.", true)
                }
                return (
                    "The before-tool hook could not be reached; Python was not started: "
                        + error.localizedDescription,
                    true)
            }
            guard await finishNativeAction(
                permit, state: .succeeded, retrySafety: .unsafe) else {
                return (journalFailureDetail ?? "The hook outcome could not be recorded.", true)
            }
            if let decision {
                if decision["block"]?.boolValue == true {
                    let reason = decision["reason"]?.stringValue
                        ?? "A hook blocked this. Try a different approach."
                    guard await appendJournalNote(
                        "A hook blocked a tool call: \(reason)", customType: "aviary.hook") else {
                        return (journalFailureDetail ?? "The hook note could not be recorded.", true)
                    }
                    return (reason, true)
                }
                if let rewritten = decision["code"]?.stringValue, rewritten != code {
                    // Recorded, because a rewritten call that looks like the agent's own would
                    // make the transcript lie about what ran.
                    guard await appendJournalNote(
                        "A hook rewrote a tool call.", customType: "aviary.hook") else {
                        return (
                            journalFailureDetail ?? "The session journal is unavailable; stop this run.",
                            true)
                    }
                    code = rewritten
                }
            }
        }
        let permit = await beginNativeAction(
            kind: .python, intent: "Execute one Python cell", target: hostSession)
        do { try requireNativePermit(permit, for: "Python") }
        catch { return (error.localizedDescription, true) }
        do {
            let result = try await host.execute(code, in: hostSession)
            let recorded = await finishNativeAction(
                permit, state: result.failed ? .failed : .succeeded,
                retrySafety: .unsafe, failureKind: result.failed ? .task : nil)
            guard recorded else {
                return (journalFailureDetail ?? "The Python outcome could not be recorded.", true)
            }
            return (Self.render(result), result.failed)
        } catch {
            let recorded = await finishNativeAction(
                permit, state: .indeterminateEffect, retrySafety: .unsafe,
                failureKind: .indeterminateEffect)
            if !recorded {
                return (journalFailureDetail ?? "The Python outcome could not be recorded.", true)
            }
            return ("The runtime host could not run that: \(error.localizedDescription)", true)
        }
    }

    /// Turn an execution into what the model sees.
    ///
    /// Order matters: output first, then the echoed value, then the traceback last so the
    /// most actionable part is nearest the model's attention. Empty output says so explicitly,
    /// because a blank tool result reads as a broken tool.
    public static func render(_ result: RuntimeHost.ExecResult) -> String {
        var parts: [String] = []
        if !result.stdout.isEmpty { parts.append(result.stdout.trimmingTrailingNewlines()) }
        if !result.stderr.isEmpty {
            parts.append("stderr:\n" + result.stderr.trimmingTrailingNewlines())
        }
        if let value = result.value { parts.append(value) }
        if let exception = result.exception {
            parts.append(exception.trimmingTrailingNewlines())
        }
        if parts.isEmpty { return "(no output)" }
        return parts.joined(separator: "\n")
    }

    /// Append one payload to the wire log, in the shape `WireLog` already reads.
    private func record(_ payload: JSONValue) {
        guard let wireLogURL else { return }
        let record = JSONValue.object([
            "v": .number(1),
            "seq": .number(Double(recordedRequests)),
            "at": .string(SessionWriter.stamp()),
            "kind": .string("request"),
            "sessionFile": .string(writer.fileURL.path),
            "payload": payload,
        ])
        recordedRequests += 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(record) else { return }
        data.append(UInt8(ascii: "\n"))
        try? FileManager.default.createDirectory(
            at: wireLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: wireLogURL.path) {
            FileManager.default.createFile(atPath: wireLogURL.path, contents: nil)
        }
        // Best-effort, and silent on failure: diagnostics must never take down a run, and a
        // full disk should not produce one error per model call.
        guard let handle = try? FileHandle(forWritingTo: wireLogURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private var recordedRequests = 0

    private func emit(_ event: Event) {
        observer?(event)
    }
}

extension String {
    func trimmingTrailingNewlines() -> String {
        var s = self
        while s.hasSuffix("\n") || s.hasSuffix("\r") { s.removeLast() }
        return s
    }
}
