export async function sendLicenseEmail(params: {
    resendApiKey: string;
    from: string;
    to: string;
    token: string;
    tier: "pro" | "enterprise";
}) {
    const tierName = params.tier === "pro" ? "Pro" : "Enterprise";

    const html = `
    <h1>Welcome to llm-cost ${tierName}!</h1>
    <p>Your license key:</p>
    <pre style="background:#f4f4f4;padding:16px;font-size:14px;white-space:pre-wrap">${params.token}</pre>

    <h2>Quick Start</h2>
    <pre style="background:#f4f4f4;padding:16px;font-size:13px">export LLM_COST_LICENSE="${params.token}"
llm-cost update-db</pre>

    <p>If you lose the key, reply to this email.</p>
  `;

    const resp = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
            Authorization: `Bearer ${params.resendApiKey}`,
            "Content-Type": "application/json",
        },
        body: JSON.stringify({
            from: params.from,
            to: [params.to],
            subject: `Your llm-cost ${tierName} License`,
            html,
        }),
    });

    if (!resp.ok) {
        const detail = await resp.text();
        console.error("Resend error:", resp.status, detail);
        return false;
    }
    return true;
}
