import Fluent
import Vapor

final class Scan: Model, @unchecked Sendable {
    static let schema = "scans"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "place_name")
    var placeName: String

    @OptionalField(key: "latitude")
    var latitude: Double?

    @OptionalField(key: "longitude")
    var longitude: Double?

    @Field(key: "confidence")
    var confidence: Double

    @Field(key: "narration")
    var narration: String

    @Field(key: "style")
    var style: String

    @Field(key: "duration")
    var duration: String

    @OptionalField(key: "image_path")
    var imagePath: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        placeName: String,
        latitude: Double?,
        longitude: Double?,
        confidence: Double,
        narration: String,
        style: String,
        duration: String,
        imagePath: String? = nil
    ) {
        self.id = id
        self.$user.id = userID
        self.placeName = placeName
        self.latitude = latitude
        self.longitude = longitude
        self.confidence = confidence
        self.narration = narration
        self.style = style
        self.duration = duration
        self.imagePath = imagePath
    }
}
