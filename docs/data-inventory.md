# Data inventory

Every piece of data in v1, where it lives and whether it is PHI. Source: [the spec](spec.md). The v1 rule is that no name, phone number, MRN or date ever reaches the server. Anything undecided is marked OPEN.

## On the server

| Data | Where it lives | PHI | Notes |
| --- | --- | --- | --- |
| Protocol manifests and modules: steps, timings, text, department defaults, time zone | PostgreSQL (RDS, encrypted at rest); published copies on S3 and CloudFront | No | Reusable content, not patient data. Every version kept forever |
| Version metadata: owner, review date, wording-only or safety-relevant flag | PostgreSQL | No | |
| Approvals | PostgreSQL | No | The author and the approver are different clinicians |
| Audit log: who, what, when, from where | PostgreSQL | No | Append-only; no PHI in any log. Holds staff identity |
| Signature | Published bundle | No | One per protocol version, covering the module hashes |
| Signing private key | AWS KMS | No | Never exported |
| Staff identity and sessions | Hospital identity provider; session cookie | No | No passwords stored anywhere in the app. OPEN: where roles and departments are stored |
| Server secrets | Secrets manager | No | None in client code |
| Monitoring and logs | CloudWatch, OpenTelemetry | No | No PHI in logs. OPEN: whether IP addresses are kept, in API logs and CDN access logs, and for how long |
| Backups | Separate AWS account, S3 Object Lock | No | Copies of the database |

## Handed to the patient

| Data | Where it lives | PHI | Notes |
| --- | --- | --- | --- |
| Scheduling QR code: protocol ID and version, module IDs, parameter values, creation instant | Paper or screen given to the patient; the patient's phone | No | Never carries identity. OPEN: where the code is generated, and whether the server sees its contents |
| Discharge QR code: the same fields for after-procedure modules | As above | No | As above |
| Printed one-page timeline | Paper | OPEN | OPEN: whether it is printed with the appointment date filled in |

## On the patient's device only

| Data | Where it lives | PHI | Notes |
| --- | --- | --- | --- |
| Procedure date and time | Patient app or web page | No, since it never leaves the device | Entered by the patient |
| Arrival time | Patient app | No, as above | Cleared by a reschedule |
| Discharge instant ("I'm home") | Patient app | No, as above | |
| Cached protocol bundle | Patient app | No | Kept for offline use |
| Computed timeline and reminders | Patient app; OS notification schedule | No, as above | Lock-screen text is "Prep step due" unless the patient opts in |
| Detailed-notification opt-in | Patient app | No | |
| "Done" and "I missed this" taps | OPEN | OPEN | OPEN: where they are stored and for how long |
| Calendar (.ics) file | Patient's calendar | No, as above | Generated without sending data to the server. OPEN: the patient's calendar may sync to a cloud provider |
| Caregiver-shared timeline | Family member's phone | OPEN | OPEN: how it is shared |

## Not collected in v1

Names, phone numbers, MRNs, email addresses, SMS consent and any staff dashboard of patient progress. These arrive only in phase 2, which needs a Business Associate Agreement and a full HIPAA program.
