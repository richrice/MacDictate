import Foundation

struct TranscriptionConfiguration: Sendable {
    let apiKey: String
    let model: TranscriptionModel
    let language: TranscriptionLanguage
    let contextPrompt: String
}

protocol TranscriptionService: Sendable {
    func transcribe(fileURL: URL, configuration: TranscriptionConfiguration) async throws -> String
}

enum TranscriptionError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidAPIKey(String)
    case quota(String)
    case rateLimited(String)
    case network(String)
    case server(status: Int, message: String)
    case rejected(status: Int, message: String)
    case malformedResponse
    case emptyTranscription
    case fileRead(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add an OpenAI API key in Settings."
        case let .invalidAPIKey(detail): "The OpenAI API key was rejected. \(detail)"
        case let .quota(detail): "The OpenAI account has insufficient quota. \(detail)"
        case let .rateLimited(detail): "OpenAI is rate limiting requests. \(detail)"
        case let .network(detail): "The transcription request could not connect. \(detail)"
        case let .server(status, message): "OpenAI returned server error \(status). \(message)"
        case let .rejected(status, message): "OpenAI rejected the request (HTTP \(status)). \(message)"
        case .malformedResponse: "OpenAI returned a malformed response."
        case .emptyTranscription: "No speech was found in the transcription response."
        case let .fileRead(detail): "The temporary recording could not be read. \(detail)"
        }
    }

    static func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 429 || (500...599).contains(statusCode)
    }
}

struct OpenAIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String?
        let type: String?
        let code: String?
    }
    let error: APIError
}

final class OpenAITranscriptionService: TranscriptionService {
    private let session: URLSession
    private let endpoint: URL
    private let retryDelayNanoseconds: UInt64

    init(
        session: URLSession = OpenAITranscriptionService.makeSession(),
        endpoint: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
        retryDelayNanoseconds: UInt64 = 800_000_000
    ) {
        self.session = session
        self.endpoint = endpoint
        self.retryDelayNanoseconds = retryDelayNanoseconds
    }

    func transcribe(fileURL: URL, configuration: TranscriptionConfiguration) async throws -> String {
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            throw TranscriptionError.fileRead(error.localizedDescription)
        }

        let request = makeRequest(fileData: fileData, configuration: configuration)
        for attempt in 0...1 {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw TranscriptionError.malformedResponse
                }
                if (200...299).contains(http.statusCode) {
                    return try Self.parseSuccessfulResponse(data)
                }

                let error = Self.mapHTTPError(statusCode: http.statusCode, data: data)
                if attempt == 0, TranscriptionError.shouldRetry(statusCode: http.statusCode) {
                    try await Task.sleep(nanoseconds: retryDelayNanoseconds)
                    continue
                }
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TranscriptionError {
                throw error
            } catch let error as URLError {
                throw TranscriptionError.network(error.localizedDescription)
            } catch {
                throw TranscriptionError.network(error.localizedDescription)
            }
        }
        throw TranscriptionError.malformedResponse
    }

    func makeRequest(fileData: Data, configuration: TranscriptionConfiguration) -> URLRequest {
        var form = MultipartFormDataBuilder()
        form.addFile(name: "file", filename: "dictation.wav", mimeType: "audio/wav", contents: fileData)
        form.addField(name: "model", value: configuration.model.rawValue)
        form.addField(name: "response_format", value: "text")
        form.addField(name: "prompt", value: configuration.contextPrompt)
        if let language = configuration.language.apiValue {
            form.addField(name: "language", value: language)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = form.finalize()
        return request
    }

    static func parseSuccessfulResponse(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw TranscriptionError.malformedResponse
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranscriptionError.emptyTranscription }
        return trimmed
    }

    static func parseErrorMessage(_ data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data),
           let message = envelope.error.message, !message.isEmpty {
            return message
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(500)
            .description ?? "No error details were returned."
    }

    static func mapHTTPError(statusCode: Int, data: Data) -> TranscriptionError {
        let message = parseErrorMessage(data)
        switch statusCode {
        case 401, 403:
            return .invalidAPIKey(message)
        case 429 where message.localizedCaseInsensitiveContains("quota"):
            return .quota(message)
        case 429:
            return .rateLimited(message)
        case 500...599:
            return .server(status: statusCode, message: message)
        default:
            return .rejected(status: statusCode, message: message)
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 75
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }
}

