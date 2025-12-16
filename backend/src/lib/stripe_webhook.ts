function timingSafeEqual(a: Uint8Array, b: Uint8Array) {
    if (a.length !== b.length) return false;
    let out = 0;
    for (let i = 0; i < a.length; i++) out |= a[i] ^ b[i];
    return out === 0;
}

async function hmacSha256(secret: string, data: string): Promise<Uint8Array> {
    const enc = new TextEncoder();
    const key = await crypto.subtle.importKey(
        "raw",
        enc.encode(secret),
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["sign"]
    );
    const sig = await crypto.subtle.sign("HMAC", key, enc.encode(data));
    return new Uint8Array(sig);
}

function hexToBytes(hex: string): Uint8Array {
    const clean = hex.trim();
    const out = new Uint8Array(clean.length / 2);
    for (let i = 0; i < out.length; i++) {
        out[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
    }
    return out;
}

// Hardened implementation as per best practices
export async function verifyStripeSignature(
    rawBody: ArrayBuffer,
    sigHeader: string | null,
    secret: string,
    toleranceSeconds = 300
): Promise<boolean> {
    if (!sigHeader) return false;

    const parts = sigHeader.split(",").map((s) => s.trim());
    const tPart = parts.find((p) => p.startsWith("t="));

    // 1. Check Timestamp
    if (!tPart) return false;
    const t = parseInt(tPart.slice(2), 10);
    const now = Math.floor(Date.now() / 1000);

    if (isNaN(t)) return false;
    if (Math.abs(now - t) > toleranceSeconds) return false; // Too old or too far in future

    // 2. Prepare Payload (t.rowBody)
    const enc = new TextEncoder();
    const tBytes = enc.encode(`${t}.`);
    const payload = new Uint8Array(tBytes.length + rawBody.byteLength);
    payload.set(tBytes, 0);
    payload.set(new Uint8Array(rawBody), tBytes.length);

    // 3. Calculate Expected Signature
    const key = await crypto.subtle.importKey(
        "raw",
        enc.encode(secret),
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["sign"]
    );
    const signature = await crypto.subtle.sign("HMAC", key, payload);
    const expected = new Uint8Array(signature);

    // 4. Verify against ALL v1 signatures (Stripe can rotate keys)
    const v1Parts = parts.filter((p) => p.startsWith("v1="));
    for (const part of v1Parts) {
        const v1 = part.slice(3);
        const got = hexToBytes(v1);
        if (timingSafeEqual(expected, got)) {
            return true; // Match found
        }
    }

    return false;
}
