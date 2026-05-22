import Fluent

struct CreateScan: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("scans")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("place_name", .string, .required)
            .field("latitude", .double)
            .field("longitude", .double)
            .field("confidence", .double, .required)
            .field("narration", .string, .required)
            .field("style", .string, .required)
            .field("duration", .string, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("scans").delete()
    }
}
