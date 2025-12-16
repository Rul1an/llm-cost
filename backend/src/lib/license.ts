export type Tier = "pro" | "enterprise";

export interface LicenseRecord {
    token: string;
    tier: Tier;
    issued_at: number;
    expires_at: number;
    subscription_id: string;
    customer_id?: string;
    email?: string;
}

export function generateLicenseToken(tier: Tier): string {
    const prefix = tier === "pro" ? "llm_cost_pro_" : "llm_cost_ent_";
    const rand = crypto.randomUUID().replace(/-/g, "");
    return `${prefix}${rand}`;
}

export async function storeLicense(kv: KVNamespace, lic: LicenseRecord) {
    // primary
    await kv.put(lic.token, JSON.stringify(lic), {
        expirationTtl: Math.max(60, lic.expires_at - Math.floor(Date.now() / 1000) + 86400),
    });

    // index by subscription -> token
    await kv.put(`sub:${lic.subscription_id}`, lic.token, {
        expirationTtl: Math.max(60, lic.expires_at - Math.floor(Date.now() / 1000) + 86400),
    });
}

export async function findTokenBySubscription(kv: KVNamespace, subscriptionId: string): Promise<string | null> {
    return (await kv.get(`sub:${subscriptionId}`)) ?? null;
}

export async function getLicenseByToken(kv: KVNamespace, token: string): Promise<LicenseRecord | null> {
    const raw = await kv.get(token);
    if (!raw) return null;
    try {
        return JSON.parse(raw) as LicenseRecord;
    } catch {
        return null;
    }
}

export async function revokeBySubscription(kv: KVNamespace, subscriptionId: string) {
    const token = await findTokenBySubscription(kv, subscriptionId);
    if (!token) return;
    await kv.delete(`sub:${subscriptionId}`);
    await kv.delete(token);
}
