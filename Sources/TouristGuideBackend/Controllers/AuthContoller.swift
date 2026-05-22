import Vapor
import Fluent
import JWT

struct AppleSignInReqeust: Content {
    let identityToken: String
    let name: String?
}

struct AuthResponse: Content {
    let token: String
    let user: UserDTO
}

struct UserDTO: Content {
    let id: UUID
    let email: String?
    let name: String?
}

struct AuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("auth")
        auth.post("apple", use: signInWithApple)
    
        // Korumalı route'lar
        let protected = auth.grouped(UserAuthenticator(), User.guardMiddleware())
        protected.get("me", use: me)
        protected.delete("me", use: deleteMe)
    }

    @Sendable
    func me(req: Request) async throws -> UserDTO {
        let user = try req.auth.require(User.self)
        return UserDTO(
            id: try user.requireID(),
            email: user.email,
            name: user.name
        )
    }

    @Sendable
    func deleteMe(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        try await user.delete(on: req.db)
        return .noContent
    }

    @Sendable
    func signInWithApple(req: Request) async throws -> AuthResponse {
        let body = try req.content.decode(AppleSignInReqeust.self)
        
        let appleToken = try await req.jwt.apple.verify(body.identityToken)
        let appleUserID = appleToken.subject.value

        let user: User
        if let existing = try await User.query(on: req.db)
            .filter(\.$appleUserID == appleUserID)
            .first() {
            user = existing
        } else {
            user = User(
                appleUserID: appleUserID,
                email: appleToken.email,
                name: body.name
            )
            try await user.save(on: req.db)
        }

        // 3. Kendi JWT'mizi üret
        let payload = UserJWTPayload(
            subject: SubjectClaim(value: try user.requireID().uuidString),
            expiration: ExpirationClaim(value: Date().addingTimeInterval(60 * 60 * 24 * 7))  // 7 gün
        )
        let token = try await req.jwt.sign(payload)

        return AuthResponse(
            token: token, 
            user: UserDTO(
                id: try user.requireID(), 
                email: user.email, 
                name: user.name
            )
        )
    }
}