import Fluent
import Vapor 

final class User: Model, Content, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "apple_user_id")
    var appleUserID: String

    @OptionalField(key: "email")
    var email: String?

    @OptionalField(key: "name")
    var name: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updateAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        appleUserID: String,
        email: String? = nil,
        name: String? = nil
    ) {
        self.id = id
        self.appleUserID = appleUserID
        self.email = email
        self.name = name
    }

}