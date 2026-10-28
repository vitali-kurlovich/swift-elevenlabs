import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// Thin, hand-written layer over the generated `Client`.
///
/// Use `client` directly for any endpoint not wrapped here.
public struct ElevenLabs: Sendable {
    public static let defaultServerURL = URL(string: "https://api.elevenlabs.io")!

    public let client: Client

    public init(
        apiKey: String,
        serverURL: URL = ElevenLabs.defaultServerURL,
        session: URLSession = .shared
    ) {
        client = Client(
            serverURL: serverURL,
            transport: URLSessionTransport(configuration: .init(session: session)),
            middlewares: [APIKeyMiddleware(apiKey: apiKey)]
        )
    }

    /// Reads the key from `ELEVENLABS_API_KEY` and an optional `ELEVENLABS_BASE_URL` (e.g. your proxy).
    public static func fromEnvironment() throws -> ElevenLabs {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["ELEVENLABS_API_KEY"], !key.isEmpty else {
            throw ElevenLabsError.missingAPIKey
        }
        let serverURL = env["ELEVENLABS_BASE_URL"].flatMap(URL.init(string:)) ?? defaultServerURL
        return ElevenLabs(apiKey: key, serverURL: serverURL)
    }

    // MARK: - Text to speech

    public typealias OutputFormat = Operations.TextToSpeechFull.Input.Query.OutputFormatPayload

    /// Synthesizes `text` and returns the encoded audio (MP3 by default).
    public func speech(
        _ text: String,
        voiceID: String,
        modelID: String = "eleven_multilingual_v2",
        outputFormat: OutputFormat = .mp344100128,
        voiceSettings: Components.Schemas.VoiceSettingsResponseModel? = nil
    ) async throws -> Data {
        let response = try await client.textToSpeechFull(
            path: .init(voiceId: voiceID),
            query: .init(outputFormat: outputFormat),
            body: .json(.init(text: text, modelId: modelID, voiceSettings: voiceSettings))
        )
        switch response {
        case .ok(let ok):
            return try await Data(collecting: ok.body.audioMpeg, upTo: .max)
        case .unprocessableContent(let error):
            throw ElevenLabsError.validation(try error.body.json)
        case .undocumented(let status, let payload):
            throw await ElevenLabsError.http(status: status, payload: payload)
        }
    }

    // MARK: - Speech to text

    /// Transcribes an audio or video file with Scribe.
    public func transcribe(
        _ audio: Data,
        filename: String = "audio.mp3",
        modelID: String = "scribe_v1",
        languageCode: String? = nil,
        diarize: Bool = false
    ) async throws -> Components.Schemas.SpeechToTextChunkResponseModel {
        typealias Part = Operations.SpeechToText.Input.Body.MultipartFormPayload
        var parts: [Part] = [
            .modelId(.init(payload: .init(body: HTTPBody(modelID)))),
            .file(.init(payload: .init(body: HTTPBody(audio)), filename: filename)),
            .diarize(.init(payload: .init(body: HTTPBody(diarize ? "true" : "false")))),
        ]
        if let languageCode {
            parts.append(.languageCode(.init(payload: .init(body: HTTPBody(languageCode)))))
        }

        let response = try await client.speechToText(body: .multipartForm(.init(parts)))
        switch response {
        case .ok(let ok):
            guard let chunk = try ok.body.json.value1 else {
                throw ElevenLabsError.unexpectedResponse("multichannel or webhook transcript")
            }
            return chunk
        case .accepted:
            throw ElevenLabsError.unexpectedResponse("transcription was queued for a webhook")
        case .unprocessableContent(let error):
            throw ElevenLabsError.validation(try error.body.json)
        case .undocumented(let status, let payload):
            throw await ElevenLabsError.http(status: status, payload: payload)
        }
    }

    // MARK: - Voices

    public func voices() async throws -> [Components.Schemas.VoiceResponseModel] {
        switch try await client.getVoices() {
        case .ok(let ok):
            return try ok.body.json.voices
        case .unprocessableContent(let error):
            throw ElevenLabsError.validation(try error.body.json)
        case .undocumented(let status, let payload):
            throw await ElevenLabsError.http(status: status, payload: payload)
        }
    }
}

public enum ElevenLabsError: Error, CustomStringConvertible {
    case missingAPIKey
    case validation(Components.Schemas.HTTPValidationError)
    case http(status: Int, body: String)
    case unexpectedResponse(String)

    static func http(status: Int, payload: UndocumentedPayload) async -> ElevenLabsError {
        var text = ""
        if let body = payload.body, let data = try? await Data(collecting: body, upTo: 1 << 20) {
            text = String(decoding: data, as: UTF8.self)
        }
        return .http(status: status, body: text)
    }

    public var description: String {
        switch self {
        case .missingAPIKey: "ELEVENLABS_API_KEY is not set"
        case .validation(let error): "Validation error: \(error.detail ?? [])"
        case .http(let status, let body): "HTTP \(status): \(body)"
        case .unexpectedResponse(let what): "Unexpected response: \(what)"
        }
    }
}

/// Adds the `xi-api-key` header to every request.
struct APIKeyMiddleware: ClientMiddleware {
    let apiKey: String

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[HTTPField.Name("xi-api-key")!] = apiKey
        return try await next(request, body, baseURL)
    }
}
