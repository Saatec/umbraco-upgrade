# Risk register: <project name>

Likelihood and impact: low, medium, high. Status: open, mitigated, accepted (by the user, with their words in `decisions.md`), closed.

| ID | Category | Risk | Likelihood | Impact | Mitigation | Phase | Status | Source |
|---|---|---|---|---|---|---|---|---|
| R1 | version facts | <each version fact the plan relies on that is secondary or unverified> | <likelihood> | <impact> | Confirm on the official page before execution | all | open | <source of the fact> |
| R2 | path | <documented risks of the selected path, for example a long-running data migration> | <likelihood> | <impact> | <mitigation from the documentation> | <phase> | open | <URL, version, date> |
| R3 | customization | <each high-difficulty pattern> | <likelihood> | <impact> | <own phase, independent check> | <phase> | open | <pattern sources> |
| R4 | handling option | <each option still marked hypothesis that the plan relies on> | <likelihood> | <impact> | Confirm in the target documentation before relying on it | <phase> | open | <option sources> |
| R5 | package | <each package without a release for the target, or with an unknown status> | <likelihood> | <impact> | Decision with you before the phase | <phase> | open | <NuGet URL, date> |
| R6 | integration | <integrations that cannot be tested locally> | <likelihood> | <impact> | Sandbox or test endpoints; manual check | <phase> | open | |
| R7 | detection | Customizations outside the detected patterns may exist (unclassified files, patterns found only in the database or content) | medium | medium | Review the "needs classification" list in inventory.md; database checks during the database phases | discovery | open | |
| R8 | data | <database health findings on the local copy> | <likelihood> | <impact> | <cleanup with approval, or accepted> | <phase> | open | <evidence file> |
