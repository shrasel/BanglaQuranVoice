import Foundation
import CryptoKit

struct AzureSpeechConfiguration {
    let apiKey: String
    let region: String
    let voiceName: String

    var endpointURL: URL {
        URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/v1")!
    }

    static func load() -> AzureSpeechConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        if let key = environment["AZURE_TTS_KEY"],
           let region = environment["AZURE_TTS_REGION"],
           !key.isEmpty,
           !region.isEmpty {
            return AzureSpeechConfiguration(apiKey: key, region: region, voiceName: "bn-BD-PradeepNeural")
        }

        if let info = Bundle.main.infoDictionary,
           let key = info["AzureSpeechKey"] as? String,
           let region = info["AzureSpeechRegion"] as? String,
           !key.isEmpty,
           !region.isEmpty {
            return AzureSpeechConfiguration(apiKey: key, region: region, voiceName: "bn-BD-PradeepNeural")
        }

        return nil
    }
}

final class AzureBanglaSpeechService {
    enum ServiceError: Error, LocalizedError {
        case missingConfiguration
        case invalidResponse(statusCode: Int)

        var errorDescription: String? {
            switch self {
            case .missingConfiguration:
                return "Azure Speech configuration is missing."
            case .invalidResponse(let statusCode):
                return "Azure Speech returned an unexpected status code: \(statusCode)."
            }
        }
    }

    private let configuration: AzureSpeechConfiguration?
    private let session: URLSession
    private let fileManager: FileManager
    private let cacheDirectory: URL

    var isConfigured: Bool {
        configuration != nil
    }

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
        self.configuration = AzureSpeechConfiguration.load()

        let baseDirectory: URL
        if let caches = try? fileManager.url(for: .cachesDirectory,
                                             in: .userDomainMask,
                                             appropriateFor: nil,
                                             create: true) {
            baseDirectory = caches
        } else {
            baseDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        }

        let directory = baseDirectory.appendingPathComponent("QuranBanglaPlayer/AzureBanglaTTS", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        self.cacheDirectory = directory
    }

    func synthesize(text: String, surahId: Int, ayahNumber: Int) async throws -> URL {
        guard let configuration else {
            throw ServiceError.missingConfiguration
        }

        let hashInput = "s\(surahId)-a\(ayahNumber)-\(text)"
        let cacheURL = cacheDirectory.appendingPathComponent(hashedFilename(for: hashInput)).appendingPathExtension("mp3")
        if fileManager.fileExists(atPath: cacheURL.path) {
            return cacheURL
        }

        var request = URLRequest(url: configuration.endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue(configuration.region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region")
        request.setValue("audio-48khz-96kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        request.setValue("BanglaQuran/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = makeSSMLBody(text: text, voiceName: configuration.voiceName).data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse(statusCode: -1)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.invalidResponse(statusCode: http.statusCode)
        }

        try data.write(to: cacheURL, options: .atomic)
        return cacheURL
    }

    private func hashedFilename(for value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func makeSSMLBody(text: String, voiceName: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <speak version="1.0" xml:lang="bn-BD">
            <voice name="\(voiceName)">
                <prosody rate="medium">\(escaped)</prosody>
            </voice>
        </speak>
        """
    }
}
