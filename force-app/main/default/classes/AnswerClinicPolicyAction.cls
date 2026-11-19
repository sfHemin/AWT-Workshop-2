/**
 * AnswerClinicPolicyAction — Sprint 5 Knowledge grounding (V3 Healthcare, core job 4).
 *
 * Returns the TEXT of Ascend Clinics' own published Knowledge articles so the agent
 * can answer policy questions grounded in them, and NEVER invents policy.
 *
 * WHY THIS LIVES IN APEX (not free retrieval): the brief's scored "Exceeds" anchor is
 * a grounded answer with a clean "I don't know" — no fabrication. This action is the
 * deterministic grounding layer:
 *   - It queries ONLY the three Ascend articles (UrlName LIKE 'ascend-clinics-%'),
 *     never the ~75 unrelated demo articles that share this org.
 *   - It returns the article bodies as the ONLY source material. The Agent Script
 *     instruction tells the LLM to answer strictly from this text and, if the text
 *     doesn't cover the question, to say so plainly and offer to escalate/help —
 *     rather than guess clinic policy.
 *
 * PUBLIC INFO (no verification): clinic hours / policy / before-your-visit are public
 * information, so this action is reachable WITHOUT verification (unlike the own-record
 * lookup and reschedule, which stay gated). It reads published Knowledge only; it
 * exposes no patient data, so there is nothing to gate.
 *
 * MASKING / SAFETY: the action returns only published article text — it never touches
 * Contact, Appointment, DOB, or Patient ID, so there is nothing sensitive to leak.
 */
public with sharing class AnswerClinicPolicyAction {

    /** Stable URL-name prefix that scopes grounding to OUR three articles only. */
    @TestVisible
    private static final String ASCEND_PREFIX = 'ascend-clinics-';

    public class Request {
        @InvocableVariable(required=true label='Question'
            description='The patient\'s policy question in their own words (e.g. "what are your clinic hours?").')
        public String question;
    }

    public class Result {
        @InvocableVariable(label='Found'
            description='True if at least one Ascend Clinics policy article is published and available to ground an answer.')
        public Boolean found;

        @InvocableVariable(label='Knowledge'
            description='The published Ascend Clinics policy articles as plain text. This is the ONLY material the agent may use to answer; if it does not cover the question, the agent must say it does not know.')
        public String knowledge;

        @InvocableVariable(label='Topics'
            description='Short list of the policy topics these articles cover, so the agent can offer them if the exact question is not covered.')
        public String topics;
    }

    @InvocableMethod(
        label='Answer Clinic Policy (Knowledge)'
        description='Returns Ascend Clinics\' own published Knowledge articles (clinic hours, rescheduling/cancellation policy, before your visit) as grounding text so the agent answers policy questions WITHOUT inventing anything. Public info — no verification required.'
        category='Ascend Clinics'
    )
    public static List<Result> answer(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(answerOne(req));
        }
        return results;
    }

    private static Result answerOne(Request req) {
        Result res = new Result();
        res.found = false;
        res.knowledge = '';
        res.topics = '';

        // Pull ONLY the published Ascend articles. Scoping by UrlName prefix keeps the
        // grounding tight — the agent can never be grounded in another squad's content.
        List<Knowledge__kav> arts = [
            SELECT Title, Summary, FAQ_Question__c, FAQ_Answer__c, Chat_Answer__c
            FROM Knowledge__kav
            WHERE UrlName LIKE :(ASCEND_PREFIX + '%')
              AND PublishStatus = 'Online'
              AND Language = 'en_US'
            ORDER BY Title ASC
        ];

        if (arts.isEmpty()) {
            res.knowledge = 'No Ascend Clinics policy articles are currently available.';
            return res;
        }

        List<String> blocks = new List<String>();
        List<String> titles = new List<String>();
        for (Knowledge__kav a : arts) {
            titles.add(cleanTitle(a.Title));

            List<String> parts = new List<String>();
            parts.add('### ' + a.Title);
            if (String.isNotBlank(a.FAQ_Question__c)) {
                parts.add('Q: ' + stripHtml(a.FAQ_Question__c));
            }
            // Prefer the full FAQ answer; fall back to the short chat answer / summary.
            String body = firstNonBlank(new List<String>{
                a.FAQ_Answer__c, a.Chat_Answer__c, a.Summary
            });
            if (String.isNotBlank(body)) {
                parts.add(stripHtml(body));
            }
            blocks.add(String.join(parts, '\n'));
        }

        res.found = true;
        res.knowledge = String.join(blocks, '\n\n');
        res.topics = String.join(titles, ', ');
        return res;
    }

    /** Turn the "Ascend Clinics — Clinic hours" title into a short topic label. */
    private static String cleanTitle(String title) {
        if (String.isBlank(title)) { return ''; }
        // Keep the part after an em-dash / hyphen separator if present.
        for (String sep : new List<String>{ ' — ', ' - ', ' – ' }) {
            if (title.contains(sep)) {
                return title.substringAfter(sep).trim();
            }
        }
        return title.trim();
    }

    private static String firstNonBlank(List<String> candidates) {
        for (String c : candidates) {
            if (String.isNotBlank(c)) { return c; }
        }
        return '';
    }

    /**
     * Convert the stored rich-text body to plain text the LLM can read cleanly:
     * list items become bullet lines, block tags become newlines, other tags drop,
     * and HTML entities are decoded.
     */
    @TestVisible
    private static String stripHtml(String html) {
        if (String.isBlank(html)) { return ''; }
        String s = html;
        s = s.replaceAll('(?i)<li[^>]*>', '\n- ');
        s = s.replaceAll('(?i)</(p|div|h1|h2|h3|h4|ul|ol|li|br)>', '\n');
        s = s.replaceAll('(?i)<br\\s*/?>', '\n');
        s = s.replaceAll('<[^>]+>', '');                 // drop any remaining tags
        s = s.replace('&nbsp;', ' ').replace('&amp;', '&')
             .replace('&lt;', '<').replace('&gt;', '>')
             .replace('&quot;', '"').replace('&#39;', '\'');
        s = s.replaceAll('[ \\t]+\n', '\n');             // trim trailing spaces on lines
        s = s.replaceAll('\n{3,}', '\n\n');              // collapse blank runs
        return s.trim();
    }
}