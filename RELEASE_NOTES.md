# Release v1.5.0: Pricing DB as a Service (PDBaaS)

This release marks a major architectural shift. `llm-cost` now supports a unified **Pricing Database as a Service**, powered by a scalable Cloudflare backend and Stripe monetization integration.

## 🚀 Key Features

### 1. Unified Pricing Backend (Cloudflare)
- **Zero-Node.js Architecture**: The new backend runs entirely on Cloudflare Workers using native `fetch` and `WebCrypto`.
- **Global CDN**: Pricing manifest is served via R2 + Worker cache, ensuring low-latency updates worldwide.
- **TUF-lite Security**: All pricing updates are cryptographically signed (Ed25519) offline. The Worker never touches private keys.

### 2. Stripe Integration (Monetization)
- **Pro & Enterprise Tiers**: License-based access to the API.
- **Automated Provisioning**: Stripe Checkout integration creates licenses instantly upon payment.
- **Secure Webhooks**: Full signature verification and idempotency for robust billing handling.

### 3. Client Updates
- **New Commands**:
    - `llm-cost upgrade`: Get your checkout link.
    - `llm-cost verify-license <key>`: Validate your license status.
    - `llm-cost update-db`: Now respects the `LLM_COST_LICENSE` environment variable for unlimited updates.
- **Rate Limiting**: Free users are capped at 10 updates/day. Pro users are unlimited.

## 🛠️ Infrastructure
- **Backend**: `backend/` folder contains the full Worker implementation.
- **Tools**: `tools/publish_release.zig` handles the secure signing pipeline.

## 🔒 Security
- **No Private Keys in Cloud**: Signing happens offline.
- **Strict Canonicalization**: Manifests are strictly ordered and minimized to prevent tampering.
- **Anti-Rollback**: Clients reject older database versions automatically.

---
**Upgrade today:**
```bash
curl -sSfL https://get.llm-cost.dev | sh
# or
llm-cost update-db
```
