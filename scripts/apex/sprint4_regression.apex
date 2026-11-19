/** Sprint 3 regression — confirm verify + lookup still work after Sprint 4. */

// Verify (ID + DOB both match the same Contact).
VerifyPatientAction.Request vr = new VerifyPatientAction.Request();
vr.patientId = 'PT-1001';
vr.dateOfBirth = 'March 12, 1985';
VerifyPatientAction.Result v =
    VerifyPatientAction.verify(new List<VerifyPatientAction.Request>{ vr })[0];
System.debug('VERIFY verified=' + v.verified + ' masked=' + v.maskedPatientId + ' msg=' + v.message);

// Wrong DOB → generic failure, no leak.
VerifyPatientAction.Request vr2 = new VerifyPatientAction.Request();
vr2.patientId = 'PT-1001';
vr2.dateOfBirth = 'January 1, 2000';
VerifyPatientAction.Result v2 =
    VerifyPatientAction.verify(new List<VerifyPatientAction.Request>{ vr2 })[0];
System.debug('VERIFY wrong-dob verified=' + v2.verified + ' msg=' + v2.message);

// Lookup scoped to the verified contact.
GetUpcomingAppointmentsAction.Request lr = new GetUpcomingAppointmentsAction.Request();
lr.contactId = v.contactId;
GetUpcomingAppointmentsAction.Result l =
    GetUpcomingAppointmentsAction.getUpcoming(new List<GetUpcomingAppointmentsAction.Request>{ lr })[0];
System.debug('LOOKUP found=' + l.found + ' count=' + l.count);
System.debug('LOOKUP summary=\n' + l.summary);
