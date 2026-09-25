import Foundation

public enum OpenRouterCapability: String, Hashable, Sendable {
    case text, vision, structuredOutput, transcription
}

public enum OpenRouterTask: String, CaseIterable, Hashable, Sendable {
    case transcriptReasoning, clipDiscovery, clipRanking
    case visionAnalysis, structuredClassification, transcription

    public var requiredCapabilities: Set<OpenRouterCapability> {
        switch self {
        case .transcriptReasoning, .clipRanking: [.text]
        case .clipDiscovery: [.text, .structuredOutput]
        case .visionAnalysis: [.vision, .structuredOutput]
        case .structuredClassification: [.text, .structuredOutput]
        case .transcription: [.transcription]
        }
    }
}

public struct OpenRouterModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let capabilities: Set<OpenRouterCapability>
    /// Catalog publication time, used to prefer current model generations.
    var created: Int = 0
    /// USD per input token, when the catalog lists it.
    var promptPrice: Double?

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
                    capabilities: previous.capabilities.union(model.capabilities),
                    created: max(previous.created, model.created),
                    promptPrice: previous.promptPrice ?? model.promptPrice
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

    /// The user's choice when it is still offered, otherwise a fast, low-cost current model.
    public func preferredModel(for task: OpenRouterTask) -> OpenRouterModel? {
        selectedModel(for: task) ?? recommendedModel(for: task)
    }

    public func recommendedModel(for task: OpenRouterTask) -> OpenRouterModel? {
        Self.recommend(from: models(supporting: task.requiredCapabilities))
    }

    static func recommend(from models: [OpenRouterModel]) -> OpenRouterModel? {
        let excluded = ["preview", "-exp", "lite", "nano", "image", "audio", "tts", "search",
                        "online", "thinking", "guard", "embed"]
        let pool = models.filter { model in
            !model.id.contains(":") && !excluded.contains { model.id.lowercased().contains($0) }
        }
        let families: [(prefix: String, hint: String)] = [
            ("z-ai/glm-", "flash"), ("google/gemini-", "flash"), ("openai/gpt-", "mini"), ("openai/gpt-", "luna"),
            ("anthropic/claude-", "haiku"), ("deepseek/", "flash"), ("qwen/", "flash"),
            ("mistralai/", "small"),
        ]
        for family in families {
            let matches = pool.filter { $0.id.hasPrefix(family.prefix) && $0.id.contains(family.hint) }
            if let newest = matches.max(by: { $0.created < $1.created }) { return newest }
        }
        let affordable = pool.filter { ($0.promptPrice ?? .infinity) <= 0.000_003 }
        return affordable.max(by: { $0.created < $1.created }) ?? pool.first ?? models.first
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
            // Strict JSON schemas need "structured_outputs"; "response_format" alone may mean JSON mode only.
            if (capabilities.contains(.text) || capabilities.contains(.vision)) &&
                parameters.contains("response_format") && parameters.contains("structured_outputs") {
                capabilities.insert(.structuredOutput)
            }
            if filter == .transcription || outputs.contains("transcription") {
                capabilities.insert(.transcription)
            }
            return OpenRouterModel(id: entry.id, name: entry.name, capabilities: capabilities,
                                   created: entry.created ?? 0,
                                   promptPrice: entry.promptPrice.flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
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
    let created: Int?
    let promptPrice: String?

    enum CodingKeys: String, CodingKey { case id, name, architecture, created, pricing, supportedParameters = "supported_parameters" }
    private struct Pricing: Decodable { let prompt: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        architecture = try? c.decode(Architecture.self, forKey: .architecture)
        supportedParameters = (try? c.decode([String].self, forKey: .supportedParameters)) ?? []
        created = try? c.decode(Int.self, forKey: .created)
        promptPrice = (try? c.decode(Pricing.self, forKey: .pricing))?.prompt
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
