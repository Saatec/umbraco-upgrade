---
type: llm
focus: last_message
---

PASS if the reply says the plan is written, points to it, and asks the user to approve it, ask for changes, or reject it, and makes clear that nothing has been executed yet.
FAIL if the reply says it approved the plan itself, started a phase, or changed project files, or if it ends without asking for a decision on the plan.
