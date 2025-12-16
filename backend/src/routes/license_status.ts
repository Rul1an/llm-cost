import type { Context } from "hono";
import type { Env } from "../index";

export async function licenseStatusRoute(c: Context<{ Bindings: Env }>) {
    const auth = c.req.header("Authorization");
    if (!auth?.startsWith("Bearer ")) return c.json({ valid: false }, 200);

    const token = auth.slice("Bearer ".length).trim();
    const rec = await c.env.LICENSES.get(token, "json") as any | null;
    if (!rec) return c.json({ valid: false }, 200);

    const now = Math.floor(Date.now() / 1000);

    // Strict Expiry Check
    if (typeof rec.expires_at !== "number") return c.json({ valid: false }, 200);
    if (now > rec.expires_at) return c.json({ valid: false }, 200);

    const allowed = new Set(["free", "pro", "enterprise"]);
    const tier = allowed.has(rec.tier) ? rec.tier : "pro";

    return c.json({ valid: true, tier: tier, expires_at: rec.expires_at }, 200);
}
