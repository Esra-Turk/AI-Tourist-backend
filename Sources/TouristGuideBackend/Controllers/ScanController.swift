import Foundation
import Fluent
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

struct ScanHistoryItem: Content {
    let id: UUID
    let placeName: String
    let latitude: Double?
    let longitude: Double?
    let confidence: Double
    let narration: String
    let style: String
    let duration: String
    let createdAt: Date?
}

struct ScanController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // Auth, mevcut endpoint'lerle aynı middleware ile yapılır; geçersiz token => 401.
        let protected = routes.grouped(UserAuthenticator(), User.guardMiddleware())
        // Görsel birkaç MB olabileceği için body limiti yükseltilir.
        protected.on(.POST, "scan", body: .collect(maxSize: "10mb"), use: scan)

        // History endpoint'leri — kullanıcının kendi taramaları.
        let scans = protected.grouped("scans")
        scans.get(use: history)
        scans.group(":scanID") { scan in
            scan.get(use: detail)
            scan.delete(use: delete)
        }
    }

    @Sendable
    func history(req: Request) async throws -> [ScanHistoryItem] {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        let scans = try await Scan.query(on: req.db)
            .filter(\.$user.$id == userID)
            .sort(\.$createdAt, .descending)
            .all()
        return try scans.map(Self.makeHistoryItem)
    }

    @Sendable
    func detail(req: Request) async throws -> ScanHistoryItem {
        return try Self.makeHistoryItem(from: try await loadOwnedScan(req: req))
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let scan = try await loadOwnedScan(req: req)
        try await scan.delete(on: req.db)
        return .noContent
    }

    private func loadOwnedScan(req: Request) async throws -> Scan {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        guard let scanID = req.parameters.get("scanID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid scan id.")
        }
        guard let scan = try await Scan.query(on: req.db)
            .filter(\.$id == scanID)
            .filter(\.$user.$id == userID)
            .first() else {
            throw Abort(.notFound)
        }
        return scan
    }

    private static func makeHistoryItem(from scan: Scan) throws -> ScanHistoryItem {
        ScanHistoryItem(
            id: try scan.requireID(),
            placeName: scan.placeName,
            latitude: scan.latitude,
            longitude: scan.longitude,
            confidence: scan.confidence,
            narration: scan.narration,
            style: scan.style,
            duration: scan.duration,
            createdAt: scan.createdAt
        )
    }

    @Sendable
    func scan(req: Request) async throws -> ScanResponse {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
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
            req.logger.info("[scan] place identified via CLOUD_VISION: \(landmark.name) (score=\(landmark.score))")
            placeName = landmark.name
            placeLatitude = landmark.latitude
            placeLongitude = landmark.longitude
            confidence = min(max(landmark.score, 0), 1)
        } else if let identified = try await NarrationService.identifyPlace(
            imageData: imageData,
            latitude: userLatitude,
            longitude: userLongitude,
            on: req
        ) {
            // 2b. Vision landmark bulamadı ama multimodal LLM görselden bir mekan
            // çıkarabildi. Koordinat bilgisi LLM'den gelmediği için kullanıcının
            // gönderdiği koordinatı (varsa) yansıtırız; emin olmadığı durumlarda
            // model UNKNOWN döndüğü için buraya yalnızca pozitif tanımlamalar düşer.
            req.logger.info("[scan] place identified via LLM_VISION: \(identified)")
            placeName = identified
            placeLatitude = userLatitude
            placeLongitude = userLongitude
            confidence = 0.5
        } else if let userLatitude, let userLongitude,
                  let place = try await PlacesService.nearbySearch(
                      latitude: userLatitude, longitude: userLongitude, on: req) {
            // 2c. LLM de bulamadı, son çare koordinatla Places nearby search. Bu
            // yalnızca bir tahmin olduğu için confidence iOS uyarı eşiğinin altında tutulur.
            req.logger.info("[scan] place identified via PLACES_NEARBY: \(place.name)")
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

        // 4. Tarama sonucunu kullanıcıya bağlı olarak kaydet.
        let scan = Scan(
            userID: userID,
            placeName: placeName,
            latitude: placeLatitude,
            longitude: placeLongitude,
            confidence: confidence,
            narration: narration,
            style: input.style.rawValue,
            duration: input.duration.rawValue
        )
        try await scan.save(on: req.db)

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
