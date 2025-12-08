# Security Policy

## Reporting a Vulnerability

We take the security of `llm-cost` seriously. If you discover a security vulnerability, please do **not** open a public issue.

Instead, please send a private report to the maintainer via GitHub Security Advisories or email (if listed).

**SLA**: We aim to acknowledge reports within 7 days and provide a timeline for a fix.

## Scope

- **In Scope**:
    - Vulnerabilities in the core binary that could lead to crashes (DoS) or unexpected data processing behavior.
    - Tokenizer inconsistencies that could lead to significant cost underestimation in `exact` mode.
- **Out of Scope**:
    - Build process exploits requiring compromised local environments.
    - Heuristic inaccuracies for unsupported models (these are expected).
