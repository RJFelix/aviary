import SwiftUI
import AviaryCore

/// Credential bytes stay in this secure-entry flow and the local store, never in AppModel,
/// a launch configuration, a transcript, or the model-facing tool schema.
struct LocalSecretsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var records: [LocalSecretMetadata] = []
    @State private var name = ""
    @State private var providerID = ""
    @State private var origin = ""
    @State private var credential = ""
    @State private var editingName: String?
    @State private var configureGrok = false
    @State private var modelID = XAIProviderSetup.suggestedModelID
    @State private var busy = false
    @State private var notice: String?
    @State private var failed = false
    @State private var pendingRemoval: LocalSecretMetadata?

    init(grokPreset: Bool = false) {
        _name = State(initialValue: grokPreset ? "grok" : "")
        _providerID = State(initialValue: grokPreset ? XAIProviderSetup.providerID : "")
        _origin = State(initialValue: grokPreset ? "https://api.x.ai" : "")
        _configureGrok = State(initialValue: grokPreset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Local secrets", systemImage: "key.horizontal.fill")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 10) {
                Image(systemName: "lock.shield").font(.title).foregroundStyle(Design.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stored in this Mac’s Keychain").font(.headline)
                    Text("Aviary sends the key only as authentication to the provider you allow. Models receive neither the key nor a copy in their context.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Divider()
            if !records.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(records) { record in
                            HStack(spacing: 10) {
                                Image(systemName: "key").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.name).font(.body.weight(.medium))
                                    Text("\(record.allowedProviderID) · \(record.allowedOrigin)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Button("Authorize agent service…") { authorizeService(record) }
                                        .font(.caption).disabled(busy)
                                }
                                Spacer()
                                Button("Replace") { edit(record) }.disabled(busy)
                                Button { pendingRemoval = record } label: {
                                    Image(systemName: "trash")
                                }.help("Remove credential").disabled(busy)
                            }.padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.frame(maxHeight: 160)
            }
            HStack {
                Text(editingName == nil ? "Add a credential" : "Replace credential").font(.headline)
                Spacer()
                Button("Set up Grok") { grok() }.disabled(busy)
                if editingName != nil { Button("New") { clear() }.disabled(busy) }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Name").foregroundStyle(.secondary)
                    TextField("e.g. grok", text: $name).disabled(editingName != nil)
                }
                GridRow {
                    Text("Provider").foregroundStyle(.secondary)
                    TextField("Provider ID in models.json", text: $providerID).disabled(configureGrok)
                }
                GridRow {
                    Text("Allowed server").foregroundStyle(.secondary)
                    TextField("https://api.example.com", text: $origin).disabled(configureGrok)
                }
                GridRow {
                    Text("API key").foregroundStyle(.secondary)
                    SecureField(editingName == nil ? "Paste key here" : "Paste replacement key", text: $credential)
                        .textContentType(.password)
                }
                if configureGrok {
                    GridRow {
                        Text("Grok model").foregroundStyle(.secondary)
                        TextField("Model ID", text: $modelID)
                    }
                }
            }.textFieldStyle(.roundedBorder).disabled(busy)
            if configureGrok {
                Text("Also adds Grok to your model picker. Choose a model available to your API account; saving does not make a paid API request.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !name.isEmpty {
                Text("Use @secret:\(name) as the provider’s apiKey in models.json.")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text("Provider calls only for now. Tool credential injection is not enabled. This is not a sandbox boundary for unrestricted local code.")
                .font(.caption).foregroundStyle(.secondary)
            if let notice {
                Label(notice, systemImage: failed ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.callout).foregroundStyle(failed ? Design.warning : Design.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(canConfigureSavedGrok ? "Save Grok configuration" : (editingName == nil ? "Save credential" : "Replace credential")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || (credential.isEmpty && !canConfigureSavedGrok) || name.isEmpty || providerID.isEmpty || origin.isEmpty)
            }
        }
        .padding(24).frame(width: 620)
        .task {
            await reload()
            if configureGrok, records.contains(where: { $0.name == name }) {
                editingName = name
            }
        }
        .onDisappear { credential = "" }
        .confirmationDialog("Remove this credential?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
                Button("Remove credential", role: .destructive) {
                    if let record = pendingRemoval { remove(record) }
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: {
                Text("Provider configuration is kept, but requests using this credential will fail until you replace it.")
            }
    }

    private func grok() {
        clear()
        name = "grok"
        providerID = XAIProviderSetup.providerID
        origin = "https://api.x.ai"
        configureGrok = true
        if records.contains(where: { $0.name == name }) { editingName = name }
    }

    private func clear() {
        name = ""; providerID = ""; origin = ""; credential = ""
        editingName = nil; configureGrok = false; notice = nil
    }

    private func edit(_ record: LocalSecretMetadata) {
        clear(); editingName = record.name; name = record.name
        providerID = record.allowedProviderID; origin = record.allowedOrigin
    }

    private func reload() async {
        let home = model.home
        do {
            records = try await Task.detached { try LocalSecretStore(home: home).list() }.value
        } catch { showFailure(error) }
    }

    private func save() {
        busy = true; notice = nil
        let home = model.home
        let entryName = name, key = credential, provider = providerID, server = origin
        let replace = editingName != nil, addGrok = configureGrok, requestedModel = modelID
        let useSaved = canConfigureSavedGrok
        Task {
            do {
                // Validate configuration before storing a new key. Re-read at publication;
                // failures after Keychain save leave the key available for a safe retry.
                try await Task.detached {
                    if addGrok {
                        _ = try XAIProviderSetup.configuration(ModelsConfig.load(home: home).raw,
                            modelID: requestedModel, secretName: entryName)
                    }
                    if !useSaved {
                        let store = LocalSecretStore(home: home)
                        if replace {
                            try store.replace(name: entryName, value: key, allowedProviderID: provider, allowedOrigin: server)
                        } else {
                            try store.save(name: entryName, value: key, allowedProviderID: provider, allowedOrigin: server)
                        }
                    }
                }.value
                credential = ""; editingName = entryName
                await reload()
                if addGrok {
                    do {
                        try await Task.detached {
                            try XAIProviderSetup.save(home: home, modelID: requestedModel, secretName: entryName)
                        }.value
                    } catch {
                        failed = true
                        notice = "The key is saved in Keychain, but Grok configuration could not be saved. Your existing provider configuration was preserved."
                        busy = false
                        return
                    }
                }
                model.reloadModelsConfig()
                await model.refreshRuntimeModels()
                failed = false
                notice = addGrok ? "Grok is configured. You can now test it from Models or start a chat." : "Credential saved. Its value is never shown here."
            } catch { showFailure(error) }
            busy = false
        }
    }

    private var canConfigureSavedGrok: Bool {
        configureGrok && credential.isEmpty && editingName == name && records.contains {
            $0.name == name && $0.allowedProviderID == XAIProviderSetup.providerID
                && $0.allowedOrigin == "https://api.x.ai"
        }
    }

    private func remove(_ record: LocalSecretMetadata) {
        pendingRemoval = nil; busy = true
        let home = model.home
        Task {
            do {
                try await Task.detached { try LocalSecretStore(home: home).remove(name: record.name) }.value
                if editingName == record.name { clear() }
                await reload()
                await model.refreshRuntimeModels()
                failed = false; notice = "Credential removed from Keychain."
            } catch { showFailure(error) }
            busy = false
        }
    }

    private func authorizeService(_ record: LocalSecretMetadata) {
        let home = model.home
        guard let helper = LocalSecretStore.currentBundledTrustedApplicationPaths().last,
              helper.hasSuffix("/Contents/Helpers/aviaryd") else {
            failed = true; notice = "Open the bundled Aviary app to authorize its agent service."
            return
        }
        busy = true; failed = false
        notice = "macOS may ask for approval. Choose Always Allow for aviaryd to enable background agent access."
        Task {
            let authorization = await Shell.run(helper,
                LocalSecretServiceAccess.arguments(home: home, record: record, interactive: true), timeout: 120)
            if case .success(let result) = authorization, result.ok {
                // A fresh process proves access survives the interactive process exiting.
                let check = await Shell.run(helper,
                    LocalSecretServiceAccess.arguments(home: home, record: record, interactive: false), timeout: 10)
                let verified: Bool
                if case .success(let result) = check { verified = result.ok } else { verified = false }
                failed = !verified
                notice = verified ? "Agent service access verified. Retry the saved chat startup."
                    : "Background access was not verified. Check the credential’s provider and server, then authorize again. If macOS asks, choose Always Allow."
                await model.refreshRuntimeModels()
            } else {
                failed = true
                notice = "Agent service authorization did not complete. The saved key is unchanged; you can try again."
            }
            busy = false
        }
    }

    private func showFailure(_ error: Error) {
        failed = true
        if let error = error as? LocalSecretStoreError { notice = error.errorDescription }
        else if let error = error as? XAIProviderSetup.Failure { notice = error.errorDescription }
        else { notice = "The credential operation could not be completed. No key value was logged." }
    }
}
