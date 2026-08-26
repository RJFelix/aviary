import Foundation

/// The functions the agent finds already in its Python namespace.
///
/// There is one *tool* — `python` — so everything else the runtime can do arrives as a name
/// already bound in the namespace. This file is the list of those names, and it is the only
/// place their prose lives.
///
/// It exists because the prose used to live twice: `Agent.tools` wrote it for an in-house run
/// and `ClaudeCodeKernel.description` wrote it again for a driven one, kept in step by a test
/// asserting the two strings were equal. That test was the tell. Two engines describing the
/// same kernel differently would make a transcript's meaning depend on which one wrote it, and
/// the honest fix is one source rendered twice rather than two sources compared.
///
/// The rule this list enforces, learned expensively: **a capability the model is not told about
/// does not exist.** `spawn()` was in the namespace and absent from the description, and a real
/// run spent twenty turns grepping the codebase for it before giving up — which reads as a
/// broken environment rather than a missing sentence. Adding a name to the runtime without
/// adding it here reproduces that bug exactly.
public enum Builtins {

    /// What has to be true for a builtin to be in the namespace at all.
    public enum Requirement: String, Sendable, Hashable, CaseIterable, Identifiable {
        /// In every session, on every engine.
        case always
        /// Only when the session has a memory store behind it.
        case memory
        /// Only when there is sub-agent depth left to spend.
        case spawn
        /// Only when the model on this run actually accepts images.
        case vision
        /// Only when there is another live run to talk to.
        case peers
        /// Only when a web search key is configured.
        case web

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .always: return "Always"
            case .memory: return "With memory"
            case .spawn: return "With sub-agents"
            case .vision: return "With a vision model"
            case .peers: return "With other live runs"
            case .web: return "With web access"
            }
        }

        public var explanation: String {
            switch self {
            case .always:
                return "Bound in every session, on both engines."
            case .memory:
                return "Bound when the run has a memory store — off for a session with "
                    + "nowhere to write."
            case .spawn:
                return "Bound only while sub-agent depth remains, and the remaining depth is "
                    + "written into the description so the model can see its own budget."
            case .vision:
                return "Bound only when the model's input modalities include images. Offering "
                    + "it to a text-only model would trade a provider error for a capability."
            case .peers:
                return "Bound only while another run is open beside this one. A solo session "
                    + "has nobody to message, and describing the names anyway would cost "
                    + "tokens on every request to advertise an empty room."
            case .web:
                return "Bound when PARALLEL_API_KEY is in the environment Aviary captured from "
                    + "your login shell. No key, no names — rather than a capability that "
                    + "exists right up until it is called."
            }
        }
    }

    /// Where the work actually happens, which decides what a call costs.
    public enum Mechanism: String, Sendable, Hashable {
        /// Runs inside the interpreter. No round trip.
        case kernel
        /// Marshalled out to Aviary and back, so the cell blocks until the app answers.
        case callback

        public var label: String {
            switch self {
            case .kernel: return "in-kernel"
            case .callback: return "calls back into Aviary"
            }
        }
    }

    public struct Entry: Sendable, Identifiable, Hashable {
        public var id: String { name }
        /// The bare name, as bound in the namespace.
        public var name: String
        /// The call shape, for a reader rather than the model.
        public var signature: String
        /// One line, for the Library list.
        public var summary: String
        /// The exact line the model is given, verbatim. Rendered with a two-space indent.
        public var bullet: String
        /// A paragraph rendered after this requirement group's bullets, if any.
        public var note: String?
        public var requirement: Requirement
        public var mechanism: Mechanism
        /// Whether this particular run actually has it.
        public var isAvailable: Bool

        public init(
            name: String, signature: String, summary: String, bullet: String,
            note: String? = nil, requirement: Requirement, mechanism: Mechanism,
            isAvailable: Bool
        ) {
            self.name = name
            self.signature = signature
            self.summary = summary
            self.bullet = bullet
            self.note = note
            self.requirement = requirement
            self.mechanism = mechanism
            self.isAvailable = isAvailable
        }
    }

    /// What a run can do, which decides both the namespace and the description.
    public struct Context: Sendable {
        public var cwd: String
        public var hasMemory: Bool
        public var canSpawn: Bool
        public var spawnBudget: Int
        public var supportsImages: Bool
        /// How many *other* runs Aviary is holding right now.
        public var peerCount: Int
        /// Whether a web search key is configured.
        public var hasWeb: Bool

        public init(
            cwd: String, hasMemory: Bool = false, canSpawn: Bool = false, spawnBudget: Int = 0,
            supportsImages: Bool = false, peerCount: Int = 0, hasWeb: Bool = false
        ) {
            self.hasWeb = hasWeb
            self.cwd = cwd
            self.hasMemory = hasMemory
            self.canSpawn = canSpawn
            self.spawnBudget = spawnBudget
            self.supportsImages = supportsImages
            self.peerCount = peerCount
        }

        /// Everything switched on, for a reader who wants to see the whole shelf rather than
        /// one run's slice of it.
        public static let reference = Context(
            cwd: "<the session's working directory>", hasMemory: true, canSpawn: true,
            spawnBudget: 1, supportsImages: true, peerCount: 1, hasWeb: true)
    }

    /// Every builtin, in description order, each marked with whether this run has it.
    public static func all(_ ctx: Context) -> [Entry] {
        [
            Entry(
                name: "sh",
                signature: "sh(command)",
                summary: "Run a shell command whose working directory and environment persist.",
                bullet: "sh(command)  – run a shell command. Returns a Future: .result() is "
                    + "{'stdout', 'stderr', 'status'}. The working directory and environment "
                    + "persist across calls, so `sh('cd subdir').result()` then "
                    + "`sh('pwd').result()` does what you expect.",
                requirement: .always, mechanism: .kernel, isAvailable: true),
            Entry(
                name: "cwd",
                signature: "cwd()",
                summary: "Where the shell currently is.",
                bullet: "cwd()        – the current working directory.",
                note: "Anything that can take a while — sh(), spawn(), search(), read_url() — "
                    + "returns a Future, so you choose. Call .result() to wait. Start several "
                    + "and collect them if they are independent. Or call .notify() on one and "
                    + "stop: its result is sent to you as a message when it finishes, even if "
                    + "this turn has ended, which is how to run a long test suite without "
                    + "sitting and watching it.",
                requirement: .always, mechanism: .kernel, isAvailable: true),
            Entry(
                name: "conversation",
                signature: "conversation(limit=40)",
                summary: "The transcript this code is part of, as data.",
                bullet: "conversation(limit=40) – this conversation so far, as a list of "
                    + "{'role', 'text', 'toolCalls'}. Use it to check what you already tried "
                    + "instead of re-deriving it.",
                requirement: .always, mechanism: .callback, isAvailable: true),
            Entry(
                name: "artifact",
                signature: "artifact(text, title=None, format='md')",
                summary: "Write a report or document to a file instead of into the reply.",
                bullet: "artifact(text, title=None, format='md') – write a document into this "
                    + "session's artifacts directory. Formats: 'md', 'txt', 'html'. Returns "
                    + "{'id', 'title', 'format', 'path', 'bytes'}, or a dict with an 'error' "
                    + "key. Titles are slugified into filenames and never overwrite an "
                    + "earlier artifact.",
                note: "When you are asked for a report, a plan, a design doc or any other "
                    + "extended piece of writing, write it with artifact() and keep your reply "
                    + "to what it says, what it concludes and where it is. Several thousand "
                    + "words pasted into the transcript is a document nobody can open, edit or "
                    + "send on, and it is re-read into context on every turn after it.",
                requirement: .always, mechanism: .callback, isAvailable: true),
            Entry(
                name: "remember",
                signature: "remember(text, scope='project', days=None, tags=[])",
                summary: "Record something worth having next time.",
                bullet: "remember(text, scope='project', days=None, tags=[]) – record "
                    + "something you will want next time. Scopes: 'session' (this task only), "
                    + "'project' (about this codebase — the usual choice), 'global' (true "
                    + "everywhere — rare). Pass `days` unless it will be true indefinitely.",
                requirement: .memory, mechanism: .callback, isAvailable: ctx.hasMemory),
            Entry(
                name: "recall",
                signature: "recall(query)",
                summary: "Search what earlier sessions recorded.",
                bullet: "recall(query) – search what you recorded before.",
                note: "Record what cost you effort to discover and would cost the same again: "
                    + "a non-obvious command, a constraint the code does not state, a dead end "
                    + "worth not repeating. Not things the repository already says clearly.",
                requirement: .memory, mechanism: .callback, isAvailable: ctx.hasMemory),
            Entry(
                name: "spawn",
                signature: "spawn(prompt, name=None, model=None)",
                summary: "Start a sub-agent. Returns a Future you may choose to await.",
                bullet: "spawn(prompt, name=None) – start a sub-agent and get back a "
                    + "`concurrent.futures.Future` immediately. It does not block: call "
                    + ".result() when you want its answer, .done() to look without waiting, "
                    + "or concurrent.futures.wait()/as_completed() over several. You may nest "
                    + "\(ctx.spawnBudget) more level(s).",
                note: "A sub-agent starts with none of your context and returns only its final "
                    + "message, so the prompt must be self-contained and must say what to "
                    + "report back. Delegate genuinely separable work; doing it yourself is "
                    + "usually cheaper.\n\nBecause it is a Future and not a blocking call, "
                    + "you decide the shape: `spawn(a).result()` to wait for one, or start "
                    + "several and collect them, or start one and keep working while it runs. "
                    + "The Futures live in your namespace, so one started in an earlier cell "
                    + "is still there in this one. Wait inside a single cell rather than across "
                    + "turns — waiting in a cell costs seconds, waiting across turns costs a "
                    + "model call each time.",
                requirement: .spawn, mechanism: .callback, isAvailable: ctx.canSpawn),
            Entry(
                name: "attach_image",
                signature: "attach_image(path, note=None)",
                summary: "Put an image on screen for yourself — a screenshot, a chart, a scan.",
                bullet: "attach_image(path, note=None) – look at an image file. It is added to "
                    + "the conversation as something you can actually see, not described to "
                    + "you. Returns {'path', 'width', 'height', 'bytes'}, or a dict with an "
                    + "'error' key. Large images are scaled down before they are sent.",
                note: "Use it when the answer is in a picture — a screenshot of a failing UI, "
                    + "a chart you just plotted, a scanned page. An image costs roughly as "
                    + "much as a page of text, so attach the one that decides the question "
                    + "rather than everything you have.",
                requirement: .vision, mechanism: .callback, isAvailable: ctx.supportsImages),
            Entry(
                name: "search",
                signature: "search(objective, queries=None, mode='fast', n=10)",
                summary: "Search the web. Returns a Future of ranked page excerpts.",
                bullet: "search(objective, queries=None) – search the web. Returns a Future "
                    + "like spawn(); .result() is a list of {'url', 'title', 'excerpts'}. "
                    + "`objective` is what you want to find out, in a sentence.",
                requirement: .web, mechanism: .callback, isAvailable: ctx.hasWeb),
            Entry(
                name: "read_url",
                signature: "read_url(urls, objective=None, full=False)",
                summary: "Pull the relevant part of pages you already have URLs for.",
                bullet: "read_url(urls, objective=None, full=False) – read pages you have the "
                    + "URLs of, PDFs and JS-rendered ones included. Future of "
                    + "{'url', 'title', 'excerpts'} per URL, or {'url', 'error'}.",
                note: "Search when you do not know the page, read_url when you do. Both are "
                    + "Futures, so start several and collect them rather than waiting for "
                    + "each. An `objective` returns only the relevant part; full=True spends "
                    + "context on the rest of the page.",
                requirement: .web, mechanism: .callback, isAvailable: ctx.hasWeb),
            Entry(
                name: "agents",
                signature: "agents()",
                summary: "The other runs open beside this one.",
                bullet: "agents() – the other runs open in Aviary right now, as a list of "
                    + "{'session', 'title', 'model', 'working', 'engine'}. Yours is not in it.",
                requirement: .peers, mechanism: .callback, isAvailable: ctx.peerCount > 0),
            Entry(
                name: "message",
                signature: "message(to, text)",
                summary: "Send a message to another run, delivered at its next turn boundary.",
                bullet: "message(to, text) – send text to another run. `to` is a 'session' "
                    + "from agents(), or a title that matches exactly one of them. Returns "
                    + "{'delivered': True, 'session': …}, or a dict with an 'error' key.",
                note: "It arrives in the other run as if a person had typed it, at that run's "
                    + "next turn boundary — never mid-turn, because a message injected between "
                    + "a tool call and its result makes a conversation its provider will "
                    + "reject. So it is a note to a colleague, not a function call: say who "
                    + "you are and what you want, because nothing else tells them.",
                requirement: .peers, mechanism: .callback, isAvailable: ctx.peerCount > 0),
        ]
    }

    /// The tool description, which must describe *everything* the runtime can do.
    ///
    /// Rendered rather than written, so a builtin cannot be added to the namespace and left
    /// out of the sentence that makes it real.
    public static func description(_ ctx: Context) -> String {
        let available = all(ctx).filter(\.isAvailable)
        var text = """
            Run Python in a persistent interpreter. Variables, imports and open handles \
            survive between calls, so build up state instead of repeating work.

            Available without importing anything:
            """
        for requirement in Requirement.allCases {
            let group = available.filter { $0.requirement == requirement }
            guard !group.isEmpty else { continue }
            // The first group runs straight on from the "Available without importing" line;
            // later ones are their own paragraph.
            text += requirement == .always ? "\n" : "\n\n"
            text += group.map { "  " + $0.bullet }.joined(separator: "\n")
            if let note = group.compactMap(\.note).last {
                text += "\n\n" + note
            }
        }
        text += """


            The value of a trailing expression is echoed back, so ending a cell with a bare \
            name shows it. Starting directory: \(ctx.cwd)
            """
        return text
    }

    /// The names bound in the namespace for this run — what the kernel must actually provide.
    public static func names(_ ctx: Context) -> [String] {
        all(ctx).filter(\.isAvailable).map(\.name)
    }
}
