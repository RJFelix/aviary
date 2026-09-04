import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The metadata-only durable projection of one producer-side system-prompt source.
///
/// This is deliberately separate from ``PromptSource``: the latter owns in-memory source
/// bodies, while this value is safe to put in a journal or manifest.  A source identity is
/// stable across content changes; the digests identify the bytes observed for this inclusion.
public struct ContextManifestSource: Codable, Hashable, Sendable {
    public let sourceID: String
    public let inclusionID: String
    public let kind: PromptSourceKind
    public let status: PromptSourceStatus
    public let label: String
    public let fullByteCount: Int?
    public let fullDigest: String?
    public let deliveredByteCount: Int
    public let deliveredDigest: String
    public let deliveredByteOffsetInRendered: Int
    public let renderedByteCount: Int
    public let renderedDigest: String
    public let fullBodyReference: TimelineBodyReference?
    public let deliveredBodyReference: TimelineBodyReference?
    public let renderedBodyReference: TimelineBodyReference?
    public let provenance: EventRef?

    public var fullBodyRef: TimelineBodyReference? { fullBodyReference }
    public var deliveredBodyRef: TimelineBodyReference? { deliveredBodyReference }
    public var renderedBodyRef: TimelineBodyReference? { renderedBodyReference }

    public init(
        sourceID: String,
        inclusionID: String,
        kind: PromptSourceKind,
        status: PromptSourceStatus,
        label: String,
        fullByteCount: Int? = nil,
        fullDigest: String? = nil,
        deliveredByteCount: Int,
        deliveredDigest: String,
        deliveredByteOffsetInRendered: Int = 0,
        renderedByteCount: Int,
        renderedDigest: String,
        fullBodyReference: TimelineBodyReference? = nil,
        deliveredBodyReference: TimelineBodyReference? = nil,
        renderedBodyReference: TimelineBodyReference? = nil,
        provenance: EventRef? = nil
    ) {
        self.sourceID = sourceID
        self.inclusionID = inclusionID
        self.kind = kind
        self.status = status
        self.label = label
        self.fullByteCount = fullByteCount
        self.fullDigest = fullDigest
        self.deliveredByteCount = deliveredByteCount
        self.deliveredDigest = deliveredDigest
        self.deliveredByteOffsetInRendered = deliveredByteOffsetInRendered
        self.renderedByteCount = renderedByteCount
        self.renderedDigest = renderedDigest
        self.fullBodyReference = fullBodyReference
        self.deliveredBodyReference = deliveredBodyReference
        self.renderedBodyReference = renderedBodyReference
        self.provenance = provenance
    }

    /// Adapt an in-memory source without serializing any body. Delivered source content and its
    /// exact rendered prompt slice remain separate when the producer added framing.
    public init(
        source: PromptSource,
        inclusionID: String,
        fullBodyReference: TimelineBodyReference? = nil,
        deliveredBodyReference: TimelineBodyReference? = nil,
        renderedBodyReference: TimelineBodyReference? = nil,
        provenance: EventRef? = nil
    ) {
        self.init(
            sourceID: source.sourceID, inclusionID: inclusionID, kind: source.kind,
            status: source.status, label: source.label, fullByteCount: source.fullByteCount,
            fullDigest: source.fullDigest, deliveredByteCount: source.deliveredByteCount,
            deliveredDigest: source.deliveredDigest,
            deliveredByteOffsetInRendered: source.deliveredByteOffsetInRendered,
            renderedByteCount: source.renderedByteCount,
            renderedDigest: source.renderedDigest, fullBodyReference: fullBodyReference,
            deliveredBodyReference: deliveredBodyReference,
            renderedBodyReference: renderedBodyReference, provenance: provenance)
    }

    public func withProvenance(_ provenance: EventRef?) -> ContextManifestSource {
        ContextManifestSource(
            sourceID: sourceID, inclusionID: inclusionID, kind: kind, status: status,
            label: label, fullByteCount: fullByteCount, fullDigest: fullDigest,
            deliveredByteCount: deliveredByteCount, deliveredDigest: deliveredDigest,
            deliveredByteOffsetInRendered: deliveredByteOffsetInRendered,
            renderedByteCount: renderedByteCount, renderedDigest: renderedDigest,
            fullBodyReference: fullBodyReference, deliveredBodyReference: deliveredBodyReference,
            renderedBodyReference: renderedBodyReference, provenance: provenance)
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case inclusionID = "inclusion_id"
        case kind, status, label
        case fullByteCount = "full_byte_count"
        case fullDigest = "full_digest"
        case deliveredByteCount = "delivered_byte_count"
        case deliveredDigest = "delivered_digest"
        case deliveredByteOffsetInRendered = "delivered_byte_offset_in_rendered"
        case renderedByteCount = "rendered_byte_count"
        case renderedDigest = "rendered_digest"
        case fullBodyReference = "full_body_ref"
        case deliveredBodyReference = "delivered_body_ref"
        case renderedBodyReference = "rendered_body_ref"
        case provenance
    }
}

/// Compatibility spelling for callers that describe these as prompt records.
public typealias ContextPromptSource = ContextManifestSource

/// A bounded account of one request's model-visible context.
///
/// The manifest is deliberately metadata-only. It never stores message text, tool arguments,
/// image data, or Python values. A component may point at a separately retained body through a
/// device-independent ``TimelineBodyReference``; when no such address is known, the digest and
/// measured size still make the crossing observable without pretending that an address exists.
public struct ContextManifest: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let measurementBasis = "aviary_chat_request_component_json_v2"

    public let schemaVersion: Int
    public let manifestID: String
    public let requestID: String
    public let modelID: String
    /// Sizes measure Aviary's stable semantic ChatRequest component encoding, not a
    /// provider-specific HTTP envelope. Authentication and transport headers are never inputs.
    public let measuredBy: String
    public let components: [ContextComponent]
    public let omissions: [ContextManifestOmission]
    public let measuredBytes: Int
    public let deliveredBytes: Int
    public let cumulativeDeliveredBytes: Int
    /// Optional producer-side decomposition of the pinned system prompt. It is auxiliary to
    /// ``components`` and therefore contributes nothing to any measured or cumulative total.
    public let systemPromptAssemblyID: String?
    public let systemPromptSources: [ContextManifestSource]?

    /// Compatibility aliases used by consumers that call this a prompt assembly.
    public var promptAssemblyID: String? { systemPromptAssemblyID }
    public var promptSources: [ContextManifestSource]? { systemPromptSources }

    public init(
        schemaVersion: Int = ContextManifest.currentSchemaVersion,
        manifestID: String,
        requestID: String,
        modelID: String,
        measuredBy: String = ContextManifest.measurementBasis,
        components: [ContextComponent],
        omissions: [ContextManifestOmission] = [],
        cumulativeDeliveredBytes: Int? = nil,
        systemPromptAssemblyID: String? = nil,
        systemPromptSources: [ContextManifestSource]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.manifestID = manifestID
        self.requestID = requestID
        self.modelID = modelID
        self.measuredBy = measuredBy
        self.components = components
        self.omissions = omissions
        measuredBytes = Self.checkedSum(components.compactMap(\.measuredBytes)) ?? -1
        deliveredBytes = Self.checkedSum(components.compactMap(\.deliveredBytes)) ?? -1
        self.cumulativeDeliveredBytes = cumulativeDeliveredBytes
            ?? deliveredBytes
        self.systemPromptAssemblyID = systemPromptAssemblyID
        self.systemPromptSources = systemPromptSources
    }

    /// Build a manifest for the request shape Aviary owns. `sourceRefs` and `bodyReferences`
    /// are optional because resumed legacy history does not always carry event identities. A
    /// caller that has them should provide both: that is what makes a body addressable across
    /// hosts rather than merely measured here.
    public static func build(
        request: ChatRequest,
        manifestID: String,
        requestID: String,
        sourceRefs: [Int: ContextSourceRef] = [:],
        bodyReferences: [String: TimelineBodyReference] = [:],
        priorDeliveredBytes: Int = 0
    ) throws -> ContextManifest {
        var components: [ContextComponent] = []
        var omissions: [ContextManifestOmission] = []

        for (index, message) in request.messages.enumerated() {
            let fullData = try canonicalBytes(for: message)
            let deliveredData = try canonicalBytes(for: message, includeThinking: false)
            let fullByteCount = fullData.count
            let deliveredByteCount = deliveredData.count
            let digest = digest(fullData)
            // A digest-derived fallback is stable when the same source is included in many
            // requests. Producers with a durable event identity should still provide sourceRefs.
            let source = sourceRefs[index]
                ?? ContextSourceRef(sourceID: "message:\(digest)")
            let mode: ContextComponentMode = message.role == .system ? .pinned : .history
            let deliveryMode: ContextDeliveryMode = deliveredByteCount == fullByteCount
                ? .full : .truncated
            let componentID = "context-component:\(digest)"
            let inclusionID = "\(manifestID):message:\(index)"
            // Do not carry a caller's stale locator into the journal. A locator is useful only
            // when its measured identity agrees with this inclusion's retained body.
            let bodyReference = bodyReferences[source.sourceID].flatMap { reference -> TimelineBodyReference? in
                guard reference.byteCount == fullByteCount, reference.digest == digest else { return nil }
                return reference
            }
            components.append(ContextComponent(
                componentID: componentID,
                inclusionID: inclusionID,
                sourceID: source.sourceID,
                sourceProvenance: source.provenance,
                mode: mode,
                deliveryMode: deliveryMode,
                measuredBytes: fullByteCount,
                includedBytes: deliveredByteCount,
                deliveredBytes: deliveredByteCount,
                fullByteCount: fullByteCount,
                bodyReference: bodyReference,
                digest: digest,
                tokenCount: nil,
                tokenizer: nil,
                omitted: false))

            if bodyReferences[source.sourceID] != nil && bodyReference == nil {
                omissions.append(ContextManifestOmission(
                    omissionID: "\(inclusionID):body-reference",
                    sourceID: source.sourceID,
                    reason: "retained_body_metadata_mismatch"))
            }

            if message.content.contains(where: { if case .thinking = $0 { return true }; return false }) {
                omissions.append(ContextManifestOmission(
                    omissionID: "\(inclusionID):thinking",
                    sourceID: source.sourceID,
                    reason: "provider_does_not_accept_replayed_reasoning",
                    measuredBytes: fullByteCount - deliveredByteCount))
            }
        }

        // Tool schemas are part of the request context even though they are not ChatMessages.
        // Keep only their measured size and digest; the schema itself can contain descriptions
        // copied from user files or integrations and must not be duplicated into the journal.
        if !request.tools.isEmpty {
            let bytes = try toolsData(for: request.tools)
            let digest = digest(bytes)
            let source = ContextSourceRef(sourceID: "tools:\(digest)")
            let bodyReference = bodyReferences[source.sourceID].flatMap { reference -> TimelineBodyReference? in
                guard reference.byteCount == bytes.count, reference.digest == digest else { return nil }
                return reference
            }
            components.append(ContextComponent(
                componentID: "context-component:\(digest)",
                inclusionID: "\(manifestID):tools",
                sourceID: source.sourceID,
                mode: .instruction,
                deliveryMode: .full,
                measuredBytes: bytes.count,
                includedBytes: bytes.count,
                deliveredBytes: bytes.count,
                fullByteCount: bytes.count,
                bodyReference: bodyReference,
                digest: digest,
                tokenCount: nil,
                tokenizer: nil,
                omitted: false))
            if bodyReferences[source.sourceID] != nil && bodyReference == nil {
                omissions.append(ContextManifestOmission(
                    omissionID: "\(manifestID):tools:body-reference",
                    sourceID: source.sourceID,
                    reason: "retained_body_metadata_mismatch"))
            }
        }

        let deliveredBytes = checkedSum(components.compactMap(\.deliveredBytes)) ?? -1
        let cumulative = priorDeliveredBytes.addingReportingOverflow(deliveredBytes)
        return ContextManifest(
            manifestID: manifestID,
            requestID: requestID,
            modelID: request.model,
            components: components,
            omissions: omissions,
            cumulativeDeliveredBytes:
                deliveredBytes < 0 || priorDeliveredBytes < 0 || cumulative.overflow
                    ? -1 : cumulative.partialValue)
    }

    static func bodyData(for message: ChatMessage, includeThinking: Bool = true) throws -> Data {
        try canonicalBytes(for: message, includeThinking: includeThinking)
    }

    static func toolsData(for tools: [ChatTool]) throws -> Data {
        try canonicalJSONData(.array(tools.map { tool in
            .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": tool.parameters,
            ])
        }))
    }

    private static func canonicalBytes(
        for message: ChatMessage, includeThinking: Bool = true
    ) throws -> Data {
        let content: [JSONValue] = message.content.compactMap { content in
            switch content {
            case .text(let text):
                return .object(["type": "text", "text": .string(text)])
            case .thinking(let text):
                return includeThinking
                    ? .object(["type": "thinking", "text": .string(text)]) : nil
            case .toolCall(let id, let name, let arguments):
                return .object([
                    "type": "tool_call", "id": .string(id), "name": .string(name),
                    "arguments": arguments,
                ])
            case .toolResult(let id, let name, let text, let isError):
                return .object([
                    "type": "tool_result", "id": .string(id), "name": .string(name),
                    "text": .string(text), "is_error": .bool(isError),
                ])
            case .image(let mimeType, let base64):
                return .object([
                    "type": "image", "mime_type": .string(mimeType),
                    "base64": .string(base64),
                ])
            }
        }
        return try canonicalJSONData(.object([
            "role": .string(message.role.rawValue), "content": .array(content),
        ]))
    }

    private static func canonicalJSONData(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Propagate invalid values such as NaN and infinity. A sentinel would give distinct
        // malformed request components the same durable identity and could authorize an effect
        // for a body that was never actually represented.
        return try encoder.encode(value)
    }

    private static func digest(_ data: Data) -> String {
        "sha256:" + AviarySHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Apply the same semantic contract at the live writer and cold reducer boundaries.
    /// Body bytes are verified separately by ``ContextBodyStore`` because reducers must remain
    /// pure and usable on devices that do not host the retained content.
    public func validate(
        authority: JournalRef,
        previousCumulativeDeliveredBytes: Int?,
        requireRetainedBodies: Bool = true
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ContextManifestValidationError.unsupportedSchema(schemaVersion)
        }
        guard measuredBy == Self.measurementBasis else {
            throw ContextManifestValidationError.unsupportedMeasurementBasis(measuredBy)
        }
        guard Self.isPresent(manifestID), Self.isPresent(requestID), Self.isPresent(modelID) else {
            throw ContextManifestValidationError.invalidIdentity
        }
        try validatePromptSources(authority: authority, requireRetainedBodies: requireRetainedBodies)
        guard !components.isEmpty else {
            throw ContextManifestValidationError.emptyComponents
        }
        guard Set(components.map(\.inclusionID)).count == components.count else {
            throw ContextManifestValidationError.duplicateInclusionIdentity
        }

        var recomputedMeasured = 0
        var recomputedDelivered = 0
        for component in components {
            guard Self.isPresent(component.componentID),
                  Self.isPresent(component.inclusionID),
                  Self.isPresent(component.sourceID),
                  let measured = component.measuredBytes,
                  let included = component.includedBytes,
                  let delivered = component.deliveredBytes,
                  let full = component.fullByteCount,
                  measured >= 0, included >= 0, delivered >= 0, full >= 0,
                  measured == full, included == delivered, delivered <= full,
                  !component.omitted else {
                throw ContextManifestValidationError.invalidComponent(component.inclusionID)
            }
            switch component.deliveryMode {
            case .full:
                guard delivered == full else {
                    throw ContextManifestValidationError.invalidComponent(component.inclusionID)
                }
            case .truncated:
                guard delivered < full else {
                    throw ContextManifestValidationError.invalidComponent(component.inclusionID)
                }
            case .summary, .manifest:
                break
            }
            if let tokenCount = component.tokenCount {
                guard tokenCount >= 0, component.tokenizer.map(Self.isPresent) == true else {
                    throw ContextManifestValidationError.invalidComponent(component.inclusionID)
                }
            } else if component.tokenizer != nil {
                throw ContextManifestValidationError.invalidComponent(component.inclusionID)
            }
            if requireRetainedBodies {
                guard let body = component.bodyReference,
                      let digest = component.digest,
                      body.authority == authority,
                      body.referenceID == digest,
                      body.digest == digest,
                      body.byteCount == full,
                      ContextBodyStore.isValidDigest(digest) else {
                    throw ContextManifestValidationError.invalidBodyReference(component.inclusionID)
                }
            }
            let measuredSum = recomputedMeasured.addingReportingOverflow(measured)
            let deliveredSum = recomputedDelivered.addingReportingOverflow(delivered)
            guard !measuredSum.overflow, !deliveredSum.overflow else {
                throw ContextManifestValidationError.measurementOverflow
            }
            recomputedMeasured = measuredSum.partialValue
            recomputedDelivered = deliveredSum.partialValue
        }
        guard recomputedMeasured == measuredBytes, recomputedDelivered == deliveredBytes else {
            throw ContextManifestValidationError.inconsistentTotals
        }

        guard Set(omissions.map(\.omissionID)).count == omissions.count,
              omissions.allSatisfy({
                  Self.isPresent($0.omissionID) && Self.isPresent($0.sourceID)
                      && Self.isPresent($0.reason) && ($0.measuredBytes.map { $0 >= 0 } ?? true)
              }) else {
            throw ContextManifestValidationError.invalidOmission
        }
        let prior = previousCumulativeDeliveredBytes ?? 0
        guard prior >= 0, cumulativeDeliveredBytes >= 0 else {
            throw ContextManifestValidationError.invalidCumulativeMeasurement(
                expected: prior, actual: cumulativeDeliveredBytes)
        }
        let expected = prior.addingReportingOverflow(deliveredBytes)
        guard !expected.overflow, cumulativeDeliveredBytes == expected.partialValue else {
            throw ContextManifestValidationError.invalidCumulativeMeasurement(
                expected: expected.partialValue, actual: cumulativeDeliveredBytes)
        }
    }

    /// Validate the optional source projection independently of message components. Source
    /// metadata is bounded and journal-authoritative, but it is never folded into context
    /// measurement totals (which remain the canonical ChatRequest component accounting).
    public func validatePromptSources(
        authority: JournalRef, requireRetainedBodies: Bool = false
    ) throws {
        guard let sources = systemPromptSources else {
            guard systemPromptAssemblyID == nil else {
                throw ContextManifestValidationError.invalidPromptSourceAssembly
            }
            return
        }
        guard !sources.isEmpty else {
            throw ContextManifestValidationError.invalidPromptSourceAssembly
        }
        guard sources.count <= 32 else {
            throw ContextManifestValidationError.tooManyPromptSources
        }
        guard Self.isBoundedIdentity(systemPromptAssemblyID ?? ""),
              ContextBodyStore.isValidDigest(systemPromptAssemblyID ?? "") else {
            throw ContextManifestValidationError.invalidPromptSourceAssembly
        }
        guard Set(sources.map(\.sourceID)).count == sources.count,
              Set(sources.map(\.inclusionID)).count == sources.count else {
            throw ContextManifestValidationError.duplicatePromptSourceIdentity
        }

        var totalRenderedBytes = 0
        for source in sources {
            guard Self.isBoundedIdentity(source.sourceID),
                  Self.isBoundedIdentity(source.inclusionID),
                  Self.isPresent(source.label), Data(source.label.utf8).count <= 256,
                  source.deliveredByteCount >= 0,
                  source.deliveredByteOffsetInRendered >= 0,
                  source.renderedByteCount >= 0,
                  ContextBodyStore.isValidDigest(source.deliveredDigest),
                  ContextBodyStore.isValidDigest(source.renderedDigest) else {
                throw ContextManifestValidationError.invalidPromptSource(source.sourceID)
            }
            if let fullByteCount = source.fullByteCount {
                guard fullByteCount >= 0,
                      let fullDigest = source.fullDigest,
                      ContextBodyStore.isValidDigest(fullDigest),
                      source.deliveredByteCount <= fullByteCount else {
                    throw ContextManifestValidationError.invalidPromptSource(source.sourceID)
                }
                switch source.status {
                case .present:
                    guard source.deliveredByteCount == fullByteCount,
                          source.deliveredDigest == fullDigest else {
                        throw ContextManifestValidationError.invalidPromptSource(source.sourceID)
                    }
                case .truncated:
                    guard source.deliveredByteCount < fullByteCount else {
                        throw ContextManifestValidationError.invalidPromptSource(source.sourceID)
                    }
                case .missing, .unreadable, .disabled:
                    throw ContextManifestValidationError.invalidPromptSource(source.sourceID)
                }
            } else {
                guard source.fullDigest == nil,
                      source.status == .missing || source.status == .unreadable
                        || source.status == .disabled,
                      source.deliveredByteCount == 0, source.renderedByteCount == 0,
                      source.deliveredByteOffsetInRendered == 0,
                      source.deliveredDigest == Self.emptyBodyDigest,
                      source.renderedDigest == Self.emptyBodyDigest,
                      source.fullBodyReference == nil, source.deliveredBodyReference == nil,
                      source.renderedBodyReference == nil else {
                    throw ContextManifestValidationError.invalidPromptSource(source.sourceID)
                }

                if source.status == .missing || source.status == .unreadable
                    || source.status == .disabled {
                    guard source.fullBodyReference == nil, source.deliveredBodyReference == nil,
                          source.renderedBodyReference == nil else {
                        throw ContextManifestValidationError.invalidPromptSourceBodyReference(source.sourceID)
                    }
                }
            }

            // Rendered bytes are the exact source slice in the flattened system message. They
            // may include framing, but can never be negative or claim less than the source bytes.
            let deliveredEnd = source.deliveredByteOffsetInRendered.addingReportingOverflow(
                source.deliveredByteCount)
            guard !deliveredEnd.overflow,
                  deliveredEnd.partialValue <= source.renderedByteCount else {
                throw ContextManifestValidationError.invalidPromptSource(source.sourceID)
            }
            let renderedTotal = totalRenderedBytes.addingReportingOverflow(
                source.renderedByteCount)
            guard !renderedTotal.overflow else {
                throw ContextManifestValidationError.invalidPromptSourceAssembly
            }
            totalRenderedBytes = renderedTotal.partialValue
            try validatePromptBodyReference(
                source.fullBodyReference, digest: source.fullDigest, byteCount: source.fullByteCount,
                authority: authority, sourceID: source.sourceID)
            try validatePromptBodyReference(
                source.deliveredBodyReference, digest: source.deliveredDigest,
                byteCount: source.deliveredByteCount, authority: authority, sourceID: source.sourceID)
            try validatePromptBodyReference(
                source.renderedBodyReference, digest: source.renderedDigest,
                byteCount: source.renderedByteCount, authority: authority, sourceID: source.sourceID)
            if let provenance = source.provenance, provenance.journal != authority {
                throw ContextManifestValidationError.invalidPromptSourceProvenance(source.sourceID)
            }
            if requireRetainedBodies {
                guard source.status == .missing || source.status == .unreadable
                    || source.status == .disabled
                    || (source.fullBodyReference != nil && source.deliveredBodyReference != nil
                        && source.renderedBodyReference != nil) else {
                    throw ContextManifestValidationError.invalidPromptSourceBodyReference(source.sourceID)
                }
            }
            if source.status == .present,
               let fullReference = source.fullBodyReference,
               let deliveredReference = source.deliveredBodyReference,
               fullReference != deliveredReference {
                throw ContextManifestValidationError.invalidPromptSourceBodyReference(source.sourceID)
            }
        }
    }

    private func validatePromptBodyReference(
        _ reference: TimelineBodyReference?, digest: String?, byteCount: Int?,
        authority: JournalRef, sourceID: String
    ) throws {
        guard let reference else { return }
        guard let digest, let byteCount, byteCount >= 0,
              reference.authority == authority,
              reference.mediaType == "application/vnd.aviary.prompt-source+utf8",
              reference.referenceID == digest,
              reference.digest == digest,
              reference.byteCount == byteCount,
              ContextBodyStore.isValidDigest(digest) else {
            throw ContextManifestValidationError.invalidPromptSourceBodyReference(sourceID)
        }
    }

    private static func isPresent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isBoundedIdentity(_ value: String) -> Bool {
        isPresent(value) && Data(value.utf8).count <= 512
    }

    private static let emptyBodyDigest =
        "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    private static func checkedSum<S: Sequence>(_ values: S) -> Int? where S.Element == Int {
        var total = 0
        for value in values {
            let addition = total.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total
    }
}

public enum ContextManifestValidationError: LocalizedError, Equatable, Sendable {
    case unsupportedSchema(Int)
    case unsupportedMeasurementBasis(String)
    case invalidIdentity
    case emptyComponents
    case duplicateInclusionIdentity
    case invalidComponent(String)
    case invalidBodyReference(String)
    case measurementOverflow
    case inconsistentTotals
    case invalidOmission
    case invalidCumulativeMeasurement(expected: Int, actual: Int)
    case invalidPromptSourceAssembly
    case tooManyPromptSources
    case duplicatePromptSourceIdentity
    case invalidPromptSource(String)
    case invalidPromptSourceBodyReference(String)
    case invalidPromptSourceProvenance(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported context manifest schema: \(version)."
        case .unsupportedMeasurementBasis(let basis):
            return "Unsupported context measurement basis: \(basis)."
        case .invalidIdentity: return "The context manifest identity is invalid."
        case .emptyComponents: return "The context manifest has no components."
        case .duplicateInclusionIdentity:
            return "The context manifest repeats an inclusion identity."
        case .invalidComponent(let identity):
            return "The context component is invalid: \(identity)."
        case .invalidBodyReference(let identity):
            return "The retained context body reference is invalid: \(identity)."
        case .measurementOverflow: return "The context manifest measurements overflow."
        case .inconsistentTotals: return "The context manifest totals are inconsistent."
        case .invalidOmission: return "The context manifest omission set is invalid."
        case .invalidCumulativeMeasurement(let expected, let actual):
            return "The cumulative context measurement is \(actual), expected \(expected)."
        case .invalidPromptSourceAssembly:
            return "The prompt source assembly identity and records must be present together."
        case .tooManyPromptSources:
            return "The prompt source decomposition exceeds its 32-source bound."
        case .duplicatePromptSourceIdentity:
            return "The prompt source decomposition repeats a source or inclusion identity."
        case .invalidPromptSource(let sourceID):
            return "The prompt source metadata is invalid: \(sourceID)."
        case .invalidPromptSourceBodyReference(let sourceID):
            return "The retained prompt source body reference is invalid: \(sourceID)."
        case .invalidPromptSourceProvenance(let sourceID):
            return "The prompt source provenance journal is invalid: \(sourceID)."
        }
    }
}

/// A local content-addressed store for full context bodies. References contain only a stable
/// content identity and the journal authority, so the same manifest remains meaningful on a
/// remote Work Host without leaking a host-local path.
public struct ContextBodyStore: Sendable, Hashable {
    public let root: URL

    public init(home: AgentHome) {
        root = home.root.appending(path: "context-bodies", directoryHint: .isDirectory)
    }

    /// Retain one full body before its `context.assembled` event is written. Existing content
    /// is verified rather than overwritten, making concurrent callers idempotent.
    public func retain(
        _ body: Data, authority: JournalRef, mediaType: String? = "application/octet-stream"
    ) throws -> TimelineBodyReference {
        let digest = Self.digest(body)
        let referenceID = digest
        let directory = root.appending(path: "sha256", directoryHint: .isDirectory)
        try Self.ensureDirectory(root, parent: root.deletingLastPathComponent())
        try Self.ensureDirectory(directory, parent: root)
        let destination = directory.appending(path: String(digest.dropFirst("sha256:".count)))
        if FileManager.default.fileExists(atPath: destination.path) {
            guard let existing = try? Data(contentsOf: destination), Self.digest(existing) == digest else {
                throw ContextBodyStoreError.conflictingBody(referenceID: referenceID)
            }
        } else {
            let temporary = directory.appending(path: ".\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard FileManager.default.createFile(
                atPath: temporary.path, contents: nil,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]) else {
                throw ContextBodyStoreError.writeFailed("could not create temporary body")
            }
            do {
                let handle = try FileHandle(forWritingTo: temporary)
                try handle.write(contentsOf: body)
                try handle.synchronize()
                try handle.close()
                do {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                } catch {
                    // Another host/process may have published the same digest first. Verify
                    // that winner rather than treating an idempotent race as corruption.
                    guard let existing = try? Data(contentsOf: destination), Self.digest(existing) == digest else {
                        throw ContextBodyStoreError.writeFailed(error.localizedDescription)
                    }
                }
            } catch let error as ContextBodyStoreError {
                throw error
            } catch {
                throw ContextBodyStoreError.writeFailed(error.localizedDescription)
            }
        }
        // The body itself was synchronized before rename. Synchronizing its parent makes the
        // content-addressed name durable as well, including when this call merely verifies a
        // file left by an earlier indeterminate publish.
        try Self.synchronizeDirectory(directory)
        return TimelineBodyReference(
            authority: authority, referenceID: referenceID, mediaType: mediaType,
            byteCount: body.count, digest: digest)
    }

    /// Resolve and verify a retained body. A malformed reference never escapes as arbitrary
    /// bytes, which keeps a reducer/report from presenting a mismatched artifact as evidence.
    public func read(_ reference: TimelineBodyReference) throws -> Data {
        guard let digest = reference.digest, reference.referenceID == digest,
              let byteCount = reference.byteCount,
              byteCount >= 0,
              let digestPath = Self.validatedDigestPath(digest) else {
            throw ContextBodyStoreError.invalidReference
        }
        let destination = root.appending(path: "sha256")
            .appending(path: digestPath)
        guard let body = try? Data(contentsOf: destination), body.count == byteCount,
              Self.digest(body) == digest else {
            throw ContextBodyStoreError.bodyUnavailable(referenceID: reference.referenceID)
        }
        return body
    }

    private static func digest(_ data: Data) -> String {
        "sha256:" + AviarySHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isValidDigest(_ digest: String) -> Bool {
        validatedDigestPath(digest) != nil
    }

    private static func validatedDigestPath(_ digest: String) -> String? {
        guard digest.hasPrefix("sha256:") else { return nil }
        let hex = String(digest.dropFirst("sha256:".count))
        guard hex.count == 64,
              hex.utf8.allSatisfy({
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                      || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
              }) else { return nil }
        return hex
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
#if canImport(Darwin)
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw ContextBodyStoreError.writeFailed("could not open retained body directory")
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw ContextBodyStoreError.writeFailed("could not synchronize retained body directory")
        }
#elseif canImport(Glibc)
        let descriptor = Glibc.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw ContextBodyStoreError.writeFailed("could not open retained body directory")
        }
        defer { _ = Glibc.close(descriptor) }
        guard Glibc.fsync(descriptor) == 0 else {
            throw ContextBodyStoreError.writeFailed("could not synchronize retained body directory")
        }
#else
        throw ContextBodyStoreError.writeFailed("directory synchronization is unsupported")
#endif
    }

    /// Creating `context-bodies/sha256` can add two names to two different directories. Each
    /// parent must be synchronized independently; syncing only the deepest directory protects
    /// the body rename but not first-use creation of the directory hierarchy itself.
    private static func ensureDirectory(_ directory: URL, parent: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ContextBodyStoreError.writeFailed(
                    "retained body directory path is not a directory")
            }
        } else {
            do {
                try manager.createDirectory(
                    at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
            } catch {
                // Concurrent retainers may race to publish the directory. Only accept the race
                // when the winning path is in fact a directory.
                isDirectory = false
                guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    throw ContextBodyStoreError.writeFailed(error.localizedDescription)
                }
            }
        }
        // Always sync the parent. This also repairs durability after an earlier caller created
        // the directory but failed or crashed before synchronizing the entry.
        try synchronizeDirectory(parent)
    }
}

public enum ContextBodyStoreError: LocalizedError, Equatable, Sendable {
    case invalidReference
    case bodyUnavailable(referenceID: String)
    case conflictingBody(referenceID: String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidReference: return "The context body reference is malformed."
        case .bodyUnavailable(let referenceID): return "The retained context body is unavailable: \(referenceID)"
        case .conflictingBody(let referenceID): return "A retained context body conflicts with \(referenceID)"
        case .writeFailed(let reason): return "Could not retain the context body: \(reason)"
        }
    }
}

/// A named reason a request component was measured but not delivered in full.
public struct ContextManifestOmission: Codable, Hashable, Sendable {
    public let omissionID: String
    public let sourceID: String
    public let reason: String
    public let measuredBytes: Int?

    public init(omissionID: String, sourceID: String, reason: String, measuredBytes: Int? = nil) {
        self.omissionID = omissionID
        self.sourceID = sourceID
        self.reason = reason
        self.measuredBytes = measuredBytes
    }

    private enum CodingKeys: String, CodingKey {
        case omissionID = "omission_id", sourceID = "source_id", reason, measuredBytes = "measured_bytes"
    }
}
