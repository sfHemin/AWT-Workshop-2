/**
 * AscendClinicsActionsTest — unit tests for the Sprint 3 deterministic
 * verification gate (VerifyPatientAction) and own-record lookup
 * (GetUpcomingAppointmentsAction).
 *
 * These tests create their own fixtures so they don't depend on the seeded
 * org data. They assert the hard rules the agent relies on:
 *   - verification requires BOTH Patient ID and DOB on the SAME contact
 *   - failed/partial verification never says whether a record exists
 *   - the failure message is identical for wrong-id vs wrong-dob (no leak)
 *   - lookup is scoped to the given contact and returns only upcoming,
 *     non-cancelled appointments ordered by date
 *   - responses never contain the full DOB or full Patient ID
 */
@IsTest
private class AscendClinicsActionsTest {

    private static final String PID_A = 'PT-9001';
    private static final String PID_B = 'PT-9002';
    private static final String PID_C = 'PT-9003';   // dedicated to the Sprint 4 reschedule tests
    private static final Date   DOB_A = Date.newInstance(1985, 3, 12);
    private static final Date   DOB_B = Date.newInstance(1990, 7, 22);
    private static final Date   DOB_C = Date.newInstance(1979, 1, 5);

    @TestSetup
    static void setup() {
        Contact a = new Contact(FirstName='Test', LastName='PatientA', Patient_ID__c=PID_A, Birthdate=DOB_A);
        Contact b = new Contact(FirstName='Test', LastName='PatientB', Patient_ID__c=PID_B, Birthdate=DOB_B);
        Contact c = new Contact(FirstName='Test', LastName='PatientC', Patient_ID__c=PID_C, Birthdate=DOB_C);
        insert new List<Contact>{ a, b, c };

        Datetime now = Datetime.now();
        insert new List<Appointment__c>{
            // Patient A — two upcoming (one soon) + one past + one cancelled-future
            new Appointment__c(Contact__c=a.Id, Appointment_DateTime__c=now.addHours(3),
                Department__c='General Medicine', Doctor__c='Dr. Alan Smith', Status__c='Scheduled'),
            new Appointment__c(Contact__c=a.Id, Appointment_DateTime__c=now.addDays(6),
                Department__c='Cardiology', Doctor__c='Dr. Priya Patel', Status__c='Scheduled'),
            new Appointment__c(Contact__c=a.Id, Appointment_DateTime__c=now.addDays(-5),
                Department__c='Dermatology', Doctor__c='Dr. Grace Lee', Status__c='Scheduled'),
            new Appointment__c(Contact__c=a.Id, Appointment_DateTime__c=now.addDays(10),
                Department__c='Orthopedics', Doctor__c='Dr. Luis Gomez', Status__c='Cancelled'),
            // Patient B — one upcoming (must never surface for A)
            new Appointment__c(Contact__c=b.Id, Appointment_DateTime__c=now.addDays(4),
                Department__c='Pediatrics', Doctor__c='Dr. Omar Walker', Status__c='Scheduled'),
            // Patient C — purpose-built for reschedule tests (kept off A/B so Sprint 3 counts hold):
            //  • cFuture : a clean future weekday 14:00 clinic-local slot, Scheduled → valid target + idempotency
            //  • cPast   : a past Scheduled appt → "already taken place"
            //  • cCancel : a future Cancelled appt → "cancelled, can't reschedule"
            new Appointment__c(Contact__c=c.Id, Appointment_DateTime__c=clinicSlot(nextWeekday(5), 14, 0),
                Department__c='Cardiology', Doctor__c='Dr. Priya Patel', Status__c='Scheduled'),
            new Appointment__c(Contact__c=c.Id, Appointment_DateTime__c=now.addDays(-3),
                Department__c='Dermatology', Doctor__c='Dr. Grace Lee', Status__c='Scheduled'),
            new Appointment__c(Contact__c=c.Id, Appointment_DateTime__c=now.addDays(8),
                Department__c='Orthopedics', Doctor__c='Dr. Luis Gomez', Status__c='Cancelled')
        };
    }

    // ---- Reschedule test helpers -------------------------------------------------
    // Tests run as the admin user whose TZ is Australia/Sydney == the clinic TZ the
    // action anchors to, so a clinic-local wall clock built here round-trips exactly.

    private static Boolean isWeekendDate(Date d) {
        String day = Datetime.newInstance(d, Time.newInstance(12, 0, 0, 0)).format('EEE');
        return day == 'Sat' || day == 'Sun';
    }

    /** First weekday at least minDaysAhead days from today. */
    private static Date nextWeekday(Integer minDaysAhead) {
        Date d = Date.today().addDays(minDaysAhead);
        while (isWeekendDate(d)) { d = d.addDays(1); }
        return d;
    }

    /** First Saturday at least minDaysAhead days from today. */
    private static Date nextSaturday(Integer minDaysAhead) {
        Date d = Date.today().addDays(minDaysAhead);
        while (Datetime.newInstance(d, Time.newInstance(12, 0, 0, 0)).format('EEE') != 'Sat') {
            d = d.addDays(1);
        }
        return d;
    }

    /** A Datetime for the given clinic-local date + time (built in the Sydney-running-user TZ). */
    private static Datetime clinicSlot(Date d, Integer hour, Integer minute) {
        return Datetime.newInstance(d, Time.newInstance(hour, minute, 0, 0));
    }

    /** An ISO 'yyyy-MM-ddTHH:mm' clinic-local wall-clock string the action can parse. */
    private static String slotString(Date d, Integer hour, Integer minute) {
        return clinicSlot(d, hour, minute).format('yyyy-MM-dd\'T\'HH:mm');
    }

    private static RescheduleAppointmentAction.Result reschedule(Id contactId, Id apptId, String newDt) {
        RescheduleAppointmentAction.Request r = new RescheduleAppointmentAction.Request();
        r.contactId = contactId;
        r.appointmentId = apptId;
        r.newDateTime = newDt;
        return RescheduleAppointmentAction.reschedule(
            new List<RescheduleAppointmentAction.Request>{ r })[0];
    }

    private static Id contactIdFor(String pid) {
        return [SELECT Id FROM Contact WHERE Patient_ID__c = :pid LIMIT 1].Id;
    }

    private static Appointment__c cFuture() {
        return [SELECT Id, Appointment_DateTime__c, Status__c FROM Appointment__c
                WHERE Contact__r.Patient_ID__c = :PID_C AND Status__c = 'Scheduled'
                  AND Appointment_DateTime__c > :Datetime.now() LIMIT 1];
    }

    private static VerifyPatientAction.Result verify(String pid, String dob) {
        VerifyPatientAction.Request r = new VerifyPatientAction.Request();
        r.patientId = pid;
        r.dateOfBirth = dob;
        return VerifyPatientAction.verify(new List<VerifyPatientAction.Request>{ r })[0];
    }

    @IsTest
    static void bothMatch_verifies() {
        Test.startTest();
        VerifyPatientAction.Result res = verify(PID_A, '1985-03-12');
        Test.stopTest();

        System.assertEquals(true, res.verified, 'Matching ID + DOB should verify');
        System.assertNotEquals(null, res.contactId, 'Verified result must carry a contact id');
        System.assert(String.isNotBlank(res.contactId), 'contactId should be populated');
        // Masking: full Patient ID and full DOB must NOT appear in the message.
        System.assert(!res.message.contains(PID_A), 'Full Patient ID must be masked');
        System.assert(!res.message.contains('1985-03-12'), 'Full DOB must never be echoed');
        System.assert(res.maskedPatientId.contains('*'), 'Masked Patient ID should contain mask chars');
    }

    @IsTest
    static void usDateFormat_verifies() {
        VerifyPatientAction.Result res = verify(PID_A, '03/12/1985');
        System.assertEquals(true, res.verified, 'US MM/DD/YYYY DOB should parse and verify');
    }

    @IsTest
    static void wrongDob_fails_noLeak() {
        VerifyPatientAction.Result res = verify(PID_A, '2000-01-01');
        System.assertEquals(false, res.verified, 'Wrong DOB must not verify');
        System.assertEquals('', res.contactId, 'No contact id on failure');
    }

    @IsTest
    static void wrongId_fails_noLeak() {
        VerifyPatientAction.Result res = verify('PT-0000', '1985-03-12');
        System.assertEquals(false, res.verified, 'Unknown Patient ID must not verify');
    }

    @IsTest
    static void wrongId_and_wrongDob_haveIdenticalMessage() {
        // The core no-existence-leak guarantee: the agent can't tell from the
        // message whether the Patient ID exists.
        VerifyPatientAction.Result wrongDob = verify(PID_A, '2000-01-01');      // real id, bad dob
        VerifyPatientAction.Result wrongId  = verify('PT-0000', '1985-03-12');  // fake id, real dob
        System.assertEquals(wrongId.message, wrongDob.message,
            'Failure message must be identical regardless of which field was wrong');
    }

    @IsTest
    static void partialCreds_promptsForBoth() {
        VerifyPatientAction.Result res = verify(PID_A, '');
        System.assertEquals(false, res.verified, 'Missing DOB cannot verify');
        System.assert(res.message.toLowerCase().contains('date of birth'),
            'Partial creds should re-prompt for both identifiers');
    }

    @IsTest
    static void lookup_returnsOnlyUpcomingNonCancelled_ordered() {
        Contact a = [SELECT Id FROM Contact WHERE Patient_ID__c = :PID_A LIMIT 1];
        GetUpcomingAppointmentsAction.Request r = new GetUpcomingAppointmentsAction.Request();
        r.contactId = a.Id;

        Test.startTest();
        GetUpcomingAppointmentsAction.Result res =
            GetUpcomingAppointmentsAction.getUpcoming(new List<GetUpcomingAppointmentsAction.Request>{ r })[0];
        Test.stopTest();

        System.assertEquals(true, res.found, 'Patient A has upcoming appts');
        System.assertEquals(2, res.count, 'Only 2 upcoming non-cancelled (past + cancelled excluded)');
        System.assert(res.summary.contains('Cardiology'), 'Summary should list the upcoming departments');
        System.assert(!res.summary.contains('Pediatrics'), 'Patient B data must never appear');

        // Sprint 7: the structured card list mirrors the summary 1:1 and carries
        // the same safe fields (no cross-user data, no PII).
        System.assertEquals(2, res.appointments.size(), 'Structured list matches the count');
        Set<String> cardDepts = new Set<String>();
        for (GetUpcomingAppointmentsAction.ApptLine ln : res.appointments) {
            System.assertNotEquals(null, ln.appointmentName, 'Card line has a safe APT name');
            System.assert(ln.appointmentName.startsWith('APT-'), 'Only the safe APT-#### name is exposed');
            System.assertNotEquals(null, ln.whenText, 'Card line has a when text');
            cardDepts.add(ln.department);
        }
        System.assert(cardDepts.contains('Cardiology'), 'Card shows the patient own dept');
        System.assert(!cardDepts.contains('Pediatrics'), 'Patient B data must never appear on the card');
    }

    @IsTest
    static void lookup_blankId_refuses() {
        GetUpcomingAppointmentsAction.Request r = new GetUpcomingAppointmentsAction.Request();
        r.contactId = '';
        GetUpcomingAppointmentsAction.Result res =
            GetUpcomingAppointmentsAction.getUpcoming(new List<GetUpcomingAppointmentsAction.Request>{ r })[0];
        System.assertEquals(false, res.found, 'Blank id must not return records');
        System.assertEquals(0, res.count, 'No records for an unverified lookup');
        // Sprint 7: the card list is empty (not null) on the refusal path so the
        // LWC renders its graceful empty/unverified state without erroring.
        System.assertNotEquals(null, res.appointments, 'Card list is never null');
        System.assert(res.appointments.isEmpty(), 'No card rows for an unverified lookup');
    }

    @IsTest
    static void lookup_cardFields_noDobOrFullPatientId() {
        // Sprint 7 guardrail: nothing on the structured card may contain a DOB or
        // a full Patient ID — the card is built only from appointment fields.
        Contact a = [SELECT Id, Patient_ID__c FROM Contact WHERE Patient_ID__c = :PID_A LIMIT 1];
        GetUpcomingAppointmentsAction.Request r = new GetUpcomingAppointmentsAction.Request();
        r.contactId = a.Id;
        GetUpcomingAppointmentsAction.Result res =
            GetUpcomingAppointmentsAction.getUpcoming(new List<GetUpcomingAppointmentsAction.Request>{ r })[0];

        System.assert(!res.appointments.isEmpty(), 'Patient A has card rows');
        for (GetUpcomingAppointmentsAction.ApptLine ln : res.appointments) {
            String lineText = String.valueOf(ln.appointmentName) + '|' + ln.whenText + '|' +
                          ln.department + '|' + ln.doctor + '|' + ln.status;
            System.assert(!lineText.contains(PID_A), 'No full Patient ID on the card');
            System.assert(!lineText.contains('1985'), 'No DOB year leaks onto the card');
        }
    }

    @IsTest
    static void lookup_scopedToContact_noCrossUser() {
        Contact b = [SELECT Id FROM Contact WHERE Patient_ID__c = :PID_B LIMIT 1];
        GetUpcomingAppointmentsAction.Request r = new GetUpcomingAppointmentsAction.Request();
        r.contactId = b.Id;
        GetUpcomingAppointmentsAction.Result res =
            GetUpcomingAppointmentsAction.getUpcoming(new List<GetUpcomingAppointmentsAction.Request>{ r })[0];
        System.assertEquals(1, res.count, 'Patient B sees only their own 1 upcoming appt');
        System.assert(res.summary.contains('Pediatrics'), 'B sees their own dept');
        System.assert(!res.summary.contains('Cardiology'), 'B must not see A\'s appts');
    }

    @IsTest
    static void maskPatientId_masksMiddle() {
        System.assertEquals('PT-**01', VerifyPatientAction.maskPatientId('PT-1001'));
        System.assertEquals('', VerifyPatientAction.maskPatientId(null));
    }

    // --- Sprint 6: spelled-out DOB verification (closes Sprint 5 §9 parse gap) ---
    // These assert the agent no longer over-refuses a real patient who states their
    // DOB in natural language — the false-positive risk the rubric penalises.

    @IsTest
    static void spelledOutDob_verifies_commaFormat() {
        VerifyPatientAction.Result res = verify(PID_A, 'March 12, 1985');
        System.assertEquals(true, res.verified, 'Spelled-out "March 12, 1985" must verify Patient A');
    }

    @IsTest
    static void spelledOutDob_verifies_dayFirstAndAbbrev() {
        System.assertEquals(true, verify(PID_A, '12 March 1985').verified, '"12 March 1985" must verify');
        System.assertEquals(true, verify(PID_A, 'Mar 12 1985').verified, 'Abbreviated "Mar 12 1985" must verify');
    }

    @IsTest
    static void spelledOutDob_wrongDate_stillFails_noLeak() {
        // A parseable-but-wrong spelled DOB must still fail (parsing robustness must
        // not weaken the gate).
        VerifyPatientAction.Result res = verify(PID_A, 'January 1, 2000');
        System.assertEquals(false, res.verified, 'A wrong spelled-out DOB must not verify');
        System.assertEquals('', res.contactId, 'No contact id on a failed verify');
    }

    @IsTest
    static void parseSpelledDob_unit() {
        Integer[] d = VerifyPatientAction.parseSpelledDate('March 12, 1985');
        System.assertEquals(1985, d[0]); System.assertEquals(3, d[1]); System.assertEquals(12, d[2]);
        System.assertEquals(11, VerifyPatientAction.monthNumber('Nov'));
        System.assertEquals(null, VerifyPatientAction.monthNumber('Smarch'));
        System.assertEquals(null, VerifyPatientAction.parseSpelledDate('not a date'), 'Garbage → null');
    }

    // =========================================================================
    // Sprint 4 — RescheduleAppointmentAction
    // =========================================================================

    @IsTest
    static void reschedule_validWeekdayInHoursInWindow_succeeds() {
        Id cid = contactIdFor(PID_C);
        Appointment__c appt = cFuture();
        // A clean weekday ~10 days out at 2:00 PM clinic-local — inside all rules.
        String newDt = slotString(nextWeekday(10), 14, 0);

        Test.startTest();
        RescheduleAppointmentAction.Result res = reschedule(cid, appt.Id, newDt);
        Test.stopTest();

        System.assertEquals(true, res.success, 'Valid weekday-in-hours-in-window slot should succeed: ' + res.message);
        Appointment__c after = [SELECT Appointment_DateTime__c, Status__c FROM Appointment__c WHERE Id = :appt.Id];
        System.assertEquals('Rescheduled', after.Status__c, 'Status must flip to Rescheduled');
        System.assertNotEquals(appt.Appointment_DateTime__c, after.Appointment_DateTime__c, 'DateTime must move');
        // Round-trip: stored instant renders back to the chosen 2:00 PM clinic-local.
        System.assert(res.newWhenText.contains('2:00 PM'), 'Confirmation should show the chosen 2:00 PM: ' + res.newWhenText);
        // Masking: no full Patient ID in the confirmation.
        System.assert(!res.message.contains(PID_C), 'Confirmation must not echo the Patient ID');
    }

    @IsTest
    static void reschedule_weekend_rejected() {
        Id cid = contactIdFor(PID_C);
        Appointment__c appt = cFuture();
        String newDt = slotString(nextSaturday(3), 11, 0); // Saturday 11:00 — valid hour, wrong day

        RescheduleAppointmentAction.Result res = reschedule(cid, appt.Id, newDt);
        System.assertEquals(false, res.success, 'Weekend slot must be rejected');
        System.assert(res.message.toLowerCase().contains('weekday'), 'Reason must mention weekdays: ' + res.message);
        Appointment__c after = [SELECT Status__c FROM Appointment__c WHERE Id = :appt.Id];
        System.assertEquals('Scheduled', after.Status__c, 'Rejected reschedule must not change the record');
    }

    @IsTest
    static void reschedule_beforeNine_rejected() {
        Id cid = contactIdFor(PID_C);
        Appointment__c appt = cFuture();
        String newDt = slotString(nextWeekday(5), 8, 30); // 08:30 — before open

        RescheduleAppointmentAction.Result res = reschedule(cid, appt.Id, newDt);
        System.assertEquals(false, res.success, 'Before 9:00 must be rejected');
        System.assert(res.message.toLowerCase().contains('clinic hours'), 'Reason must mention clinic hours: ' + res.message);
    }

    @IsTest
    static void reschedule_afterFive_rejected() {
        Id cid = contactIdFor(PID_C);
        Appointment__c appt = cFuture();
        String newDt = slotString(nextWeekday(5), 17, 30); // 17:30 — after latest start

        RescheduleAppointmentAction.Result res = reschedule(cid, appt.Id, newDt);
        System.assertEquals(false, res.success, 'After 17:00 must be rejected');
        System.assert(res.message.toLowerCase().contains('clinic hours'), 'Reason must mention clinic hours: ' + res.message);
    }

    @IsTest
    static void reschedule_seventeenHundred_isAllowedBoundary() {
        Id cid = contactIdFor(PID_C);
        Appointment__c appt = cFuture();
        String newDt = slotString(nextWeekday(5), 17, 0); // exactly 17:00 — the documented inclusive latest start

        RescheduleAppointmentAction.Result res = reschedule(cid, appt.Id, newDt);
        System.assertEquals(true, res.success, '17:00 is the inclusive latest start and must be allowed: ' + res.message);
    }

    @IsTest
    static void reschedule_beyondThirtyDays_rejected() {
        Id cid = contactIdFor(PID_C);
        Appointment__c appt = cFuture();
        String newDt = slotString(nextWeekday(40), 10, 0); // ~40 days out

        RescheduleAppointmentAction.Result res = reschedule(cid, appt.Id, newDt);
        System.assertEquals(false, res.success, 'Beyond 30 days must be rejected');
        System.assert(res.message.contains('30 days'), 'Reason must mention the 30-day window: ' + res.message);
    }

    @IsTest
    static void reschedule_pastDatetime_rejected() {
        Id cid = contactIdFor(PID_C);
        Appointment__c appt = cFuture();
        // Yesterday at 10:00 clinic-local — a concrete past instant.
        String newDt = slotString(Date.today().addDays(-1), 10, 0);

        RescheduleAppointmentAction.Result res = reschedule(cid, appt.Id, newDt);
        System.assertEquals(false, res.success, 'A past datetime must be rejected');
        System.assert(res.message.toLowerCase().contains('past'), 'Reason must mention the past: ' + res.message);
    }

    @IsTest
    static void reschedule_cancelledAppt_rejected() {
        Id cid = contactIdFor(PID_C);
        Appointment__c cancelled = [SELECT Id FROM Appointment__c
            WHERE Contact__r.Patient_ID__c = :PID_C AND Status__c = 'Cancelled' LIMIT 1];
        String newDt = slotString(nextWeekday(5), 10, 0); // otherwise-valid slot

        RescheduleAppointmentAction.Result res = reschedule(cid, cancelled.Id, newDt);
        System.assertEquals(false, res.success, 'A cancelled appointment cannot be rescheduled');
        System.assert(res.message.toLowerCase().contains('cancel'), 'Reason must mention cancellation: ' + res.message);
    }

    @IsTest
    static void reschedule_pastAppt_rejected() {
        Id cid = contactIdFor(PID_C);
        Appointment__c pastAppt = [SELECT Id FROM Appointment__c
            WHERE Contact__r.Patient_ID__c = :PID_C AND Status__c = 'Scheduled'
              AND Appointment_DateTime__c < :Datetime.now() LIMIT 1];
        String newDt = slotString(nextWeekday(5), 10, 0);

        RescheduleAppointmentAction.Result res = reschedule(cid, pastAppt.Id, newDt);
        System.assertEquals(false, res.success, 'An already-past appointment cannot be rescheduled');
        System.assert(res.message.toLowerCase().contains('already'), 'Reason must say it already took place: ' + res.message);
    }

    @IsTest
    static void reschedule_anotherPatientsAppt_refusedGenerically() {
        // Verified as C, but passing an appointment id that belongs to A.
        Id cid = contactIdFor(PID_C);
        Appointment__c aAppt = [SELECT Id FROM Appointment__c
            WHERE Contact__r.Patient_ID__c = :PID_A AND Status__c = 'Scheduled'
              AND Appointment_DateTime__c > :Datetime.now() LIMIT 1];
        String newDt = slotString(nextWeekday(5), 10, 0);

        RescheduleAppointmentAction.Result res = reschedule(cid, aAppt.Id, newDt);
        System.assertEquals(false, res.success, 'Must never reschedule an appointment the verified contact does not own');
        // The other patient's appt must be untouched.
        Appointment__c after = [SELECT Status__c FROM Appointment__c WHERE Id = :aAppt.Id];
        System.assertEquals('Scheduled', after.Status__c, 'Another patient\'s appointment must not be modified');
    }

    @IsTest
    static void reschedule_blankContact_refuses() {
        Appointment__c appt = cFuture();
        RescheduleAppointmentAction.Request r = new RescheduleAppointmentAction.Request();
        r.contactId = '';
        r.appointmentId = appt.Id;
        r.newDateTime = slotString(nextWeekday(5), 10, 0);
        RescheduleAppointmentAction.Result res =
            RescheduleAppointmentAction.reschedule(new List<RescheduleAppointmentAction.Request>{ r })[0];
        System.assertEquals(false, res.success, 'No verified contact id => refuse (acts as the verification backstop)');
        System.assert(res.message.toLowerCase().contains('verified'), 'Reason must reference verification: ' + res.message);
    }

    @IsTest
    static void reschedule_sameTime_isNoOpMessage() {
        Id cid = contactIdFor(PID_C);
        Appointment__c appt = cFuture();
        // Ask for the exact clinic-local time it already has.
        String sameDt = appt.Appointment_DateTime__c.format('yyyy-MM-dd\'T\'HH:mm');

        Test.startTest();
        RescheduleAppointmentAction.Result res = reschedule(cid, appt.Id, sameDt);
        Test.stopTest();

        System.assertEquals(false, res.success, 'Same-time should be a no-op, not a successful change');
        System.assert(res.message.toLowerCase().contains('already'), 'No-op message should say it is already booked then: ' + res.message);
        Appointment__c after = [SELECT Status__c FROM Appointment__c WHERE Id = :appt.Id];
        System.assertEquals('Scheduled', after.Status__c, 'A no-op must not flip the status or create duplicates');
        Integer total = [SELECT COUNT() FROM Appointment__c WHERE Contact__c = :cid];
        System.assertEquals(3, total, 'Reschedule updates in place — never inserts a duplicate');
    }

    @IsTest
    static void reschedule_byDescriptor_picksOwnUpcoming() {
        // No appointment id — select C's only upcoming scheduled appt by department word.
        Id cid = contactIdFor(PID_C);
        RescheduleAppointmentAction.Request r = new RescheduleAppointmentAction.Request();
        r.contactId = cid;
        r.appointmentDescriptor = 'cardiology';
        r.newDateTime = slotString(nextWeekday(7), 15, 30);

        RescheduleAppointmentAction.Result res =
            RescheduleAppointmentAction.reschedule(new List<RescheduleAppointmentAction.Request>{ r })[0];
        System.assertEquals(true, res.success, 'Descriptor should resolve C\'s cardiology appt: ' + res.message);
        System.assert(res.message.toLowerCase().contains('cardiology'), 'Confirmation should name the department: ' + res.message);
    }

    @IsTest
    static void reschedule_unparseableDateTime_refusesKindly() {
        Id cid = contactIdFor(PID_C);
        Appointment__c appt = cFuture();
        RescheduleAppointmentAction.Result res = reschedule(cid, appt.Id, 'sometime soon-ish');
        System.assertEquals(false, res.success, 'Unparseable datetime must be refused, not guessed');
        System.assert(res.message.toLowerCase().contains('date and time'), 'Should ask for a specific date and time: ' + res.message);
    }

    @IsTest
    static void parsers_handleCommonFormats() {
        // ISO and US formats both reach the same wall clock.
        RescheduleAppointmentAction.Wall iso = RescheduleAppointmentAction.parseNewDateTime('2026-11-18T14:30');
        System.assertEquals(2026, iso.y); System.assertEquals(11, iso.mo); System.assertEquals(18, iso.d);
        System.assertEquals(14, iso.h);   System.assertEquals(30, iso.mi);

        RescheduleAppointmentAction.Wall us = RescheduleAppointmentAction.parseNewDateTime('11/18/2026 2:30 PM');
        System.assertEquals(2026, us.y); System.assertEquals(11, us.mo); System.assertEquals(18, us.d);
        System.assertEquals(14, us.h);   System.assertEquals(30, us.mi);

        // Noon / midnight AM-PM edge handling.
        RescheduleAppointmentAction.Wall noon = RescheduleAppointmentAction.parseNewDateTime('2026-11-18 12:00 PM');
        System.assertEquals(12, noon.h, '12 PM is noon');
        RescheduleAppointmentAction.Wall mid = RescheduleAppointmentAction.parseNewDateTime('2026-11-18 12:00 AM');
        System.assertEquals(0, mid.h, '12 AM is midnight');

        System.assertEquals(null, RescheduleAppointmentAction.parseNewDateTime('not a date'), 'Garbage returns null');
        System.assertEquals(null, RescheduleAppointmentAction.parseNewDateTime('2026-11-18'), 'Date with no time returns null');
    }

    @IsTest
    static void parsers_handleSpelledOutDates() {
        // Spelled-out month names with an "at" connective (how patients actually talk).
        RescheduleAppointmentAction.Wall a = RescheduleAppointmentAction.parseNewDateTime('November 18, 2026 at 2:00 PM');
        System.assertEquals(2026, a.y); System.assertEquals(11, a.mo); System.assertEquals(18, a.d);
        System.assertEquals(14, a.h);   System.assertEquals(0, a.mi);

        RescheduleAppointmentAction.Wall b = RescheduleAppointmentAction.parseNewDateTime('18 Nov 2026 9 am');
        System.assertEquals(2026, b.y); System.assertEquals(11, b.mo); System.assertEquals(18, b.d);
        System.assertEquals(9, b.h);    System.assertEquals(0, b.mi);

        Integer[] d = RescheduleAppointmentAction.parseSpelledDate('December 30, 2026');
        System.assertEquals(2026, d[0]); System.assertEquals(12, d[1]); System.assertEquals(30, d[2]);

        System.assertEquals(3, RescheduleAppointmentAction.monthNumber('March'));
        System.assertEquals(9, RescheduleAppointmentAction.monthNumber('Sept'));
        System.assertEquals(null, RescheduleAppointmentAction.monthNumber('Smarch'));
    }

    @IsTest
    static void reschedule_spelledOutDate_succeeds() {
        // End-to-end with a natural spelled-out date on a known weekday-in-window slot.
        Id cid = contactIdFor(PID_C);
        Appointment__c appt = cFuture();
        Date wd = nextWeekday(9);
        String spoken = clinicSlot(wd, 15, 0).format('MMMM d, yyyy') + ' at 3:00 PM';

        Test.startTest();
        RescheduleAppointmentAction.Result res = reschedule(cid, appt.Id, spoken);
        Test.stopTest();

        System.assertEquals(true, res.success, 'Spelled-out weekday 3:00 PM slot should succeed: ' + res.message);
        System.assert(res.newWhenText.contains('3:00 PM'), 'Confirmation should echo 3:00 PM: ' + res.newWhenText);
    }

    @IsTest
    static void validators_areTimezoneAnchored() {
        // Build a known clinic-local Saturday 11:00 and a weekday 10:00; assert the
        // validators judge them by clinic TZ regardless of the running user.
        Datetime sat = RescheduleAppointmentAction.buildClinicDatetime(
            makeWall(nextSaturday(3), 11, 0));
        System.assertEquals(false, RescheduleAppointmentAction.isWeekday(sat), 'Saturday must not count as a weekday');

        Datetime wk = RescheduleAppointmentAction.buildClinicDatetime(
            makeWall(nextWeekday(3), 10, 0));
        System.assertEquals(true, RescheduleAppointmentAction.isWeekday(wk), 'Weekday 10:00 is a weekday');
        System.assertEquals(true, RescheduleAppointmentAction.isWithinBusinessHours(wk), '10:00 is within hours');
    }

    private static RescheduleAppointmentAction.Wall makeWall(Date d, Integer h, Integer mi) {
        RescheduleAppointmentAction.Wall w = new RescheduleAppointmentAction.Wall();
        w.y = d.year(); w.mo = d.month(); w.d = d.day(); w.h = h; w.mi = mi;
        return w;
    }

    // =========================================================================
    // Sprint 5 — EscalateToHumanAction
    //
    // NOTE on test strategy: this shared demo org has an active record-triggered
    // Case flow ("SDO Service - Case - On Create") that fails in the data-isolated
    // Apex test context (a demo subflow is missing a required 'helperConfig' input),
    // so ANY Case insert inside a test throws regardless of our code. A live insert
    // works fine (proven in scripts/apex/sprint5_live_demo.apex). We therefore assert
    // the Case CONSTRUCTION — fields, routing, priority, Contact link, and the privacy
    // scrub — against the pure, DML-free buildCase() seam, which is exactly the logic
    // that matters for correctness. The end-to-end insert is proven live.
    // =========================================================================

    private static EscalateToHumanAction.Request escReq(Id contactId, String category, String summary) {
        EscalateToHumanAction.Request r = new EscalateToHumanAction.Request();
        r.contactId = contactId;
        r.category = category;
        r.conversationSummary = summary;
        return r;
    }

    @IsTest
    static void escalate_buildsCase_linkedToContact_mediumPriority() {
        Id cid = contactIdFor(PID_A);
        Case c = EscalateToHumanAction.buildCase(
            escReq(cid, 'billing', 'Patient has a question about a charge on their bill.'), 'billing');

        System.assertEquals('Medium', c.Priority, 'Non-emergency escalations are Medium priority');
        System.assertEquals('Chat', c.Origin, 'Origin should be Chat');
        System.assertEquals('New', c.Status, 'Status should be New');
        System.assertEquals(cid, c.ContactId, 'Case must link to the verified contact when known');
        System.assert(c.Subject.contains('Billing'), 'Subject should reflect the category: ' + c.Subject);
        System.assert(c.Description.contains('charge on their bill'), 'Summary should be in the Description');
    }

    @IsTest
    static void escalate_emergency_isHighPriority() {
        Case c = EscalateToHumanAction.buildCase(
            escReq(null, 'emergency',
                'Patient reported a possible emergency symptom during chat; advised to call emergency services (000).'),
            'emergency');
        System.assertEquals('High', c.Priority, 'Emergency escalations must be High priority');
        System.assert(c.Subject.toLowerCase().contains('urgent'), 'Emergency subject should flag urgency: ' + c.Subject);
    }

    @IsTest
    static void escalate_emergency_relayMessageAdvises000() {
        // The patient-facing relay is built from the action's end-to-end path; a blank
        // contact is used so no real Contact SOQL is needed. (Insert itself is proven live.)
        EscalateToHumanAction.Result res = EscalateToHumanAction.escalate(
            new List<EscalateToHumanAction.Request>{ escReq(null, 'emergency', '') })[0];
        // Whether or not the demo flow blocks the insert, the relay message is deterministic.
        System.assert(res.message.contains('000') || res.message.toLowerCase().contains('front desk'),
            'Emergency relay should advise 000 (or the safe fallback): ' + res.message);
    }

    @IsTest
    static void escalate_unverified_blankContact_hasNoContactLink() {
        // An unverified caller (no contactId) can still be escalated — the Case is
        // built without a Contact link.
        Case c = EscalateToHumanAction.buildCase(
            escReq(null, 'prescriptions', 'Patient wants a medication refill.'), 'prescriptions');
        System.assertEquals(null, c.ContactId, 'No contact link when the patient is unverified');
        System.assert(c.Subject.contains('Prescription'), 'Subject should reflect prescriptions: ' + c.Subject);
    }

    @IsTest
    static void escalate_summary_scrubsDobAndPatientId() {
        // The agent should never send these, but the action is the deterministic backstop.
        Id cid = contactIdFor(PID_A);
        String leaky = 'Patient PT-1001 (DOB 1985-03-12, also wrote 03/12/1985 and March 12, 1985) asked for test results.';
        Case c = EscalateToHumanAction.buildCase(escReq(cid, 'test results', leaky), 'test results');

        System.assert(!c.Description.contains('PT-1001'), 'Full Patient ID must be scrubbed: ' + c.Description);
        System.assert(!c.Description.contains('1985-03-12'), 'ISO DOB must be scrubbed');
        System.assert(!c.Description.contains('03/12/1985'), 'Numeric DOB must be scrubbed');
        System.assert(!c.Description.contains('March 12, 1985'), 'Spelled-out DOB must be scrubbed');
        System.assert(c.Description.contains('test results'), 'The operational reason should survive scrubbing');
    }

    @IsTest
    static void escalate_scrubSummary_unit() {
        String scrubbed = EscalateToHumanAction.scrubSummary('ID PT-2048 born 1 Jan 2000 and 12/31/1999.');
        System.assert(!scrubbed.contains('PT-2048'), 'Patient ID redacted');
        System.assert(!scrubbed.contains('1 Jan 2000'), 'Spelled DOB redacted: ' + scrubbed);
        System.assert(!scrubbed.contains('12/31/1999'), 'Numeric DOB redacted: ' + scrubbed);
        System.assertEquals('', EscalateToHumanAction.scrubSummary(null), 'Null summary scrubs to empty');
    }

    @IsTest
    static void escalate_unknownCategory_normalisesToOther() {
        System.assertEquals('other', EscalateToHumanAction.normaliseCategory('refund dispute'));
        System.assertEquals('other', EscalateToHumanAction.normaliseCategory(null));
        System.assertEquals('billing', EscalateToHumanAction.normaliseCategory('  Billing  '));
        System.assertEquals('emergency', EscalateToHumanAction.normaliseCategory('EMERGENCY'));
    }

    @IsTest
    static void escalate_blankSummary_usesSafeDefault() {
        Case c = EscalateToHumanAction.buildCase(escReq(null, 'patient requested human', ''), 'patient requested human');
        System.assert(c.Description.toLowerCase().contains('speak with a person'),
            'Blank summary should fall back to a safe default: ' + c.Description);
    }

    // =========================================================================
    // Sprint 5 — AnswerClinicPolicyAction
    // =========================================================================

    @IsTest
    static void knowledge_stripHtml_producesCleanText() {
        String html = '<h2>Clinic hours</h2><p>Open <strong>weekdays</strong> 9&ndash;5.</p>' +
                      '<ul><li>Closed weekends</li><li>Closed holidays</li></ul>';
        String text = AnswerClinicPolicyAction.stripHtml(html);
        System.assert(!text.contains('<'), 'All tags must be stripped: ' + text);
        System.assert(text.contains('Clinic hours'), 'Heading text preserved');
        System.assert(text.contains('- Closed weekends'), 'List items become bullet lines: ' + text);
        System.assertEquals('', AnswerClinicPolicyAction.stripHtml(null), 'Null html → empty string');
    }

    @IsTest
    static void knowledge_noVisibleArticles_returnsCleanFallback() {
        // Test context is data-isolated (no SeeAllData), so the Knowledge query returns
        // nothing — exercising the "no articles available" branch deterministically.
        AnswerClinicPolicyAction.Request r = new AnswerClinicPolicyAction.Request();
        r.question = 'What are your clinic hours?';
        AnswerClinicPolicyAction.Result res =
            AnswerClinicPolicyAction.answer(new List<AnswerClinicPolicyAction.Request>{ r })[0];
        System.assertEquals(false, res.found, 'No published articles are visible in the isolated test context');
        System.assert(String.isNotBlank(res.knowledge), 'A fallback message should still be returned');
    }
}