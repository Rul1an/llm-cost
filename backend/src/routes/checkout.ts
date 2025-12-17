import { Hono } from "hono";
import { stripePostForm } from "../lib/stripe";

export const checkoutRoutes = new Hono();

function priceId(env: any, plan: string, billing: string): string | null {
    if (plan === "pro" && billing === "monthly") return env.STRIPE_PRO_MONTHLY_PRICE_ID;
    if (plan === "pro" && billing === "annual") return env.STRIPE_PRO_ANNUAL_PRICE_ID;
    if (plan === "enterprise" && billing === "monthly") return env.STRIPE_ENT_MONTHLY_PRICE_ID;
    if (plan === "enterprise" && billing === "annual") return env.STRIPE_ENT_ANNUAL_PRICE_ID;
    return null;
}

checkoutRoutes.post("/session", async (c) => {
    const { plan, billing } = await c.req.json().catch(() => ({}));

    if ((plan !== "pro" && plan !== "enterprise") || (billing !== "monthly" && billing !== "annual")) {
        return c.json({ error: "invalid_plan" }, 400);
    }

    const pid = priceId(c.env, plan, billing);
    if (!pid) return c.json({ error: "missing_price_id" }, 500);

    const clientRef = crypto.randomUUID();

    const res = await stripePostForm(c.env, "/v1/checkout/sessions", {
        mode: "subscription",
        "payment_method_types[0]": "card",
        "line_items[0][price]": pid,
        "line_items[0][quantity]": "1",

        // Enforce trailing slash for Cloudflare Pages compatibility
        success_url: `${c.env.SUCCESS_URL}/?session_id={CHECKOUT_SESSION_ID}`,
        cancel_url: `${c.env.CANCEL_URL}/?canceled=1`,

        client_reference_id: clientRef,

        "metadata[plan]": plan,
        "metadata[billing]": billing,
    });

    if (!res.ok) {
        return c.json(
            {
                error: "stripe_error",
                message: res.json?.error?.message || "Payment service unavailable",
            },
            502
        );
    }

    return c.json({ url: res.json.url });
});
