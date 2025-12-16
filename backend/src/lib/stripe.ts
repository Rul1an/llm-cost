function formEncode(obj: Record<string, string>) {
    return Object.entries(obj)
        .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
        .join("&");
}

export async function stripePostForm(env: any, path: string, data: Record<string, string>) {
    const resp = await fetch(`https://api.stripe.com${path}`, {
        method: "POST",
        headers: {
            Authorization: `Bearer ${env.STRIPE_SECRET_KEY}`,
            "Content-Type": "application/x-www-form-urlencoded",
        },
        body: formEncode(data),
    });

    const json = await resp.json<any>().catch(() => ({}));

    if (!resp.ok) {
        // Log full details server-side, return sanitized error
        console.error("Stripe error:", JSON.stringify(json));
        return { ok: false as const, status: resp.status, json };
    }

    return { ok: true as const, status: resp.status, json };
}

export async function stripeGetJson(env: any, path: string) {
    const resp = await fetch(`https://api.stripe.com${path}`, {
        headers: { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}` },
    });

    const json = await resp.json<any>().catch(() => ({}));
    if (!resp.ok) {
        console.error("Stripe GET error:", JSON.stringify(json));
        return { ok: false as const, status: resp.status, json };
    }
    return { ok: true as const, status: resp.status, json };
}
