import Foundation

/// Pure projection of a Work journal. Applying the same prefix live or from cold storage yields
/// the same snapshot; no runtime, filesystem, wall-clock, or GUI state is consulted.
public struct WorkReducer: Sendable {
    private var transitionState: InMemoryWorkTransitionState

    /// The public snapshot remains the exact WorkSnapshot projection.  The transition adapter
    /// owns its scalar continuation and materializes this value only when a caller observes it;
    /// reducing a long journal therefore does not retain/copy every collection once per event.
    public private(set) var snapshot: WorkSnapshot {
        get { transitionState.snapshot }
        set { transitionState = InMemoryWorkTransitionState(snapshot: newValue) }
    }

    public init(snapshot: WorkSnapshot = WorkSnapshot()) {
        self.transitionState = InMemoryWorkTransitionState(snapshot: snapshot)
    }

    public static func reduce<S: Sequence>(
        _ events: S, initial: WorkSnapshot = WorkSnapshot()
    ) -> WorkSnapshot where S.Element == TimelineEvent {
        var reducer = WorkReducer(snapshot: initial)
        for event in events { reducer.apply(event) }
        return reducer.snapshot
    }

    public mutating func apply(_ event: TimelineEvent) {
        WorkReducerTransition.apply(event, to: &transitionState)
    }
}

/// Pure projection of a Session journal. Work identity and attachment state are kept separate
/// from the visible conversation so a session can continue, detach, or archive independently.
public struct SessionReducer: Sendable {
    private var transitionState: InMemorySessionTransitionState

    /// The public snapshot remains the exact SessionSnapshot projection. The transition adapter
    /// owns indexes and scalar continuation state; it is materialized only when observed.
    public private(set) var snapshot: SessionSnapshot {
        get { transitionState.snapshot }
        set { transitionState = InMemorySessionTransitionState(snapshot: newValue) }
    }

    // These counters are reducer-local instrumentation, not persisted projection state.
    internal var visibleProjectionRebuildCount: Int { transitionState.visibleProjectionRebuildCount }
    internal var visibleProjectionMessagesScanned: Int { transitionState.visibleProjectionMessagesScanned }
    internal var visibleProjectionFastPathCount: Int { transitionState.visibleProjectionFastPathCount }

    public init(snapshot: SessionSnapshot = SessionSnapshot()) {
        self.transitionState = InMemorySessionTransitionState(snapshot: snapshot)
    }

    public static func reduce<S: Sequence>(
        _ events: S, initial: SessionSnapshot = SessionSnapshot()
    ) -> SessionSnapshot where S.Element == TimelineEvent {
        var reducer = SessionReducer(snapshot: initial)
        for event in events { reducer.apply(event) }
        return reducer.snapshot
    }

    public mutating func apply(_ event: TimelineEvent) {
        SessionReducerTransition.apply(event, to: &transitionState)
    }
}

func decodeContextComponents(_ payload: JSONValue) -> [ContextComponent]? {
    guard let values = payload["components"]?.arrayValue else { return nil }
    let decoded = values.compactMap { value -> ContextComponent? in
        guard let component: ContextComponent = decodeTimelineValue(value) else { return nil }
        if [.truncated, .summary, .manifest].contains(component.deliveryMode),
           (component.bodyReference == nil || component.digest == nil || component.fullByteCount == nil) {
            return nil
        }
        if let body = component.bodyReference,
           body.digest != component.digest || body.byteCount != component.fullByteCount {
            return nil
        }
        return component
    }
    return decoded.count == values.count ? decoded : nil
}

func decodeContextManifest(
    _ payload: JSONValue, components: [ContextComponent]
) -> ContextManifest? {
    guard let manifestID = payload["manifest_id"]?.stringValue,
          let requestID = payload["request_id"]?.stringValue,
          let modelID = payload["model_id"]?.stringValue,
          let measuredBy = payload["measured_by"]?.stringValue,
          let schemaVersion = payload["schema_version"]?.intValue,
          let measuredBytes = payload["measured_bytes"]?.intValue,
          let deliveredBytes = payload["delivered_bytes"]?.intValue,
          let cumulativeDeliveredBytes = payload["cumulative_delivered_bytes"]?.intValue,
          let omissionValues = payload["omissions"]?.arrayValue else { return nil }
    let omissions: [ContextManifestOmission] = omissionValues.compactMap {
        decodeTimelineValue($0)
    }
    guard omissions.count == omissionValues.count else { return nil }
    let sourceValues = payload["system_prompt_sources"]?.arrayValue
    let promptSources: [ContextManifestSource]?
    if let sourceValues {
        let decoded: [ContextManifestSource] = sourceValues.compactMap {
            decodeTimelineValue($0)
        }
        guard decoded.count == sourceValues.count else { return nil }
        promptSources = decoded
    } else {
        promptSources = nil
    }
    let manifest = ContextManifest(
        schemaVersion: schemaVersion, manifestID: manifestID, requestID: requestID,
        modelID: modelID, measuredBy: measuredBy, components: components,
        omissions: omissions, cumulativeDeliveredBytes: cumulativeDeliveredBytes,
        systemPromptAssemblyID: payload["system_prompt_assembly_id"]?.stringValue,
        systemPromptSources: promptSources)
    guard manifest.measuredBytes == measuredBytes,
          manifest.deliveredBytes == deliveredBytes else { return nil }
    return manifest
}

func decodeContextSources(_ payload: JSONValue) -> [ContextManifestSource]? {
    guard let values = payload["sources"]?.arrayValue,
          let expectedCount = payload["source_count"]?.intValue,
          expectedCount == values.count else { return nil }
    let decoded: [ContextManifestSource] = values.compactMap { decodeTimelineValue($0) }
    return decoded.count == values.count ? decoded : nil
}
