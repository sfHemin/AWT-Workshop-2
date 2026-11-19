/*
 * Sprint 5 live evidence — real org Apex against seeded data + published Knowledge.
 * Run:  sf apex run --file scripts/apex/sprint5_live_demo.apex --target-org storm-org
 *
 * Proves end-to-end (what the Apex tests can't, because this shared demo org's
 * record-triggered Case flow blocks Case DML inside the isolated test context):
 *   1. AnswerClinicPolicyAction returns grounded text for the 3 Ascend articles.
 *   2. EscalateToHumanAction actually INSERTS a Case (billing + emergency), links the
 *      Contact, sets priority, and scrubs DOB / Patient ID from the Description.
 * Cleans up the Cases it creates so re-runs stay tidy.
 */

System.debug('=== 1. KNOWLEDGE GROUNDING ===');
AnswerClinicPolicyAction.Request kq = new AnswerClinicPolicyAction.Request();
kq.question = 'What are your clinic hours?';
AnswerClinicPolicyAction.Result kr =
    AnswerClinicPolicyAction.answer(new List<AnswerClinicPolicyAction.Request>{ kq })[0];
System.debug('found=' + kr.found + '  topics=' + kr.topics);
System.debug('knowledge (first 400 chars):\n' + (kr.knowledge == null ? '' : kr.knowledge.left(400)));

// Resolve Sarah (PT-1001) exactly as the verify action does, for the Contact link.
Id sarahId = null;
List<Contact> sarah = [SELECT Id FROM Contact WHERE Patient_ID__c = 'PT-1001' LIMIT 1];
if (!sarah.isEmpty()) { sarahId = sarah[0].Id; }
System.debug('Sarah contact: ' + sarahId);

Set<Id> toClean = new Set<Id>();

System.debug('=== 2a. ESCALATION — billing (Medium, Contact-linked, scrubbed) ===');
EscalateToHumanAction.Request b = new EscalateToHumanAction.Request();
b.contactId = sarahId;
b.category = 'billing';
// Deliberately leaky summary — the action must scrub it before persisting.
b.conversationSummary = 'Patient PT-1001 (DOB 1985-03-12) asked about a charge on their bill.';
EscalateToHumanAction.Result br =
    EscalateToHumanAction.escalate(new List<EscalateToHumanAction.Request>{ b })[0];
System.debug('success=' + br.success + '  case=' + br.caseNumber + '  msg=' + br.message);
if (br.caseId != null) {
    toClean.add((Id) br.caseId);
    Case c = [SELECT Priority, Origin, ContactId, Subject, Description FROM Case WHERE Id = :br.caseId];
    System.debug('  Priority=' + c.Priority + ' Origin=' + c.Origin + ' Contact=' + c.ContactId);
    System.debug('  Subject=' + c.Subject);
    System.debug('  Description=' + c.Description);
    System.debug('  SCRUBBED? no PT-1001: ' + !c.Description.contains('PT-1001') +
                 ' | no 1985-03-12: ' + !c.Description.contains('1985-03-12'));
}

System.debug('=== 2b. ESCALATION — emergency (High priority) ===');
EscalateToHumanAction.Request e = new EscalateToHumanAction.Request();
e.contactId = sarahId;
e.category = 'emergency';
e.conversationSummary = 'Patient reported a possible emergency symptom during chat; advised to call emergency services (000).';
EscalateToHumanAction.Result er =
    EscalateToHumanAction.escalate(new List<EscalateToHumanAction.Request>{ e })[0];
System.debug('success=' + er.success + '  case=' + er.caseNumber + '  msg=' + er.message);
if (er.caseId != null) {
    toClean.add((Id) er.caseId);
    Case c = [SELECT Priority, Subject FROM Case WHERE Id = :er.caseId];
    System.debug('  Priority=' + c.Priority + '  Subject=' + c.Subject);
}

// ---- cleanup the demo Cases ----
if (!toClean.isEmpty()) {
    delete [SELECT Id FROM Case WHERE Id IN :toClean];
    System.debug('Cleaned up ' + toClean.size() + ' demo Case(s).');
}
