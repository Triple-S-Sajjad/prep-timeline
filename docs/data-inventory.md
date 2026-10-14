# Data inventory

Every piece of data in v1, where it lives and whether the hospital or a vendor holds it. Health information counts as PHI only when the hospital or one of its vendors holds it; data that stays with the patient is not PHI but is still sensitive. Source: [the spec](spec.md). The v1 rule is that no name, phone number, MRN or date ever reaches the server. Anything undecided is marked OPEN.

## On the server

| Data | Where it lives | Held by hospital or vendor? | Notes |
| --- | --- | --- | --- |
| Protocol manifests and modules: steps, timings, text, department defaults, time zone | PostgreSQL (RDS, encrypted at rest); published copies on S3 and CloudFront | Yes; not patient data | Reusable content. Every version kept forever |
| Version metadata: owner, review date, wording-only or safety-relevant flag | PostgreSQL | Yes; not patient data | |
| Approvals | PostgreSQL | Yes; not patient data | The author and the approver are different clinicians |
| Audit log: who, what, when, from where | PostgreSQL | Yes; staff data, not patient data | Append-only; no patient data. Holds staff identity |
| Signature | Published bundle | Yes; not patient data | One per protocol version, covering the module hashes |
| Signing private key | AWS KMS | Yes; not patient data | Never exported |
| Staff identity and sessions | Hospital identity provider; session cookie | Yes; staff data, not patient data | No passwords stored anywhere in the app. OPEN: where roles and departments are stored |
| Server secrets | Secrets manager | Yes; not patient data | None in client code |
| Monitoring and logs | CloudWatch, OpenTelemetry | Yes. OPEN: treat as PHI until retention is decided | An IP address plus a protocol ID in API or CDN logs can link a person to a procedure. To meet the spec's 'no PHI in any log', either IP addresses are not logged with protocol IDs, or those logs are handled as PHI. OPEN: whether IP addresses are kept, in API logs and CDN access logs, and for how long |
| Backups | Separate AWS account, S3 Object Lock | Yes; not patient data | Copies of the database |

## Handed to the patient

| Data | Where it lives | Held by hospital or vendor? | Notes |
| --- | --- | --- | --- |
| Scheduling QR code: protocol ID and version, module IDs, parameter values, creation instant | Paper or screen given to the patient; the patient's phone | OPEN: treat as PHI until decided | The code never carries identity, but staff create it for a known patient, and its module IDs reveal conditions and medications, for example a warfarin hold. OPEN: where the code is generated, and whether the server sees its contents |
| Discharge QR code: the same fields for after-procedure modules | As above | OPEN: treat as PHI until decided | As above |
| Printed one-page timeline | Paper | OPEN: treat as PHI until decided | OPEN: whether it is printed with the appointment date filled in |

## On the patient's device only

| Data | Where it lives | Held by hospital or vendor? | Notes |
| --- | --- | --- | --- |
| Procedure date and time | Patient app or web page | No: stays on the patient's device; still sensitive health information | Entered by the patient |
| Arrival time | Patient app | No: stays on the patient's device; still sensitive health information | Cleared by a reschedule |
| Discharge instant ("I'm home") | Patient app | No: stays on the patient's device; still sensitive health information | |
| Cached protocol bundle | Patient app | No: stays on the patient's device; still sensitive health information | Kept for offline use |
| Computed timeline and reminders | Patient app; OS notification schedule | No: stays on the patient's device; still sensitive health information | Lock-screen text is "Prep step due" unless the patient opts in |
| Detailed-notification opt-in | Patient app | No: stays on the patient's device; still sensitive health information | |
| "Done" and "I missed this" taps | OPEN | OPEN: treat as PHI until decided | OPEN: where they are stored and for how long |
| Calendar (.ics) file | Patient's calendar | No: stays with the patient and their own calendar provider; still sensitive health information | Generated without sending data to the server. OPEN: the patient's calendar may sync to a cloud provider |
| Caregiver-shared timeline | Family member's phone | OPEN: treat as PHI until decided | OPEN: how it is shared |

## Not collected in v1

Names, phone numbers, MRNs, email addresses, SMS consent and any staff dashboard of patient progress. These arrive only in phase 2, which needs a Business Associate Agreement and a full HIPAA program.
