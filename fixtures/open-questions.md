# Open questions for clinical owners

Contradictions and ambiguities inside the public source sheets behind the test fixtures. Each needs an answer from the sheet's clinical owner before a real module is written from it.

- Karmanos split prep: the morning schedule is for appointments "before 12 noon" and the afternoon one "after 12 noon", so a 12:00 appointment fits neither. The fixtures put 12:00 in the afternoon module. [Source](https://www.karmanos.org/uploads/Public/Documents/Northern/forms/602.035%20Split%20Colonoscopy%20Prep%20Instructions.pdf)
- Karmanos split prep: regular pills are allowed with sips of water up to 3 hours before, but all oral intake stops 4 hours before. [Source](https://www.karmanos.org/uploads/Public/Documents/Northern/forms/602.035%20Split%20Colonoscopy%20Prep%20Instructions.pdf)
- UMMC GoLytely split dose: "nothing to eat or drink except the prep" on the procedure morning, but "take your regular medications with a sip of water" on exam day. [Source](https://www.umms.org/ummc/-/media/files/ummc/health-services/digestive-health/colonos-prep-instr-golytely-split-dose.pdf)
- Cleveland Clinic SUTAB: "repeat steps 1-3" six hours before. In the evening step 2 comes 3 hours after step 1; with the same gap in the morning it lands on the 3-hour liquid cutoff. What spacing applies in the morning? [Source](https://my.clevelandclinic.org/health/articles/sutab-bowel-preparation-instructions)
- BMC GoLYTELY split dose: the header says arrive 1 hour before the "appointment time", while steps say "2 hours before your appointment" and "1 hour before your procedure time". Are appointment time and procedure time the same? [Source](https://www.bmc.org/files/gastro-prep/english/Colonoscopy%20Golytely%20Split%20Dose%20Prep.pdf)
- BMC medication sheet: the diabetes table says to skip a daily GLP-1 only on the procedure day, but the weight-loss section says not to take any GLP-1 for 1 week before. [Source](https://www.bmc.org/files/gastro-prep/english/MEDICATION%20MANAGEMENT%20INSTRUCTIONS%20FOR%20ENDOSCOPY%20-%20update%203.4.25.pdf)
- UW heart catheterization: fasting counts from check-in (6 and 8 hours), but the snack and alarm advice counts from the procedure time, which the patient isn't told. [Source](https://healthonline.washington.edu/sites/default/files/record_pdfs/How-to-Prepare-for-Your-Heart-Catheterization_a11y.pdf)
- UW heart catheterization: nothing to eat or drink for 6 hours before check-in, but take usual morning medicines with small sips of water. [Source](https://healthonline.washington.edu/sites/default/files/record_pdfs/How-to-Prepare-for-Your-Heart-Catheterization_a11y.pdf)
- UW heart catheterization: the sheet has separate after-care for a groin site and an arm (wrist) site. The fixtures treat them as either/or: the discharge nurse picks exactly one. Can a patient ever have both sites, and if so, which instructions apply? [Source](https://healthonline.washington.edu/sites/default/files/record_pdfs/How-to-Prepare-for-Your-Heart-Catheterization_a11y.pdf)

## Past-due levels to confirm

The sheets don't say what happens when a hold starts late. The fixtures set these `pastDue` levels as placeholders; each needs the clinical owner to confirm or change it. `critical` tells the patient to call their care team; `doNow` tells them to do it today.

- Iron holds set to `doNow`: a late start is assumed not to cancel the procedure. [UMMC](https://www.umms.org/ummc/-/media/files/ummc/health-services/digestive-health/colonos-prep-instr-golytely-split-dose.pdf), [BMC](https://www.bmc.org/files/gastro-prep/english/MEDICATION%20MANAGEMENT%20INSTRUCTIONS%20FOR%20ENDOSCOPY%20-%20update%203.4.25.pdf), [Karmanos](https://www.karmanos.org/uploads/Public/Documents/Northern/forms/602.035%20Split%20Colonoscopy%20Prep%20Instructions.pdf), [Cleveland Clinic](https://my.clevelandclinic.org/health/articles/sutab-bowel-preparation-instructions)
- NSAID holds set to `doNow`. [Karmanos](https://www.karmanos.org/uploads/Public/Documents/Northern/forms/602.035%20Split%20Colonoscopy%20Prep%20Instructions.pdf), [MSK](https://www.mskcc.org/cancer-care/patient-education/instructions-before-your-procedure-or-surgery)
- Supplement holds (vitamins, supplements, herbal remedies) set to `doNow`. [MSK](https://www.mskcc.org/cancer-care/patient-education/instructions-before-your-procedure-or-surgery)
- GLP-1 holds, weekly and daily, set to `critical`: a late start is assumed to risk cancellation. [BMC](https://www.bmc.org/files/gastro-prep/english/MEDICATION%20MANAGEMENT%20INSTRUCTIONS%20FOR%20ENDOSCOPY%20-%20update%203.4.25.pdf)
- SGLT2 hold set to `critical`. [BMC](https://www.bmc.org/files/gastro-prep/english/MEDICATION%20MANAGEMENT%20INSTRUCTIONS%20FOR%20ENDOSCOPY%20-%20update%203.4.25.pdf)
- Aspirin limit set to `critical`, the same as the blood-thinner holds. [Karmanos](https://www.karmanos.org/uploads/Public/Documents/Northern/forms/602.035%20Split%20Colonoscopy%20Prep%20Instructions.pdf)

## Daylight-saving rule to confirm

No source sheet covers this; the rule comes from the timeline calculator and applies to every protocol. It needs the clinical owner to confirm or change it.

- A clock time that doesn't exist because of a spring-forward change resolves to the earlier instant; a time that happens twice resolves to its first occurrence. For cutoffs, earlier is the more restrictive choice. Example: a 2:30 AM prep dose on the night clocks spring forward is due at 1:30 AM; a 1:30 AM cutoff on the night clocks fall back applies at the first 1:30 AM.

## Reminder rules to confirm

These come from the app's design, not a source sheet, and apply to every protocol.

- A reminder is never dropped. If it would come during quiet hours (for a step not allowed at night) or after the step has already started, it moves earlier to the nearest allowed time. Its text always gives the real time the step starts.
- The app never uses the appointment time in place of an arrival time the patient hasn't entered. If a step that counts from arrival is still waiting at the evening reminder time the day before the appointment, the patient gets "Enter your arrival time or call us" instead.
- A restriction that lasts a set time, like "no driving for 24 hours", is reminded when it starts. No reminder comes when it ends; the app shows the end time.

## Reminders that may fail the publish check

Publishing fails if any reminder would need moving out of quiet hours or to before its step takes effect (the move on the phone is only a safety net).

- UMMC arrival: the reminder comes 1 hour before the appointment, and the step isn't allowed at night. With the placeholder bookable hours (from 7 AM) the earliest reminder is 6 AM, which passes. If the department books appointments before 6 AM, this step needs `allowNight` or a different reminder before the publish check lands. [UMMC](https://www.umms.org/ummc/-/media/files/ummc/health-services/digestive-health/colonos-prep-instr-golytely-split-dose.pdf)
- UW first day after a groin catheterization: the reminder comes 24 hours after discharge, and the step isn't allowed at night. The publish check samples discharge across the whole day, so a discharge between 11 PM and 5 AM puts the reminder in quiet hours. Options: `allowNight` or a different reminder on this step, or protocols declare discharge hours the way they declare bookable hours. Undecided. [UW](https://healthonline.washington.edu/sites/default/files/record_pdfs/How-to-Prepare-for-Your-Heart-Catheterization_a11y.pdf)

## Placeholder hours to replace

No source sheet gives these, so every fixture manifest uses a placeholder. The department needs to supply its real values.

- Quiet hours, when reminders don't go out unless a step must happen at night: 11 PM to 5 AM in every fixture.
- Bookable appointment hours, the times the department actually schedules: 7 AM to 5 PM in every fixture, except 7 AM to noon for the UMMC morning-only prep.

## How long day steps last

Each step tied to a calendar day now says whether it lasts one day or until the appointment. The fixtures choose by the sheet's wording; each choice needs the clinical owner to confirm or change it.

- One day: clear liquids (UMMC, BMC, Karmanos, Cleveland Clinic), mixing the prep (UMMC, BMC, Karmanos), half-dose insulin (BMC, Cleveland Clinic), the daily GLP-1 hold (BMC, "today"), rereading the medication sheet (BMC), reading the instructions, buying supplies and asking about blood thinners (Karmanos), picking up the kit and asking about blood thinners (Cleveland Clinic), and the "nurse hasn't called" check (UW).
- Until the appointment: iron, warfarin, Plavix-type, SGLT2, Ticlid, DOAC, Lovenox, NSAID and supplement holds; the weekly GLP-1 hold; the aspirin limit (Karmanos); low-fiber diets (BMC, Karmanos, Cleveland Clinic); nothing but prep on the procedure morning (UMMC); and skipping diabetes pills that morning (BMC).
- The weekly GLP-1 hold says "until after your procedure", but "until the appointment" ends at the appointment time. [BMC](https://www.bmc.org/files/gastro-prep/english/MEDICATION%20MANAGEMENT%20INSTRUCTIONS%20FOR%20ENDOSCOPY%20-%20update%203.4.25.pdf)
- Clear liquids are set to one day because the sheets say "today". That leaves the procedure morning, before the fasting cutoff, with no diet step at BMC, Karmanos and Cleveland Clinic. Do clear liquids continue that morning? [BMC](https://www.bmc.org/files/gastro-prep/english/Colonoscopy%20Golytely%20Split%20Dose%20Prep.pdf), [Karmanos](https://www.karmanos.org/uploads/Public/Documents/Northern/forms/602.035%20Split%20Colonoscopy%20Prep%20Instructions.pdf), [Cleveland Clinic](https://my.clevelandclinic.org/health/articles/sutab-bowel-preparation-instructions)

## Arrival entry to decide

This comes from the app's design, not a source sheet, and applies to every protocol. Decide before the arrival-entry screen is built.

- Arrival lower bound: `arrivalAt` rejects an arrival after the appointment but accepts any earlier one, so a wrong date the patient types (a day or a year early) moves every arrival-anchored step. Proposed: the protocol states an explicit maximum lead, such as arrival no more than `PT12H` before the appointment, written in the manifest rather than hardcoded. Open: the value per department, and whether it belongs in `departmentDefaults` or per protocol.
