// app.js - Pricing Interaction

document.addEventListener('DOMContentLoaded', () => {
    // 1. Copy Snippet Logic
    const copyBtn = document.getElementById('copy-btn');
    const cmdText = document.getElementById('install-cmd').innerText;

    copyBtn.addEventListener('click', () => {
        navigator.clipboard.writeText(cmdText).then(() => {
            copyBtn.innerText = 'COPIED';
            setTimeout(() => copyBtn.innerText = 'COPY', 2000);
        });
    });

    // 2. Billing Toggle
    const toggle = document.getElementById('billing-toggle');
    const priceDisplay = document.getElementById('price-display');
    let isAnnual = false;

    toggle.addEventListener('click', () => {
        isAnnual = !isAnnual;
        toggle.setAttribute('aria-checked', isAnnual);

        // Simple client-side update (visual only)
        if (isAnnual) {
            priceDisplay.innerHTML = '$8.33<span class="period">/mo</span>'; // $100/yr
        } else {
            priceDisplay.innerHTML = '$10<span class="period">/mo</span>';
        }
    });

    // 3. Checkout Interaction
    const checkoutBtn = document.getElementById('checkout-btn');

    checkoutBtn.addEventListener('click', async () => {
        const originalText = checkoutBtn.innerText;
        checkoutBtn.innerText = 'Redirecting...';
        checkoutBtn.disabled = true;

        try {
            // Determine Price ID (should match backend env vars)
            // Example: 'price_monthly' or 'price_annual'
            // We'll trust the backend default if quantity=1, or pass a flag if needed.
            // For now, assuming the Checkout endpoint defaults to standard monthly unless arg provided.

            // Backend expects { plan: 'pro'|'enterprise', billing: 'monthly'|'annual' }
            const billing = isAnnual ? 'annual' : 'monthly';

            const response = await fetch('https://api.llm-cost.dev/v1/checkout/session', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({
                    plan: 'pro',
                    billing: billing
                })
            });

            if (!response.ok) {
                throw new Error('Network response was not ok');
            }

            const data = await response.json();

            if (data.url) {
                window.location.href = data.url;
            } else {
                throw new Error('No checkout URL returned');
            }

        } catch (error) {
            console.error('Checkout failed:', error);
            checkoutBtn.innerText = 'Error - Try Again';
            checkoutBtn.disabled = false;
            setTimeout(() => checkoutBtn.innerText = originalText, 3000);
        }
    });
});
