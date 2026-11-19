/**
 * Sprint 4 live-org evidence harness.
 *
 * Exercises RescheduleAppointmentAction against the REAL seeded org data exactly
 * as the agent would at runtime: it resolves the verified contact id the same way
 * VerifyPatientAction does (PT-1001 + DOB → Contact.Id), then calls the invocable
 * with that id for the valid reschedule plus the three refusals (weekend,
 * after-hours, >30 days) and the ownership guard. Prints each outcome.
 *
 * Run: sf apex run --file scripts/apex/sprint4_live_demo.apex --target-org storm-org
 */

// --- Resolve the verified contact id the way the verify action does (ID + DOB) ---
Contact sarah = [SELECT Id, FirstName FROM Contact
                 WHERE Patient_ID__c = 'PT-1001' AND Birthdate = 1985-03-12 LIMIT 1];
String cid = sarah.Id;
System.debug('=== Verified contact: ' + sarah.FirstName + ' (' + cid + ') ===');

// The cardiology appointment is the reschedule demo target.
Appointment__c cardio = [SELECT Id, Name, Appointment_DateTime__c, Status__c
                         FROM Appointment__c
                         WHERE Contact__c = :cid AND Department__c = 'Cardiology'
                           AND Status__c != 'Cancelled'
                           AND Appointment_DateTime__c > :Datetime.now()
                         ORDER BY Appointment_DateTime__c ASC LIMIT 1];
System.debug('Target cardiology appt: ' + cardio.Name + ' currently ' + cardio.Appointment_DateTime__c);

void run(String caption, String cidIn, Id apptId, String newDt) {
    RescheduleAppointmentAction.Request r = new RescheduleAppointmentAction.Request();
    r.contactId = cidIn;
    r.appointmentId = apptId;
    r.newDateTime = newDt;
    RescheduleAppointmentAction.Result res =
        RescheduleAppointmentAction.reschedule(new List<RescheduleAppointmentAction.Request>{ r })[0];
    System.debug('\n--- ' + caption + ' ---');
    System.debug('input newDateTime = ' + newDt);
    System.debug('success = ' + res.success);
    System.debug('message = ' + res.message);
    System.debug('newWhenText = ' + res.newWhenText);
}

// 1) VALID — weekday (Wed 18 Nov 2026) 2:00 PM, within 30 days, future → should succeed.
run('VALID reschedule (Wed 18 Nov 2026 2:00 PM)', cid, cardio.Id, '2026-11-18T14:00');

// Re-read the record to show it actually moved + Status flipped.
Appointment__c afterMove = [SELECT Name, Appointment_DateTime__c, Status__c
                            FROM Appointment__c WHERE Id = :cardio.Id];
System.debug('\n>>> Record now: ' + afterMove.Name + ' @ ' + afterMove.Appointment_DateTime__c
             + ' status=' + afterMove.Status__c);

// 2) WEEKEND — Sat 21 Nov 2026 11:00 AM → refused (weekday rule).
run('REFUSAL weekend (Sat 21 Nov 2026 11:00 AM)', cid, cardio.Id, '2026-11-21T11:00');

// 3) AFTER HOURS — Wed 18 Nov 2026 6:30 PM → refused (business hours rule).
run('REFUSAL after-hours (Wed 18 Nov 2026 6:30 PM)', cid, cardio.Id, '2026-11-18T18:30');

// 4) BEYOND 30 DAYS — 30 Dec 2026 10:00 AM → refused (window rule).
run('REFUSAL >30 days (Wed 30 Dec 2026 10:00 AM)', cid, cardio.Id, '2026-12-30T10:00');

// 5) OWNERSHIP — verified as Sarah, but target Michael Chen's (PT-1002) appt → refused generically.
Appointment__c michaels = [SELECT Id FROM Appointment__c
                           WHERE Contact__r.Patient_ID__c = 'PT-1002'
                             AND Status__c != 'Cancelled'
                             AND Appointment_DateTime__c > :Datetime.now()
                           ORDER BY Appointment_DateTime__c ASC LIMIT 1];
run('REFUSAL ownership (Sarah targeting PT-1002 appt)', cid, michaels.Id, '2026-11-18T10:00');
Appointment__c michaelsAfter = [SELECT Status__c FROM Appointment__c WHERE Id = :michaels.Id];
System.debug('\n>>> PT-1002 appt untouched, status still = ' + michaelsAfter.Status__c);

// 6) IDEMPOTENT — reschedule to the time it now has → friendly no-op (no change/insert).
Datetime cur = afterMove.Appointment_DateTime__c;
run('IDEMPOTENT same-time no-op', cid, cardio.Id, cur.format('yyyy-MM-dd\'T\'HH:mm', 'Australia/Sydney'));

System.debug('\n=== Sprint 4 live demo complete ===');
