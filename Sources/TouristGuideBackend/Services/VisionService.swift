import Foundation
import Vapor

// Google Cloud Vision LANDMARK_DETECTION sonucundaki tek bir aday.
struct LandmarkCandidate: Sendable {
    let name: String
    let score: Double
    let latitude: Double?
    let longitude: Double?
}

// Görseli Google Cloud Vision API'ye gönderip landmark adaylarını döner.
enum VisionService {
    private struct AnnotateRequestBody: Content {
        struct ImageContent: Content { let content: String }
        struct Feature: Content {
            let type: String
            let maxResults: Int
        }
        struct Entry: Content {
            let image: ImageContent
            let features: [Feature]
        }
        let requests: [Entry]
    }

    private struct AnnotateResponseBody: Content {
        struct LatLng: Content {
            let latitude: Double
            let longitude: Double
        }
        struct Location: Content { let latLng: LatLng }
        struct Landmark: Content {
            let description: String
            let score: Double
            let locations: [Location]?
        }
        struct Entry: Content {
            let landmarkAnnotations: [Landmark]?
        }
        let responses: [Entry]
    }

    static func detectLandmarks(imageData: Data, on req: Request) async throws -> [LandmarkCandidate] {
        guard let apiKey = Environment.get("GOOGLE_API_KEY"), !apiKey.isEmpty else {
            req.logger.error("GOOGLE_API_KEY is not configured")
            throw Abort(.internalServerError, reason: "Landmark detection is not configured.")
        }

        let payload = AnnotateRequestBody(requests: [
            .init(
                image: .init(content: imageData.base64EncodedString()),
                features: [.init(type: "LANDMARK_DETECTION", maxResults: 5)]
            )
        ])

        let uri = URI(string: "https://vision.googleapis.com/v1/images:annotate?key=\(apiKey)")
        let clientResponse: ClientResponse
        do {
            clientResponse = try await req.client.post(uri) { clientRequest in
                try clientRequest.content.encode(payload)
            }
        } catch {
            req.logger.error("Vision API request failed: \(error)")
            throw Abort(.badGateway, reason: "Landmark detection failed.")
        }

        guard clientResponse.status == .ok else {
            req.logger.error("Vision API returned non-OK status: \(clientResponse.status.code)")
            throw Abort(.badGateway, reason: "Landmark detection failed.")
        }

        let decoded: AnnotateResponseBody
        do {
            decoded = try clientResponse.content.decode(AnnotateResponseBody.self)
        } catch {
            req.logger.error("Vision API response could not be decoded: \(error)")
            throw Abort(.badGateway, reason: "Landmark detection failed.")
        }

        // landmarkAnnotations hiç landmark bulunmadığında yanıtta yer almaz.
        guard let landmarks = decoded.responses.first?.landmarkAnnotations else {
            return []
        }

        return landmarks.map { landmark in
            let latLng = landmark.locations?.first?.latLng
            return LandmarkCandidate(
                name: landmark.description,
                score: landmark.score,
                latitude: latLng?.latitude,
                longitude: latLng?.longitude
            )
        }
    }
}
