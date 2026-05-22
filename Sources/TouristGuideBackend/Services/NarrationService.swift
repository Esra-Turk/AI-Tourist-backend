import Foundation
import Vapor

// Tespit edilen mekan için style/duration'a uygun sesli rehber anlatımını
// OpenAI Chat Completions API üzerinden üretir. Sistem talimatı sabit
// tutulduğunda OpenAI 1024+ token'lık prefix'i otomatik cache'ler.
enum NarrationService {
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

    private struct ChatRequestBody: Content {
        struct Message: Content {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let maxTokens: Int

        enum CodingKeys: String, CodingKey {
            case model, messages
            case maxTokens = "max_tokens"
        }
    }

    private struct ChatResponseBody: Content {
        struct Choice: Content {
            struct Message: Content {
                let role: String
                let content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    // Cloud Vision landmark detection boş döndüğünde son çare olarak görseli
    // doğrudan multimodal LLM'e gönderir ve mekan adını çıkartmaya çalışır.
    // Model emin değilse "UNKNOWN" döner; bu durumda nil verilir, böylece çağıran
    // taraf başka bir fallback'e geçebilir veya hata üretebilir.
    private struct VisionIdentifyBody: Content {
        struct Message: Content {
            struct ContentPart: Content {
                struct ImageURL: Content {
                    let url: String
                }
                let type: String
                let text: String?
                let imageUrl: ImageURL?

                enum CodingKeys: String, CodingKey {
                    case type, text
                    case imageUrl = "image_url"
                }
            }
            let role: String
            let content: [ContentPart]
        }
        let model: String
        let messages: [Message]
        let maxTokens: Int

        enum CodingKeys: String, CodingKey {
            case model, messages
            case maxTokens = "max_tokens"
        }
    }

    static func identifyPlace(
        imageData: Data,
        latitude: Double?,
        longitude: Double?,
        on req: Request
    ) async throws -> String? {
        guard let apiKey = Environment.get("OPENAI_API_KEY"), !apiKey.isEmpty else {
            req.logger.error("OPENAI_API_KEY is not configured")
            return nil
        }
        let model = Environment.get("LLM_VISION_MODEL").flatMap { $0.isEmpty ? nil : $0 } ?? "gpt-4o"

        var promptLines = [
            "You are helping identify a real-world place from a tourist's photo.",
            "Look at the image and determine the specific named place (landmark, museum, square, building, neighborhood, natural site, etc.) it depicts.",
            "Use any visible clues: architecture, signage, text, layout, surroundings.",
            "Rules:",
            "- If you are confident, respond with ONLY the place name on a single line. Include the city or country if it helps disambiguate (e.g. \"Galata Tower, Istanbul\").",
            "- If you are NOT confident, or the image is too generic to identify a specific place, respond with exactly UNKNOWN.",
            "- Do not guess. Do not invent. No explanations, no punctuation beyond the name itself."
        ]
        if let latitude, let longitude {
            promptLines.append("The photo was taken approximately at coordinates: \(latitude), \(longitude). Use this only as a hint.")
        }
        let prompt = promptLines.joined(separator: "\n")

        let base64 = imageData.base64EncodedString()
        let dataUrl = "data:image/jpeg;base64,\(base64)"

        let payload = VisionIdentifyBody(
            model: model,
            messages: [
                .init(role: "user", content: [
                    .init(type: "text", text: prompt, imageUrl: nil),
                    .init(type: "image_url", text: nil, imageUrl: .init(url: dataUrl))
                ])
            ],
            maxTokens: 60
        )

        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(apiKey)")

        let uri = URI(string: "https://api.openai.com/v1/chat/completions")
        let clientResponse: ClientResponse
        do {
            clientResponse = try await req.client.post(uri, headers: headers) { clientRequest in
                try clientRequest.content.encode(payload)
            }
        } catch {
            req.logger.error("OpenAI vision identify request failed: \(error)")
            return nil
        }

        guard clientResponse.status == .ok else {
            let bodyString = clientResponse.body
                .flatMap { $0.getString(at: $0.readerIndex, length: $0.readableBytes) }
                ?? "(empty body)"
            req.logger.error("OpenAI vision identify non-OK: \(clientResponse.status.code) body: \(bodyString)")
            return nil
        }

        let decoded: ChatResponseBody
        do {
            decoded = try clientResponse.content.decode(ChatResponseBody.self)
        } catch {
            req.logger.error("OpenAI vision identify decode failed: \(error)")
            return nil
        }

        let raw = decoded.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }

        let normalized = raw.uppercased()
        if normalized == "UNKNOWN" || normalized.hasPrefix("UNKNOWN") {
            return nil
        }
        // Modelin tek satır dönmesi beklenir; yine de ilk satırı alıp tırnakları temizliyoruz.
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        let cleaned = firstLine
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.“”‘’ "))
        return cleaned.isEmpty ? nil : cleaned
    }

    static func generate(
        placeName: String,
        latitude: Double?,
        longitude: Double?,
        style: ScanStyle,
        duration: ScanDuration,
        on req: Request
    ) async throws -> String {
        guard let apiKey = Environment.get("OPENAI_API_KEY"), !apiKey.isEmpty else {
            req.logger.error("OPENAI_API_KEY is not configured")
            throw Abort(.internalServerError, reason: "Narration is not configured.")
        }
        // Boş env değeri de unset gibi davranmalı — Environment.get boş string'i
        // nil'e çevirmez, bu yüzden açık şekilde boş kontrolü yapıyoruz.
        let model = Environment.get("LLM_MODEL").flatMap { $0.isEmpty ? nil : $0 } ?? "gpt-4o"

        var userLines = ["Write the narration now.", "", "Place: \(placeName)"]
        if let latitude, let longitude {
            userLines.append("Approximate location: \(latitude), \(longitude)")
        }
        userLines.append("Style: \(style.rawValue)")
        userLines.append("Length: \(duration.rawValue)")

        let payload = ChatRequestBody(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userLines.joined(separator: "\n"))
            ],
            maxTokens: 1500
        )

        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(apiKey)")

        let uri = URI(string: "https://api.openai.com/v1/chat/completions")
        let clientResponse: ClientResponse
        do {
            clientResponse = try await req.client.post(uri, headers: headers) { clientRequest in
                try clientRequest.content.encode(payload)
            }
        } catch {
            req.logger.error("OpenAI API request failed: \(error)")
            throw Abort(.badGateway, reason: "Narration generation failed.")
        }

        guard clientResponse.status == .ok else {
            let bodyString = clientResponse.body
                .flatMap { $0.getString(at: $0.readerIndex, length: $0.readableBytes) }
                ?? "(empty body)"
            req.logger.error("OpenAI API returned non-OK status: \(clientResponse.status.code) body: \(bodyString)")
            throw Abort(.badGateway, reason: "Narration generation failed.")
        }

        let decoded: ChatResponseBody
        do {
            decoded = try clientResponse.content.decode(ChatResponseBody.self)
        } catch {
            req.logger.error("OpenAI API response could not be decoded: \(error)")
            throw Abort(.badGateway, reason: "Narration generation failed.")
        }

        let narration = decoded.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let narration, !narration.isEmpty else {
            req.logger.error("OpenAI API returned no narration text")
            throw Abort(.badGateway, reason: "Narration generation failed.")
        }

        return narration
    }
}
