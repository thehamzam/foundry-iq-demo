# Synthetic Chunking Lab Procedure - Multi-Stage Duplicate Intake

**Document ID:** PROC-CHUNKLAB-101
**Version:** 1.0-SYNTHETIC
**Effective Date:** 2030-01-15
**Owner:** Synthetic Chunking Lab
**Classification:** SYNTHETIC DEMO CONTENT - PUBLIC TEST DATA

> **Synthetic demonstration notice:** This document is entirely fictional test content created only to demonstrate retrieval and chunk-size behavior. It is not real financial-services policy, legal advice, compliance guidance, operational guidance, or institutional instruction. It contains no real customer data. Names, codes, thresholds, dates, queues, and workflows are invented and must never be used for live decisions.

## 1. Purpose and Synthetic Applicability

This procedure creates a deliberately long, internally consistent demonstration of duplicate processing intake. Its only purpose is testing how retrieval systems behave when chunk sizes, overlap, ranking, and citation windows change. Every instruction is fictional. The procedure uses invented queues, timing targets, evidence markers, and terminal codes so expected answers can be measured without borrowing an operational rule. A tester should cite the exact numbered heading that contains a fact and should retrieve any separately headed exception before answering a boundary-sensitive question.

The procedure follows a staged path: open a synthetic case, normalize event details, form a candidate pair, test exclusions, request fictional evidence, apply a waiting rule, resolve exceptions, review quality, and route the drill. The same terms recur across distant sections so lexical retrieval alone is insufficient. “Duplicate candidate,” “correlation key,” and “synthetic business day” are controlled phrases. They mean only what this document says and carry no meaning outside the lab.

## 2. Stable Terms and Record Model

A **duplicate candidate** is a pair of fictional event rows offered for comparison. A **correlation key** is the exact three-part value **merchant label + amount + local purchase date**. No terminal identifier, posting date, channel, or narrative belongs in that key. A **synthetic business day** is a numbered lab interval, not a calendar or banking day. A **case clock** measures rehearsal elapsed time only. The stable document ID is PROC-CHUNKLAB-101.

Each drill record contains a case label, two event labels, the correlation key, a reason for comparison, evidence markers, exclusions considered, and the selected route. Missing data is recorded as **NOT-PROVIDED-IN-DRILL**; invented personal details are prohibited. Exact equality of the correlation key creates a candidate, not a conclusion. Later sections can disqualify the pair.

## 3. Stage One - Open and Label the Synthetic Case

Create a case label in the form **DUP-LAB-YYYY-NNN**. Add the document ID and version, then state that the record is synthetic. Capture the channel as a neutral lab value. Do not add a person name, account identifier, address, phone number, email address, credential, or real merchant. The opening stage ends only when the synthetic notice is visible in the case narrative and both fictional event rows have stable labels.

The intake operator must not infer a duplicate merely because two amounts match. Matching amounts are common in the rehearsal corpus. The operator advances both rows to normalization and records which fields are absent. Any row that appears to contain real data is removed from the exercise rather than masked inside the case.

## 4. Stage Two - Normalize the Candidate Pair

Normalize merchant labels by trimming surrounding spaces and using the drill-provided canonical label. Preserve the amount exactly to two decimal places and preserve the local purchase date exactly as supplied. Do not convert the local purchase date to posting date. Build the correlation key only after all three components are present. The expected key order is merchant label, amount, local purchase date.

When normalization yields two identical keys, mark **PAIR-CANDIDATE**. When it yields different keys, mark **PAIR-DIVERGENT** and continue to the exclusion review because a later drill note may explain the divergence. The procedure intentionally separates candidate formation from final disposition to test whether a retrieved chunk overstates an intermediate result.

## 5. Stage Three - Timed Duplicate Pair Review

The synthetic duplicate pair review target is **18 minutes** from the moment both normalized rows are available. The target measures lab workflow latency; it is not a service commitment, legal deadline, or customer promise. During the 18-minute target, compare the correlation key, event descriptions, fictional authorization sequence, and evidence markers. Record **TIMER-PAUSED-SYNTHETIC** if the lab facilitator pauses the exercise.

Meeting the target never overrides an exclusion. If an operator reaches minute 17 without the necessary evidence, the correct result is an incomplete drill record, not an assumed duplicate. The exact expected answer for the review-target query is “18 minutes,” cited to this heading.

## 6. Candidate Evidence Package

The base package includes both event labels, the correlation key, a statement that only one fictional purchase was intended, and a contact-attempt marker. For alternate-payment scenarios, the required marker is **ALT-PAY-ORANGE**. That marker is deliberately unique. It means the simulated packet includes a fictional alternate-payment artifact; it does not represent money, a receipt, or a real transaction.

A missing marker cannot be inferred from narrative similarity. A packet may contain many uses of “alternate payment,” but only ALT-PAY-ORANGE satisfies this drill. Reviewers should test whether smaller chunks retain the marker and its definition together.

## 7. General Merchant-Contact Waiting Rule

After the synthetic contact attempt is logged, wait **3 synthetic business days** before advancing a standard duplicate candidate to final disposition. Count begins at interval one after the contact marker. The wait is a fictional chunking-lab rule and must not be mapped to any real process. Record each interval as **LAB-DAY-1**, **LAB-DAY-2**, and **LAB-DAY-3**.

The general rule applies even when the correlation key matches and the 18-minute review is complete. Candidate review and contact waiting are different clocks. The next heading contains the only skip condition, intentionally separated from this rule to test boundary behavior.

## 8. Boundary Exception - Offline Terminal Code

Skip the 3-synthetic-business-day wait **only** when the fictional terminal status is exactly **LAB-OFFLINE-7**. Similar strings, a blank status, a narrative claim that a terminal was offline, or codes LAB-OFFLINE-6 and LAB-OFFLINE-8 do not qualify. This exception changes only the waiting step; it does not waive normalization, evidence, exclusion review, or final routing.

The condition in Section 7 and exception in Section 8 are intentionally split by headings. A complete answer must cite both headings and state that LAB-OFFLINE-7 is the sole skip code.

## 9. Split-Tender Review Condition

If the fictional purchase description shows two funding instruments for one combined purchase, mark **SPLIT-TENDER-REVIEW**. Do not decide from matching amounts alone. Compare the intended allocation, event labels, and total synthetic purchase value. The condition is placed at the end of this section so its exception begins across a heading boundary.

## 10. Boundary Exception - Split Tender Is Not a Duplicate

A properly allocated split-tender pair is **not** a duplicate in this synthetic procedure, even when individual display labels look similar. Route it to **LAB-SPLIT-EXCLUDED**. This exception supersedes candidate status but does not erase the audit trail. The expected boundary-sensitive answer requires Sections 9 and 10 together.

An improperly repeated allocation may return to duplicate review only when the facilitator provides the marker **SPLIT-REPEAT-CONFIRMED**. Without that marker, the exclusion stands.

## 11. Alternate-Payment Branch

When the exercise states that a fictional purchase was satisfied by another method and a card event also appears, require ALT-PAY-ORANGE from Section 6. Confirm the merchant label and local purchase date, but do not require identical amounts when the scenario explicitly includes a synthetic fee. Record the branch as **ALT-PAY-LAB**.

This branch exists to create a distant dependency: the evidence marker is defined five sections earlier. Answers that mention alternate payment without the marker are incomplete.

## 12. Recurring Event Exclusion

Two fictional events on a disclosed rehearsal schedule are routed to **LAB-RECURRING-EXCLUDED**, even when amount and merchant label repeat. The operator must find the schedule marker **RECURRENCE-DISCLOSED**. Absence of that marker does not prove recurrence. This exclusion is independent of split tender and should be cited separately.

## 13. Quality Review and Citation Test

A reviewer verifies the document ID, metadata, correlation-key order, 18-minute target, evidence marker, waiting rule, boundary exception, exclusions, and destination queue. The reviewer records each cited heading verbatim. A response that cites only a rehearsal record fails if a controlling numbered section exists.

The quality test intentionally asks the same concept in different language. “How is a pair joined?” maps to the correlation key in Section 2. “When can the contact wait be bypassed?” requires Sections 7 and 8. “Where does a completed case go?” maps to Section 15.

## 14. Final Disposition Codes

Use **LAB-DUP-CONFIRMED** only when the candidate survives exclusions and all required evidence is present. Use **LAB-DUP-INCOMPLETE** when evidence is absent. Use **LAB-SPLIT-EXCLUDED** or **LAB-RECURRING-EXCLUDED** for their scoped exclusions. These are fictional labels, not reason codes. Preserve the original candidate state in the synthetic audit sequence.

## 15. Final Handoff Queue

Every completed synthetic duplicate-processing drill that is not excluded is handed to **LAB-DUP-REVIEW**. The queue name is the precise expected fact. Excluded drills retain their exclusion route and are not sent to LAB-DUP-REVIEW. Incomplete drills remain in the lab holding state until the facilitator closes them.

The handoff record repeats PROC-CHUNKLAB-101, the cited disposition section, and the synthetic notice. No external system, cloud service, or real queue is contacted.

## 16. Closeout and Reset

Closeout confirms that every artifact is fictional, every field is safe for public test use, and no live action occurred. Reset timers and discard transient exercise notes. Retain only the synthetic Markdown corpus and evaluation results approved for the demo. The reset step prevents a rehearsal state from being mistaken for an instruction in a later session.

## 17. Extended Synthetic Rehearsal Records

The following repetitive records provide lexical density and long-distance retrieval pressure. They are examples, not additional rules.

### PROC-17.01 Synthetic Rehearsal Record 01

Rehearsal record 1 is a fictional counter simulation example for the capture stage. The operator records the stable drill label **PROC-17-CASE-001**, repeats the controlled term **duplicate candidate**, and cites the nearest numbered section before selecting any branch. The record exists to create realistic distance between definitions, thresholds, and later exceptions. It never represents a person, account, merchant, event, or production outcome. Reviewers compare the retrieved passage with the document heading and metadata rather than treating a nearby number as authority.

For this record, the simulated evidence packet contains an invented timestamp, a synthetic channel label, a neutral event description, and a completion marker. It deliberately excludes names, addresses, account numbers, credentials, contact details, and free-form biographical details. The reviewer must distinguish a required field from a narrative example, preserve the order stated in the controlling section, and reject any answer that drops the scope word “synthetic.” The repeated vocabulary gives chunking experiments multiple lexical matches while the stable record label allows deterministic citation checks.

Boundary check: The general wait is in Section 7, its sole skip code is in Section 8, and split tender is resolved across Sections 9 and 10. This reminder is intentionally repeated, but it does not replace the exact condition or exception in the cited controlling section. A retrieval result is complete only when it joins the governing condition to the separately headed exception. The record closes with a fictional quality note: verify document ID, version, section heading, and expected fact before marking the drill complete.

### PROC-17.02 Synthetic Rehearsal Record 02

Rehearsal record 2 is a fictional voice rehearsal example for the normalize stage. The operator records the stable drill label **PROC-17-CASE-002**, repeats the controlled term **correlation key**, and cites the nearest numbered section before selecting any branch. The record exists to create realistic distance between definitions, thresholds, and later exceptions. It never represents a person, account, merchant, event, or production outcome. Reviewers compare the retrieved passage with the document heading and metadata rather than treating a nearby number as authority.

For this record, the simulated evidence packet contains an invented timestamp, a synthetic channel label, a neutral event description, and a completion marker. It deliberately excludes names, addresses, account numbers, credentials, contact details, and free-form biographical details. The reviewer must distinguish a required field from a narrative example, preserve the order stated in the controlling section, and reject any answer that drops the scope word “synthetic.” The repeated vocabulary gives chunking experiments multiple lexical matches while the stable record label allows deterministic citation checks.

Boundary check: The general wait is in Section 7, its sole skip code is in Section 8, and split tender is resolved across Sections 9 and 10. This reminder is intentionally repeated, but it does not replace the exact condition or exception in the cited controlling section. A retrieval result is complete only when it joins the governing condition to the separately headed exception. The record closes with a fictional quality note: verify document ID, version, section heading, and expected fact before marking the drill complete.

### PROC-17.03 Synthetic Rehearsal Record 03

Rehearsal record 3 is a fictional secure-message drill example for the compare stage. The operator records the stable drill label **PROC-17-CASE-003**, repeats the controlled term **alternate payment**, and cites the nearest numbered section before selecting any branch. The record exists to create realistic distance between definitions, thresholds, and later exceptions. It never represents a person, account, merchant, event, or production outcome. Reviewers compare the retrieved passage with the document heading and metadata rather than treating a nearby number as authority.

For this record, the simulated evidence packet contains an invented timestamp, a synthetic channel label, a neutral event description, and a completion marker. It deliberately excludes names, addresses, account numbers, credentials, contact details, and free-form biographical details. The reviewer must distinguish a required field from a narrative example, preserve the order stated in the controlling section, and reject any answer that drops the scope word “synthetic.” The repeated vocabulary gives chunking experiments multiple lexical matches while the stable record label allows deterministic citation checks.

Boundary check: The general wait is in Section 7, its sole skip code is in Section 8, and split tender is resolved across Sections 9 and 10. This reminder is intentionally repeated, but it does not replace the exact condition or exception in the cited controlling section. A retrieval result is complete only when it joins the governing condition to the separately headed exception. The record closes with a fictional quality note: verify document ID, version, section heading, and expected fact before marking the drill complete.

### PROC-17.04 Synthetic Rehearsal Record 04

Rehearsal record 4 is a fictional batch replay example for the verify stage. The operator records the stable drill label **PROC-17-CASE-004**, repeats the controlled term **merchant-contact wait**, and cites the nearest numbered section before selecting any branch. The record exists to create realistic distance between definitions, thresholds, and later exceptions. It never represents a person, account, merchant, event, or production outcome. Reviewers compare the retrieved passage with the document heading and metadata rather than treating a nearby number as authority.

For this record, the simulated evidence packet contains an invented timestamp, a synthetic channel label, a neutral event description, and a completion marker. It deliberately excludes names, addresses, account numbers, credentials, contact details, and free-form biographical details. The reviewer must distinguish a required field from a narrative example, preserve the order stated in the controlling section, and reject any answer that drops the scope word “synthetic.” The repeated vocabulary gives chunking experiments multiple lexical matches while the stable record label allows deterministic citation checks.

Boundary check: The general wait is in Section 7, its sole skip code is in Section 8, and split tender is resolved across Sections 9 and 10. This reminder is intentionally repeated, but it does not replace the exact condition or exception in the cited controlling section. A retrieval result is complete only when it joins the governing condition to the separately headed exception. The record closes with a fictional quality note: verify document ID, version, section heading, and expected fact before marking the drill complete.

### PROC-17.05 Synthetic Rehearsal Record 05

Rehearsal record 5 is a fictional quality review example for the route stage. The operator records the stable drill label **PROC-17-CASE-005**, repeats the controlled term **split-tender review**, and cites the nearest numbered section before selecting any branch. The record exists to create realistic distance between definitions, thresholds, and later exceptions. It never represents a person, account, merchant, event, or production outcome. Reviewers compare the retrieved passage with the document heading and metadata rather than treating a nearby number as authority.

For this record, the simulated evidence packet contains an invented timestamp, a synthetic channel label, a neutral event description, and a completion marker. It deliberately excludes names, addresses, account numbers, credentials, contact details, and free-form biographical details. The reviewer must distinguish a required field from a narrative example, preserve the order stated in the controlling section, and reject any answer that drops the scope word “synthetic.” The repeated vocabulary gives chunking experiments multiple lexical matches while the stable record label allows deterministic citation checks.

Boundary check: The general wait is in Section 7, its sole skip code is in Section 8, and split tender is resolved across Sections 9 and 10. This reminder is intentionally repeated, but it does not replace the exact condition or exception in the cited controlling section. A retrieval result is complete only when it joins the governing condition to the separately headed exception. The record closes with a fictional quality note: verify document ID, version, section heading, and expected fact before marking the drill complete.

### PROC-17.06 Synthetic Rehearsal Record 06

Rehearsal record 6 is a fictional counter simulation example for the close stage. The operator records the stable drill label **PROC-17-CASE-006**, repeats the controlled term **duplicate candidate**, and cites the nearest numbered section before selecting any branch. The record exists to create realistic distance between definitions, thresholds, and later exceptions. It never represents a person, account, merchant, event, or production outcome. Reviewers compare the retrieved passage with the document heading and metadata rather than treating a nearby number as authority.

For this record, the simulated evidence packet contains an invented timestamp, a synthetic channel label, a neutral event description, and a completion marker. It deliberately excludes names, addresses, account numbers, credentials, contact details, and free-form biographical details. The reviewer must distinguish a required field from a narrative example, preserve the order stated in the controlling section, and reject any answer that drops the scope word “synthetic.” The repeated vocabulary gives chunking experiments multiple lexical matches while the stable record label allows deterministic citation checks.

Boundary check: The general wait is in Section 7, its sole skip code is in Section 8, and split tender is resolved across Sections 9 and 10. This reminder is intentionally repeated, but it does not replace the exact condition or exception in the cited controlling section. A retrieval result is complete only when it joins the governing condition to the separately headed exception. The record closes with a fictional quality note: verify document ID, version, section heading, and expected fact before marking the drill complete.

### PROC-17.07 Synthetic Rehearsal Record 07

Rehearsal record 7 is a fictional voice rehearsal example for the capture stage. The operator records the stable drill label **PROC-17-CASE-007**, repeats the controlled term **correlation key**, and cites the nearest numbered section before selecting any branch. The record exists to create realistic distance between definitions, thresholds, and later exceptions. It never represents a person, account, merchant, event, or production outcome. Reviewers compare the retrieved passage with the document heading and metadata rather than treating a nearby number as authority.

For this record, the simulated evidence packet contains an invented timestamp, a synthetic channel label, a neutral event description, and a completion marker. It deliberately excludes names, addresses, account numbers, credentials, contact details, and free-form biographical details. The reviewer must distinguish a required field from a narrative example, preserve the order stated in the controlling section, and reject any answer that drops the scope word “synthetic.” The repeated vocabulary gives chunking experiments multiple lexical matches while the stable record label allows deterministic citation checks.

Boundary check: The general wait is in Section 7, its sole skip code is in Section 8, and split tender is resolved across Sections 9 and 10. This reminder is intentionally repeated, but it does not replace the exact condition or exception in the cited controlling section. A retrieval result is complete only when it joins the governing condition to the separately headed exception. The record closes with a fictional quality note: verify document ID, version, section heading, and expected fact before marking the drill complete.

### PROC-17.08 Synthetic Rehearsal Record 08

Rehearsal record 8 is a fictional secure-message drill example for the normalize stage. The operator records the stable drill label **PROC-17-CASE-008**, repeats the controlled term **alternate payment**, and cites the nearest numbered section before selecting any branch. The record exists to create realistic distance between definitions, thresholds, and later exceptions. It never represents a person, account, merchant, event, or production outcome. Reviewers compare the retrieved passage with the document heading and metadata rather than treating a nearby number as authority.

For this record, the simulated evidence packet contains an invented timestamp, a synthetic channel label, a neutral event description, and a completion marker. It deliberately excludes names, addresses, account numbers, credentials, contact details, and free-form biographical details. The reviewer must distinguish a required field from a narrative example, preserve the order stated in the controlling section, and reject any answer that drops the scope word “synthetic.” The repeated vocabulary gives chunking experiments multiple lexical matches while the stable record label allows deterministic citation checks.

Boundary check: The general wait is in Section 7, its sole skip code is in Section 8, and split tender is resolved across Sections 9 and 10. This reminder is intentionally repeated, but it does not replace the exact condition or exception in the cited controlling section. A retrieval result is complete only when it joins the governing condition to the separately headed exception. The record closes with a fictional quality note: verify document ID, version, section heading, and expected fact before marking the drill complete.

### PROC-17.09 Synthetic Rehearsal Record 09

Rehearsal record 9 is a fictional batch replay example for the compare stage. The operator records the stable drill label **PROC-17-CASE-009**, repeats the controlled term **merchant-contact wait**, and cites the nearest numbered section before selecting any branch. The record exists to create realistic distance between definitions, thresholds, and later exceptions. It never represents a person, account, merchant, event, or production outcome. Reviewers compare the retrieved passage with the document heading and metadata rather than treating a nearby number as authority.

For this record, the simulated evidence packet contains an invented timestamp, a synthetic channel label, a neutral event description, and a completion marker. It deliberately excludes names, addresses, account numbers, credentials, contact details, and free-form biographical details. The reviewer must distinguish a required field from a narrative example, preserve the order stated in the controlling section, and reject any answer that drops the scope word “synthetic.” The repeated vocabulary gives chunking experiments multiple lexical matches while the stable record label allows deterministic citation checks.

Boundary check: The general wait is in Section 7, its sole skip code is in Section 8, and split tender is resolved across Sections 9 and 10. This reminder is intentionally repeated, but it does not replace the exact condition or exception in the cited controlling section. A retrieval result is complete only when it joins the governing condition to the separately headed exception. The record closes with a fictional quality note: verify document ID, version, section heading, and expected fact before marking the drill complete.

### PROC-17.10 Synthetic Rehearsal Record 10

Rehearsal record 10 is a fictional quality review example for the verify stage. The operator records the stable drill label **PROC-17-CASE-010**, repeats the controlled term **split-tender review**, and cites the nearest numbered section before selecting any branch. The record exists to create realistic distance between definitions, thresholds, and later exceptions. It never represents a person, account, merchant, event, or production outcome. Reviewers compare the retrieved passage with the document heading and metadata rather than treating a nearby number as authority.

For this record, the simulated evidence packet contains an invented timestamp, a synthetic channel label, a neutral event description, and a completion marker. It deliberately excludes names, addresses, account numbers, credentials, contact details, and free-form biographical details. The reviewer must distinguish a required field from a narrative example, preserve the order stated in the controlling section, and reject any answer that drops the scope word “synthetic.” The repeated vocabulary gives chunking experiments multiple lexical matches while the stable record label allows deterministic citation checks.

Boundary check: The general wait is in Section 7, its sole skip code is in Section 8, and split tender is resolved across Sections 9 and 10. This reminder is intentionally repeated, but it does not replace the exact condition or exception in the cited controlling section. A retrieval result is complete only when it joins the governing condition to the separately headed exception. The record closes with a fictional quality note: verify document ID, version, section heading, and expected fact before marking the drill complete.

### PROC-17.11 Synthetic Rehearsal Record 11

Rehearsal record 11 is a fictional counter simulation example for the route stage. The operator records the stable drill label **PROC-17-CASE-011**, repeats the controlled term **duplicate candidate**, and cites the nearest numbered section before selecting any branch. The record exists to create realistic distance between definitions, thresholds, and later exceptions. It never represents a person, account, merchant, event, or production outcome. Reviewers compare the retrieved passage with the document heading and metadata rather than treating a nearby number as authority.

For this record, the simulated evidence packet contains an invented timestamp, a synthetic channel label, a neutral event description, and a completion marker. It deliberately excludes names, addresses, account numbers, credentials, contact details, and free-form biographical details. The reviewer must distinguish a required field from a narrative example, preserve the order stated in the controlling section, and reject any answer that drops the scope word “synthetic.” The repeated vocabulary gives chunking experiments multiple lexical matches while the stable record label allows deterministic citation checks.

Boundary check: The general wait is in Section 7, its sole skip code is in Section 8, and split tender is resolved across Sections 9 and 10. This reminder is intentionally repeated, but it does not replace the exact condition or exception in the cited controlling section. A retrieval result is complete only when it joins the governing condition to the separately headed exception. The record closes with a fictional quality note: verify document ID, version, section heading, and expected fact before marking the drill complete.

### PROC-17.12 Synthetic Rehearsal Record 12

Rehearsal record 12 is a fictional voice rehearsal example for the close stage. The operator records the stable drill label **PROC-17-CASE-012**, repeats the controlled term **correlation key**, and cites the nearest numbered section before selecting any branch. The record exists to create realistic distance between definitions, thresholds, and later exceptions. It never represents a person, account, merchant, event, or production outcome. Reviewers compare the retrieved passage with the document heading and metadata rather than treating a nearby number as authority.

For this record, the simulated evidence packet contains an invented timestamp, a synthetic channel label, a neutral event description, and a completion marker. It deliberately excludes names, addresses, account numbers, credentials, contact details, and free-form biographical details. The reviewer must distinguish a required field from a narrative example, preserve the order stated in the controlling section, and reject any answer that drops the scope word “synthetic.” The repeated vocabulary gives chunking experiments multiple lexical matches while the stable record label allows deterministic citation checks.

Boundary check: The general wait is in Section 7, its sole skip code is in Section 8, and split tender is resolved across Sections 9 and 10. This reminder is intentionally repeated, but it does not replace the exact condition or exception in the cited controlling section. A retrieval result is complete only when it joins the governing condition to the separately headed exception. The record closes with a fictional quality note: verify document ID, version, section heading, and expected fact before marking the drill complete.

### PROC-17.13 Synthetic Rehearsal Record 13

Rehearsal record 13 is a fictional secure-message drill example for the capture stage. The operator records the stable drill label **PROC-17-CASE-013**, repeats the controlled term **alternate payment**, and cites the nearest numbered section before selecting any branch. The record exists to create realistic distance between definitions, thresholds, and later exceptions. It never represents a person, account, merchant, event, or production outcome. Reviewers compare the retrieved passage with the document heading and metadata rather than treating a nearby number as authority.

For this record, the simulated evidence packet contains an invented timestamp, a synthetic channel label, a neutral event description, and a completion marker. It deliberately excludes names, addresses, account numbers, credentials, contact details, and free-form biographical details. The reviewer must distinguish a required field from a narrative example, preserve the order stated in the controlling section, and reject any answer that drops the scope word “synthetic.” The repeated vocabulary gives chunking experiments multiple lexical matches while the stable record label allows deterministic citation checks.

Boundary check: The general wait is in Section 7, its sole skip code is in Section 8, and split tender is resolved across Sections 9 and 10. This reminder is intentionally repeated, but it does not replace the exact condition or exception in the cited controlling section. A retrieval result is complete only when it joins the governing condition to the separately headed exception. The record closes with a fictional quality note: verify document ID, version, section heading, and expected fact before marking the drill complete.

### PROC-17.14 Synthetic Rehearsal Record 14

Rehearsal record 14 is a fictional batch replay example for the normalize stage. The operator records the stable drill label **PROC-17-CASE-014**, repeats the controlled term **merchant-contact wait**, and cites the nearest numbered section before selecting any branch. The record exists to create realistic distance between definitions, thresholds, and later exceptions. It never represents a person, account, merchant, event, or production outcome. Reviewers compare the retrieved passage with the document heading and metadata rather than treating a nearby number as authority.

For this record, the simulated evidence packet contains an invented timestamp, a synthetic channel label, a neutral event description, and a completion marker. It deliberately excludes names, addresses, account numbers, credentials, contact details, and free-form biographical details. The reviewer must distinguish a required field from a narrative example, preserve the order stated in the controlling section, and reject any answer that drops the scope word “synthetic.” The repeated vocabulary gives chunking experiments multiple lexical matches while the stable record label allows deterministic citation checks.

Boundary check: The general wait is in Section 7, its sole skip code is in Section 8, and split tender is resolved across Sections 9 and 10. This reminder is intentionally repeated, but it does not replace the exact condition or exception in the cited controlling section. A retrieval result is complete only when it joins the governing condition to the separately headed exception. The record closes with a fictional quality note: verify document ID, version, section heading, and expected fact before marking the drill complete.

### PROC-17.15 Synthetic Rehearsal Record 15

Rehearsal record 15 is a fictional quality review example for the compare stage. The operator records the stable drill label **PROC-17-CASE-015**, repeats the controlled term **split-tender review**, and cites the nearest numbered section before selecting any branch. The record exists to create realistic distance between definitions, thresholds, and later exceptions. It never represents a person, account, merchant, event, or production outcome. Reviewers compare the retrieved passage with the document heading and metadata rather than treating a nearby number as authority.

For this record, the simulated evidence packet contains an invented timestamp, a synthetic channel label, a neutral event description, and a completion marker. It deliberately excludes names, addresses, account numbers, credentials, contact details, and free-form biographical details. The reviewer must distinguish a required field from a narrative example, preserve the order stated in the controlling section, and reject any answer that drops the scope word “synthetic.” The repeated vocabulary gives chunking experiments multiple lexical matches while the stable record label allows deterministic citation checks.

Boundary check: The general wait is in Section 7, its sole skip code is in Section 8, and split tender is resolved across Sections 9 and 10. This reminder is intentionally repeated, but it does not replace the exact condition or exception in the cited controlling section. A retrieval result is complete only when it joins the governing condition to the separately headed exception. The record closes with a fictional quality note: verify document ID, version, section heading, and expected fact before marking the drill complete.

## 18. Synthetic Fact Index

- Correlation key: merchant label + amount + local purchase date (Section 2).
- Review target: 18 minutes (Section 5).
- Alternate-payment marker: ALT-PAY-ORANGE (Section 6).
- General wait: 3 synthetic business days (Section 7).
- Sole wait-skip code: LAB-OFFLINE-7 (Section 8).
- Split-tender condition and exception: Sections 9 and 10.
- Final handoff queue: LAB-DUP-REVIEW (Section 15).

This index is synthetic and exists for evaluation setup. Retrieval tests should still cite the controlling sections.
