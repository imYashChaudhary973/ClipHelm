import Foundation
import ClipHelmSecurity

public enum CatalogFilter: String, Sendable, Hashable {
    case all
    case transcription
}

public enum OpenRouterGatewayError: Error, LocalizedError, Equatable, Sendable {
    case invalidKey
    case rateLimited
    case networkUnavailable
    case serviceUnavailable
    case invalidResponse
    case unsupportedTranscription

    public var errorDescription: String? {
        switch self {
        case .invalidKey: "OpenRouter rejected this API key. Replace it in Settings."
        case .rateLimited: "OpenRouter is rate limiting requests. Try again later."
        case .networkUnavailable: "Could not reach OpenRouter. Check your connection and try again."
        case .serviceUnavailable: "OpenRouter is unavailable. Try again later."
        case .invalidResponse: "OpenRouter returned an unexpected response. Try again later."
        case .unsupportedTranscription: "This model could not return word-timed transcription. Choose another transcription model."
        }
    }
}

/// The only AI network boundary. Future inference methods belong here.
public protocol OpenRouterGateway: Sendable {
    func testConnection() async throws
    func fetchCatalog(_ filter: CatalogFilter) async throws -> Data
    func transcribeAudio(_ audio: Data, modelID: String) async throws -> Data
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public actor LiveOpenRouterGateway: OpenRouterGateway {
    private let secrets: any OpenRouterSecretReading
    private let session: URLSession

    public init(secrets: any OpenRouterSecretReading) {
        self.secrets = secrets
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    // Test-only injection uses a URLProtocol-backed session; production always uses the secure session above.
    init(secrets: any OpenRouterSecretReading, session: URLSession) {
        self.secrets = secrets
        self.session = session
    }

    public func testConnection() async throws {
        let data = try await perform(path: "/api/v1/key", filter: nil, maximumBytes: 64_000)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["data"] is [String: Any] else {
            throw OpenRouterGatewayError.invalidResponse
        }
    }

    public func fetchCatalog(_ filter: CatalogFilter) async throws -> Data {
        try await perform(path: "/api/v1/models", filter: filter, maximumBytes: 8_000_000)
    }

    public func transcribeAudio(_ audio: Data, modelID: String) async throws -> Data {
        guard (1...8_000_000).contains(audio.count),
              (1...200).contains(modelID.count),
              modelID.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0)
                  && !CharacterSet.controlCharacters.contains($0) }) else {
            throw OpenRouterGatewayError.invalidResponse
        }
        let body = try JSONEncoder().encode(TranscriptionRequest(
            model: modelID, inputAudio: .init(data: audio.base64EncodedString(), format: "m4a"),
            responseFormat: "verbose_json", timestampGranularities: ["word"]))
        return try await perform(path: "/api/v1/audio/transcriptions", filter: nil,
                                 maximumBytes: 2_000_000, body: body)
    }

    private func perform(path: String, filter: CatalogFilter?, maximumBytes: Int,
                         body: Data? = nil) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "openrouter.ai"
        components.path = path
        if let filter { components.queryItems = [URLQueryItem(name: "output_modalities", value: filter.rawValue)] }
        guard let url = components.url else { throw OpenRouterGatewayError.invalidResponse }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 70
        }
        request.setValue("Bearer \(try secrets.readKey())", forHTTPHeaderField: "Authorization")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw OpenRouterGatewayError.networkUnavailable
        }
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme == "https", http.url?.host == "openrouter.ai" else {
            throw OpenRouterGatewayError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw OpenRouterGatewayError.invalidKey
        case 429: throw OpenRouterGatewayError.rateLimited
        case 400 where body != nil: throw OpenRouterGatewayError.unsupportedTranscription
        case 500..<600: throw OpenRouterGatewayError.serviceUnavailable
        default: throw OpenRouterGatewayError.invalidResponse
        }
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw OpenRouterGatewayError.invalidResponse }
                data.append(byte)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OpenRouterGatewayError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw OpenRouterGatewayError.networkUnavailable
        }
        return data
    }
}

public actor MockOpenRouterGateway: OpenRouterGateway {
    public var connectionError: OpenRouterGatewayError?
    public var catalogs: [CatalogFilter: Data]
    public private(set) var requestedFilters: [CatalogFilter] = []
    public var transcriptionResponse: Data?
    public private(set) var transcriptionRequests: [(modelID: String, audioBytes: Int)] = []

    public init(catalogs: [CatalogFilter: Data] = [:], connectionError: OpenRouterGatewayError? = nil) {
        self.catalogs = catalogs
        self.connectionError = connectionError
    }

    public func testConnection() async throws {
        if let connectionError { throw connectionError }
    }

    public func fetchCatalog(_ filter: CatalogFilter) async throws -> Data {
        requestedFilters.append(filter)
        guard let data = catalogs[filter] else { throw OpenRouterGatewayError.invalidResponse }
        return data
    }

    public func transcribeAudio(_ audio: Data, modelID: String) async throws -> Data {
        transcriptionRequests.append((modelID, audio.count))
        guard let transcriptionResponse else { throw OpenRouterGatewayError.invalidResponse }
        return transcriptionResponse
    }

    public func setTranscriptionResponse(_ response: Data) {
        transcriptionResponse = response
    }
}

private struct TranscriptionRequest: Encodable {
    struct Audio: Encodable { let data: String; let format: String }
    let model: String
    let inputAudio: Audio
    let responseFormat: String
    let timestampGranularities: [String]

    enum CodingKeys: String, CodingKey {
        case model
        case inputAudio = "input_audio"
        case responseFormat = "response_format"
        case timestampGranularities = "timestamp_granularities"
    }
}
