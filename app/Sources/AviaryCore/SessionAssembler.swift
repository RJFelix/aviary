import Foundation

/// The explicit seam between a Session journal and its attached Work journal.
///
/// Assembly never merges the journals by wall-clock order. The caller supplies the attachment
/// cursor it observed, so a GUI can render a stable session prefix while Work continues remotely.
public struct SessionAssembly: Codable, Hashable, Sendable {
    public let session: SessionSnapshot
    public let worksByAttachmentID: [String: WorkSnapshot]
    public let attachmentCursors: [String: JournalCursor]
    /// The attention a client should act on after combining Session-authored attention with
    /// attached Work state.  Work actions with an indeterminate external effect take
    /// precedence over an authored Session attention because completion/retry is unsafe until
    /// a human resolves the effect.  Keeping this on the assembly makes the rule available to
    /// every reader of the linked journals, rather than only to a diagnostic projection.
    public var effectiveAttention: SessionAttention {
        worksByAttachmentID.values.contains {
            $0.actions.values.contains { $0.state == .indeterminateEffect }
        } ? .error : session.attention
    }

    public init(
        session: SessionSnapshot,
        worksByAttachmentID: [String: WorkSnapshot],
        attachmentCursors: [String: JournalCursor] = [:]
    ) {
        self.session = session
        self.worksByAttachmentID = worksByAttachmentID
        self.attachmentCursors = attachmentCursors
    }
}

public enum SessionAssembler {
    /// Returns nil when the supplied cursor does not point into the attached Work journal.
    public static func assemble(
        session: SessionSnapshot,
        works: [WorkSnapshot],
        at cursors: [String: JournalCursor] = [:]
    ) -> SessionAssembly? {
        var selected: [String: WorkSnapshot] = [:]
        var resolvedCursors: [String: JournalCursor] = [:]
        for attachment in session.attachments.values where attachment.isAttached {
            guard let work = works.first(where: { $0.work == attachment.work }) else { return nil }
            guard let cursor = cursors[attachment.attachment.attachmentID] ?? attachment.cursor else { return nil }
            guard cursor.journal == work.journal,
                  cursor.sequence == work.lastSequence,
                  cursor.eventID == work.lastEventID
            else { return nil }
            selected[attachment.attachment.attachmentID] = work
            resolvedCursors[attachment.attachment.attachmentID] = cursor
        }
        return SessionAssembly(session: session, worksByAttachmentID: selected,
                               attachmentCursors: resolvedCursors)
    }

    /// Convenience for the initial one-Work UI while callers migrate to the N-Work API.
    public static func assemble(
        session: SessionSnapshot,
        work: WorkSnapshot,
        at cursor: JournalCursor
    ) -> SessionAssembly? {
        guard let attachmentID = session.attachments.values.first(where: {
            $0.isAttached && $0.work == work.work
        })?.attachment.attachmentID else { return nil }
        return assemble(session: session, works: [work], at: [attachmentID: cursor])
    }
}
