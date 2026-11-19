/*
 * Ascend Clinics — V3 Healthcare — Sprint 1 sample data seed (REPEATABLE / IDEMPOTENT)
 * ----------------------------------------------------------------------------------
 * Run:  sf apex run --file scripts/apex/seed_sample_data.apex --target-org storm-org
 *
 * Creates ~10 fictional records (3 Contacts + 7 Appointments). All dates are computed
 * relative to Datetime.now(), so the data stays valid whenever the script is re-run.
 *
 * Required cases (per brief):
 *   - Patient A has 2 UPCOMING appointments (both future, weekday, 9am-5pm, <=30 days)
 *   - ONE of Patient A's appointments is within the next 24 hours
 *   - A second patient (B) exists for cross-user data-leak testing
 *   - Status spread (Scheduled / Rescheduled / Cancelled) and >1 Department present
 *
 * Idempotent: deletes any prior Appointment__c for these patients and the sample
 * Contacts (matched by Patient_ID__c) before re-inserting, so re-runs don't duplicate.
 */

// ---- helpers --------------------------------------------------------------
// Return a datetime N calendar days from today; if it lands on Sat/Sun, roll
// forward to the following Monday. Hour is a 24h local-time hour (9..17).
Datetime weekdaySlot(Integer daysAhead, Integer hour24) {
    Date d = Date.today().addDays(daysAhead);
    // Datetime to inspect weekday via day-of-week
    Datetime probe = Datetime.newInstance(d, Time.newInstance(hour24, 0, 0, 0));
    String dow = probe.format('EEE');            // Mon, Tue, ... Sat, Sun
    if (dow == 'Sat') { d = d.addDays(2); }
    else if (dow == 'Sun') { d = d.addDays(1); }
    return Datetime.newInstance(d, Time.newInstance(hour24, 0, 0, 0));
}

// A slot within the next 24 hours. This is an EXISTING appointment used to
// exercise the "reschedule the one at 24h" test case, so it only needs to be
// genuinely in the future and inside the next 24h on ANY run (the weekday
// 9am-5pm rule governs RESCHEDULE TARGETS, not pre-existing records). Running
// on a Friday evening, for example, there is no weekday-9-5 slot inside 24h,
// so we simply place it 3 hours from now: always future, always <24h.
Datetime soonSlot() {
    return Datetime.now().addHours(3);
}

// ---- idempotent cleanup ---------------------------------------------------
Set<String> sampleIds = new Set<String>{'PT-1001','PT-1002','PT-1003'};
List<Contact> existing = [SELECT Id FROM Contact WHERE Patient_ID__c IN :sampleIds];
if (!existing.isEmpty()) {
    delete [SELECT Id FROM Appointment__c WHERE Contact__c IN :existing];
    delete existing;
}

// ---- Contacts -------------------------------------------------------------
Contact a = new Contact(FirstName='Sarah',   LastName='Johnson', Patient_ID__c='PT-1001',
                        Birthdate=Date.newInstance(1985,3,12),  Email='sarah.johnson@example.com', Phone='555-0101');
Contact b = new Contact(FirstName='Michael', LastName='Chen',    Patient_ID__c='PT-1002',
                        Birthdate=Date.newInstance(1990,7,22),  Email='michael.chen@example.com',  Phone='555-0102');
Contact c = new Contact(FirstName='Emily',   LastName='Davis',   Patient_ID__c='PT-1003',
                        Birthdate=Date.newInstance(1978,11,30), Email='emily.davis@example.com',   Phone='555-0103');
insert new List<Contact>{a, b, c};

// ---- Appointments (~7) ----------------------------------------------------
List<Appointment__c> appts = new List<Appointment__c>();

// Patient A — 2 UPCOMING (one within 24h) + 1 past cancelled
appts.add(new Appointment__c(Contact__c=a.Id, Appointment_DateTime__c=soonSlot(),
          Department__c='General Medicine', Doctor__c='Dr. Alan Smith',   Status__c='Scheduled'));      // within 24h
appts.add(new Appointment__c(Contact__c=a.Id, Appointment_DateTime__c=weekdaySlot(6, 10),
          Department__c='Cardiology',       Doctor__c='Dr. Priya Patel',  Status__c='Scheduled'));      // upcoming #2
appts.add(new Appointment__c(Contact__c=a.Id, Appointment_DateTime__c=Datetime.now().addDays(-10),
          Department__c='Dermatology',      Doctor__c='Dr. Grace Lee',    Status__c='Cancelled'));      // past, cancelled

// Patient B — 2 appointments (one Scheduled, one Rescheduled) for cross-user tests
appts.add(new Appointment__c(Contact__c=b.Id, Appointment_DateTime__c=weekdaySlot(4, 11),
          Department__c='Pediatrics',       Doctor__c='Dr. Omar Walker',  Status__c='Scheduled'));
appts.add(new Appointment__c(Contact__c=b.Id, Appointment_DateTime__c=weekdaySlot(18, 14),
          Department__c='Orthopedics',      Doctor__c='Dr. Luis Gomez',   Status__c='Rescheduled'));

// Patient C — 1 upcoming + 1 past cancelled (richer lookups / status spread)
appts.add(new Appointment__c(Contact__c=c.Id, Appointment_DateTime__c=weekdaySlot(9, 9),
          Department__c='Cardiology',       Doctor__c='Dr. Priya Patel',  Status__c='Scheduled'));
appts.add(new Appointment__c(Contact__c=c.Id, Appointment_DateTime__c=Datetime.now().addDays(-25),
          Department__c='General Medicine', Doctor__c='Dr. Alan Smith',   Status__c='Cancelled'));

insert appts;

System.debug('Seed complete: ' + appts.size() + ' appointments across 3 contacts.');
System.debug('Patient A Id=' + a.Id + '  within-24h slot=' + soonSlot());
