import type { Context } from "hono";
import type { Env } from "../index";

const FREE_LIMIT = 10;
const WINDOW_SECONDS = 86400;

function windowId(nowSec: number) {
    return Math.floor(nowSec / WINDOW_SECONDS);
}

async function isAuthed(c: Context<{ Bindings: Env }>) {
    const auth = c.req.header("Authorization");
    if (!auth?.startsWith("Bearer ")) return { ok: false as const };
    const token = auth.slice("Bearer ".length).trim();
    if (!token) return { ok: false as const };

    const rec = await c.env.LICENSES.get(token, "json") as any | null;
    if (!rec) return { ok: false as const };

    const now = Math.floor(Date.now() / 1000);
    if (typeof rec.expires_at === "number" && now > rec.expires_at) return { ok: false as const };

    return { ok: true as const, tier: rec.tier ?? "pro" };
}

async function rateLimitFree(c: Context<{ Bindings: Env }>) {
    const ip = c.req.header("CF-Connecting-IP") ?? "unknown";

    // Bypass rate limit for unknown IP (e.g. dev/localhost)
    if (ip === "unknown") return false;

    const now = Math.floor(Date.now() / 1000);
    const key = `ip:${ip}:${windowId(now)}`;

    const val = await c.env.RATE_LIMITS.get(key);
    const count = val ? parseInt(val, 10) : 0;
    // Guard against NaN
    const safeCount = Number.isFinite(count) ? count : 0;

    if (safeCount >= FREE_LIMIT) return true;

    await c.env.RATE_LIMITS.put(key, String(safeCount + 1), { expirationTtl: WINDOW_SECONDS });
    return false;
}

export async function manifestRoute(c: Context<{ Bindings: Env }>) {
    const auth = await isAuthed(c);

    if (!auth.ok) {
        const limited = await rateLimitFree(c);
        if (limited) {
            return c.json(
                { error: "rate_limited", message: "Free tier: 1 update/day", upgrade_url: "https://llm-cost.dev/pro" },
                429
            );
        }
    }

    const obj = await c.env.PRICING_BUCKET.get("pricing/latest/manifest.json");
    if (!obj) return c.json({ error: "manifest_not_found" }, 500);

    // Serve bytes directly to avoid encoding issues
    const body = await obj.arrayBuffer();
    return c.body(body, 200, {
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": auth.ok ? "private, max-age=60" : "public, max-age=60",
        "Vary": "Authorization",
        "X-LLM-Cost-Tier": auth.ok ? auth.tier : "free",
    });
}
