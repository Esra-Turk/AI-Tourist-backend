import Foundation
import Vapor

// Tespit edilen mekan için style/duration'a uygun sesli rehber anlatımı üretir.
enum NarrationService {
    // Sabit sistem talimatı: prompt caching ile önbelleğe alınır. Değişken
    // kısım (mekan adı, style, duration) yalnızca user mesajında yer alır.
    private static let systemPrompt = """
    You are the narration writer for Scana, a mobile travel-guide app. A traveler \
    has photographed a place, the app has identified it, and your job is to produce \
    the script that the app reads aloud to them through text-to-speech.

    OUTPUT RULES
    - Return ONLY the narration text itself. No title, no heading, no preamble, no \
    sign-off, no quotation marks, no markdown, no bullet points, no stage directions.
    - The text is converted directly to speech, so write flowing, natural spoken \
    prose in complete sentences.
    - Write in English.
    - Address the listener directly and warmly, as if standing next to them at the place.
    - Be accurate. Rely on well-established facts. If you are not certain of a \
    specific detail (a date, a name, a number), speak in general terms instead of \
    inventing specifics.
    - If a place cannot carry the requested length with real substance, write the \
    best shorter narration rather than padding with filler.

    LENGTH
    The app reads roughly 150 words per minute. Match the requested length:
    - thirtySeconds: about 75 words.
    - oneMinute: about 150 words.
    - threeMinutes: about 450 words.

    STYLE
    Match the requested style:
    - fun: playful, warm and conversational, like an enthusiastic friend showing the \
    traveler around; light humor and vivid, surprising details are welcome.
    - historical: focused on history — origins, key dates, the people and events tied \
    to the place, and why it matters. Knowledgeable but accessible, never dry.
    - simple: short, plain and easy to follow. Everyday words, clear sentences. Ideal \
    for casual listeners or non-native English speakers. Cover only the essentials.
    - detailed: comprehensive and in-depth. Cover history, architecture or design, \
    cultural significance and context, and what makes the place notable.

    You will be given the place name, an optional approximate location, the requested \
    style, and the requested length. Use the location only as context to ground or \
    disambiguate the narration; the narration is about the place, not the coordinates.
    """

    private struct AnthropicRequestBody: Content {
        struct CacheControl: Content { let type: String }
        struct SystemBlock: Content {
            let type: String
            let text: String
            let cacheControl: CacheControl

            enum CodingKeys: String, CodingKey {
                case type, text
                case cacheControl = "cache_control"
            }
        }
        struct Message: Content {
            let role: String
            let content: String
        }
        let model: String
        let maxTokens: Int
        let system: [SystemBlock]
        let messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model, system, messages
            case maxTokens = "max_tokens"
        }
    }

    private struct AnthropicResponseBody: Content {
        struct ContentBlock: Content {
            let type: String
            let text: String?
        }
        let content: [ContentBlock]
    }

    static func generate(
        placeName: String,
        latitude: Double?,
        longitude: Double?,
        style: ScanStyle,
        duration: ScanDuration,
        on req: Request
    ) async throws -> String {
        guard let apiKey = Environment.get("ANTHROPIC_API_KEY"), !apiKey.isEmpty else {
            req.logger.error("ANTHROPIC_API_KEY is not configured")
            throw Abort(.internalServerError, reason: "Narration is not configured.")
        }
        let model = Environment.get("LLM_MODEL") ?? "claude-opus-4-7"

        var userLines = ["Write the narration now.", "", "Place: \(placeName)"]
        if let latitude, let longitude {
            userLines.append("Approximate location: \(latitude), \(longitude)")
        }
        userLines.append("Style: \(style.rawValue)")
        userLines.append("Length: \(duration.rawValue)")

        let payload = AnthropicRequestBody(
            model: model,
            maxTokens: 1500,
            system: [
                .init(type: "text", text: systemPrompt, cacheControl: .init(type: "ephemeral"))
            ],
            messages: [
                .init(role: "user", content: userLines.joined(separator: "\n"))
            ]
        )

        var headers = HTTPHeaders()
        headers.add(name: "x-api-key", value: apiKey)
        headers.add(name: "anthropic-version", value: "2023-06-01")

        let uri = URI(string: "https://api.anthropic.com/v1/messages")
        let clientResponse: ClientResponse
        do {
            clientResponse = try await req.client.post(uri, headers: headers) { clientRequest in
                try clientRequest.content.encode(payload)
            }
        } catch {
            req.logger.error("Anthropic API request failed: \(error)")
            throw Abort(.badGateway, reason: "Narration generation failed.")
        }

        guard clientResponse.status == .ok else {
            req.logger.error("Anthropic API returned non-OK status: \(clientResponse.status.code)")
            throw Abort(.badGateway, reason: "Narration generation failed.")
        }

        let decoded: AnthropicResponseBody
        do {
            decoded = try clientResponse.content.decode(AnthropicResponseBody.self)
        } catch {
            req.logger.error("Anthropic API response could not be decoded: \(error)")
            throw Abort(.badGateway, reason: "Narration generation failed.")
        }

        let narration = decoded.content
            .first { $0.type == "text" }?
            .text?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let narration, !narration.isEmpty else {
            req.logger.error("Anthropic API returned no narration text")
            throw Abort(.badGateway, reason: "Narration generation failed.")
        }

        return narration
    }
}
