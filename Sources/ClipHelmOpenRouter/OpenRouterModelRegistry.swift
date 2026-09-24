import Foundation

public enum OpenRouterCapability: String, Hashable, Sendable {
    case text, vision, structuredOutput, transcription
}

public enum OpenRouterTask: String, CaseIterable, Hashable, Sendable {
    case transcriptReasoning, clipDiscovery, clipRanking
    case visionAnalysis, structuredClassification, transcription

    public var requiredCapabilities: Set<OpenRouterCapability> {
        switch self {
        case .transcriptReasoning, .clipDiscovery, .clipRanking: [.text]
        case .visionAnalysis: [.vision]
        case .structuredClassification: [.text, .structuredOutput]
        case .transcription: [.transcription]
        }
    }
}

public struct OpenRouterModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let capabilities: Set<OpenRouterCapability>

    public func supports(_ requirements: Set<OpenRouterCapability>) -> Bool {
        capabilities.isSuperset(of: requirements)
    }
}

public enum OpenRouterModelRegistryError: Error, LocalizedError, Equatable, Sendable {
    case invalidCatalog
    case modelUnavailable
    case unsupportedTask

    public var errorDescription: String? {
        switch self {
        case .invalidCatalog: "The OpenRouter model list could not be read."
        case .modelUnavailable: "This model is no longer available. Refresh the model list."
        case .unsupportedTask: "This model does not support the selected task."
        }
    }
}

public actor OpenRouterModelRegistry {
    private let gateway: any OpenRouterGateway
    private let defaults: UserDefaults
    private let storageKey = "OpenRouterModelSelections"
    private var modelsByID: [String: OpenRouterModel] = [:]
    private var selectedIDs: [OpenRouterTask: String] = [:]

    public init(gateway: any OpenRouterGateway, defaultsSuiteName: String? = nil) {
        self.gateway = gateway
        let defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.defaults = defaults
        if let stored = defaults.dictionary(forKey: storageKey) as? [String: String] {
            selectedIDs = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
                OpenRouterTask(rawValue: key).map { ($0, value) }
            })
        }
    }

    @discardableResult
    public func refresh() async throws -> [OpenRouterModel] {
        async let allData = gateway.fetchCatalog(.all)
        async let transcriptionData = gateway.fetchCatalog(.transcription)
        let all = try Self.decode(try await allData, filter: .all)
        let transcription = try Self.decode(try await transcriptionData, filter: .transcription)

        var merged: [String: OpenRouterModel] = [:]
        for model in all + transcription {
            if let previous = merged[model.id] {
                merged[model.id] = OpenRouterModel(
                    id: model.id, name: model.name,
                    capabilities: previous.capabilities.union(model.capabilities)
                )
            } else {
                merged[model.id] = model
            }
        }
        modelsByID = merged
        return models(supporting: [])
    }

    public func models(supporting capabilities: Set<OpenRouterCapability>) -> [OpenRouterModel] {
        modelsByID.values.filter { $0.supports(capabilities) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func selectModel(id: String, for task: OpenRouterTask) throws {
        guard let model = modelsByID[id] else { throw OpenRouterModelRegistryError.modelUnavailable }
        guard model.supports(task.requiredCapabilities) else {
            throw OpenRouterModelRegistryError.unsupportedTask
        }
        selectedIDs[task] = id
        defaults.set(Dictionary(uniqueKeysWithValues: selectedIDs.map { ($0.key.rawValue, $0.value) }),
                     forKey: storageKey)
    }

    public func selectedModel(for task: OpenRouterTask) -> OpenRouterModel? {
        guard let id = selectedIDs[task], let model = modelsByID[id],
              model.supports(task.requiredCapabilities) else { return nil }
        return model
    }

    private static func decode(_ data: Data, filter: CatalogFilter) throws -> [OpenRouterModel] {
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
              catalog.data.count <= 10_000 else {
            throw OpenRouterModelRegistryError.invalidCatalog
        }
        return catalog.data.compactMap { entry in
            guard !entry.id.isEmpty, entry.id.count <= 200,
                  !entry.name.isEmpty, entry.name.count <= 200,
                  entry.id.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }) else {
                return nil
            }
            let inputs = Set(entry.architecture?.inputModalities ?? [])
            let outputs = Set(entry.architecture?.outputModalities ?? [])
            let parameters = Set(entry.supportedParameters)
            var capabilities: Set<OpenRouterCapability> = []
            if inputs.contains("text") && outputs.contains("text") { capabilities.insert(.text) }
            if inputs.contains("image") && outputs.contains("text") { capabilities.insert(.vision) }
            if capabilities.contains(.text) && parameters.contains("response_format") {
                capabilities.insert(.structuredOutput)
            }
            if filter == .transcription || outputs.contains("transcription") {
                capabilities.insert(.transcription)
            }
            return OpenRouterModel(id: entry.id, name: entry.name, capabilities: capabilities)
        }
    }
}

private struct Catalog: Decodable {
    let data: [CatalogEntry]
}

private struct CatalogEntry: Decodable {
    let id: String
    let name: String
    let architecture: Architecture?
    let supportedParameters: [String]

    enum CodingKeys: String, CodingKey { case id, name, architecture, supportedParameters = "supported_parameters" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        architecture = try? c.decode(Architecture.self, forKey: .architecture)
        supportedParameters = (try? c.decode([String].self, forKey: .supportedParameters)) ?? []
    }
}

private struct Architecture: Decodable {
    let inputModalities: [String]
    let outputModalities: [String]

    enum CodingKeys: String, CodingKey {
        case inputModalities = "input_modalities", outputModalities = "output_modalities"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputModalities = (try? c.decode([String].self, forKey: .inputModalities)) ?? []
        outputModalities = (try? c.decode([String].self, forKey: .outputModalities)) ?? []
    }
}
