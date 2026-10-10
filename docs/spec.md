# Pre-Procedure Prep App — Build Spec

Oct 7, 2026 · @Sajjad Shaik

## Reality check and v1 scope

No software is un-hackable, so the real target is this: pass a hospital vendor security review, limit the damage of any breach, detect attacks fast, and recover cleanly. Anyone promising "un-hackable" in a security review loses credibility on the spot.

The strongest security decision is architectural: **hold as little patient data as possible**. Data you never store cannot leak.

**Recommended v1 design ("zero-PHI server"):**

- Clinicians author prep *protocols* on the server. A protocol is reusable content (e.g., "Colonoscopy, split-dose PEG, morning slot"), not patient data.
- The patient gets a protocol code or QR at scheduling. The app downloads the protocol, and the patient enters the procedure date and time **on the device only**.
- The timeline and reminders are computed and scheduled locally on the phone. No name, phone number, MRN or date ever reaches the server.
- Trade-off: no SMS reminders and no staff dashboard of who is on track in v1. Both require storing PHI, which brings in HIPAA's full weight. Add them in a later phase, deliberately.

**v1 scope:** one procedure family (colonoscopy, the most common prep failure), one department, a clinician protocol editor, a patient timeline with reminders, a day-of checklist, and a "something went wrong" screen that routes to a phone number rather than giving advice.

**What "Cleveland Clinic-ready" actually takes:** a sponsoring department, a clinical owner who signs off on content, a Business Associate Agreement if any PHI is touched, and their IT security review. Build as if all of that will happen; none of it can be skipped later.

- [ ]

  ## Lessons from similar products

Prep apps help, but the evidence is weaker than vendors claim, and most existing apps share the same fixable defects. Up to 25% of colonoscopies fail due to poor prep ([JMIR Human Factors, 2025](https://humanfactors.jmir.org/article/export/ris/humanfactors_v12i1e67043)). A 2019 meta-analysis found app users had better cleansing (87.1% vs 76.9%) in randomized trials, but the pooled result was not statistically significant ([Endoscopy International Open](https://thieme-connect.de/products/ejournals/html/10.1055/a-0796-6423?lang=en)).

| Defect | Where it shows up | How this project fixes it |
| --- | --- | --- |
| Hardwired to one prep drug or one schedule | [Prepit](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8414298/) is made by Ferring, a prep-drug maker; the [Zhengzhou trial app](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC13416303/) only covers sodium phosphate with morning prep and afternoon procedures | Protocols are data, not code. Any regimen, time slot or procedure is a new protocol, not a new release |
| Content goes stale | GLP-1 drug guidance flipped from "hold" (2023) to a more individualized approach in Dec 2024 ([AGA](https://news.gastro.org/issues/2026/january/glp1-receptor-agonist-use-in-gastrointestinal-endoscopy-a-review-of-current-evidence-and-guidelines)). Hardcoded apps lag | Every protocol has a named clinical owner, version number and mandatory review date. Expired protocols stop being served |
| Excludes people without smartphones or tech skills | Trials commonly exclude them ([NCT07395492](https://clinicaltrials.gov/study/NCT07395492)) | Printable one-page timeline from the same protocol; caregiver mode; large text; works as a web app with no install |
| Single platform | [ColoprAPP](https://mhealth.jmir.org/2017/9/e138/PDF) was Android-only | One Flutter codebase for iOS and Android, plus a no-install web page with print and calendar download |
| Failure discovered too late | At Brigham, poor prep usually shows only after sedation and scope insertion ([BWH Bulletin](https://bwhbulletin.org/2018/02/01/endoscopy-center-sees-success-with-text-message-reminder-system/)) | Day-of self-check with a picture guide. If prep looks inadequate, the app tells the patient to call the unit before leaving home |
| Reminders without behavior change | An editorial on the Walter et al. trial argues the delivery vehicle matters less than behavior-change principles ([CGH editorial](https://pmc.ncbi.nlm.nih.gov/articles/PMC7897467)) | Each step needs a tap to confirm ("Done" / "I missed this"). A missed step routes to a clinician-written recovery instruction or a phone number |
| Too much data entry, too little reassurance | Patients asked for minimal input, alerts up to 7 days out, visuals, a trusted source and post-procedure info ([colonAPPscopy study](https://zendy.io/title/10.2196/12242)) | Patient enters only date and time. Hospital branding, pictograms, a 7-day window and a short after-procedure section |
| Broken authorization and hardcoded secrets | All 30 tested mHealth apps had BOLA flaws; 77% had hardcoded API keys ([SecurityWeek](https://www.securityweek.com/mobile-health-apps-found-expose-records-millions-users), [CISO Mag](https://www.cisomag.com/?p=9959)) | Zero-PHI patient side; object-level authorization on every staff endpoint; no secrets in client code (see Security) |
| Tracking pixels leaking health data | Legacy Health ran Meta Pixel and Google Analytics on its portal from 2019 to 2024 ([gblock](https://www.gblock.app/articles/legacy-health-tracking-pixel-settlement)); Novant settled for $6.6M ([WRAL](https://www.wral.com/amp/21230147/)) | No third-party analytics, ad SDKs or CDNs on patient pages, enforced by Content Security Policy and a CI check |

The gap this project fills: a **vendor-neutral, protocol-driven** tool that clinicians can update without developers, with privacy built in rather than bolted on.

## Regulatory and compliance requirements

The zero-PHI v1 avoids most HIPAA obligations, but accessibility, FDA scope and the hospital's own review still apply in full. This is not legal advice; the Clinic's compliance and legal teams make the final call.

| Requirement | What it means for this app | When it bites |
| --- | --- | --- |
| HIPAA Privacy and Security Rules | Applies once the server stores any patient-linked data (phone, name, date + procedure). Then you need a Business Associate Agreement, risk analysis, encryption, access controls, audit logs and breach procedures | Phase 2 (SMS, staff dashboard) |
| HHS tracking-technology guidance | Third-party trackers that send PHI without patient authorization or a BAA are a HIPAA problem ([HIPAA Journal](https://www.hipaajournal.com/palm-beach-health-sued-meta-pixel-patient-portal/)). Simplest rule: no third-party trackers at all | Day one |
| FDA software-as-a-medical-device | FDA exercises enforcement discretion for low-risk apps that give reminders or help patients follow schedules ([FDA](https://www.fda.gov/medicaldevices/digitalhealth/mobilemedicalapplications/ucm368744.htm)). Stay there: show clinician-written instructions only. The moment the app *decides* treatment (e.g., "based on your answers, skip your blood thinner"), it may become a regulated device | Every feature decision |
| Section 504 accessibility | Hospital websites and mobile apps, including third-party ones, must meet WCAG 2.1 AA. HHS extended the deadline to May 11, 2027 for organizations with 15+ employees ([Duane Morris](https://www.duanemorris.com/alerts/health_human_services_follows_department_justices_lead_extends_section_504_web_mobile_0526.html)) | Day one; audited before any pilot |
| Section 1557 language access | Federally funded providers must offer meaningful access for patients with limited English. Plan for translated protocols reviewed by qualified translators, not machine output alone | Before any pilot |
| TCPA and carrier rules for SMS | Text reminders need documented consent and opt-out handling | Phase 2 |
| Hospital vendor security review | Expect a security questionnaire (often HECVAT or SIG), a penetration test report and possibly SOC 2 Type II or HITRUST for production | Before any real deployment |
| Clinical governance | Content must be approved by the department that owns the procedure, with a documented review cycle | Before any patient sees it |

## Security design

With no patient data on the server, the biggest threat shifts from *data theft* to *content tampering*: an attacker who edits a protocol can tell thousands of patients to take the wrong dose. Integrity of instructions is the top priority, then availability, then confidentiality.

**Principles:** store nothing you don't need, trust no request, give every account the least access possible, assume a breach will happen and limit what it reaches.

| Attack class | Control |
| --- | --- |
| Tampered or malicious protocol content | Two-person rule: an author drafts, a different clinician approves. Approved bundles are cryptographically signed (e.g., Ed25519). The patient app refuses any unsigned or mis-signed bundle. Every publish triggers an alert to the clinical owner |
| Staff account takeover (phishing, credential stuffing) | No local passwords. Sign in only through the hospital's identity provider (SAML/OIDC) with phishing-resistant MFA (passkeys/FIDO2). Short sessions; re-authenticate before approving or publishing |
| Broken object-level authorization (BOLA/IDOR) | Every request checks the user's role *and* department against the specific object, server-side. Random IDs, never sequential. An automated test for every endpoint proves a user from department A cannot touch department B's protocols |
| Injection (SQL, XSS through protocol text) | Parameterized queries only. Protocol content is structured fields plus a tiny sanitized Markdown subset, never raw HTML. Strict Content Security Policy with no inline scripts |
| Stolen tokens, CSRF, clickjacking | Staff web uses httpOnly, Secure, SameSite cookies, never tokens in localStorage. CSRF tokens on writes. `frame-ancestors 'none'`. HSTS with TLS 1.2+ only |
| Hardcoded secrets | The patient app needs no secrets: it only reads public, signed bundles. Server secrets live in a secrets manager. Secret scanning (e.g., gitleaks) blocks any commit containing a key |
| Third-party trackers and scripts | Zero third-party JavaScript on patient pages. All assets self-hosted on your own domain. CI fails the build if a CSP violation or unknown domain appears |
| Supply-chain compromise (malicious npm package) | Minimal dependencies, lockfiles, pinned versions, automated dependency updates, vulnerability scanning (e.g., OSV-Scanner), an SBOM for every release, signed build artifacts |
| Ransomware or data destruction | Immutable, versioned backups in a separate account (e.g., S3 Object Lock). Infrastructure as code so the whole system can be rebuilt. Restore tested quarterly |
| Outage the night before a procedure | The app caches the patient's protocol offline once downloaded, and reminders are scheduled on the device, so a server outage cannot stop a prep already in progress |
| Lock-screen leakage | Notifications say "Prep step due" by default, never the procedure name. Patients can opt into detailed text |
| Fake app or phishing QR codes | QR codes resolve only to the hospital's own domain; the app always displays that domain. Printed materials tell patients what the real address looks like |
| Insider misuse | Roles separated (author, approver, admin). Append-only audit log of every change: who, what, when, from where. No PHI in any log |

**How to verify it, not just claim it:**

- Use [OWASP ASVS](https://owasp.org/www-project-application-security-verification-standard/) Level 2 as the requirements checklist, and the OWASP API Security Top 10 for the server.
- Keep a written threat model (STRIDE works) and update it whenever a feature changes.
- Run static analysis (Semgrep or CodeQL) and dynamic scanning (OWASP ZAP) in CI on every pull request.
- Get an independent penetration test before any pilot. Publish a vulnerability disclosure policy (`security.txt`).

## Usability

A nurse should be able to create a correct protocol in under 10 minutes with no training, and a patient should never have to think about anything except the next step.

**For clinicians (protocol editor):**

- **Steps, not documents.** Each step is a structured row: time offset from the procedure ("7 days before", "6 hours before"), step type (stop medication, diet change, drink prep, stop all liquids, arrange ride, arrive), short instruction text and an optional pictogram.
- **Start from a template.** Duplicate an approved protocol and change what differs. Nobody starts from a blank page.
- **Live patient preview.** Pick a sample appointment (7:30 AM vs 2:00 PM) and see the exact timeline the patient will get. This catches errors like a second prep dose landing at 2 AM.
- **Safety checks while typing.** Warnings for steps between 11 PM and 5 AM, missing "stop liquids" step, overlapping steps, or a fasting window shorter than the department's minimum. Each department configures its own rules.
- **Reading-level meter.** Shows the grade level of each instruction as it is typed, with a target of 6th grade or lower.
- **Approver sees a diff.** The approving clinician sees exactly what changed from the last version, highlighted, and approves with one action.
- **Handouts generated automatically.** Every published protocol produces a printable one-page timeline and a QR code for the scheduler to hand over.

**For patients:**

- The home screen answers one question: "What do I do now?" It shows the current step, the next step and a countdown.
- Each step has "Done" and "I missed this" buttons. "I missed this" shows the clinician-written recovery instruction or a phone number, never improvised advice.
- Rescheduled? Change the date once and every reminder is recomputed.
- All times are anchored to the hospital's time zone and handle daylight-saving changes. Travel and DST shifts are a classic source of wrong-hour reminders.
- Include a "confirm your ride home" step. Sedated patients without an escort are a common, avoidable reason for same-day cancellation.
- Caregiver mode: share the timeline with a family member's phone.
- Large tap targets, screen-reader labels, high contrast and full WCAG 2.1 AA conformance.

**Validate with real users.** Run think-aloud sessions with 3–5 nurses and 5 patients (or proxies) before writing more features. Small samples catch most usability problems.

## Changeability

Most future changes should be content edits done by clinicians in minutes, not code releases done by developers in weeks. That only works if content and logic are separated from day one.

**1. Protocols are versioned data.** A protocol is a JSON document validated against a published schema. Clinical changes never touch code. (The values below are illustrative, not clinical guidance.)

```json
{
  "schemaVersion": 1,
  "protocolId": "colo-peg-split-am",
  "version": 7,
  "owner": "GI Endoscopy",
  "reviewBy": "2027-04-01",
  "timezone": "America/New_York",
  "steps": [
    { "offset": "-P7D", "type": "medication_hold", "text": "Stop iron pills." },
    { "offset": "-P1D", "type": "diet", "text": "Clear liquids only today." },
    { "offset": "-PT6H", "type": "prep_dose", "text": "Drink the second half of your prep." },
    { "offset": "-PT2H", "type": "npo", "text": "Stop all liquids now." }
  ],
  "signature": "…"
}
```

**2. Published versions are immutable.** Edits create a new version; old ones are kept forever for audit. When publishing, the approver marks the change as either *wording only* or *safety-relevant*. Safety-relevant changes notify patients holding the old version on their next app open.

**3. One small, heavily tested core.** The timeline calculator (offsets + appointment time + time zone → dated steps) is the only clinical logic. It exists exactly once: a pure Dart package used by the patient app and compiled to JavaScript for the portal's preview, so the preview can never disagree with what patients receive. It gets the most tests:

- Unit tests for each step type.
- Property-based tests across daylight-saving transitions and every hour of the day.
- Explicit safety-invariant tests: no step lands in quiet hours, liquids stop before the procedure, steps stay in order. These assert behavior directly. Stored golden timelines exist only as a regression net on top, never as the main test.

**4. Clear module boundaries.** Start as one deployable service with four separate modules: authoring, approval and signing, bundle delivery, and the patient client. Split them only when there is a real reason.

**5. Built-in habits that keep it editable later:**

- All user-facing strings externalized from day one, so adding Spanish or Arabic is a translation task, not a refactor.
- Department rules (quiet hours, minimum fasting window) are configuration, not code.
- Feature flags for anything new, so it can be piloted with one department.
- Database migrations in version control; schema versions on every protocol so old bundles still load.
- Architecture Decision Records: one short file per major choice explaining *why*, so the next developer doesn't undo it blindly.

## Tech stack and build plan

The patient app should be native, because only native apps can reliably fire scheduled reminders with no server and no network. Everything else should be boring, well-documented technology.

&#91;embedded content: architecture · 7 steps, server to phone\]

Clinical content flows one way, from server to phone. The appointment date and reminders exist only on the patient's device.

| Component | Choice | Why |
| --- | --- | --- |
| Patient app | Flutter (iOS + Android) with on-device scheduled notifications | Reminders fire offline with nothing sent to a server. Web apps cannot reliably schedule reminders while closed |
| Patient web fallback | Static page: timeline, print, calendar (.ics) download | The phone's own calendar does the reminding, still with zero data sent to the server |
| Staff portal | TypeScript + React | Mature accessibility tooling. Flutter web draws to a canvas and is harder to make WCAG-conformant |
| API | Python (FastAPI) | Pick one language and keep it boring |
| Database | PostgreSQL (AWS RDS), encrypted at rest | Protocols, versions, approvals, audit log |
| Protocol delivery | Signed static JSON on S3 + CloudFront under the hospital's domain | Read-only, cacheable, keeps working during API outages |
| Signing key | Held in AWS KMS, never exported | Only the approval service may request a signature, and every request is logged |
| Staff login | OIDC to the hospital identity provider; Keycloak for local development | No passwords stored anywhere in the app |
| Infrastructure | Terraform; separate dev, staging and prod AWS accounts; GitHub Actions deploying via OIDC | No long-lived cloud keys exist to leak |
| Monitoring | CloudWatch + OpenTelemetry; alerts on every publish and on login failures | Detects tampering fast; no PHI in logs |

**Build phases** (each ends with a pass/fail check, not a date):

1. **Discovery.** Interview 3–5 endoscopy nurses or schedulers; collect real prep sheets; list the top reasons for same-day cancellation. *Done when:* one real protocol is chosen to digitize.
2. **Core.** Protocol schema, timeline calculator with full tests, patient app showing one signed protocol with offline reminders. *Done when:* golden and daylight-saving tests pass.
3. **Authoring.** Staff portal, two-person approval, signing, audit log, printable handout and QR. *Done when:* a nurse builds a correct protocol in under 10 minutes in a usability test.
4. **Hardening.** ASVS Level 2 checklist, WCAG 2.1 AA audit, threat model, security scans in CI, backup-restore drill, independent penetration test. *Done when:* no high or critical findings are open.
5. **Pilot (needs a clinical sponsor).** One department, one procedure. *Done when:* same-day prep cancellations and adequate-prep rates are measured against the baseline.
6. **PHI features, only if the pilot justifies them.** SMS reminders, a staff dashboard of who is on track, EHR integration via SMART on FHIR. This phase brings in a BAA and a full HIPAA program.

## AI-slop guardrails

All 29 points are enforced below, by tooling where a machine can check them and by a pull-request checklist where it can't. Work through the lists in order; each item names the point numbers it covers.

**Where the rules need nuance in this project:**

- **#4 caught a flaw in this spec.** The original plan leaned on golden (snapshot) timelines as the main test. Changeability now makes explicit safety-invariant tests primary.
- **#10 caught a second one.** The staff preview and the patient app would each have computed timelines, two copies of the only clinical logic. The calculator now exists once.
- **#7 is not "never validate."** Medical software must validate everything at trust boundaries: signed bundles, user input, API requests. The rule bans re-checking, deep inside the code, states the types already make impossible.
- **#9 has one legitimate exception here.** An injectable clock for the timeline calculator has two real implementations (system clock and test clock), so it stays.

### Step 1: before the first feature

- [ ] Branch protection on `main`: block force pushes and deletion. Solo workflow: review locally, then push directly; a pre-push hook runs every lint, type and test check so nothing failing reaches GitHub. Switch to pull requests with one approval once a second person joins (#1)
- [ ] Pull-request template containing the Step 2 checklist (#1, #29)
- [ ] Strict typing that fails CI: TypeScript `strict` plus `no-explicit-any` and `no-unsafe-*`; Dart `strict-casts`, `strict-inference`, `strict-raw-types`; Python `mypy --strict`. Any type-ignore needs a written reason (#11)
- [ ] Lint rules that fail CI: no `console`/`print` (ESLint `no-console`, Dart `avoid_print`, Ruff `T20`) (#12); no empty catches (ESLint `no-empty`, Dart `empty_catches`, Ruff `S110`) (#13); no useless catches (ESLint `no-useless-catch`, Ruff `TRY` rules) (#6)
- [ ] Dependency gate: GitHub dependency review and OSV-Scanner on every pull request; each new package gets one line in an ADR saying why (#2)
- [ ] Duplicate-code check (e.g., jscpd) in CI (#10)
- [ ] Vale prose linter on docs and UI strings, with a banned list: `delve`, `leverage`, `robust`, `seamless`, `unlock`, emoji bullets (#26, #27)
- [ ] Automated accessibility checks (axe-core) in the portal's end-to-end tests (#14)
- [ ] Design-system tokens file written before any screen: colors from hospital branding, type scale, spacing, radius, and at most two elevation levels (overlays only, flat by default) (#15, #16, #17)

### Step 2: before every push

- [ ] I read every line, including AI-generated ones, and can explain and defend each. Anything I can't explain is removed (#1, #29)
- [ ] Every new package was checked on its registry: it exists, has the expected name and maintainer, and isn't a brand-new lookalike (#2)
- [ ] Every test asserts a specific outcome. Mocks only at real boundaries: network, clock, storage (#3)
- [ ] Behavior is tested directly; snapshots never replace an assertion (#4)
- [ ] Every try/catch wraps code that can actually throw and does something useful: recover, add context, or convert the error (#5, #6, #13)
- [ ] No checks for states the types already rule out; validation only at trust boundaries (#7)
- [ ] Comments explain *why*, never restate *what* (#8)
- [ ] No new interface, factory or wrapper without a second real use (#9)
- [ ] I searched the codebase for existing logic before writing new logic (#10)
- [ ] UI works by keyboard and screen reader, at 200% text size, and on the smallest supported phone with no feature hidden (#14, #18)

### Step 3: Core phase

- [ ] Timeline calculator built as one pure Dart package, compiled to JavaScript for the portal preview (#10)
- [ ] Property-based safety-invariant tests written before golden files (#3, #4)
- [ ] Mutation testing run on the calculator; every surviving mutant is either killed with a new test or explained in writing (#3)

### Step 4: Authoring phase

- [ ] Every screen reviewed against the tokens file: no default template look, no uniform shadows (#15, #16, #17)
- [ ] Every portal feature works at tablet width; nothing is cut for small screens (#18)

### Step 5: Hardening phase

- [ ] Manual VoiceOver and TalkBack pass on the patient app; manual keyboard pass on the portal (#14)
- [ ] Code walkthrough without AI: explain each module out loud to another person (#29)
- [ ] README and this spec reread: delete any paragraph a reviewer couldn't act on. Passing Vale doesn't count if the content is empty (#24, #28)

### Step 6: Pilot and later phases

- [ ] Every dashboard chart names the question it answers and the decision it informs (#19)
- [ ] Any AI feature proposal needs, before code: a named user problem, an opt-out, and a fully working non-AI path (#20, #21, #22)

### Ongoing, outside the code

- [ ] Describe the product as a prep app. It is not "AI-powered"; at most say it was built with AI assistance (#23)
- [ ] Reproduce any bug in an upstream library yourself before reporting it; never file unverified AI-written issues or pull requests (#25)

## Suggestions and open risks

The hardest part of this project is not technical: without a clinical sponsor it stays a well-built demo that no patient ever uses.

**Suggestions:**

- **Define the success metric before writing code.** Pick one: same-day cancellations caused by prep, or the share of patients with adequate prep on the Boston Bowel Preparation Scale. Without a baseline, nobody can say the app worked.
- **Keep AI out of patient instructions in v1.** No LLM writes or rewrites what patients read, and no "ask a question about your prep" chatbot. That is where hallucination becomes patient harm and where FDA scope gets murky.
- **Find out what the hospital already uses.** Large systems often push instructions through Epic MyChart or a vendor. Your pitch has to be what those don't do: interactive timeline, missed-step recovery, day-of self-check, zero patient data.
- **Design the schema for more than colonoscopy.** Surgery fasting, cardiac catheterization (blood-thinner holds) and contrast imaging all follow the same "steps relative to a procedure time" pattern.
- **Write the hard documents early.** Threat model, data-flow diagram, accessibility statement and a one-page "what data we store" sheet. Hospital reviewers ask for these first.

**Open questions to settle:**

- [ ] Which department would sponsor a pilot, and who is the clinical owner of content?
- [ ] Is a no-SMS v1 acceptable to the clinicians, or are text reminders a hard requirement?
- [ ] Which languages besides English are needed for the pilot population?
- [ ] Does the hospital require its own app-store developer account or branding for patient-facing apps?
- [ ] What baseline data on prep-related cancellations can the department share?

## Sources

- [Think-Aloud Testing of a Companion App for Colonoscopy Examinations, JMIR Human Factors 2025](https://humanfactors.jmir.org/article/export/ris/humanfactors_v12i1e67043)
- [Smartphone apps and bowel preparation: systematic review and meta-analysis, Endoscopy International Open 2019](https://thieme-connect.de/products/ejournals/html/10.1055/a-0796-6423?lang=en)
- [Prepit randomized controlled trial, JMIR mHealth](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8414298/)
- [AI image-recognition prep app RCT, Zhengzhou](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC13416303/)
- [NCT07395492 app-based education trial](https://clinicaltrials.gov/study/NCT07395492)
- [ColoprAPP feasibility study, JMIR mHealth 2017](https://mhealth.jmir.org/2017/9/e138/PDF)
- [Colonoscopy Bowel Preparation: Is There an App for That? (editorial)](https://pmc.ncbi.nlm.nih.gov/articles/PMC7897467)
- [colonAPPscopy qualitative study](https://zendy.io/title/10.2196/12242)
- [Brigham endoscopy text-reminder program](https://bwhbulletin.org/2018/02/01/endoscopy-center-sees-success-with-text-message-reminder-system/)
- [GLP-1 RA use in GI endoscopy, AGA review](https://news.gastro.org/issues/2026/january/glp1-receptor-agonist-use-in-gastrointestinal-endoscopy-a-review-of-current-evidence-and-guidelines)
- [30 mHealth apps exposed via API flaws, SecurityWeek](https://www.securityweek.com/mobile-health-apps-found-expose-records-millions-users)
- [All That We Let In findings, CISO Mag](https://www.cisomag.com/?p=9959)
- [Legacy Health tracking-pixel settlement](https://www.gblock.app/articles/legacy-health-tracking-pixel-settlement)
- [Novant Meta Pixel settlement, WRAL](https://www.wral.com/amp/21230147/)
- [Palm Beach Health pixel lawsuit and OCR guidance, HIPAA Journal](https://www.hipaajournal.com/palm-beach-health-sued-meta-pixel-patient-portal/)
- [FDA: software functions under enforcement discretion](https://www.fda.gov/medicaldevices/digitalhealth/mobilemedicalapplications/ucm368744.htm)
- [HHS Section 504 deadline extension, Duane Morris](https://www.duanemorris.com/alerts/health_human_services_follows_department_justices_lead_extends_section_504_web_mobile_0526.html)
- [OWASP ASVS](https://owasp.org/www-project-application-security-verification-standard/)
