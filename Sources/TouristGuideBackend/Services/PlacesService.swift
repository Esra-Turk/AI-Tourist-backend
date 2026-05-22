import Vapor

// Google Places nearby search ile bulunan bir mekan.
struct PlaceResult: Sendable {
    let name: String
    let latitude: Double
    let longitude: Double
}

// Vision hiç landmark döndürmediğinde, koordinata göre en olası mekanı bulur.
enum PlacesService {
    private struct NearbyResponseBody: Content {
        struct Geometry: Content {
            struct LocationLiteral: Content {
                let lat: Double
                let lng: Double
            }
            let location: LocationLiteral
        }
        struct Place: Content {
            let name: String
            let geometry: Geometry
        }
        let status: String
        let results: [Place]?
    }

    static func nearbySearch(
        latitude: Double,
        longitude: Double,
        on req: Request
    ) async throws -> PlaceResult? {
        guard let apiKey = Environment.get("GOOGLE_API_KEY"), !apiKey.isEmpty else {
            req.logger.error("GOOGLE_API_KEY is not configured")
            throw Abort(.internalServerError, reason: "Place lookup is not configured.")
        }

        let uri = URI(string: "https://maps.googleapis.com/maps/api/place/nearbysearch/json"
            + "?location=\(latitude),\(longitude)&radius=150&key=\(apiKey)")

        let clientResponse: ClientResponse
        do {
            clientResponse = try await req.client.get(uri)
        } catch {
            req.logger.error("Places API request failed: \(error)")
            throw Abort(.badGateway, reason: "Place lookup failed.")
        }

        guard clientResponse.status == .ok else {
            req.logger.error("Places API returned non-OK status: \(clientResponse.status.code)")
            throw Abort(.badGateway, reason: "Place lookup failed.")
        }

        let decoded: NearbyResponseBody
        do {
            decoded = try clientResponse.content.decode(NearbyResponseBody.self)
        } catch {
            req.logger.error("Places API response could not be decoded: \(error)")
            throw Abort(.badGateway, reason: "Place lookup failed.")
        }

        // ZERO_RESULTS "yakında bir şey yok" anlamına gelir, bir hata değil.
        guard decoded.status == "OK" || decoded.status == "ZERO_RESULTS" else {
            req.logger.error("Places API returned status \(decoded.status)")
            throw Abort(.badGateway, reason: "Place lookup failed.")
        }

        guard let place = decoded.results?.first else {
            return nil
        }

        return PlaceResult(
            name: place.name,
            latitude: place.geometry.location.lat,
            longitude: place.geometry.location.lng
        )
    }
}
