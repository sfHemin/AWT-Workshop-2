#!/usr/bin/env bash
# Ascend Clinics — V3 Healthcare — Sprint 1 verification (repeatable)
# Usage: bash scripts/verify_sample_data.sh
# Confirms the required sample-data cases in storm-org via SOQL.
set -euo pipefail
ORG="storm-org"
NOWUTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PLUS24=$(date -u -v+1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ)

echo "now(UTC)=$NOWUTC   +24h=$PLUS24"
echo
echo "### Contacts (patients) ###"
sf data query --target-org "$ORG" \
  --query "SELECT Patient_ID__c, Name, Birthdate FROM Contact WHERE Patient_ID__c LIKE 'PT-%' ORDER BY Patient_ID__c"

echo "### All appointments (local time) ###"
sf data query --target-org "$ORG" \
  --query "SELECT Name, Contact__r.Patient_ID__c, Contact__r.Name, FORMAT(Appointment_DateTime__c), Department__c, Doctor__c, Status__c FROM Appointment__c ORDER BY Contact__r.Patient_ID__c, Appointment_DateTime__c"

echo "### CHECK 1: Patient A (PT-1001) upcoming, not Cancelled — expect 2 ###"
sf data query --target-org "$ORG" \
  --query "SELECT Name, FORMAT(Appointment_DateTime__c), Status__c FROM Appointment__c WHERE Contact__r.Patient_ID__c='PT-1001' AND Appointment_DateTime__c > $NOWUTC AND Status__c != 'Cancelled' ORDER BY Appointment_DateTime__c"

echo "### CHECK 2: Patient A appointment within next 24h — expect 1 ###"
sf data query --target-org "$ORG" \
  --query "SELECT Name, FORMAT(Appointment_DateTime__c), Status__c FROM Appointment__c WHERE Contact__r.Patient_ID__c='PT-1001' AND Appointment_DateTime__c > $NOWUTC AND Appointment_DateTime__c < $PLUS24"

echo "### CHECK 3: Patient B (PT-1002) appointment count — expect >=1 ###"
sf data query --target-org "$ORG" \
  --query "SELECT COUNT(Id) FROM Appointment__c WHERE Contact__r.Patient_ID__c='PT-1002'"

echo "### CHECK 4: Status spread ###"
sf data query --target-org "$ORG" \
  --query "SELECT Status__c, COUNT(Id) FROM Appointment__c GROUP BY Status__c ORDER BY Status__c"

echo "### CHECK 5: Department spread ###"
sf data query --target-org "$ORG" \
  --query "SELECT Department__c, COUNT(Id) FROM Appointment__c GROUP BY Department__c ORDER BY Department__c"
