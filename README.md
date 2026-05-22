# TouristGuideBackend — Proje Dokümantasyonu

Swift [Vapor](https://vapor.codes) framework'ü ile geliştirilen turist rehberi uygulamasının backend servisi.

## İçindekiler

- [Teknoloji Yığını](#teknoloji-yığını)
- [Kurulum ve Çalıştırma](#kurulum-ve-çalıştırma)
- [Ortam Değişkenleri](#ortam-değişkenleri)
- [Veritabanı Modelleri](#veritabanı-modelleri)
- [Kimlik Doğrulama (Auth)](#kimlik-doğrulama-auth)
- [API Endpoint'leri](#api-endpointleri)
- [Proje Yapısı](#proje-yapısı)

## Teknoloji Yığını

| Bileşen        | Teknoloji                         |
|----------------|-----------------------------------|
| Dil            | Swift                             |
| Framework      | Vapor                             |
| ORM            | Fluent                            |
| Veritabanı     | PostgreSQL (FluentPostgresDriver) |
| Kimlik doğrulama | JWT + Sign in with Apple        |
| Konteyner      | Docker / docker-compose           |

## Kurulum ve Çalıştırma

```bash
# Derleme
swift build

# Sunucuyu başlatma
swift run

# Testleri çalıştırma
swift test
```

Docker ile:

```bash
docker-compose up
```

## Ortam Değişkenleri

`configure.swift` içinden okunan değişkenler (`.env` dosyasında tanımlanır):

| Değişken               | Açıklama                              | Varsayılan                              |
|------------------------|---------------------------------------|-----------------------------------------|
| `DATABASE_HOST`        | PostgreSQL sunucu adresi              | `localhost`                             |
| `DATABASE_PORT`        | PostgreSQL portu                      | IANA varsayılan portu                   |
| `DATABASE_USERNAME`    | Veritabanı kullanıcı adı              | `vapor_username`                        |
| `DATABASE_PASSWORD`    | Veritabanı şifresi                    | `vapor_password`                        |
| `DATABASE_NAME`        | Veritabanı adı                        | `vapor_database`                        |
| `JWT_SECRET`           | JWT imzalama anahtarı (HMAC-SHA256)   | `dev-only-secret-change-in-production`  |
| `APPLE_APP_BUNDLE_ID`  | Apple Sign In için uygulama bundle ID | —                                       |
| `GOOGLE_API_KEY`       | Google Cloud Vision + Places API anahtarı | —                                   |
| `ANTHROPIC_API_KEY`    | Anthropic API anahtarı (anlatım üretimi) | —                                    |
| `LLM_MODEL`            | Anlatım için kullanılan LLM modeli    | `claude-opus-4-7`                       |

> **Not:** Üretim ortamında `JWT_SECRET` mutlaka değiştirilmelidir.

## Veritabanı Modelleri

### User (`users` tablosu)

Migration: `CreateUser`

| Alan            | Tip      | Açıklama                          |
|-----------------|----------|-----------------------------------|
| `id`            | UUID     | Birincil anahtar                  |
| `apple_user_id` | String   | Apple'dan gelen benzersiz kullanıcı kimliği |
| `email`         | String?  | E-posta (opsiyonel)               |
| `name`          | String?  | İsim (opsiyonel)                  |
| `created_at`    | Date     | Oluşturulma zamanı (otomatik)     |
| `updated_at`    | Date     | Güncellenme zamanı (otomatik)     |

### Todo (`todos` tablosu)

Migration: `CreateTodo`. Vapor şablonundan gelen örnek modeldir; turist rehberi iş mantığına ait değildir.

| Alan    | Tip    | Açıklama          |
|---------|--------|-------------------|
| `id`    | UUID   | Birincil anahtar  |
| `title` | String | Görev başlığı     |

## Kimlik Doğrulama (Auth)

Uygulama **Sign in with Apple** ile giriş yapar ve kendi **JWT** token'ını üretir.

**Akış:**

1. İstemci, Apple'dan aldığı `identityToken`'ı `POST /auth/apple`'a gönderir.
2. Sunucu token'ı Apple ile doğrular ve `apple_user_id`'yi çıkarır.
3. Kullanıcı veritabanında varsa getirilir, yoksa yeni kayıt oluşturulur.
4. Sunucu kendi JWT'sini üretir (**7 gün** geçerli) ve kullanıcı bilgisiyle birlikte döner.
5. Korumalı endpoint'lere `Authorization: Bearer <token>` başlığıyla erişilir.

JWT payload (`UserJWTPayload`): `subject` alanında kullanıcının UUID'si, `expiration` alanında son kullanım tarihi tutulur.

### Korumalı route'lar ve kullanıcı doğrulama

Korumalı route'lar `UserAuthenticator` (özel `AsyncBearerAuthenticator`) + `User.guardMiddleware()` ile korunur. `UserAuthenticator`:

1. `Authorization: Bearer <token>` başlığındaki JWT'yi doğrular (imza + son kullanım tarihi).
2. Token'daki `userID` ile kullanıcıyı **veritabanından yükler**.
3. Kullanıcı bulunursa `User` modelini authenticate eder; bulunamazsa hiçbir şey yapmaz.

Bu sayede **silinmiş bir kullanıcının token'i hâlâ geçerli olsa bile** korumalı route'lara erişemez — `guardMiddleware()` `401 Unauthorized` döner. Kullanıcı varlığı tek bir yerde kontrol edildiği için her endpoint'te ayrıca kontrol gerekmez; handler içinde `req.auth.require(User.self)` ile doğrudan kullanıcıya erişilir.

## API Endpoint'leri

### Auth

#### `POST /auth/apple` — Apple ile giriş / kayıt

İstek gövdesi:

```json
{
  "identityToken": "<apple-identity-token>",
  "name": "Esra Türk"
}
```

Yanıt `200 OK`:

```json
{
  "token": "<jwt-token>",
  "user": {
    "id": "uuid",
    "email": "ornek@mail.com",
    "name": "Esra Türk"
  }
}
```

#### `GET /auth/me` — Giriş yapan kullanıcının bilgileri 🔒

JWT gerektirir. Yanıt `200 OK`:

```json
{
  "id": "uuid",
  "email": "ornek@mail.com",
  "name": "Esra Türk"
}
```

Hata: token geçersiz/süresi dolmuş ya da kullanıcı silinmişse `401 Unauthorized`.

#### `DELETE /auth/me` — Giriş yapan kullanıcıyı sil 🔒

JWT gerektirir. Token'daki kullanıcıyı veritabanından siler.

- Başarılı: `204 No Content`
- Hata: token geçersiz/süresi dolmuş ya da kullanıcı silinmişse `401 Unauthorized`

### Scan

#### `POST /scan` — Fotoğraftan mekan tanıma ve sesli rehber anlatımı 🔒

JWT gerektirir. `multipart/form-data` ile fotoğraf ve tercihler gönderilir.

İstek alanları (`multipart/form-data`):

| Alan        | Tip          | Zorunlu | Açıklama                                          |
|-------------|--------------|---------|---------------------------------------------------|
| `image`     | JPEG dosyası | Evet    | Mekanın fotoğrafı                                 |
| `latitude`  | String       | Hayır   | Cihazın enlemi (ondalık derece)                   |
| `longitude` | String       | Hayır   | Cihazın boylamı (ondalık derece)                  |
| `style`     | String       | Evet    | `fun` \| `historical` \| `simple` \| `detailed`   |
| `duration`  | String       | Evet    | `thirtySeconds` \| `oneMinute` \| `threeMinutes`  |

İşleyiş:

1. Görsel Google Cloud Vision'a `LANDMARK_DETECTION` ile gönderilir.
2. Koordinat geldiyse landmark adayları konuma göre teyit edilir. Vision hiç landmark bulamaz ve koordinat varsa Google Places nearby search ile en olası mekan bulunur.
3. Tespit edilen mekan, `style` ve `duration`'a uygun bir anlatım için LLM'e verilir (sabit sistem talimatı prompt caching ile önbelleğe alınır).

Yanıt `200 OK`:

```json
{
  "placeName": "Hagia Sophia",
  "confidence": 0.92,
  "latitude": 41.0086,
  "longitude": 28.9802,
  "narration": "..."
}
```

- `confidence`: 0–1 arası Vision skoru. Places fallback'i kullanıldıysa 0.6'nın altında bir değer döner (iOS bu eşiğin altında "emin değiliz" uyarısı gösterir).
- `latitude`/`longitude`: tespit edilen mekanın koordinatı; bilinmiyorsa `null`.
- Anlatım İngilizce döner; `ScanResult` modelinde dil alanı yoktur.

Hatalar:

- Mekan tanınamazsa `422 Unprocessable Entity`.
- Token geçersiz/süresi dolmuşsa `401 Unauthorized`.
- Vision/Places/LLM servisleri başarısız olursa `502 Bad Gateway`.

### Todo (örnek/şablon)

| Method | Yol                  | Açıklama                |
|--------|----------------------|-------------------------|
| GET    | `/todos`             | Tüm todo'ları listeler  |
| POST   | `/todos`             | Yeni todo oluşturur     |
| DELETE | `/todos/:todoID`     | Belirtilen todo'yu siler |

### Diğer (şablon route'ları)

| Method | Yol                | Açıklama                          |
|--------|--------------------|-----------------------------------|
| GET    | `/`                | "It works!" döner                 |
| GET    | `/hello`           | "Hello, world!" döner             |
| GET    | `/hello/:name`     | İsme selam verir                  |
| GET    | `/json/:name`      | JSON olarak selam mesajı döner    |
| POST   | `/user-info`       | İsim ve yaş alıp mesaj döner      |

> 🔒 işaretli endpoint'ler `Authorization: Bearer <token>` başlığı gerektirir.

## Proje Yapısı

```
Sources/TouristGuideBackend/
├── Controllers/
│   ├── AuthContoller.swift     # Apple giriş, /me, /me silme
│   ├── ScanController.swift    # POST /scan — fotoğraftan mekan tanıma + anlatım
│   └── TodoController.swift    # Örnek Todo CRUD
├── Services/
│   ├── VisionService.swift     # Google Cloud Vision — landmark tespiti
│   ├── PlacesService.swift     # Google Places — koordinat fallback'i
│   └── NarrationService.swift  # LLM ile sesli rehber anlatımı üretimi
├── Middleware/
│   └── UserAuthenticator.swift # JWT doğrular + kullanıcının DB'de varlığını kontrol eder
├── Models/
│   ├── User.swift              # Kullanıcı modeli
│   ├── UserJWTPayload.swift    # JWT payload yapısı
│   └── Todo.swift              # Örnek Todo modeli
├── Migrations/
│   ├── CreateUser.swift        # users tablosu
│   └── CreateTodo.swift        # todos tablosu
├── DTOs/
│   └── TodoDTO.swift
├── configure.swift             # DB, JWT, migration yapılandırması
├── routes.swift                # Route kayıtları
└── entrypoint.swift            # Uygulama giriş noktası
```

## Yapılacaklar / Notlar

- `POST /scan` ile fotoğraftan mekan tanıma ve sesli rehber anlatımı eklendi. Tur/rehber yönetimi gibi diğer özellikler henüz yok.
- Todo modülü Vapor şablonundan gelmektedir; ileride kaldırılabilir.
