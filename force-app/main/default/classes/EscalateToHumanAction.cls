/**
 * EscalateToHumanAction — Sprint 5 clean hand-off to a human (V3 Healthcare, core job 5).
 *
 * Creates a Case so a human can follow up when the request is out of scope
 * (test results, prescriptions, billing), sensitive/clinical, when the patient
 * asks for a person, or when an emergency is detected. Returns a ready-to-relay
 * confirmation ("a team member / nurse will follow up…").
 *
 * WHY THIS LIVES IN APEX: escalation is an operational guardrail. Building the Case
 * in code means the routing fields (Type / Priority / Origin) and the PRIVACY SCRUB
 * are deterministic — they hold even if the model is coaxed. The Agent Script only
 * composes the reason + a short summary and relays the confirmation.
 *
 * PRIVACY SCRUB (minimum-necessary, operational guardrail): the conversation summary
 * the agent composes is run through scrubSummary() before it is persisted, which
 * redacts anything that looks like a full date of birth or a full Patient ID. The
 * Case therefore never stores a full DOB or Patient ID, and carries no clinical
 * detail beyond the short operational reason — exactly what a human needs to act,
 * nothing more. (A verified contactId may be linked so the human can find the record,
 * but the identifiers themselves are not written into free text.)
 *
 * PRIORITY: emergency escalations are created High priority; everything else Medium.
 */
public with sharing class EscalateToHumanAction {

    /** Recognised escalation categories → how the Case is routed/subject-lined. */
    @TestVisible
    private static final Set<String> KNOWN_CATEGORIES = new Set<String>{
        'test results', 'prescriptions', 'billing',
        'patient requested human', 'clinical', 'emergency', 'other'
    };

    public class Request {
        @InvocableVariable(label='Contact Id'
            description='Optional. The verified Contact id, if the patient has been verified. May be blank for an unverified caller. Used only to LINK the Case to the record — never written into free text.')
        public String contactId;

        @InvocableVariable(required=true label='Category'
            description='Short reason bucket: "test results", "prescriptions", "billing", "patient requested human", "clinical", "emergency", or "other".')
        public String category;

        @InvocableVariable(label='Conversation Summary'
            description='A SHORT, factual summary of what the patient asked, for the human to act on. No clinical detail, no full DOB, no full Patient ID. Scrubbed again server-side before saving.')
        public String conversationSummary;
    }

    public class Result {
        @InvocableVariable(label='Success' description='True if a Case was created for human follow-up.')
        public Boolean success;

        @InvocableVariable(label='Case Id' description='The created Case record id.')
        public String caseId;

        @InvocableVariable(label='Case Number' description='The human-readable Case number.')
        public String caseNumber;

        @InvocableVariable(label='Message'
            description='Ready-to-relay confirmation for the patient (e.g. a team member/nurse will follow up). Safe: contains no DOB or Patient ID.')
        public String message;
    }

    @InvocableMethod(
        label='Escalate To Human (create Case)'
        description='Creates a Case with a short, privacy-scrubbed conversation summary and sensible routing/priority so a human can follow up. Use for out-of-scope (test results / prescriptions / billing), clinical questions, explicit human requests, or emergencies.'
        category='Ascend Clinics'
    )
    public static List<Result> escalate(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(escalateOne(req));
        }
        return results;
    }

    private static Result escalateOne(Request req) {
        Result res = new Result();
        res.success = false;

        String category = normaliseCategory(req == null ? null : req.category);
        Boolean isEmergency = category == 'emergency';

        // Build the Case deterministically (fields, routing, priority, scrubbed
        // summary) in a pure, DML-free method so the construction can be unit-tested
        // without tripping this shared org's record-triggered Case flows.
        Case c = buildCase(req, category);

        try {
            insert c;
            Case created = [SELECT CaseNumber FROM Case WHERE Id = :c.Id LIMIT 1];
            res.success    = true;
            res.caseId     = c.Id;
            res.caseNumber = created.CaseNumber;
            res.message    = relayMessageFor(category, isEmergency);
        } catch (Exception e) {
            // Never surface a stack trace to the patient — give a calm fallback.
            res.success = false;
            res.message = 'I wasn\'t able to log this just now, but please don\'t worry — ' +
                          'you can call our front desk and a team member will help you directly.';
        }
        return res;
    }

    /**
     * Pure, DML-free construction of the escalation Case: routing fields, priority,
     * optional Contact link, and the privacy-scrubbed Description. Returns the Case
     * ready to insert. @TestVisible so the field/priority/scrub logic can be asserted
     * without inserting (this shared org has demo Case flows that fail in test context).
     */
    @TestVisible
    private static Case buildCase(Request req, String category) {
        Boolean isEmergency = category == 'emergency';

        // Scrub the agent-composed summary so no full DOB / Patient ID is persisted.
        String safeSummary = scrubSummary(req == null ? null : req.conversationSummary);
        if (String.isBlank(safeSummary)) {
            safeSummary = defaultSummaryFor(category);
        }

        Case c = new Case();
        c.Subject     = subjectFor(category);
        c.Status      = 'New';
        c.Origin      = 'Chat';
        c.Type        = 'General';                 // routing bucket (demo: a simple Type/Reason)
        c.Priority    = isEmergency ? 'High' : 'Medium';
        c.Description = buildDescription(category, safeSummary);

        // Link to the verified Contact when known, so the human can find the record
        // — the identifier itself is never written into the Description free text.
        if (req != null && String.isNotBlank(req.contactId)) {
            try { c.ContactId = (Id) req.contactId.trim(); }
            catch (Exception e) { /* ignore a malformed id; the Case is still created */ }
        }
        return c;
    }

    @TestVisible
    private static String normaliseCategory(String raw) {
        if (String.isBlank(raw)) { return 'other'; }
        String c = raw.trim().toLowerCase();
        return KNOWN_CATEGORIES.contains(c) ? c : 'other';
    }

    private static String subjectFor(String category) {
        switch on category {
            when 'test results'             { return 'Ascend Clinics — Test results request (needs care team)'; }
            when 'prescriptions'            { return 'Ascend Clinics — Prescription / refill request'; }
            when 'billing'                  { return 'Ascend Clinics — Billing enquiry'; }
            when 'patient requested human'  { return 'Ascend Clinics — Patient requested a human'; }
            when 'clinical'                 { return 'Ascend Clinics — Clinical question (needs clinician)'; }
            when 'emergency'                { return 'Ascend Clinics — URGENT: possible emergency reported in chat'; }
            when else                       { return 'Ascend Clinics — Patient request for follow-up'; }
        }
    }

    private static String defaultSummaryFor(String category) {
        switch on category {
            when 'emergency' {
                return 'Patient reported a possible emergency symptom during chat; advised to call emergency services (000).';
            }
            when 'patient requested human' {
                return 'Patient asked to speak with a person.';
            }
            when else {
                return 'Patient asked about something outside the assistant\'s scope (' + category + ').';
            }
        }
    }

    private static String buildDescription(String category, String safeSummary) {
        return 'Escalated by the Ascend Clinics Assistant.\n' +
               'Category: ' + category + '\n\n' +
               'Summary (patient-facing detail only, scrubbed of identifiers):\n' + safeSummary;
    }

    private static String relayMessageFor(String category, Boolean isEmergency) {
        if (isEmergency) {
            return 'I\'ve alerted our team right away. If this is an emergency, please call 000 ' +
                   '(emergency services) or go to your nearest emergency department now.';
        }
        if (category == 'test results' || category == 'clinical') {
            return 'I\'ve passed this to our care team with a short summary, and a member of the team ' +
                   'will follow up with you. Is there anything about your appointments I can help with in the meantime?';
        }
        if (category == 'prescriptions') {
            return 'I\'ve passed your prescription request to the right team with a short note, and they\'ll ' +
                   'follow up with you. Can I help with anything about your appointments in the meantime?';
        }
        if (category == 'billing') {
            return 'I\'ve passed your billing question to our accounts team with a short summary, and they\'ll ' +
                   'be in touch. Is there anything about your appointments I can help with meanwhile?';
        }
        return 'I\'ve logged this for our team with a short summary, and someone will follow up with you. ' +
               'Is there anything about your appointments I can help with in the meantime?';
    }

    /**
     * Redact anything that looks like a full DOB or full Patient ID from the
     * agent-composed summary, so the persisted Case holds minimum-necessary info.
     * Deterministic belt-and-braces behind the prompt instruction to omit them.
     */
    @TestVisible
    private static String scrubSummary(String raw) {
        if (String.isBlank(raw)) { return ''; }
        String s = raw;

        // Full Patient IDs like "PT-1001" / "PT1001" → keep the "PT-" cue, redact digits.
        s = s.replaceAll('(?i)\\bPT[-\\s]?\\d{3,}\\b', 'PT-[redacted]');

        // ISO dates YYYY-MM-DD and numeric D/M/YYYY or M/D/YYYY (a likely DOB).
        s = s.replaceAll('\\b\\d{4}-\\d{1,2}-\\d{1,2}\\b', '[dob redacted]');
        s = s.replaceAll('\\b\\d{1,2}[/\\.]\\d{1,2}[/\\.]\\d{2,4}\\b', '[dob redacted]');

        // Spelled-out dates with a year, e.g. "March 12, 1985" / "12 March 1985".
        String months = '(January|February|March|April|May|June|July|August|September|October|November|December' +
                        '|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)';
        s = s.replaceAll('(?i)\\b' + months + '\\s+\\d{1,2}(st|nd|rd|th)?,?\\s+\\d{4}\\b', '[dob redacted]');
        s = s.replaceAll('(?i)\\b\\d{1,2}(st|nd|rd|th)?\\s+' + months + '\\s+\\d{4}\\b', '[dob redacted]');

        return s.trim();
    }
}