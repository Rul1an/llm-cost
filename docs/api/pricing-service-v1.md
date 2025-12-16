# Pricing Service API v1 Contract

**Base URL**: `https://api.llm-cost.dev/v1`
**Version**: v1.4.0 (Draft)

## 1. Authentication

*   **Public Endpoints**: No authentication required. Rate-limited by IP (e.g., 60 req/hour).
*   **Authenticated Endpoints**: Require `Authorization: Bearer <LICENSE_TOKEN_OR_KEY>`. No rate limits (within fair use).

## 2. Endpoints

### 2.1. Get Pricing Manifest (Latest)

Fetches the signed manifest describing the latest valid pricing database.

*   **GET** `/pricing/manifest.json`
*   **Auth**: Public / Bearer
*   **Headers**:
    *   `If-None-Match`: <etag> (Recommended)

**Response (200 OK):**
```json
{
  "schema_version": 1,
  "version": 2026011501,
  "generated_at": "2026-01-15T07:35:00Z",
  "db": {
    "url": "https://cdn.llm-cost.dev/pricing/2026011501/pricing_db.zst",
    "sha256": "a3b2c1...d4e5f6",
    "size_bytes": 145203
  },
  "sig": "base64_encoded_signature_of_manifest_json_bytes"
}
```

**Response (304 Not Modified):** No content. client should use cached manifest.

**Response (429 Too Many Requests):** Public tier limit exceeded.

### 2.2. Get Pricing Database (Artifact)

The database file itself is served via CDN, potentially from a different domain. The manifest provides the authoritative integrity hash.

*   **GET** `/pricing/<VERSION>/pricing_db.zst`
*   **Auth**: Public (Signed URL or Public Bucket)

### 2.3. Activate License (Pro/Ent)

Exchange a purchase token or login session for an offline-signed license file.

*   **POST** `/license/activate`
*   **Auth**: Bearer <PURCHASE_TOKEN>
*   **Body**:
    ```json
    {
      "machine_id": "optional-hardware-id",
      "friendly_name": "My MacBook Pro"
    }
    ```

**Response (200 OK):**
```json
{
  "license_file": {
    "tier": "pro",
    "org_id": "acme-corp",
    "version": 1,
    "expires_at": 1799999999,
    "features": 7,
    "sig": "base64_ed25519_signature"
  },
  "message": "License activated successfully."
}
```

## 3. Caching & Freshness

*   Manifests include standard `Cache-Control` headers (e.g., `public, max-age=3600`).
*   Clients **MUST** respect the TTL in the manifest (`now - generated_at <= 7 days`) to prevent freeze attacks, regardless of HTTP caching.
*   Clients **MUST** verify the signature of the manifest before trusting `db.url` or `db.sha256`.

## 4. Error Responses

Standard JSON error format:
```json
{
  "error": {
    "code": "invalid_license",
    "message": "The provided license token is expired or invalid.",
    "doc_url": "https://llm-cost.dev/docs/errors#invalid_license"
  }
}
```

| Code | Description |
| :--- | :--- |
| `rate_limited` | IP quota exceeded. Upgrade to Pro. |
| `invalid_signature` | Server-side validation failure (rare). |
| `manifest_stale` | Server clock issue or freeze attack detected (client-side logic). |
