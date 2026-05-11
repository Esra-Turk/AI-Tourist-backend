import Fluent

struct CreateUser: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .id()
            .field("apple_user_id", .string, .required)
            .field("email", .string)
            .field("name", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "apple_user_id")
            .create()

    }

    func revert(on database: Database) async throws {
        try await database.schema("users").delete()
    }
}
