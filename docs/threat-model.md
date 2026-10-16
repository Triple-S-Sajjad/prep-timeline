# Threat model

STRIDE threats per component, with the controls [the spec](spec.md#security-design) sets. Anything the spec leaves undecided is marked OPEN. Update this file whenever a feature changes.

The ranking comes from the spec: integrity of instructions first, then availability, then confidentiality. With no patient data on the server, the main threat is someone changing a protocol so that patients are told the wrong thing.

## Patient app

Flutter app for iOS and Android, plus the static web page used as a fallback. The patient enters the procedure date and time on the device only.

| STRIDE | Threat | Control |
| --- | --- | --- |
| Spoofing | Fake app or phishing QR code sends the patient to a look-alike site | QR codes resolve only to the hospital's own domain, and the app always displays that domain. Printed materials show what the real address looks like. OPEN: who owns the app-store developer account (the spec lists this as an open question) |
| Tampering | Bundle changed in transit or in storage | The app refuses any unsigned or mis-signed bundle |
| Tampering | QR code edited to change modules or parameter values | Each parameter value is checked against its declared range when the QR code is decoded and again in the calculator. For an appointmentTime group, the app rejects a code whose ticked module doesn't match the appointment time. OPEN, decide before Phase 3: whether the QR code itself is signed |
| Tampering | Older, validly signed bundle served in place of the current one | The app rejects a version older than the one it holds, and the same version with different manifest bytes, since published versions are immutable. OPEN: whether it checks the review date itself |
| Tampering | Device clock or time zone set wrong, so the app reads the wrong current time | OPEN: reminder times, reminder lateness and the newly-past-due check on a reschedule all trust the device's current time; nothing checks it against another source |
| Tampering | Time zone rules on the device are out of date, so local times after a rule change are wrong | OPEN: how the app's time zone rules get updated. The calculator's data is IANA 2025c and ends in 2037 ([ADR 1, Known limitations](adr/0001-repository-tooling.md#known-limitations)) |
| Repudiation | Not applicable on the server: no patient actions reach it | OPEN: where "Done" and "I missed this" taps are stored |
| Information disclosure | Lock screen shows the procedure | Notifications say "Prep step due" by default; the patient can opt into detailed text |
| Information disclosure | Lost or shared phone exposes the appointment date | OPEN: whether data on the device is encrypted beyond the OS default |
| Information disclosure | Third-party trackers on patient pages | No third-party JavaScript, analytics, ad SDKs or CDNs on patient pages. All assets are self-hosted on the hospital's domain, enforced by Content Security Policy and a CI check |
| Information disclosure | Caregiver mode shares the timeline | OPEN: how sharing works and what data it sends |
| Denial of service | Server outage the night before a procedure | The protocol is cached offline once downloaded, and reminders are scheduled on the device |
| Denial of service | The OS limits or drops scheduled local notifications: iOS keeps only a capped number pending per app, and Android battery optimization can delay or drop them | OPEN: how the app stays under the iOS cap and what it does when Android holds back a reminder |
| Elevation of privilege | Client secret extracted from the app | The app holds no secrets; it only reads public, signed bundles |

## Static bundle delivery

Signed static JSON on S3 and CloudFront, under the hospital's domain. A protocol's manifest and modules are versioned and signed as one unit: the manifest records each module's version and SHA-256, and a detached signature, protocol.sig, signs the ASCII label "prep-timeline/manifest/v1" followed by the SHA-256 of the manifest's exact bytes.

| STRIDE | Threat | Control |
| --- | --- | --- |
| Spoofing | Bundles served from a domain the attacker controls | Served only under the hospital's domain; the app checks the signature whatever the source |
| Tampering | A file changed in S3 or at the CDN | The signature covers every byte of the manifest, and the manifest lists every module's hash, so a changed or swapped manifest or module fails verification |
| Repudiation | A publish nobody admits to | Every publish alerts the clinical owner, and the audit log records who, what, when and from where |
| Information disclosure | Bundle contents read by anyone | Bundles are public protocol content with no patient data |
| Information disclosure | Access logs link an IP address to a protocol ID | OPEN: whether CDN access logs are kept, and for how long |
| Denial of service | API outage | Bundles are static and cacheable, and keep being served during API outages |
| Denial of service | Traffic flood against the CDN | OPEN: no rate limiting or flood protection is specified |
| Elevation of privilege | Write access to the bucket | Infrastructure as code; deploys use GitHub Actions with OIDC, so no long-lived cloud keys exist. Write access alone can't produce a valid signature. OPEN: which role may write the bucket |
| Elevation of privilege | Expired protocol still served | Expired protocols stop being served. OPEN: how expiry is enforced |

## Staff portal

TypeScript and React. Sign-in through the hospital's identity provider. Roles: author, approver, admin.

| STRIDE | Threat | Control |
| --- | --- | --- |
| Spoofing | Phishing or credential stuffing | No local passwords. SAML or OIDC sign-in through the hospital's identity provider with phishing-resistant MFA (passkeys or FIDO2). Short sessions. OPEN: session length |
| Spoofing | Hijacked session used to approve | Re-authentication before approving or publishing |
| Tampering | Malicious protocol content | Two-person rule: an author drafts and a different clinician approves. The approver sees a highlighted diff from the last version |
| Tampering | XSS through protocol text | Content is structured fields plus a small sanitized Markdown subset, never raw HTML. Strict Content Security Policy with no inline scripts |
| Tampering | CSRF and clickjacking | CSRF tokens on writes; `frame-ancestors 'none'` |
| Repudiation | Staff member denies a change | Append-only audit log of every change: who, what, when, from where |
| Information disclosure | Token theft | httpOnly, Secure, SameSite cookies; never tokens in localStorage. HSTS, TLS 1.2 or later only |
| Denial of service | Portal unavailable | Patients are unaffected, since delivery is static. OPEN: no portal availability target is set |
| Elevation of privilege | User acts outside their role | Roles separated; the API checks role and department on every request. OPEN: whether an admin can also author or approve |

## API

Python and FastAPI, one deployable service holding the authoring, approval and signing, and bundle delivery modules. PostgreSQL on RDS holds protocols, versions, approvals and the audit log.

| STRIDE | Threat | Control |
| --- | --- | --- |
| Spoofing | Request with a forged or stolen session | Session cookies from the identity-provider sign-in; short sessions |
| Tampering | SQL injection | Parameterized queries only |
| Tampering | Published version changed afterwards | Published versions are immutable; an edit creates a new version, and old ones are kept for audit |
| Tampering | Malicious dependency | Few dependencies, lockfiles, pinned versions, automated updates, OSV-Scanner, an SBOM for every release, signed build artifacts |
| Repudiation | Change without a record | Append-only audit log; no PHI in any log. OPEN: how append-only is enforced |
| Information disclosure | Broken object-level authorization (BOLA/IDOR) | Every request checks role and department against the specific object, server-side. Random IDs, never sequential. An automated test per endpoint proves a user in department A can't touch department B's protocols |
| Information disclosure | Leaked server secrets | Secrets in a secrets manager; secret scanning blocks commits containing keys. Database encrypted at rest |
| Denial of service | Ransomware or data destruction | Immutable, versioned backups in a separate account (S3 Object Lock). Infrastructure as code so the system can be rebuilt. Restore tested quarterly |
| Denial of service | Request flood | OPEN: no rate limiting is specified |
| Elevation of privilege | Cross-department access | Server-side role and department checks, tested per endpoint (above). OPEN: whether roles and departments come from the identity provider or the database |

Detection: CloudWatch and OpenTelemetry, with alerts on every publish and on login failures. Static analysis (Semgrep or CodeQL) and dynamic scanning (OWASP ZAP) run on every pull request.

## Signing and KMS

The signing key is held in AWS KMS and never exported. Only the approval service may request a signature.

| STRIDE | Threat | Control |
| --- | --- | --- |
| Spoofing | Another service requests a signature | Only the approval service may request one. OPEN: how that restriction is enforced |
| Tampering | Unapproved content signed | Signing follows two-person approval. The signature is Ed25519 over the label and the SHA-256 of the manifest's exact bytes, and the manifest lists each module's hash |
| Repudiation | Signature nobody admits to | Every signature request is logged; every publish alerts the clinical owner |
| Information disclosure | Private key stolen | Never exported from KMS |
| Denial of service | KMS unavailable | Publishing needs a signature; bundles already published keep being served |
| Elevation of privilege | Approval service compromised and signs attacker content | Re-authentication before approving, publish alerts, audit log. OPEN: key rotation, revocation, and how the app gets and trusts the public key |
