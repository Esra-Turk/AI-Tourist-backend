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
| `OPENAI_API_KEY`       | OpenAI API anahtarı (anlatım üretimi + görsel mekan tanıma fallback'i) | —                  |
| `LLM_MODEL`            | Anlatım için kullanılan OpenAI Chat Completions modeli | `gpt-4o`               |
| `LLM_VISION_MODEL`     | Vision landmark tespiti boş döndüğünde fotoğraftan mekan tanımak için kullanılan multimodal model | `gpt-4o` |

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

JWT gerektirir. `multipart/form-data` ile fotoğraf ve tercihler gönderilir (görselin ikili olarak taşınması gerektiği için saf JSON kullanılmaz).

**İstek şeması** (alanlar `multipart/form-data` part'ı olarak gönderilir; aşağıdaki JSON yapısı her bir part'ın mantıksal karşılığıdır):

```jsonc
{
  "image":     "<binary JPEG>",   // zorunlu — multipart dosya part'ı
  "latitude":  "41.0086",         // opsiyonel — string, ondalık derece
  "longitude": "28.9802",         // opsiyonel — string, ondalık derece
  "style":     "historical",      // zorunlu — "fun" | "historical" | "simple" | "detailed"
  "duration":  "oneMinute"        // zorunlu — "thirtySeconds" | "oneMinute" | "threeMinutes"
}
```

| Alan        | Tip          | Zorunlu | Açıklama                                          |
|-------------|--------------|---------|---------------------------------------------------|
| `image`     | JPEG dosyası | Evet    | Mekanın fotoğrafı (max 10 MB)                     |
| `latitude`  | String       | Hayır   | Cihazın enlemi (ondalık derece)                   |
| `longitude` | String       | Hayır   | Cihazın boylamı (ondalık derece)                  |
| `style`     | String       | Evet    | `fun` \| `historical` \| `simple` \| `detailed`   |
| `duration`  | String       | Evet    | `thirtySeconds` \| `oneMinute` \| `threeMinutes`  |

Örnek `curl`:

```bash
curl -X POST https://<host>/scan \
  -H "Authorization: Bearer <jwt-token>" \
  -F "image=@hagia-sophia.jpg;type=image/jpeg" \
  -F "latitude=41.0086" \
  -F "longitude=28.9802" \
  -F "style=historical" \
  -F "duration=oneMinute"
```

İşleyiş — mekan tanıma 3 kademeli fallback ile yapılır:

1. **Cloud Vision landmark detection** (`CLOUD_VISION`): Görsel Google Cloud Vision'a `LANDMARK_DETECTION` ile gönderilir. Koordinat geldiyse adaylardan kullanıcıya en yakını (haversine) seçilir; koordinat yoksa en yüksek skorlu aday. `confidence` doğrudan Vision skorudur (0–1).
2. **LLM Vision fallback** (`LLM_VISION`): Vision hiç landmark bulamazsa görsel multimodal LLM'e (`LLM_VISION_MODEL`, varsayılan `gpt-4o`) gönderilir. Model emin değilse `UNKNOWN` döner ve bir sonraki adıma geçilir; emin olduğu durumlarda mekan adı tek satır olarak döner. Koordinat LLM'den gelmediği için kullanıcı koordinatı (varsa) yansıtılır. `confidence = 0.5`.
3. **Places nearby search fallback** (`PLACES_NEARBY`): LLM de bulamazsa ve koordinat varsa Google Places nearby search ile en olası mekan bulunur. `confidence = 0.5`.

Hiçbiri tutmazsa `422 Unprocessable Entity` döner.

Tespit edilen mekan, `style` ve `duration`'a uygun bir anlatım için OpenAI Chat Completions API'ye (`LLM_MODEL`, varsayılan `gpt-4o`) verilir. Sabit sistem talimatı OpenAI tarafından otomatik prompt caching'e tabidir.

Hangi yolun kullanıldığı sunucu loglarına yazılır (`[scan] place identified via ...`).

**Başarılı yanıt** `200 OK` (`application/json`):

```json
{
  "placeName": "Hagia Sophia",
  "confidence": 0.92,
  "latitude": 41.0086,
  "longitude": 28.9802,
  "narration": "Stand before the soaring dome of Hagia Sophia and you stand at a crossroads of empires..."
}
```

| Alan         | Tip            | Açıklama                                                                                                  |
|--------------|----------------|-----------------------------------------------------------------------------------------------------------|
| `placeName`  | String         | Tespit edilen mekanın adı.                                                                                |
| `confidence` | Number (0–1)   | Cloud Vision yolunda Vision skoru; LLM Vision veya Places fallback'i kullanıldıysa sabit `0.5`.            |
| `latitude`   | Number \| null | Tespit edilen mekanın enlemi; bilinmiyorsa `null`.                                                        |
| `longitude`  | Number \| null | Tespit edilen mekanın boylamı; bilinmiyorsa `null`.                                                       |
| `narration`  | String         | İngilizce sesli rehber metni. Dil alanı yoktur; uzunluk `duration`'a göre değişir.                        |

iOS, `confidence < 0.6` olduğunda kullanıcıya "emin değiliz" uyarısı gösterir.

**Hata yanıtları** (Vapor varsayılanı, `application/json`):

```json
{
  "error": true,
  "reason": "Couldn't identify a place in this photo."
}
```

| Durum                          | Sebep                                                            |
|--------------------------------|------------------------------------------------------------------|
| `400 Bad Request`              | `image` part'ı eksik veya boş.                                   |
| `401 Unauthorized`             | JWT eksik / geçersiz / süresi dolmuş veya kullanıcı silinmiş.    |
| `422 Unprocessable Entity`     | Üç fallback de mekanı tanıyamadı.                                |
| `502 Bad Gateway`              | Vision / Places / OpenAI servislerinden biri başarısız oldu.     |

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
│   └── NarrationService.swift  # OpenAI Chat Completions ile anlatım üretimi + LLM Vision mekan tanıma fallback'i
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
