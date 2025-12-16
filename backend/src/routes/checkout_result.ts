import type { Context } from "hono";
import type { Env } from "../index";
import { findTokenBySubscription } from "../lib/license";
import { stripeGetJson } from "../lib/stripe";

export async function checkoutResultRoute(c: Context<{ Bindings: Env }>) {
    const sessionId = c.req.query("session_id");
    if (!sessionId) return c.json({ error: "missing_session_id" }, 400);

    const sess = await stripeGetJson(c.env, `/v1/checkout/sessions/${encodeURIComponent(sessionId)}`);
    if (!sess.ok) return c.json({ status: "error" }, 502);

    const session = sess.json as any;

    // subscription checkouts can be "paid" or sometimes "no_payment_required"
    const paid =
        session.payment_status === "paid" ||
        session.payment_status === "no_payment_required";

    if (!paid) return c.json({ status: "pending" }, 202);

    const subId = session.subscription as string | undefined;
    if (!subId) return c.json({ status: "error" }, 502);

    const token = await findTokenBySubscription(c.env.LICENSES, subId);
    if (!token) return c.json({ status: "processing" }, 202);

    return c.json({
        status: "complete",
        license: token,
        tier: session?.metadata?.plan ?? null,
    });
}
