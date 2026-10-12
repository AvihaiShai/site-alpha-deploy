# 14 · Better prompts and a separate drill project

## What your original prompt left open

| Missing | Why it matters | Where it goes in the prompt |
|---|---|---|
| **Date/time of the onsite** and hours you can study per day | Decides how deep each topic goes; the 16-hour cap only makes sense with a calendar | "Onsite is on ___; I can study ___ h/day" |
| **Ziv's answers** (laptop, OS, tools, internet, AI access, GCP role, egress policy, can I bring a repo) | Changes the plan: Cloud Shell vs own laptop, NAT vs air-gap, repo vs printout | Paste them, or "unknown" per item |
| **Is outbound internet allowed from the project?** | If not, the whole K3s/CNPG install becomes an air-gap problem | Explicit question |
| **Your rehearsal environment** (own GCP account? billing? laptop OS?) | Can't rehearse what you can't run | "I have / don't have a GCP account with billing; my laptop is ___" |
| **Definition of "confident"** | Otherwise prep never ends | e.g. "Empty project → READY FOR HANDOVER in < 60 min, twice; answer 25/30 Q&A without notes" |
| **Live-change and failure-injection practice** | They will change requirements or break things | "Include drills where you change requirements mid-way" |
| **Transparency strategy for prepared code** | Prepared code that looks hidden hurts more than helps | "How do I present that I prepared a kit?" |
| **Credential hygiene on a borrowed laptop** | Security role, so it is observed | "What do I clean up afterwards?" |
| **Salary band / conditions answer** | Go/no-go gate from the earlier assessment | "Band is ___ / still unknown" |
| **Language of the slides** (Hebrew/English) | Interview language | State it |

## Prompt 1: the improved version of your request (for any future exercise)

```
Context: I have an onsite technical exercise on <DATE> at <COMPANY> for a <ROLE>. Attached: the exercise brief.
My real experience: <bullets; say used / operated / troubleshot / implemented / owned>.
Known gaps: <bullets>.
Environment facts from the company: laptop=<theirs/mine/unknown>, OS=<>, internet=<>, AI tools=<>,
cloud permissions=<>, outbound internet from the cloud project=<allowed/forbidden/unknown>, bring a repo=<yes/no/unknown>.
My rehearsal environment: <own cloud account with billing? laptop OS?>.
Time: I can study <N> h/day until the onsite; hard cap <M> hours total.
Done means: <e.g. full run from an empty project in < 60 min twice; explain every file; answer 25/30 Q&A cold>.

Deliver:
1. A deployment kit I can bring (code + neutral engineering docs), with every design decision explained (why / alternative / trade-off),
   pinned and verified versions, and whatever you can test offline actually tested.
2. A separate private study kit: primers mapped to my background, onsite minute plan with talk tracks, failure drills,
   live-change drills, skeptical-client Q&A, blind spots.
3. The <N>-minute opening slides.
4. Questions I must send the company before investing further.
Flag anything that depends on facts I haven't given you, and tell me the cheapest way to resolve each one.
```

## Prompt 2: skeptical-client / interviewer drill (run in a fresh chat or the drill project)

```
Act as two people at once during my onsite exercise rehearsal:
(1) "Dana", the Sector-9 security officer: skeptical, Zero Trust-minded, interrupts with "why?" and "what if?";
(2) the hiring manager, silently scoring me.
Material: the architecture and decisions doc, the validator doc, the DB sizing doc (attached).
Rules: ask ONE question at a time; wait for my answer; push back once if my answer is vague or overclaims experience;
then score it 1-5 on correctness, clarity, honesty about limits, and give the model answer in max 3 sentences.
Cover: network/access, K3s, CNPG HA and RPO/RTO, sizing, Terraform at scale, the validator's security, AI-generated code.
After 12 questions: summary of my weakest 3 areas and one drill for each.
```

## Prompt 3: live-change drill

```
I'm rehearsing an infrastructure exercise (repo attached: Terraform for GCP bastion + private K3s VM + CNPG Postgres).
Give me ONE realistic mid-exercise change request at a time, like a client would ("we also need access from our SOC range",
"we can't allow public IPs", "make it 2 instances, we're short on quota", "prove replicas are read-only").
Wait for my plan (files + commands + risks). Then critique it: what I missed, blast radius, what the plan output would show.
Time-box each to 3 minutes; tell me if my approach would take longer on the day.
```

## Prompt 4: rehearsal debugging coach

```
I'm in my rehearsal and something broke. Do NOT give me the fix first.
Here is the exact error + the command I ran: <paste>.
1) Ask me for my hypothesis. 2) Tell me which single command would confirm or refute it.
3) Only after I run it and paste the output, explain the root cause and the fix,
and add the case to my troubleshooting notes as: symptom → cause → command → fix.
```

## Prompt 5: debrief right after the onsite (back in the Job Seek project)

```
Debrief of the Airis Labs onsite exercise, written within 2 hours of it.
What happened, step by step: <timeline>. Where I got stuck: <...>. Questions they asked and my answers: <...>.
Their reactions / comments: <...>. What I finished / didn't: <...>.
Classify each problem as Knowledge / Recall-Stress / Experience / Role mismatch (per project instructions),
update the recurring-gaps view, produce a ledger delta block, and draft a short thank-you note to the hiring manager.
```

## Should this be a separate Claude project?

**Recommended: yes, a small dedicated drill project.** Keep the debrief and pipeline tracking in *Job Seek*.

**Why:**
- *Job Seek*'s instructions steer every answer toward job evaluation and the ledger.
- Drills need a different persona (coach + skeptical client) and a clean knowledge base (just the deploy docs + this kit), so retrieval doesn't pull in webinar notes.

**Setup:**
- **Name:** `Site Alpha - onsite drills`.
- **Knowledge:** upload `site-alpha-deploy/README.md`, `site-alpha-deploy/docs/*.md`, `validator/validate.py`, `k8s/10-airis-core-cluster.yaml`, `terraform/firewall.tf`, and this prep kit.
- **Project instructions (paste):**

```
You are my drill coach for an onsite infrastructure exercise (GCP + Terraform bastion/private VM, K3s,
CloudNativePG, Python validator), plus, when I say "client mode", the client's skeptical security officer.
My background: OpenShift/Kubernetes operations, Linux/RHEL, networking/firewalls, Helm, Jenkins, monitoring,
customer-facing integration. Terraform is lab-level; GCP, K3s, CNPG and Postgres sizing are new to me.
Rules: make me answer before you explain; one question at a time; correct overclaiming of experience
(used vs operated vs owned); keep model answers to 2-3 sentences in claim → reason → limit form;
track my weak areas across chats and revisit them; use only the uploaded repo docs as the source of truth
for how the system is built. Answer in the language I use.
```
