/**
 * GetUpcomingAppointmentsAction — Sprint 3 own-record lookup (V3 Healthcare).
 *
 * Returns the UPCOMING appointments (Appointment_DateTime__c in the future,
 * Status__c != 'Cancelled') for ONE contact, ordered by date, summarised in
 * plain language.
 *
 * Scoping (own-record only): the method queries strictly by the supplied
 * contactId. In the Agent Script this input is bound ONLY to the verified
 * contact id that the verification action produced (@variables.verified_contact_id),
 * which the LLM never sees in plaintext and cannot fabricate for another patient.
 * It also refuses to run on a blank id. A platform-level Current-User scoping
 * rule on Appointment__c is planned for the guardrails sprint (Sprint 6) as a
 * second, data-layer guarantee — this action is written to be compatible with it.
 *
 * Masking: the summary references appointments only by date/time, department,
 * doctor and status. It never includes the patient's DOB or full Patient ID.
 */
public with sharing class GetUpcomingAppointmentsAction {

    public class Request {
        @InvocableVariable(required=true label='Verified Contact Id' description='The verified Contact record id (from the Verify Patient action). Lookups are scoped to this id only.')
        public String contactId;
    }

    /**
     * One row of the appointment card (Sprint 7). Every field here is SAFE to
     * render in the chat: a non-PII appointment name (APT-####), a clinic-local
     * plain-language time, department, doctor and status. No DOB or Patient ID
     * is ever placed on a line — masking is preserved from the summary path.
     * Field names match the Custom Lightning Type c__appointmentListResult.
     */
    public class ApptLine {
        @InvocableVariable(label='Appointment Name' description='Safe, non-PII appointment name, e.g. APT-00184.')
        public String appointmentName;

        @InvocableVariable(label='When Text' description='Clinic-local plain-language date/time, e.g. "Monday 23 November 2026 at 10:00 AM".')
        public String whenText;

        @InvocableVariable(label='Department' description='Clinic department, e.g. Cardiology.')
        public String department;

        @InvocableVariable(label='Doctor' description='Treating doctor / care team.')
        public String doctor;

        @InvocableVariable(label='Status' description='Appointment status, e.g. Scheduled or Rescheduled.')
        public String status;
    }

    public class Result {
        @InvocableVariable(label='Found' description='True if the verified patient has at least one upcoming appointment.')
        public Boolean found;

        @InvocableVariable(label='Count' description='Number of upcoming appointments.')
        public Integer count;

        @InvocableVariable(label='Summary' description='Plain-language summary of the upcoming appointments, ready to relay. No DOB or Patient ID is included.')
        public String summary;

        @InvocableVariable(label='Appointments' description='Structured, displayable list of the verified patient\'s upcoming appointments for the appointment card. Each line is safe to render (no DOB / Patient ID).')
        public List<ApptLine> appointments = new List<ApptLine>();
    }

    @InvocableMethod(
        label='Get Upcoming Appointments'
        description='Returns the verified patient\'s own upcoming (future, non-cancelled) appointments, ordered by date, summarised in plain language. Scoped strictly to the supplied verified Contact id.'
        category='Ascend Clinics'
    )
    public static List<Result> getUpcoming(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(getOne(req));
        }
        return results;
    }

    private static Result getOne(Request req) {
        Result res = new Result();
        res.found = false;
        res.count = 0;

        // Hard guard: never run an unscoped lookup. A blank id means the caller
        // is not verified (the verify action only emits an id on success).
        if (req == null || String.isBlank(req.contactId)) {
            res.summary = 'I can\'t look up any appointments until you\'re verified with your Patient ID and date of birth.';
            return res;
        }

        Id cid;
        try {
            cid = (Id) req.contactId.trim();
        } catch (Exception e) {
            res.summary = 'I can\'t look up any appointments until you\'re verified with your Patient ID and date of birth.';
            return res;
        }

        Datetime nowDt = Datetime.now();
        List<Appointment__c> appts = [
            SELECT Name, Appointment_DateTime__c, Department__c, Doctor__c, Status__c
            FROM Appointment__c
            WHERE Contact__c = :cid
              AND Appointment_DateTime__c > :nowDt
              AND Status__c != 'Cancelled'
            ORDER BY Appointment_DateTime__c ASC
        ];

        res.count = appts.size();
        res.found = !appts.isEmpty();

        if (appts.isEmpty()) {
            res.summary = 'You don\'t have any upcoming appointments on file right now. ' +
                          'Would you like help with anything else?';
            return res;
        }

        List<String> lines = new List<String>();
        for (Appointment__c a : appts) {
            // Format in the running user's timezone for a natural read-back.
            String whenText = a.Appointment_DateTime__c == null
                ? 'date to be confirmed'
                : a.Appointment_DateTime__c.format('EEEE d MMMM yyyy \'at\' h:mm a');
            String dept = String.isBlank(a.Department__c) ? 'General' : a.Department__c;
            String doc  = String.isBlank(a.Doctor__c) ? 'your care team' : a.Doctor__c;
            lines.add('• ' + whenText + ' — ' + dept + ' with ' + doc + ' (' + a.Status__c + ')');

            // Structured, displayable line for the appointment card (Sprint 7).
            // Reuses the exact same safe fields as the text summary — no PII added.
            ApptLine line = new ApptLine();
            line.appointmentName = a.Name;        // APT-#### — safe, non-PII
            line.whenText        = whenText;
            line.department      = dept;
            line.doctor          = doc;
            line.status          = a.Status__c;
            res.appointments.add(line);
        }

        String intro = res.count == 1
            ? 'Here is your upcoming appointment:'
            : 'Here are your ' + res.count + ' upcoming appointments:';
        res.summary = intro + '\n' + String.join(lines, '\n');
        return res;
    }
}