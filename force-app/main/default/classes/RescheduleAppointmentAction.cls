/**
 * RescheduleAppointmentAction — Sprint 4 transactional action (V3 Healthcare).
 *
 * Reschedules ONE of a verified patient's own appointments to a patient-chosen
 * date/time, updating the record in place to the new time with Status = Rescheduled.
 *
 * WHY THE RULES LIVE HERE (not in the prompt): the clinic's booking rules —
 * weekday only, 09:00–17:00, within the next 30 days, in the future, not on a
 * Cancelled or already-past appointment — are HARD rules. A rule left to the LLM
 * is probabilistic and can be talked around (the pilot-failure anti-pattern). Here
 * every rule is computed in Apex and the agent only relays the ready-made message.
 * The Agent Script instructions only orchestrate (gather inputs) + relay the result.
 *
 * SCOPING (own-record only): the method ONLY ever touches appointments whose
 * Contact__c equals the supplied contactId. In the Agent Script this input is bound
 * exclusively to @variables.verified_contact_id (set by VerifyPatientAction), which
 * the LLM never sees in plaintext and cannot fabricate for another patient. A
 * user-typed appointmentId is never trusted on its own — it is re-queried with
 * `WHERE Id = :apptId AND Contact__c = :contactId`, so an id belonging to someone
 * else returns no row and is refused generically (no existence leak).
 *
 * TIMEZONE (deterministic): the clinic operates in Australia/Sydney (where the
 * sample data was authored). The running agent user is in America/Los_Angeles, so
 * relying on the default (running-user) timezone of Datetime.hour()/format() would
 * be a GMT-vs-local bug. Every weekday / business-hours / window check is therefore
 * computed against the FIXED clinic timezone via TimeZone + format(fmt, CLINIC_TZ),
 * independent of whoever runs the action. The patient's chosen wall-clock time is
 * interpreted as clinic-local and stored as the correct UTC instant.
 *
 * MASKING: confirmations reference the appointment only by date/time, department,
 * doctor and status — never the DOB or full Patient ID.
 */
public with sharing class RescheduleAppointmentAction {

    /** The clinic's operating timezone. All rule checks are anchored here so the
     *  result is identical no matter which user's context the action runs in. */
    @TestVisible
    private static final String CLINIC_TZ = 'Australia/Sydney';

    /** Business-hours window as minutes-from-midnight (clinic local).
     *  09:00 is the earliest start, 17:00 the LATEST start (inclusive) — a 17:00
     *  slot is allowed, anything after 17:00 is not. Documented boundary. */
    @TestVisible
    private static final Integer OPEN_MINUTES  = 9  * 60;  // 540  = 09:00
    @TestVisible
    private static final Integer CLOSE_MINUTES = 17 * 60;  // 1020 = 17:00

    /** How far ahead a new slot may be booked. */
    @TestVisible
    private static final Integer MAX_DAYS_AHEAD = 30;

    public class Request {
        @InvocableVariable(required=true label='Verified Contact Id'
            description='The verified Contact record id (from the Verify Patient action). The ONLY source of scope — never a patient-typed id. Reschedule can only touch appointments belonging to this contact.')
        public String contactId;

        @InvocableVariable(label='Appointment Id'
            description='Optional. The specific appointment record id to reschedule. Only honoured if it belongs to the verified contact; otherwise refused. Leave blank to select by description instead.')
        public String appointmentId;

        @InvocableVariable(label='Appointment Descriptor'
            description='Optional. How the patient referred to the appointment, e.g. a department ("cardiology") or doctor name. Used to pick which of their own upcoming appointments to move when no appointment id is given.')
        public String appointmentDescriptor;

        @InvocableVariable(required=true label='New Date And Time'
            description='The patient-chosen new date and time, interpreted in clinic (Australia/Sydney) local time. Accepts ISO 8601 (2026-11-18T14:00) or common formats (11/18/2026 2:00 PM). Resolve relative dates like "next Tuesday" to a concrete value before calling.')
        public String newDateTime;
    }

    public class Result {
        @InvocableVariable(label='Success'
            description='True only when an appointment was actually updated to the new time.')
        public Boolean success;

        @InvocableVariable(label='Message'
            description='A ready-to-relay message — the confirmation on success, or a specific, kind reason on refusal. Safe: contains no DOB or full Patient ID.')
        public String message;

        @InvocableVariable(label='New When Text'
            description='The new appointment date/time in clinic-local plain language, for the confirmation. Empty on refusal.')
        public String newWhenText;
    }

    @InvocableMethod(
        label='Reschedule Appointment'
        description='Reschedules ONE of the verified patient\'s own appointments to a chosen date/time. Enforces weekday + 09:00-17:00 + within 30 days + future + not-cancelled deterministically in code, scoped strictly to the verified contact. Returns a ready-to-relay confirmation or a specific refusal.'
        category='Ascend Clinics'
    )
    public static List<Result> reschedule(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(rescheduleOne(req));
        }
        return results;
    }

    private static Result rescheduleOne(Request req) {
        Result res = new Result();
        res.success = false;
        res.newWhenText = '';

        // Generic refusal used whenever the targeted appointment can't be resolved
        // to one the verified contact owns — identical whether it doesn't exist or
        // belongs to someone else, so ownership is never leaked.
        final String GENERIC_NOT_FOUND =
            'I couldn\'t find an upcoming appointment of yours matching that. ' +
            'Could you tell me which appointment you\'d like to move — for example the department or the current date?';

        // Hard scope guard: no verified contact id => not verified => do nothing.
        if (req == null || String.isBlank(req.contactId)) {
            res.message = 'I can\'t reschedule anything until you\'re verified with your Patient ID and date of birth.';
            return res;
        }
        Id cid;
        try {
            cid = (Id) req.contactId.trim();
        } catch (Exception e) {
            res.message = 'I can\'t reschedule anything until you\'re verified with your Patient ID and date of birth.';
            return res;
        }

        // 1) Resolve WHICH appointment — strictly within the verified contact's own records.
        Appointment__c appt = resolveOwnedAppointment(cid, req.appointmentId, req.appointmentDescriptor, res);
        if (appt == null) {
            // resolveOwnedAppointment set a specific message when it could (ambiguous /
            // none of that department); fall back to the generic not-found otherwise.
            if (String.isBlank(res.message)) {
                res.message = GENERIC_NOT_FOUND;
            }
            return res;
        }

        // 2) Can't reschedule a Cancelled appointment.
        if (appt.Status__c == 'Cancelled') {
            res.message = 'That appointment has been cancelled, so I can\'t reschedule it. ' +
                          'If you\'d like a new appointment, a team member can help you book one.';
            return res;
        }

        // 3) Can't reschedule an appointment that has already passed.
        if (appt.Appointment_DateTime__c != null && appt.Appointment_DateTime__c <= Datetime.now()) {
            res.message = 'That appointment has already taken place, so there\'s nothing to reschedule. ' +
                          'I can help you with a future appointment instead.';
            return res;
        }

        // 4) Parse the patient's chosen wall-clock date/time (interpreted clinic-local).
        Wall w = parseNewDateTime(req.newDateTime);
        if (w == null) {
            res.message = 'I couldn\'t read that date and time. Please give me a specific day and time within clinic hours, ' +
                          'for example "18 November 2026 at 2:00 PM".';
            return res;
        }
        Datetime newWhen = buildClinicDatetime(w);
        String whenText = formatClinic(newWhen);

        // 5) Idempotency: asking for the time it already has is a friendly no-op, not an error.
        if (appt.Appointment_DateTime__c != null && appt.Appointment_DateTime__c == newWhen) {
            res.message = 'That appointment is already booked for ' + whenText + ', so there\'s nothing to change.';
            res.newWhenText = whenText;
            return res;
        }

        // 6) Deterministic business-rule validation — each failure returns its own reason.
        if (newWhen <= Datetime.now()) {
            res.message = 'That time is in the past. Please choose a date and time in the future, within the next ' +
                          MAX_DAYS_AHEAD + ' days.';
            return res;
        }
        if (!isWeekday(newWhen)) {
            res.message = 'The clinic is only open on weekdays (Monday to Friday). ' +
                          'Please choose a weekday, between 9:00 AM and 5:00 PM.';
            return res;
        }
        if (!isWithinBusinessHours(newWhen)) {
            res.message = 'That time is outside clinic hours. Appointments start between 9:00 AM and 5:00 PM. ' +
                          'Please choose a time in that window.';
            return res;
        }
        if (!isWithinWindow(newWhen)) {
            res.message = 'I can only reschedule to a slot within the next ' + MAX_DAYS_AHEAD + ' days. ' +
                          'Please choose an earlier date.';
            return res;
        }

        // 7) All rules passed — update in place (never insert) and confirm.
        appt.Appointment_DateTime__c = newWhen;
        appt.Status__c = 'Rescheduled';
        update appt;

        String dept = String.isBlank(appt.Department__c) ? 'General' : appt.Department__c;
        String doc  = String.isBlank(appt.Doctor__c) ? 'your care team' : appt.Doctor__c;
        res.success = true;
        res.newWhenText = whenText;
        res.message = 'Done — your ' + dept + ' appointment with ' + doc +
                      ' is now booked for ' + whenText + '. It\'s marked as Rescheduled. ' +
                      'Is there anything else I can help you with?';
        return res;
    }

    /**
     * Resolve the appointment to act on, STRICTLY within the verified contact's own
     * records. Never trusts an appointmentId that isn't owned by the contact.
     * Returns null (and may set a specific message on res) when it can't resolve one.
     */
    @TestVisible
    private static Appointment__c resolveOwnedAppointment(Id cid, String apptId, String descriptor, Result res) {
        // Precise path: an explicit appointment id must belong to the verified contact.
        if (String.isNotBlank(apptId)) {
            Id aid;
            try {
                aid = (Id) apptId.trim();
            } catch (Exception e) {
                return null; // malformed id => generic not-found
            }
            // Re-query scoped by contact — an id for someone else returns 0 rows.
            List<Appointment__c> owned = [
                SELECT Id, Appointment_DateTime__c, Department__c, Doctor__c, Status__c, Contact__c
                FROM Appointment__c
                WHERE Id = :aid AND Contact__c = :cid
                LIMIT 1
            ];
            return owned.isEmpty() ? null : owned[0];
        }

        // Descriptor path: pick from the contact's OWN upcoming, non-cancelled appts.
        List<Appointment__c> upcoming = [
            SELECT Id, Appointment_DateTime__c, Department__c, Doctor__c, Status__c, Contact__c
            FROM Appointment__c
            WHERE Contact__c = :cid
              AND Appointment_DateTime__c > :Datetime.now()
              AND Status__c != 'Cancelled'
            ORDER BY Appointment_DateTime__c ASC
        ];

        if (upcoming.isEmpty()) {
            res.message = 'You don\'t have any upcoming appointments to reschedule right now.';
            return null;
        }

        // No descriptor but exactly one upcoming appt — unambiguous, use it.
        if (String.isBlank(descriptor)) {
            if (upcoming.size() == 1) {
                return upcoming[0];
            }
            res.message = 'You have more than one upcoming appointment. ' +
                          'Which one would you like to move — for example, by department?';
            return null;
        }

        // Match by department / doctor text contained in what the patient said.
        String needle = descriptor.trim().toLowerCase();
        List<Appointment__c> matches = new List<Appointment__c>();
        for (Appointment__c a : upcoming) {
            String dept = a.Department__c == null ? '' : a.Department__c.toLowerCase();
            String doc  = a.Doctor__c == null ? '' : a.Doctor__c.toLowerCase();
            if ((String.isNotBlank(dept) && (needle.contains(dept) || dept.contains(needle)))
                || (String.isNotBlank(doc) && (needle.contains(doc) || doc.contains(needle)))) {
                matches.add(a);
            }
        }

        if (matches.size() == 1) {
            return matches[0];
        }
        if (matches.size() > 1) {
            res.message = 'You have more than one upcoming appointment matching that. ' +
                          'Could you tell me the current date of the one you\'d like to move?';
            return null;
        }
        // No department/doctor match — but if they only have one upcoming appt, use it.
        if (upcoming.size() == 1) {
            return upcoming[0];
        }
        return null; // caller falls back to the generic not-found message
    }

    // ---------------------------------------------------------------------------
    // Deterministic validators — all anchored to CLINIC_TZ, not the running user.
    // ---------------------------------------------------------------------------

    /** True if the instant falls on Mon–Fri in the clinic's timezone. */
    @TestVisible
    private static Boolean isWeekday(Datetime dt) {
        String day = dt.format('EEE', CLINIC_TZ); // Mon, Tue, ... Sat, Sun
        return day != 'Sat' && day != 'Sun';
    }

    /** True if the clinic-local time is between 09:00 and 17:00 inclusive (17:00 = latest start). */
    @TestVisible
    private static Boolean isWithinBusinessHours(Datetime dt) {
        Integer minutes = clinicMinutesOfDay(dt);
        return minutes >= OPEN_MINUTES && minutes <= CLOSE_MINUTES;
    }

    /** True if the instant is within the next MAX_DAYS_AHEAD days from now. */
    @TestVisible
    private static Boolean isWithinWindow(Datetime dt) {
        return dt <= Datetime.now().addDays(MAX_DAYS_AHEAD);
    }

    /** Minutes-from-midnight of the instant in clinic-local time. */
    @TestVisible
    private static Integer clinicMinutesOfDay(Datetime dt) {
        Integer hh = Integer.valueOf(dt.format('HH', CLINIC_TZ));
        Integer mm = Integer.valueOf(dt.format('mm', CLINIC_TZ));
        return hh * 60 + mm;
    }

    /** Plain-language clinic-local rendering for confirmations. */
    @TestVisible
    private static String formatClinic(Datetime dt) {
        return dt.format('EEEE d MMMM yyyy \'at\' h:mm a', CLINIC_TZ);
    }

    // ---------------------------------------------------------------------------
    // Datetime construction & parsing
    // ---------------------------------------------------------------------------

    /** A bare wall-clock the patient intends, interpreted in clinic-local time. */
    @TestVisible
    private class Wall {
        @TestVisible Integer y;
        @TestVisible Integer mo;
        @TestVisible Integer d;
        @TestVisible Integer h;
        @TestVisible Integer mi;
    }

    /**
     * Build the UTC instant whose CLINIC_TZ wall clock equals the given components.
     * We treat the components as GMT, then subtract the clinic's UTC offset at that
     * instant so the stored instant renders back as the patient's intended local time.
     * (A single offset correction is used; slots falling exactly on a DST transition
     * are a negligible edge for weekday 9–5 clinic bookings and are documented.)
     */
    @TestVisible
    private static Datetime buildClinicDatetime(Wall w) {
        Datetime asIfGmt = Datetime.newInstanceGmt(w.y, w.mo, w.d, w.h, w.mi, 0);
        Integer offsetMs = TimeZone.getTimeZone(CLINIC_TZ).getOffset(asIfGmt);
        return asIfGmt.addSeconds(-(offsetMs / 1000));
    }

    /**
     * Parse a patient-supplied date/time into bare wall-clock components, tolerating
     * common formats (ISO 8601, US slash with optional AM/PM). Returns null if it
     * can't extract both a date and a time (caller then asks for a clearer value).
     */
    @TestVisible
    private static Wall parseNewDateTime(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String s = raw.trim();

        // Normalise the ISO 'T' date/time separator to a space so we can split uniformly.
        if (s.length() >= 11 && s.substring(10, 11).equalsIgnoreCase('T')) {
            s = s.substring(0, 10) + ' ' + s.substring(11);
        }
        // Drop a connective "at" so "November 18, 2026 at 2:00 PM" tokenises cleanly.
        String flat = (' ' + s + ' ').replaceAll('(?i)\\s+at\\s+', ' ').trim();

        String datePart;
        String timePart;
        Integer sp = flat.indexOf(' ');
        if (sp < 0) {
            return null; // date only, no time — need a time
        }

        if (flat.substring(0, sp).length() == 10 && flat.substring(4, 5) == '-') {
            // ISO date followed by the time.
            datePart = flat.substring(0, sp).trim();
            timePart = flat.substring(sp + 1).trim();
        } else {
            // Free-form: the TIME is whichever token carries ':' or am/pm; the rest is the date.
            // A standalone am/pm token (e.g. "9 am") pairs with the bare-number token just
            // before it, so that number is read as the hour, not the day.
            String[] toks = flat.split(' ');
            List<String> dateToks = new List<String>();
            List<String> timeToks = new List<String>();
            for (Integer i = 0; i < toks.size(); i++) {
                String tok = toks[i];
                String low = tok.toLowerCase();
                Boolean standaloneMeridiem = low == 'am' || low == 'pm' || low == 'a.m.' || low == 'p.m.';
                Boolean hasColon = tok.contains(':');
                Boolean suffixMeridiem = !standaloneMeridiem && (low.endsWith('am') || low.endsWith('pm'));

                if (hasColon || suffixMeridiem) {
                    timeToks.add(tok);
                } else if (standaloneMeridiem) {
                    // Re-home the immediately preceding bare number (the hour) from date to time,
                    // but only when no explicit time was seen yet and the number reads as an hour
                    // (1–12) — never steal a 4-digit year like "2026 ... PM".
                    if (timeToks.isEmpty() && !dateToks.isEmpty()) {
                        String prev = dateToks[dateToks.size() - 1];
                        if (prev.isNumeric() && Integer.valueOf(prev) >= 1 && Integer.valueOf(prev) <= 12) {
                            timeToks.add(dateToks.remove(dateToks.size() - 1));
                        }
                    }
                    timeToks.add(tok);
                } else {
                    dateToks.add(tok);
                }
            }
            datePart = String.join(dateToks, ' ').trim();
            timePart = String.join(timeToks, ' ').trim();
        }

        if (String.isBlank(datePart) || String.isBlank(timePart)) {
            return null;
        }

        Integer[] ymd = parseDatePart(datePart);
        Integer[] hm  = parseTimePart(timePart);
        if (ymd == null || hm == null) {
            return null;
        }

        // Sanity-range the components so obviously bad input is refused, not silently stored.
        Wall w = new Wall();
        w.y = ymd[0]; w.mo = ymd[1]; w.d = ymd[2]; w.h = hm[0]; w.mi = hm[1];
        if (w.mo < 1 || w.mo > 12 || w.d < 1 || w.d > 31 || w.h < 0 || w.h > 23 || w.mi < 0 || w.mi > 59) {
            return null;
        }
        return w;
    }

    /** {year, month, day} from ISO yyyy-mm-dd, US m/d/yyyy, or spelled-out "November 18, 2026". */
    @TestVisible
    private static Integer[] parseDatePart(String datePart) {
        try {
            // ISO: yyyy-mm-dd
            if (datePart.length() >= 10 && datePart.substring(4, 5) == '-' && datePart.substring(7, 8) == '-') {
                return new Integer[]{
                    Integer.valueOf(datePart.substring(0, 4)),
                    Integer.valueOf(datePart.substring(5, 7)),
                    Integer.valueOf(datePart.substring(8, 10))
                };
            }
        } catch (Exception e) { /* fall through */ }

               try {
            String norm = datePart.replace('.', '/').replace('-', '/');
            String[] parts = norm.split('/');
            if (parts.size() == 3) {
                Integer a = Integer.valueOf(parts[0].trim());
                Integer b = Integer.valueOf(parts[1].trim());
                Integer c = Integer.valueOf(parts[2].trim());
                if (parts[0].trim().length() == 4) {
                    return new Integer[]{ a, b, c };          // yyyy/mm/dd
                } else if (c >= 1000) {
                    Integer day, month;
                    if (a > 12 && b <= 12) {        day = a; month = b; }  // DD/MM/YYYY
                    else if (b > 12 && a <= 12) {   day = b; month = a; }  // MM/DD/YYYY
                    else {                           day = a; month = b; }  // AU day-first
                    return new Integer[]{ c, month, day };
                }
            }
        } catch (Exception e) { /* fall through */ }


        // Spelled-out: "November 18, 2026" / "18 November 2026" / "Nov 18 2026".
        return parseSpelledDate(datePart);
    }

    /** Month-name date parse — tolerates "November 18, 2026", "18 Nov 2026", etc. */
    @TestVisible
    private static Integer[] parseSpelledDate(String datePart) {
        try {
            String cleaned = datePart.replace(',', ' ').trim();
            while (cleaned.contains('  ')) { cleaned = cleaned.replace('  ', ' '); }
            String[] toks = cleaned.split(' ');
            if (toks.size() < 3) {
                return null;
            }
            Integer month = null, day = null, year = null;
            for (String t : toks) {
                Integer m = monthNumber(t);
                if (m != null && month == null) {
                    month = m;
                    continue;
                }
                Integer n;
                try { n = Integer.valueOf(t.trim()); } catch (Exception e) { continue; }
                if (n >= 1000) {
                    year = n;
                } else if (day == null) {
                    day = n;
                }
            }
            if (month != null && day != null && year != null) {
                return new Integer[]{ year, month, day };
            }
        } catch (Exception e) { /* fall through */ }
        return null;
    }

    /** Map a month name/abbreviation to 1–12, or null if the token isn't a month. */
    @TestVisible
    private static Integer monthNumber(String token) {
        if (String.isBlank(token)) {
            return null;
        }
        String t = token.trim().toLowerCase();
        Map<String, Integer> months = new Map<String, Integer>{
            'january'=>1,'jan'=>1, 'february'=>2,'feb'=>2, 'march'=>3,'mar'=>3,
            'april'=>4,'apr'=>4, 'may'=>5, 'june'=>6,'jun'=>6, 'july'=>7,'jul'=>7,
            'august'=>8,'aug'=>8, 'september'=>9,'sep'=>9,'sept'=>9, 'october'=>10,'oct'=>10,
            'november'=>11,'nov'=>11, 'december'=>12,'dec'=>12
        };
        return months.get(t);
    }

    /** {hour24, minute} from "14:00", "2:00 PM", "2 pm", "2PM". */
    @TestVisible
    private static Integer[] parseTimePart(String timePart) {
        try {
            String tp = timePart.trim().toUpperCase();
            Boolean isPm = tp.contains('PM') || tp.contains('P.M.');
            Boolean isAm = tp.contains('AM') || tp.contains('A.M.');
            tp = tp.replace('P.M.', '').replace('A.M.', '').replace('PM', '').replace('AM', '').trim();

            String[] hm = tp.split(':');
            Integer hh = Integer.valueOf(hm[0].trim());
            Integer mi = hm.size() > 1 ? Integer.valueOf(hm[1].trim()) : 0;

            if (isPm && hh < 12) hh += 12;
            if (isAm && hh == 12) hh = 0;

            return new Integer[]{ hh, mi };
        } catch (Exception e) {
            return null;
        }
    }
}