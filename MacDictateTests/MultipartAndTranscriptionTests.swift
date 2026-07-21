import Foundation
import XCTest
@testable import MacDictate

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    /// When true, requests never complete, simulating an in-flight upload.
    nonisolated(unsafe) static var hangs = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if Self.hangs { return }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    func increment() -> Int { lock.withLock { storage += 1; return storage } }
    var value: Int { lock.withLock { storage } }
}

final class MultipartAndTranscriptionTests: XCTestCase {
    private let configuration = TranscriptionConfiguration(
        apiKey: "test-secret-key",
        model: .mini,
        language: .english,
        contextPrompt: "developer context"
    )

    func testMultipartConstructionContainsBinaryFileAndRequiredFields() {
        var builder = MultipartFormDataBuilder(boundary: "TEST-BOUNDARY")
        let binary = Data([0x00, 0xFF, 0x41, 0x0D, 0x0A])
        builder.addFile(name: "file", filename: "audio.wav", mimeType: "audio/wav", contents: binary)
        builder.addField(name: "model", value: "gpt-4o-mini-transcribe")
        builder.addField(name: "response_format", value: "text")
        builder.addField(name: "prompt", value: "developer context")
        builder.addField(name: "language", value: "en")
        let body = builder.finalize()

        XCTAssertTrue(body.contains(binary))
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"audio.wav\""))
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\ngpt-4o-mini-transcribe"))
        XCTAssertTrue(text.contains("name=\"response_format\"\r\n\r\ntext"))
        XCTAssertTrue(text.contains("name=\"prompt\"\r\n\r\ndeveloper context"))
        XCTAssertTrue(text.contains("name=\"language\"\r\n\r\nen"))
        XCTAssertTrue(text.hasSuffix("--TEST-BOUNDARY--\r\n"))
    }

    func testAuthorizationHeaderConstruction() {
        let service = OpenAITranscriptionService()
        let request = service.makeRequest(fileData: Data("wav".utf8), configuration: configuration)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + configuration.apiKey)
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testSuccessfulPlainTextParsing() throws {
        XCTAssertEqual(try OpenAITranscriptionService.parseSuccessfulResponse(Data("  Fix AppCoordinator.swift.\n".utf8)), "Fix AppCoordinator.swift.")
        XCTAssertThrowsError(try OpenAITranscriptionService.parseSuccessfulResponse(Data(" \n".utf8)))
    }

    func testJSONErrorParsing() {
        let data = Data(#"{"error":{"message":"Incorrect API key","type":"invalid_request_error","code":"invalid_api_key"}}"#.utf8)
        XCTAssertEqual(OpenAITranscriptionService.parseErrorMessage(data), "Incorrect API key")
        XCTAssertEqual(
            OpenAITranscriptionService.mapHTTPError(statusCode: 401, data: data),
            .invalidAPIKey("Incorrect API key")
        )
    }

    func testRetryClassification() {
        XCTAssertTrue(TranscriptionError.shouldRetry(statusCode: 429))
        XCTAssertTrue(TranscriptionError.shouldRetry(statusCode: 500))
        XCTAssertTrue(TranscriptionError.shouldRetry(statusCode: 503))
        XCTAssertFalse(TranscriptionError.shouldRetry(statusCode: 401))
        XCTAssertFalse(TranscriptionError.shouldRetry(statusCode: 400))
    }

    func testURLProtocolSuccessAndOneRetry() async throws {
        let counter = LockedCounter()
        MockURLProtocol.handler = { request in
            let attempt = counter.increment()
            let status = attempt == 1 ? 429 : 200
            let body = attempt == 1
                ? Data(#"{"error":{"message":"slow down"}}"#.utf8)
                : Data("Use rg to locate the symbol.".utf8)
            return (
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                body
            )
        }
        defer { MockURLProtocol.handler = nil }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let service = OpenAITranscriptionService(session: session, retryDelayNanoseconds: 1)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        try Data("fake wav".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = try await service.transcribe(fileURL: file, configuration: configuration)
        XCTAssertEqual(result, "Use rg to locate the symbol.")
        XCTAssertEqual(counter.value, 2)
    }

    func testServerErrorIsRetriedOnce() async throws {
        let counter = LockedCounter()
        MockURLProtocol.handler = { request in
            let attempt = counter.increment()
            let status = attempt == 1 ? 503 : 200
            let body = attempt == 1 ? Data("upstream overloaded".utf8) : Data("Recovered fine.".utf8)
            return (
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                body
            )
        }
        defer { MockURLProtocol.handler = nil }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let service = OpenAITranscriptionService(
            session: URLSession(configuration: sessionConfiguration),
            retryDelayNanoseconds: 1
        )
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        try Data("fake wav".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = try await service.transcribe(fileURL: file, configuration: configuration)
        XCTAssertEqual(result, "Recovered fine.")
        XCTAssertEqual(counter.value, 2)
    }

    func testInFlightCancellationThrowsCancellationError() async throws {
        MockURLProtocol.hangs = true
        defer { MockURLProtocol.hangs = false }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let service = OpenAITranscriptionService(
            session: URLSession(configuration: sessionConfiguration),
            retryDelayNanoseconds: 1
        )
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        try Data("fake wav".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let requestConfiguration = configuration
        let transcription = Task {
            try await service.transcribe(fileURL: file, configuration: requestConfiguration)
        }
        try await Task.sleep(for: .milliseconds(200))
        transcription.cancel()

        do {
            _ = try await transcription.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "Cancellation surfaced as \(error) instead of CancellationError")
        }
    }

    func testPromptEchoDetection() {
        let prompt = SettingsStore.defaultPrompt

        // The observed failure: the whole prompt wrapped in ### markers.
        XCTAssertTrue(PromptEchoDetector.isLikelyEcho(transcript: "###\n\(prompt)\n###", contextPrompt: prompt))
        // A verbatim echo without wrappers.
        XCTAssertTrue(PromptEchoDetector.isLikelyEcho(transcript: prompt, contextPrompt: prompt))
        // A sizable fragment of the prompt and nothing else.
        XCTAssertTrue(PromptEchoDetector.isLikelyEcho(
            transcript: "Preserve technical names, filenames, file paths, shell commands,",
            contextPrompt: prompt
        ))

        // Real dictations that merely share vocabulary with the prompt must pass.
        XCTAssertFalse(PromptEchoDetector.isLikelyEcho(transcript: "Fix the Docker file", contextPrompt: prompt))
        XCTAssertFalse(PromptEchoDetector.isLikelyEcho(
            transcript: "Use Git to revert the last commit on the MacDictate repository and rerun the tests.",
            contextPrompt: prompt
        ))
        // Short transcripts are never treated as echoes.
        XCTAssertFalse(PromptEchoDetector.isLikelyEcho(transcript: "Use normal punctuation", contextPrompt: prompt))
        // An empty context prompt disables the check.
        XCTAssertFalse(PromptEchoDetector.isLikelyEcho(transcript: "anything the user says here", contextPrompt: ""))
    }

    func testRecordedAudioSilenceGate() {
        let url = URL(fileURLWithPath: "/tmp/gate.wav")
        // Normal speech levels pass.
        XCTAssertFalse(RecordedAudio(fileURL: url, duration: 1, peakAmplitude: 0.4, rmsAmplitude: 0.05).isEffectivelySilent)
        // A click peak over near-silence is rejected by the RMS gate.
        XCTAssertTrue(RecordedAudio(fileURL: url, duration: 1, peakAmplitude: 0.05, rmsAmplitude: 0.0001).isEffectivelySilent)
        // Flat digital silence is rejected by the peak gate.
        XCTAssertTrue(RecordedAudio(fileURL: url, duration: 1, peakAmplitude: 0.001, rmsAmplitude: 0.0005).isEffectivelySilent)
        XCTAssertTrue(RecordedAudio(fileURL: url, duration: 0, peakAmplitude: 0.4, rmsAmplitude: 0.05).isEffectivelySilent)
    }

    func testRetryAfterHeaderParsing() {
        let fallback: UInt64 = 800_000_000
        XCTAssertEqual(OpenAITranscriptionService.parseRetryDelay(header: "2", fallbackNanoseconds: fallback), 2_000_000_000)
        XCTAssertEqual(OpenAITranscriptionService.parseRetryDelay(header: "120", fallbackNanoseconds: fallback), 5_000_000_000)
        XCTAssertEqual(OpenAITranscriptionService.parseRetryDelay(header: "0", fallbackNanoseconds: fallback), 0)
        XCTAssertEqual(OpenAITranscriptionService.parseRetryDelay(header: "Wed, 21 Oct 2026 07:28:00 GMT", fallbackNanoseconds: fallback), fallback)
        XCTAssertEqual(OpenAITranscriptionService.parseRetryDelay(header: "-1", fallbackNanoseconds: fallback), fallback)
        XCTAssertEqual(OpenAITranscriptionService.parseRetryDelay(header: nil, fallbackNanoseconds: fallback), fallback)
    }

    func testAuthenticationFailureIsNotRetried() async throws {
        let counter = LockedCounter()
        MockURLProtocol.handler = { request in
            _ = counter.increment()
            return (
                HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data(#"{"error":{"message":"bad key"}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let service = OpenAITranscriptionService(
            session: URLSession(configuration: sessionConfiguration),
            retryDelayNanoseconds: 1
        )
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        try Data("fake wav".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        do {
            _ = try await service.transcribe(fileURL: file, configuration: configuration)
            XCTFail("Expected authentication failure")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .invalidAPIKey("bad key"))
        }
        XCTAssertEqual(counter.value, 1)
    }
}

