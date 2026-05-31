import Fluent

struct AddScanImagePath: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("scans")
            .field("image_path", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("scans")
            .deleteField("image_path")
            .update()
    }
}
