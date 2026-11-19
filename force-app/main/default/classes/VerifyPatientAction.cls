/**
 * VerifyPatientAction — Sprint 3 deterministic verification gate (V3 Healthcare).
 *
 * The agent must verify a patient with TWO identifiers — Patient ID
 * (Contact.Patient_ID__c) AND Date of Birth (Contact.Birthdate) — and BOTH must
 * match the SAME Contact before any lookup or action is allowed.
 *
 * Why this lives in Apex (not the prompt): verification is a hard rule. A rule
 * left to the LLM is probabilistic; here the match is computed in code and the
 * agent only ever learns a boolean + an opaque record id. On failure the method
 * returns a single generic outcome so the agent can NOT tell the difference
 * between "no such Patient ID", "DOB wrong", or "both wrong" — i.e. it never
 * leaks whether a matching record exists.
 *
 * Masking: this action deliberately returns NO echo of the DOB or the full
 * Patient ID. It returns only the patient's first name and a masked patient id
 * (e.g. "PT-**01") so the agent can confirm identity without reading creds back.
 */
public with sharing class VerifyPatientAction {

    public class Request {
        @InvocableVariable(required=true label='Patient ID' description='The patient-provided Patient ID, e.g. PT-1001.')
        public String patientId;

        @InvocableVariable(required=true label='Date of Birth' description='The patient-provided date of birth. Accepts YYYY-MM-DD, MM/DD/YYYY, or a spelled-out date.')
        public String dateOfBirth;
    }

    public class Result {
        @InvocableVariable(label='Verified' description='True only when Patient ID and DOB both match the same Contact.')
        public Boolean verified;

        @InvocableVariable(label='Contact Id' description='The verified Contact record id. Empty unless verified=true. Used internally to scope lookups.')
        public String contactId;

        @InvocableVariable(label='Patient First Name' description='Verified patient first name, for a friendly greeting. Empty unless verified.')
        public String patientFirstName;

        @InvocableVariable(label='Masked Patient Id' description='Patient ID with the middle masked (e.g. PT-**01). Safe to display. Empty unless verified.')
        public String maskedPatientId;

        @InvocableVariable(label='Message' description='A ready-to-use message for the agent to relay. Generic on failure so existence is never leaked.')
        public String message;
    }

    @InvocableMethod(
        label='Verify Patient (ID + DOB)'
        description='Deterministic verification gate: confirms a Patient ID and Date of Birth both match the SAME Contact. Returns verified=true + an internal contactId on success, or a generic failure that never reveals whether a record exists.'
        category='Ascend Clinics'
    )
    public static List<Result> verify(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(verifyOne(req));
        }
        return results;
    }

    private static Result verifyOne(Request req) {
        Result res = new Result();
        res.verified = false;
        res.contactId = '';
        res.patientFirstName = '';
        res.maskedPatientId = '';

        // Generic refusal — identical regardless of WHY verification failed, so the
        // agent cannot infer whether a Patient ID exists (no existence leak).
        final String GENERIC_FAIL =
            'I couldn\'t verify you with those details. For your security I can\'t say which part didn\'t match. ' +
            'Please share your Patient ID and date of birth again, and I\'ll try once more.';

        String rawPid = req == null ? null : req.patientId;
        String rawDob = req == null ? null : req.dateOfBirth;

        if (String.isBlank(rawPid) || String.isBlank(rawDob)) {
            res.message = 'To look up your appointments I first need to verify you. ' +
                          'Please provide BOTH your Patient ID and your date of birth.';
            return res;
        }

        String pid = rawPid.trim();
        Date dob = parseDob(rawDob);
        if (dob == null) {
            // Unparseable DOB — treat as a failed verification, no existence hint.
            res.message = GENERIC_FAIL;
            return res;
        }

        // The crux of the gate: BOTH identifiers must match the SAME Contact.
        // Patient_ID__c is Unique + case-insensitive, so this returns 0 or 1 row.
        List<Contact> matches = [
            SELECT Id, FirstName, Patient_ID__c
            FROM Contact
            WHERE Patient_ID__c = :pid AND Birthdate = :dob
            LIMIT 2
        ];

        if (matches.size() == 1) {
            Contact c = matches[0];
            res.verified = true;
            res.contactId = c.Id;
            res.patientFirstName = c.FirstName == null ? '' : c.FirstName;
            res.maskedPatientId = maskPatientId(c.Patient_ID__c);
            res.message = 'Thanks' + (String.isBlank(res.patientFirstName) ? '' : ', ' + res.patientFirstName) +
                          ' — you\'re verified. I can see your appointments under Patient ID ' +
                          res.maskedPatientId + '.';
        } else {
            // 0 matches (or an impossible >1) => generic failure, no leak.
            res.message = GENERIC_FAIL;
        }
        return res;
    }

    /**
     * Mask a Patient ID so it can be shown without exposing the full value.
     * Keeps a short prefix and the last 2 chars; masks the middle.
     * "PT-1001" -> "PT-**01".
     */
    @TestVisible
    private static String maskPatientId(String pid) {
        if (String.isBlank(pid)) {
            return '';
        }
        String p = pid.trim();
        if (p.length() <= 4) {
            // Too short to mask meaningfully — mask all but the last char.
            return p.length() <= 1 ? '*' : ('*'.repeat(p.length() - 1) + p.substring(p.length() - 1));
        }
        String prefix = p.substring(0, 3);           // keep the "PT-" style prefix
        String suffix = p.substring(p.length() - 2); // keep the last 2 chars
        Integer maskLen = p.length() - prefix.length() - suffix.length();
        return prefix + '*'.repeat(maskLen) + suffix;
    }

    /**
     * Parse a patient-supplied DOB string into a Date, tolerating common formats.
     * Returns null if it can't be parsed (caller treats null as a failed verify).
     */
    @TestVisible
    private static Date parseDob(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String s = raw.trim();

        // 1) ISO 8601: YYYY-MM-DD (also tolerates a time component).
        try {
            if (s.length() >= 10 && s.substring(4, 5) == '-' && s.substring(7, 8) == '-') {
                return Date.valueOf(s.substring(0, 10));
            }
        } catch (Exception e) { /* fall through */ }

                // 2) Slash or dash numeric formats. Clinic locale is Australia, so numeric
        //    dates are read DAY-FIRST (DD/MM/YYYY), with swaps when a number can only
        //    be a day, and day-first as the default when the date is ambiguous.
        try {
            String norm = s.replace('.', '/').replace('-', '/');
            String[] parts = norm.split('/');
            if (parts.size() == 3) {
                Integer a = safeInt(parts[0]);
                Integer b = safeInt(parts[1]);
                Integer c = safeInt(parts[2]);
                if (a != null && b != null && c != null) {
                    if (parts[0].length() == 4) {
                        return Date.newInstance(a, b, c);        // YYYY/MM/DD
                    } else if (c >= 1000) {
                        Integer day, month;
                        if (a > 12 && b <= 12) {        // first can only be a day
                            day = a; month = b;          // DD/MM/YYYY
                        } else if (b > 12 && a <= 12) { // second can only be a day
                            day = b; month = a;          // MM/DD/YYYY
                        } else {                         // ambiguous → AU day-first
                            day = a; month = b;
                        }
                        return Date.newInstance(c, month, day);
                    }
                }
            }
        } catch (Exception e) { /* fall through */ }


        // 3) Spelled-out dates, e.g. "March 12, 1985" / "12 March 1985" / "Mar 12 1985".
        //    Ported from RescheduleAppointmentAction (Sprint 5 §9 hand-off): the old
        //    JSON.deserialize approach was format/locale-fragile and quietly rejected
        //    many legitimately-phrased DOBs, causing verification to over-refuse a real
        //    patient. This deterministic month-name parse is the same logic the
        //    reschedule action already trusts.
        Integer[] ymd = parseSpelledDate(s);
        if (ymd != null) {
            try {
                return Date.newInstance(ymd[0], ymd[1], ymd[2]);
            } catch (Exception e) { /* fall through to null */ }
        }

        return null;
    }

    /**
     * Month-name date parse — tolerates "March 12, 1985", "12 March 1985", "Mar 12 1985".
     * Returns {year, month, day} or null if it isn't a spelled-out date.
     * (Mirrors RescheduleAppointmentAction.parseSpelledDate so verify and reschedule
     * accept the SAME natural phrasings.)
     */
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

    private static Integer safeInt(String v) {
        try { return Integer.valueOf(v.trim()); } catch (Exception e) { return null; }
    }
}