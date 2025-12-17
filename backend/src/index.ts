import { Hono } from "hono";
import { cors } from "hono/cors";
import { getLicenseByToken } from "./lib/license";
import { checkoutRoutes } from "./routes/checkout";
import { checkoutResultRoute } from "./routes/checkout_result";
import { manifestRoute } from "./routes/manifest";
import { stripeWebhookRoute } from "./routes/webhook_stripe";

export type Env = {
    RATE_LIMITS: KVNamespace;
    LICENSES: KVNamespace;
    PRICING_BUCKET: R2Bucket;

    STRIPE_SECRET_KEY: string;
    STRIPE_WEBHOOK_SECRET: string;

    STRIPE_PRO_MONTHLY_PRICE_ID: string;
    STRIPE_PRO_ANNUAL_PRICE_ID: string;
    STRIPE_ENT_MONTHLY_PRICE_ID: string;
    STRIPE_ENT_ANNUAL_PRICE_ID: string;

    SUCCESS_URL: string;
    CANCEL_URL: string;

    RESEND_API_KEY: string;
    EMAIL_FROM: string;
};

const app = new Hono<{ Bindings: Env }>();

app.use("*", cors({
    origin: ["https://llm-cost.dev", "https://preview.llm-cost.dev", "http://localhost:3000"],
    allowMethods: ["GET", "POST", "OPTIONS"],
    allowHeaders: ["Content-Type", "Authorization"],
    maxAge: 86400,
}));

app.get("/health", (c) => c.json({ ok: true, version: "1.5.0" }));

// Pricing API
app.get("/v1/pricing/manifest.json", manifestRoute);

// License Status (for CLI)
app.get("/v1/license/status", async (c) => {
    const auth = c.req.header("Authorization");
    if (!auth?.startsWith("Bearer ")) {
        return c.json({ valid: false, error: "missing_token" }, 401);
    }
    const token = auth.slice("Bearer ".length).trim();
    const license = await getLicenseByToken(c.env.LICENSES, token);

    if (!license) {
        return c.json({ valid: false, error: "invalid_or_expired" }, 401);
    }

    const now = Math.floor(Date.now() / 1000);
    if (now > license.expires_at) {
        return c.json({ valid: false, error: "expired", expires_at: license.expires_at }, 401);
    }

    return c.json({
        valid: true,
        tier: license.tier,
        expires_at: license.expires_at,
    });
});

// Checkout Flow
app.route("/v1/checkout", checkoutRoutes);
app.get("/v1/checkout/result", checkoutResultRoute);

// Webhook
app.post("/v1/webhook/stripe", stripeWebhookRoute);

export default app;
