import NIOSSL
import Fluent
import FluentPostgresDriver
import Vapor
import JWT

// configures your application
public func configure(_ app: Application) async throws {
    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    app.databases.use(DatabaseConfigurationFactory.postgres(configuration: .init(
        hostname: Environment.get("DATABASE_HOST") ?? "localhost",
        port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? SQLPostgresConfiguration.ianaPortNumber,
        username: Environment.get("DATABASE_USERNAME") ?? "vapor_username",
        password: Environment.get("DATABASE_PASSWORD") ?? "vapor_password",
        database: Environment.get("DATABASE_NAME") ?? "vapor_database",
        tls: .prefer(try .init(configuration: .clientDefault)))
    ), as: .psql)

    // JWT signing key - kendi token'larımızı imzalamak için
    let jwtSecret = Environment.get("JWT_SECRET") ?? "dev-only-secret-change-in-production"
    await app.jwt.keys.add(hmac: HMACKey(stringLiteral: jwtSecret), digestAlgorithm: .sha256)
    
    // Apple Sign In için bundle ID
    if let bundleID = Environment.get("APPLE_APP_BUNDLE_ID") {
        app.jwt.apple.applicationIdentifier = bundleID
    }
    
    app.migrations.add(CreateTodo())
    app.migrations.add(CreateUser())

    // register routes
    try routes(app)
}
