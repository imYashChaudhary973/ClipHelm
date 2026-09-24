import Foundation
import XCTest
import ClipHelmSecurity
@testable import ClipHelmOpenRouter

private struct FakeSecret: OpenRouterSecretReading {
    let key = "unit-test-token"
    func readKey() throws -> String { key }
}

private final class StubState: @unchecked Sendable {
    private let lock = NSLock()
    private var status = 200
    private var body = Data(#"{"data":{}}"#.utf8)
    private var requests: [URLRequest] = []
    private var requestBodies: [Data] = []

    func configure(status: Int, body: Data) {
        lock.lock()
        self.status = status
        self.body = body
        requests = []
        requestBodies = []
        lock.unlock()
    }

    func response(for request: URLRequest) -> (Int, Data) {
        var requestBody = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                requestBody.append(contentsOf: bytes.prefix(count))
            }
        }
        lock.lock()
        requests.append(request)
        requestBodies.append(requestBody)
        let result = (status, body)
        lock.unlock()
        return result
    }

    func lastRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last
    }

    func lastRequestBody() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return requestBodies.last
    }
}

private final class StubURLProtocol: URLProtocol {
    static let state = StubState()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { }

    override func startLoading() {
        let (status, body) = Self.state.response(for: request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status,
                                             httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: OpenRouterGatewayError.invalidResponse)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class OpenRouterInfrastructureTests: XCTestCase {
    private func stubbedGateway() -> LiveOpenRouterGateway {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return LiveOpenRouterGateway(secrets: FakeSecret(), session: URLSession(configuration: configuration))
    }

    func testConnectionUsesFixedHTTPSKeyEndpointAndSanitizedError() async throws {
        StubURLProtocol.state.configure(status: 200, body: Data(#"{"data":{}}"#.utf8))
        let gateway = stubbedGateway()
        try await gateway.testConnection()
        let request = try XCTUnwrap(StubURLProtocol.state.lastRequest())
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-token")

        StubURLProtocol.state.configure(status: 401, body: Data(#"{"error":"secret body must not surface"}"#.utf8))
        do {
            try await gateway.testConnection()
            XCTFail("Expected invalid key")
        } catch let error as OpenRouterGatewayError {
            XCTAssertEqual(error, .invalidKey)
            XCTAssertFalse(error.localizedDescription.contains("secret body"))
            XCTAssertFalse(error.localizedDescription.contains("unit-test-token"))
        }

        StubURLProtocol.state.configure(status: 200, body: Data(repeating: 65, count: 64_001))
        do {
            try await gateway.testConnection()
            XCTFail("Expected bounded response rejection")
        } catch let error as OpenRouterGatewayError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testRegistryDiscoversCapabilitiesAndPersistsModelSelections() async throws {
        let all = Data(#"{"data":[{"id":"vendor/text","name":"Text","architecture":{"input_modalities":["text"],"output_modalities":["text"]},"supported_parameters":["response_format"]},{"id":"vendor/vision","name":"Vision","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"supported_parameters":[]}] }"#.utf8)
        let transcription = Data(#"{"data":[{"id":"vendor/speech","name":"Speech","architecture":{"input_modalities":["audio"],"output_modalities":["transcription"]}}]}"#.utf8)
        let gateway = MockOpenRouterGateway(catalogs: [.all: all, .transcription: transcription])
        let suite = "ClipHelm-Models-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let registry = OpenRouterModelRegistry(gateway: gateway, defaultsSuiteName: suite)
        let models = try await registry.refresh()
        XCTAssertEqual(models.count, 3)
        let structured = await registry.models(supporting: [.text, .structuredOutput])
        XCTAssertEqual(structured.map(\.id), ["vendor/text"])
        let vision = await registry.models(supporting: [.vision])
        XCTAssertEqual(vision.map(\.id), ["vendor/vision"])
        let speech = await registry.models(supporting: [.transcription])
        XCTAssertEqual(speech.map(\.id), ["vendor/speech"])

        do {
            try await registry.selectModel(id: "vendor/vision", for: .structuredClassification)
            XCTFail("Expected capability rejection")
        } catch let error as OpenRouterModelRegistryError {
            XCTAssertEqual(error, .unsupportedTask)
        }
        try await registry.selectModel(id: "vendor/text", for: .structuredClassification)
        let selected = await registry.selectedModel(for: .structuredClassification)
        XCTAssertEqual(selected?.id, "vendor/text")
        let restored = OpenRouterModelRegistry(gateway: gateway, defaultsSuiteName: suite)
        _ = try await restored.refresh()
        let restoredSelection = await restored.selectedModel(for: .structuredClassification)
        XCTAssertEqual(restoredSelection?.id, "vendor/text")
        let requestedFilters = await gateway.requestedFilters
        XCTAssertEqual(Set(requestedFilters), Set([.all, .transcription]))
    }
}
