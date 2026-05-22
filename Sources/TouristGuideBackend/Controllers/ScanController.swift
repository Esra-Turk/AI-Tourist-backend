import Foundation
import Vapor

// iOS tarafıyla sabitlenmiş enum değerleri — değiştirilemez.
enum ScanStyle: String, Codable, Sendable {
    case fun
    case historical
    case simple
    case detailed
}

enum ScanDuration: String, Codable, Sendable {
    case thirtySeconds
    case oneMinute
    case threeMinutes
}

struct ScanRequest: Content {
    var image: File
    var latitude: String?
    var longitude: String?
    var style: ScanStyle
    var duration: ScanDuration
}

struct ScanResponse: Content {
    let placeName: String
    let confidence: Double
    let latitude: Double?
    let longitude: Double?
    let narration: String
}

struct ScanController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // Auth, mevcut endpoint'lerle aynı middleware ile yapılır; geçersiz token => 401.
        let protected = routes.grouped(UserAuthenticator(), User.guardMiddleware())
        // Görsel birkaç MB olabileceği için body limiti yükseltilir.
        protected.on(.POST, "scan", body: .collect(maxSize: "10mb"), use: scan)
    }

    @Sendable
    func scan(req: Request) async throws -> ScanResponse {
        let input = try req.content.decode(ScanRequest.self)

        var buffer = input.image.data
        let imageBytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        guard !imageBytes.isEmpty else {
            throw Abort(.badRequest, reason: "Image file is missing or empty.")
        }
        let imageData = Data(imageBytes)

        let userLatitude = input.latitude.flatMap(Double.init)
        let userLongitude = input.longitude.flatMap(Double.init)

        // 1. Landmark tespiti.
        let candidates = try await VisionService.detectLandmarks(imageData: imageData, on: req)

        let placeName: String
        let placeLatitude: Double?
        let placeLongitude: Double?
        let confidence: Double

        if let landmark = bestLandmark(from: candidates, near: userLatitude, userLongitude) {
            // 2a. Vision bir landmark buldu — skoru confidence olarak yansıtılır.
            placeName = landmark.name
            placeLatitude = landmark.latitude
            placeLongitude = landmark.longitude
            confidence = min(max(landmark.score, 0), 1)
        } else if let userLatitude, let userLongitude,
                  let place = try await PlacesService.nearbySearch(
                      latitude: userLatitude, longitude: userLongitude, on: req) {
            // 2b. Vision boş döndü, koordinatla Places fallback. Bu yalnızca bir
            // tahmin olduğu için confidence, iOS'in uyarı eşiği olan 0.6'nın altında tutulur.
            placeName = place.name
            placeLatitude = place.latitude
            placeLongitude = place.longitude
            confidence = 0.5
        } else {
            // Mekan tanınamadı — iOS bunu "Couldn't analyze this photo" ile gösterir.
            throw Abort(.unprocessableEntity, reason: "Couldn't identify a place in this photo.")
        }

        // 3. Anlatım üretimi.
        let narration = try await NarrationService.generate(
            placeName: placeName,
            latitude: placeLatitude,
            longitude: placeLongitude,
            style: input.style,
            duration: input.duration,
            on: req
        )

        return ScanResponse(
            placeName: placeName,
            confidence: confidence,
            latitude: placeLatitude,
            longitude: placeLongitude,
            narration: narration
        )
    }

    // Koordinat geldiyse, ona en yakın adayı seçer — böylece uzaktaki yanlış bir
    // landmark, daha yakın bir eşleşmeye karşı elenir. Koordinat yoksa Vision'ın
    // kendi sıralamasına (en yüksek skor başta) güvenilir.
    private func bestLandmark(
        from candidates: [LandmarkCandidate],
        near latitude: Double?,
        _ longitude: Double?
    ) -> LandmarkCandidate? {
        guard let latitude, let longitude else {
            return candidates.first
        }
        return candidates.min { lhs, rhs in
            distanceKilometers(from: lhs, to: latitude, longitude)
                < distanceKilometers(from: rhs, to: latitude, longitude)
        }
    }

    private func distanceKilometers(
        from candidate: LandmarkCandidate,
        to latitude: Double,
        _ longitude: Double
    ) -> Double {
        guard let candidateLat = candidate.latitude,
              let candidateLng = candidate.longitude else {
            return .greatestFiniteMagnitude
        }
        let earthRadius = 6371.0
        let dLat = (candidateLat - latitude) * .pi / 180
        let dLng = (candidateLng - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * .pi / 180) * cos(candidateLat * .pi / 180)
            * sin(dLng / 2) * sin(dLng / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
