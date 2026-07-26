# Legal — MacSteam Ultimate Distribution Boundaries

This directory contains the policy documents that govern how MacSteam Ultimate components are licensed, distributed, and referenced. These documents define the legal boundaries for the `cloverpit-u1` release and all future releases.

---

## Document Index

| Document | Purpose |
|---|---|
| **[COMPONENT_POLICY.md](./COMPONENT_POLICY.md)** | Component licensing rules — SPDX headers, `component-lock.json`, runtime vs. proprietary boundaries, unknown-license handling, and the component review pipeline. |
| **[DISTRIBUTION_POLICY.md](./DISTRIBUTION_POLICY.md)** | Distribution boundaries — what may be redistributed, what must never be bundled, conditional Wine binary distribution requirements, and third-party download integrity rules. |
| **[PROPRIETARY_COMPONENTS.md](./PROPRIETARY_COMPONENTS.md)** | Registry of all proprietary components relevant to MacSteam, each with owner, licence type, redistribution policy, and U1 status. |
| **[SOURCE_OFFER_POLICY.md](./SOURCE_OFFER_POLICY.md)** | GPL source offer procedures — how Corresponding Source is made available, the standard offer text, build instructions reference, and compliance checklist. |
| **[TRADEMARK_POLICY.md](./TRADEMARK_POLICY.md)** | Trademark boundaries — nominative use of third-party marks (Steam, CrossOver, Apple, Wine, CloverPit), logo policy, and required disclaimers. |

---

## Quick Reference

| Topic | Policy |
|---|---|
| MacSteam source licence | GPL-3.0-or-later — freely distributable with source offer |
| Steam Client | Never bundled — user-obtained only |
| CloverPit | Never bundled — user-obtained via Steam |
| D3DMetal / GPTK | Never bundled — future detection adapter only |
| Wine binaries | Conditional — see 7 requirements in DISTRIBUTION_POLICY.md |
| Microsoft DLLs / fonts | Never bundled |
| Unknown-license components | Treated as forbidden until reviewed |
| Third-party downloads | Must have signed manifest, TLS, SHA-256, atomic install |
| Trademark disclaimers | Required in README, website footer, and About dialog |

---

## Maintenance

These documents are living policies. They should be reviewed and updated when:

- A new third-party component is added to MacSteam
- A component's licence changes
- Distribution methods expand (e.g., auto-updater, new package manager)
- Trademark concerns are raised
- A new major release changes the component boundary

Submit updates via pull request following the component review process described in [COMPONENT_POLICY.md](./COMPONENT_POLICY.md#6-component-review-process).

---

*Maintained by the MacSteam project contributors.*
