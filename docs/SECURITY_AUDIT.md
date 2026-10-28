# Security audit — 2026-10-28 UTC

Scope: the Rust API and its 17 route entry points, browser code, SQL migrations and live Supabase catalogs/Auth configuration, CLI, installer, release workflows, private compute health server, and M5StickS3 firmware source. Linked project: `bbmdkpzzzalkvthwgsek` (Fizz). This is a source/configuration audit with regression tests, not an independent penetration-test certification.

## Deployment status

**Live:** migrations `20261028031014_authenticated_owner_rls` and `20261028032625_security_hardening`; production Auth minimum password length and sign-in/verification limits; required SSL for external database connections. Applied with Supabase CLI 2.120.0 and verified against the linked database.

**Working tree:** API/browser defenses, outgoing HTTP clients, paid-provider request enforcement, dependency updates, CLI, firmware, compute server, and CI changes. These require the corresponding app deployment, CLI release, firmware installation, or compute deployment. The database budget RPC exists, but chat/voice limits take effect only when the updated API calls it. No app, CLI, firmware, or compute release was published during this audit.

## Findings and fixes

| Priority | Finding | Remediation | State |
| --- | --- | --- | --- |
| High | Both lockfiles contained six RustSec TLS/certificate advisories. The backend also had a Tokio unsoundness warning. | Updated rustls to 0.23.46, rustls-webpki to 0.103.16, webpki-roots to 1.0.11, and backend Tokio to 1.54.1. | Source |
| High | A NULL sensor key hash could make SQL's `<>` comparison fail to reject a shaped credential. | `IS DISTINCT FROM` fails closed for absent hashes; regression covers correct, foreign, absent, and NULL-stored keys. | Live |
| High | Fizz's independent 12-hour sessions survived Auth credential changes and bans. | Auth trigger deletes sessions on password/email/suspension changes. Session lookup and new OAuth session issuance check Auth suspension/deletion/anonymous state. Bans/deletion also revoke agents, phone devices, API keys and pending pairings, disable alerts and skip queued calls. | Live |
| Medium | The live `rls_auto_enable` SECURITY DEFINER helper was executable by client roles; default grants exposed newly created objects. | Revoked helper execution, public-schema creation, and future table/function grants to client roles. Removed PostgreSQL's global PUBLIC function-execution default, which schema-local revocation cannot override. | Live |
| High | A password-only Supabase session could be promoted to a Fizz session even with verified MFA factors. | Refuse partial (AAL1) authentication when Supabase reports verified factors; only an AAL2 session can proceed. | Source; MFA challenge UI is outside the current app |
| Medium | Browser origin authorization trusted forwarded host data, and auth redirects accepted arbitrary hostnames or localhost prefixes. | Shared guard at every API entry point validates configured hosts, exact origins and Fetch Metadata; forwarded hosts cannot authorize requests. Exact JSON media types replace prefix matching. | Source |
| Medium | No application budgets bounded chat/voice spending or device uploads. | Customer budgets: chat 20/minute and 200/hour; voice 20/minute and 100/hour. API ingest 1,200 metric readings/sensor/minute and 5,000/customer/minute; phone readings 1,200/sensor/minute, transcripts 60/hour and clips 20/hour. Counters are in PostgreSQL and survive session rotation. | Device budgets live; paid API enforcement requires deployment |
| Medium | Production Auth allowed six-character passwords, 3,000 sign-ins and 1,000 token verifications per five minutes per IP. | New/changed passwords require 12 characters; sign-in and verification limits are now 30 per five minutes per IP. Existing passwords remain usable at sign-in. App checks preserve bcrypt's 72-byte ceiling. | Auth live; app validation in source |
| Medium | Public responses lacked CSP, framing, MIME-sniffing and referrer defenses. | Added CSP (scripts only from self, no inline JavaScript), DENY framing, nosniff, no-referrer, HSTS, API no-store and restricted browser permissions. Moved landing-page scripts into local assets. Phone microphone, location and motion permissions remain available to its own origin. | Source |
| Medium | The CLI accepted plaintext remote API URLs and wrote credentials by truncating potentially linked files. | HTTPS required except exact loopback origins; no credentials/userinfo, path, query or fragment in base URLs; redirects disabled. Config uses private atomic writes, regular-file/owner/permission checks and no-follow reads. | Source |
| Medium | Custom API-key headers could follow provider redirects. | Disabled redirects for Supabase, AI Gateway, ElevenLabs and AgentPhone clients, as well as the device CLI. | Source |
| Medium | Direct external database connections did not require TLS. | Enabled Supabase SSL enforcement. Application requests already use HTTPS. | Live |
| Low | Release builds had repository write access, and Actions used moving references. | Build/security jobs are read-only; only release publishing can write. Actions are pinned to verified commit hashes. Added weekly/PR dependency audits, Rust tests and JS syntax checks. | Source |
| Low | A stalled/broken health-check connection could stop the private worker; firmware accumulated an unbounded HTTP response. | Worker uses timeouts and survives individual connection failures. Firmware caps responses at 64 KiB and retains certificate verification. | Source; firmware hardware validation pending |

TLS advisories addressed: RUSTSEC-2026-0346, -0347, -0348, -0349, -0381 and -0382. Tokio warning addressed: RUSTSEC-2026-0386.

## Ownership and privilege verification

All 13 customer-owned tables have four policies each, scoped to `authenticated` and mapped through `fizz_customers.auth_user_id`. Tests cover own CRUD, foreign ownership, ownership transfers, mixed related IDs, anonymous Auth accounts, missing JWTs and the `anon` role. Direct client table grants remain absent: the server-only API still validates Fizz sessions because `service_role` bypasses RLS.

The live catalog had no public storage buckets, public views or public tables without RLS. No Fizz privileged RPC or auto-RLS helper remains executable by `anon`/`authenticated`. Waitlist, business-interest and rate-limit tables intentionally have RLS with no client policies; Supabase's three INFO findings for these tables are expected.

Future objects created by `postgres` need explicit client permissions when intended. Future functions also need explicit PUBLIC execution grants outside this schema if that behavior is desired. Managed Supabase system-owner defaults were not changed.

## Validation

- `cargo test --locked --all-targets`: 33 backend tests pass; all API targets compile. Local mock HTTP servers exercise notification requests and provider failures.
- `cargo test --locked --manifest-path cli/Cargo.toml`: six CLI tests pass, including URL transport and private/atomic/symlink config regressions.
- `cargo audit --deny warnings` for both lockfiles: zero known vulnerabilities and zero warnings with the refreshed RustSec database.
- Linked `authenticated_owner_rls.sql`: **281 assertions pass** after migration.
- Linked `security_hardening.sql`: **54 assertions pass**, including service-role RPC calls, budgets shared across sessions, password/email invalidation, ban revocation and future default grants. Migration preflight passed in a rolled-back transaction before deployment. All test fixtures and temporary grants roll back.
- SSL enforcement update returned `database: true`, and a subsequent linked query confirmed TLS connectivity. There were zero verified MFA factors in the linked Auth catalog.
- Linked database lint: no errors; one existing unused `p_ip` parameter warning in `fizz_agent_call`.
- HTML/CSP asset checks, all browser JavaScript syntax checks, firmware Python syntax, worker compilation, Rust formatting and `git diff --check` pass.
- Targeted secret-pattern/JWT scan covered 105 tracked files and 291 historical Git blobs, with no matches for private keys, Supabase secret/service-role JWTs, GitHub tokens, AWS access keys or recognized provider secret prefixes. This cannot establish that every possible secret format is absent.

## Remaining operations and limitations

1. **Enable Supabase Auth breached-password protection.** The live advisor still reports `auth_leaked_password_protection`. This CLI's config comparison does not expose the management API's `password_hibp_enabled` property; declaring it produced no managed update. Enable the Have I Been Pwned check in [Auth password settings](https://supabase.com/dashboard/project/bbmdkpzzzalkvthwgsek/auth/providers); plan availability may apply. Re-run the advisor afterward.
2. **Review the Auth email budget.** The pulled remote value is 10,000 emails/hour. This CLI reports `auth.rate_limit.email_sent` as unmanaged and will not push it. Reduce it to the intended launch volume in [Auth rate limits](https://supabase.com/dashboard/project/bbmdkpzzzalkvthwgsek/auth/rate-limits). The existing one-minute per-address frequency and tightened IP limits remain active.
3. **Deploy/release the source changes** listed above. Confirm the response headers on the deployed site and exercise Google/email/passkey login, phone permissions/recordings, chat and voice with test accounts. Real provider calls, production account changes and device flashing were not exercised. The firmware response bound was syntax-checked, not tested on physical hardware.
4. Phone alerts have owner-only authorization, normalized US numbers, per-rule/customer call caps and model-output validation, but recipients are not independently verified. Keep provider spending limits and abuse monitoring enabled; recipient verification needs a product/provider integration. Model instructions do not eliminate prompt injection: server ownership/schema checks remain the authority.
5. The app has no TOTP/MFA challenge UI. Accounts with verified MFA factors now fail closed when signing in with a partial Supabase session. Add an MFA-capable sign-in flow before offering TOTP enrollment in the app; Enrollment/challenge flows are unsupported by this UI, and factor-change session invalidation is not implemented; address that lifecycle before adding MFA enrollment.
6. Direct database network access is not IP-restricted; define operator/CI CIDRs if stable sources are available. This audit did not rotate secrets, change backup/PITR plans, validate organization membership/MFA enforcement, inspect provider billing policies, or conduct destructive/load tests.

## Reproduce

Run linked CLI operations sequentially: concurrent commands refresh the same temporary database login role and can invalidate one another's connection credentials.

```sh
npx --yes supabase@2.120.0 db query --linked --file supabase/tests/authenticated_owner_rls.sql
npx --yes supabase@2.120.0 db query --linked --file supabase/tests/security_hardening.sql
npx --yes supabase@2.120.0 db advisors --linked --type security --level info
npx --yes supabase@2.120.0 db lint --linked --level warning
cargo test --locked --all-targets
cargo test --locked --manifest-path cli/Cargo.toml
cargo audit --deny warnings --file Cargo.lock
cargo audit --deny warnings --file cli/Cargo.lock
```

The narrow production security profile is `supabase/config.production-security.toml`. To review/apply it again without pushing local-development defaults:

```sh
mkdir -p /tmp/fizz-security-config/supabase
cp supabase/config.production-security.toml /tmp/fizz-security-config/supabase/config.toml
npx --yes supabase@2.120.0 config diff --project-ref bbmdkpzzzalkvthwgsek --workdir /tmp/fizz-security-config
npx --yes supabase@2.120.0 config push --project-ref bbmdkpzzzalkvthwgsek --workdir /tmp/fizz-security-config --yes
```
