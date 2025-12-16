import type { Context } from "hono";
import type { Env } from "../index";
import { sendLicenseEmail } from "../lib/email";
import { findTokenBySubscription, generateLicenseToken, getLicenseByToken, revokeBySubscription, storeLicense } from "../lib/license";
import { stripeGetJson } from "../lib/stripe";
import { verifyStripeSignature } from "../lib/stripe_webhook";

export async function stripeWebhookRoute(c: Context<{ Bindings: Env }>) {
    const sig = c.req.header("Stripe-Signature");

    // 1. Raw Bytes for Verification
    const raw = await c.req.arrayBuffer();
    const ok = await verifyStripeSignature(raw, sig, c.env.STRIPE_WEBHOOK_SECRET);
    if (!ok) return c.json({ error: "invalid_signature" }, 400);

    // 2. Safe Parsing
    let event: any;
    try {
        const rawText = new TextDecoder("utf-8").decode(raw);
        event = JSON.parse(rawText);
    } catch {
        return c.json({ error: "invalid_json" }, 400);
    }

    switch (event.type) {
        case "checkout.session.completed": {
            const session = event.data.object as any;
            const plan = session?.metadata?.plan;
            const subId = session?.subscription;

            // 3. Strict Validation
            if (typeof subId !== "string" || !subId) {
                console.log("Ignored checkout.session.completed without subscription ID");
                break;
            }
            if (plan !== "pro" && plan !== "enterprise") break;

            // 4. Idempotency Check (Check before expensive fetch)
            const existing = await findTokenBySubscription(c.env.LICENSES, subId);
            if (existing) {
                console.log(`Already processed subscription ${subId}`);
                break;
            }

            // 5. Fetch details (Authoritative)
            const sub = await stripeGetJson(c.env, `/v1/subscriptions/${encodeURIComponent(subId)}`);
            if (!sub.ok) break;

            const expiresAt = sub.json.current_period_end as number;
            const now = Math.floor(Date.now() / 1000);
            const token = generateLicenseToken(plan);
            const email = session?.customer_details?.email ?? undefined;

            await storeLicense(c.env.LICENSES, {
                token,
                tier: plan,
                issued_at: now,
                expires_at: expiresAt,
                subscription_id: subId,
                customer_id: session?.customer,
                email,
            });

            // Backup delivery
            if (email) {
                await sendLicenseEmail({
                    resendApiKey: c.env.RESEND_API_KEY,
                    from: c.env.EMAIL_FROM,
                    to: email,
                    token,
                    tier: plan,
                });
            }
            break;
        }

        case "customer.subscription.deleted": {
            const subId = event.data.object?.id;
            if (typeof subId === "string") await revokeBySubscription(c.env.LICENSES, subId);
            break;
        }

        case "customer.subscription.updated": {
            const sub = event.data.object as any;
            const subId = sub?.id;

            if (typeof subId !== "string") break;

            const token = await findTokenBySubscription(c.env.LICENSES, subId);
            if (!token) break;

            const lic = await getLicenseByToken(c.env.LICENSES, token);
            if (!lic) break;

            if (typeof sub.current_period_end === "number") {
                lic.expires_at = sub.current_period_end;
                await storeLicense(c.env.LICENSES, lic);
            }
            break;
        }
    }

    return c.json({ received: true }, 200);
}
