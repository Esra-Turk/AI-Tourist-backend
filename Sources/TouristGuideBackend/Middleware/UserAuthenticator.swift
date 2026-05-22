import Vapor
import Fluent
import JWT

// JWT'yi doğrular ve kullanıcının veritabanında hâlâ var olduğunu kontrol eder.
// Silinmiş bir kullanıcının token'i geçerli olsa bile authenticate edilmez.
struct UserAuthenticator: AsyncBearerAuthenticator {
    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        let payload: UserJWTPayload
        do {
            payload = try await request.jwt.verify(bearer.token, as: UserJWTPayload.self)
        } catch {
            return
        }

        guard let userID = payload.userID,
              let user = try await User.find(userID, on: request.db) else {
            return
        }

        request.auth.login(user)
    }
}
