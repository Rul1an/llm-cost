# Security Policy

## Supported Versions

Only the latest `main` branch and the latest release tag are supported.

| Version | Supported          |
| ------- | ------------------ |
| v1.6.x  | :white_check_mark: |
| < v1.5  | :x:                |

## Reporting a Vulnerability

**Do not open public GitHub issues for security vulnerabilities.**

If you discover a security issue, please contact the maintainer directly or email security@example.com (Replace with actual contact).

### What to include

1.  A description of the issue.
2.  Steps to reproduce.
3.  Impact of the vulnerability.

## CI/CD Security
This project enforces strict supply chain security:
- All actions are pinned to SHA.
- **Root of Trust**: Zig compiler pinned to `0.14.0`.
- Least privilege permissions.
- Hermetic builds.

Any PR modifying `.github/` requires code owner review.
