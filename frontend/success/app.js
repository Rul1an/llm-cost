// app.js - Success Polling

document.addEventListener('DOMContentLoaded', () => {
    // 1. Get Session ID
    const urlParams = new URLSearchParams(window.location.search);
    const sessionId = urlParams.get('session_id');
    const sessionDisplay = document.getElementById('session-id-display');

    if (!sessionId) {
        showError("Missing session_id");
        return;
    }

    // Display formatted session ID (last 8 chars)
    sessionDisplay.innerText = "..." + sessionId.slice(-8);

    // 2. Poll Result
    let attempts = 0;
    const maxAttempts = 30; // 60 seconds (2s interval)

    const pollInterval = setInterval(async () => {
        attempts++;
        try {
            const res = await fetch(`https://api.llm-cost.dev/v1/checkout/result?session_id=${sessionId}`);

            if (res.status === 200) {
                const data = await res.json();

                if (data.status === 'complete' && data.license_key) {
                    clearInterval(pollInterval);
                    showSuccess(data.license_key);
                } else if (data.status === 'failed') {
                    clearInterval(pollInterval);
                    showError("Provisioning failed. Contact Support.");
                }
                // If 'pending', continue polling
            } else if (res.status >= 400 && res.status !== 404) {
                // 404 might mean "not yet consistent", so ignore, but 400/500 is real error
                // Actually checkout_result usually returns 200 with status='pending' or 404 if unknown
            }
        } catch (e) {
            console.error(e);
        }

        if (attempts >= maxAttempts) {
            clearInterval(pollInterval);
            showTimeout();
        }
    }, 2000);

    // Helpers
    function showSuccess(licenseKey) {
        document.getElementById('status-area').classList.add('hidden');
        const licenseBlock = document.getElementById('license-block');
        const instructionBlock = document.getElementById('instructions');

        licenseBlock.classList.remove('hidden');
        instructionBlock.classList.remove('hidden');

        const codeEl = document.getElementById('license-key');
        codeEl.innerText = licenseKey;

        // Copy button
        document.getElementById('copy-btn').addEventListener('click', () => {
            navigator.clipboard.writeText(licenseKey);
        });

        // Download button
        document.getElementById('download-btn').addEventListener('click', () => {
            const blob = new Blob([`LLM_COST_LICENSE="${licenseKey}"\n`], { type: 'text/plain' });
            const url = window.URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = 'llm-cost.env';
            a.click();
        });

        // Update instructions
        document.querySelectorAll('.cmd').forEach(el => {
            if (el.innerText.includes('X_LICENSE')) {
                el.innerText = `export LLM_COST_LICENSE="${licenseKey}"`;
            }
        });
    }

    function showError(msg) {
        document.querySelector('.status-text').innerText = msg;
        document.querySelector('.spinner').style.display = 'none';
        document.querySelector('.status-text').style.color = 'red';
    }

    function showTimeout() {
        showError("Taking longer than expected. Please check email.");
    }
});
