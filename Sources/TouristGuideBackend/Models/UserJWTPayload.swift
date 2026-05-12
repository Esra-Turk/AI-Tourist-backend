import Vapor
import JWT

struct UserJWTPayload: JWTPayload, Authenticatable {
    var subject: SubjectClaim
    var expiration: ExpirationClaim

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try self.expiration.verifyNotExpired()
    }

    var userID: UUID? {
        UUID(uuidString: self.subject.value)
    }
}