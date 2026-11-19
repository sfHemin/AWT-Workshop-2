/*
 * Ascend Clinics — V3 Healthcare — Sprint 5 Knowledge seed (REPEATABLE / IDEMPOTENT)
 * ----------------------------------------------------------------------------------
 * Run:  sf apex run --file scripts/apex/seed_knowledge.apex --target-org storm-org
 *
 * Creates + PUBLISHES the 3 Lightning Knowledge articles the V3 brief requires:
 *   1. Clinic hours
 *   2. Rescheduling and cancellation policy
 *   3. Before your visit
 *
 * The bodies are deliberately kept consistent with the deterministic reschedule
 * rules built in Sprint 4 (weekday, 09:00-17:00, within 30 days, Australia/Sydney).
 *
 * WHY Apex and not the Studio UI: Knowledge article creation IS scriptable via the
 * standard Knowledge__kav object + KbManagement.PublishingService, so the whole set
 * is reproducible with one command (no manual clicks). The equivalent manual Setup
 * steps are documented in sprint details/sprint 5.md for anyone who prefers the UI.
 *
 * Grounding handle: every article this agent answers from carries the stable URL-name
 * prefix 'ascend-clinics-'. AnswerClinicPolicyAction queries ONLY articles with that
 * prefix, so the agent is grounded strictly in these three — never the ~75 unrelated
 * demo articles that already live in this shared org.
 *
 * Idempotent: any prior 'ascend-clinics-%' article (draft, online, or archived) is
 * removed before re-inserting, so re-runs never duplicate or hit a UrlName clash.
 */

final String PREFIX = 'ascend-clinics-';

// ---- idempotent cleanup --------------------------------------------------
// Online articles must be archived before they can be deleted; drafts/archived
// can be deleted directly. Handle every publish state so a re-run is clean.
for (Knowledge__kav k : [SELECT Id, KnowledgeArticleId, PublishStatus
                         FROM Knowledge__kav WHERE UrlName LIKE :(PREFIX + '%')]) {
    try {
        if (k.PublishStatus == 'Online') {
            KbManagement.PublishingService.archiveOnlineArticle(k.KnowledgeArticleId, null);
        }
    } catch (Exception e) { System.debug('archive skip: ' + e.getMessage()); }
}
List<Knowledge__kav> stale = [SELECT Id, KnowledgeArticleId FROM Knowledge__kav
                              WHERE UrlName LIKE :(PREFIX + '%')];
for (Knowledge__kav k : stale) {
    try { KbManagement.PublishingService.deleteArchivedArticle(k.KnowledgeArticleId); }
    catch (Exception e) { /* may already be gone / still draft — fall through to delete */ }
}
List<Knowledge__kav> leftover = [SELECT Id FROM Knowledge__kav WHERE UrlName LIKE :(PREFIX + '%')];
if (!leftover.isEmpty()) { delete leftover; }

// ---- 1. Clinic hours ------------------------------------------------------
Knowledge__kav hours = new Knowledge__kav(
    Title   = 'Ascend Clinics — Clinic hours',
    UrlName = PREFIX + 'clinic-hours',
    Summary = 'Opening hours, closed days, and public-holiday note for Ascend Clinics.',
    FAQ_Question__c = 'What are your clinic hours? When are you open?',
    FAQ_Answer__c =
        '<p>Ascend Clinics is open <strong>weekdays (Monday to Friday) from 9:00 AM to 5:00 PM</strong>, clinic-local time (Australia/Sydney).</p>' +
        '<p>We are <strong>closed on weekends (Saturday and Sunday) and on public holidays</strong>.</p>' +
        '<p>Appointments can be booked or rescheduled only into these open hours — a weekday between 9:00 AM and 5:00 PM.</p>',
    Chat_Answer__c =
        'We are open weekdays 9:00 AM-5:00 PM (clinic-local time) and closed on weekends and public holidays.'
);

// ---- 2. Rescheduling and cancellation policy ------------------------------
Knowledge__kav reschedule = new Knowledge__kav(
    Title   = 'Ascend Clinics — Rescheduling and cancellation policy',
    UrlName = PREFIX + 'reschedule-cancellation-policy',
    Summary = 'How to reschedule or cancel an appointment, the valid-slot rules, and the no-show note.',
    FAQ_Question__c = 'How do I reschedule or cancel my appointment? What are the rules?',
    FAQ_Answer__c =
        '<h2>Rescheduling</h2>' +
        '<ul>' +
        '<li>You can reschedule an upcoming appointment to a new slot that is a <strong>weekday, between 9:00 AM and 5:00 PM, and within the next 30 days</strong>.</li>' +
        '<li>The new time must be in the future; past, weekend, after-hours, or beyond-30-day slots are not available.</li>' +
        '<li>Cancelled or already-completed appointments cannot be rescheduled.</li>' +
        '</ul>' +
        '<h2>Cancellation</h2>' +
        '<ul>' +
        '<li>Please give <strong>at least 24 hours notice</strong> if you need to cancel, so we can offer the slot to another patient.</li>' +
        '<li><strong>No-shows</strong> (missing an appointment without notice) may be noted on your record; repeated no-shows may affect future booking.</li>' +
        '</ul>',
    Chat_Answer__c =
        'Reschedule to a weekday 9:00 AM-5:00 PM within the next 30 days. Give at least 24 hours notice to cancel. ' +
        'Cancelled or completed appointments cannot be rescheduled, and no-shows may be noted on your record.'
);

// ---- 3. Before your visit -------------------------------------------------
Knowledge__kav before = new Knowledge__kav(
    Title   = 'Ascend Clinics — Before your visit',
    UrlName = PREFIX + 'before-your-visit',
    Summary = 'What to bring and do before an Ascend Clinics appointment: arrival time, ID, medication list, parking.',
    FAQ_Question__c = 'What should I bring and do before my visit?',
    FAQ_Answer__c =
        '<h2>Before your visit</h2>' +
        '<ul>' +
        '<li><strong>Arrive 10 minutes early</strong> so we can check you in without delay.</li>' +
        '<li>Bring a <strong>photo ID</strong> and your <strong>current medication list</strong> (names and doses).</li>' +
        '<li>Bring any <strong>referral letter or test results</strong> your doctor asked you to bring.</li>' +
        '<li><strong>Parking:</strong> free patient parking is available in the on-site car park off the main entrance; accessible bays are near the front doors.</li>' +
        '<li>If you have symptoms of a contagious illness, please call ahead before coming in.</li>' +
        '</ul>',
    Chat_Answer__c =
        'Arrive 10 minutes early, bring photo ID and your current medication list (plus any referral/results your doctor requested). ' +
        'Free patient parking is in the on-site car park off the main entrance.'
);

insert new List<Knowledge__kav>{ hours, reschedule, before };

// ---- publish all three ----------------------------------------------------
for (Knowledge__kav k : [SELECT Id, KnowledgeArticleId, Title
                         FROM Knowledge__kav WHERE UrlName LIKE :(PREFIX + '%')]) {
    KbManagement.PublishingService.publishArticle(k.KnowledgeArticleId, true);
    System.debug('Published: ' + k.Title);
}

Integer online = [SELECT COUNT() FROM Knowledge__kav
                  WHERE UrlName LIKE :(PREFIX + '%') AND PublishStatus = 'Online'];
System.debug('Ascend Knowledge seed complete — ' + online + ' articles Online.');
