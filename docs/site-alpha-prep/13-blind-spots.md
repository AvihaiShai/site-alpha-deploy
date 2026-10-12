# 13 · Blind spots: things that are easy not to know you don't know

## A. About the exercise itself

1. **Be transparent about the prepared kit.**
   - The brief invites preparation, so the risk isn't preparing. The risk is *looking like you hid it*.
   - Open with: *"As the brief suggested, I prepared a deployment kit in advance; I'll walk you through it and adapt it live."*
   - Then prove it's yours by **changing it live** when asked.
2. **Expect a live change request.** Practise each until it takes < 3 minutes:
   - add a second allowed CIDR;
   - change `instances` to 2;
   - add a firewall rule and explain its priority;
   - change `shared_buffers` and predict the restart behaviour;
   - apply the NetworkPolicy;
   - switch to IAP mode.
3. **Expect deliberate breakage.** The brief lists "failed Terraform applies" and "CrashLoopBackOff" as signals. They may pre-break the project or break something mid-way. That's why the drills exist.
4. **"Zero Trust client" may mean no internet egress at all.**
   - Then NAT is forbidden, and K3s plus all images must be staged (air-gap).
   - **Ask Ziv before the day:** *"Will the project allow outbound internet from a private subnet via NAT?"*
   - If the answer is no, the plan changes significantly. Raise it immediately, don't discover it at minute 20.
5. **Ask clarifying questions as the FDE at the start** (data type/volume, RPO/RTO, egress policy, org policies). Asking before building is part of what's evaluated in a forward-deployed role.
6. **The 5-minute presentation is short.**
   - 5 slides, about 1 minute each.
   - End on assumptions + phase 2, not on a diagram.
   - Rehearse with a timer.
7. **Name your limits before they find them.**
   - "Single node", "local Terraform state" and "admin kubeconfig on the bastion" said by you sound like seniority.
   - Found by them, they sound like gaps.

## B. Repo, laptop and credentials hygiene

8. **Repo visibility.**
   - Keep `site-alpha-deploy` **private**: it's built around their exercise.
   - **Never** put the brief's text or the coaching kit (this folder) in it.
   - After the process you can publish a sanitised copy as a portfolio piece (rename `airis` → generic).
9. **Cloning a private repo on their laptop.** Options, best first:
   - (a) **Fine-grained GitHub token:** read-only, *this repo only*, 7-day expiry. Use it as the HTTPS password, then revoke it. This is itself a security talking point.
   - (b) Download the ZIP while logged into github.com in a private browser window, then log out.
   - (c) A USB stick / email to yourself with a ZIP.
   - (d) Print `firewall.tf`, `nat.tf` and `compute.tf` as a last resort.
10. **Leave nothing behind:** `./scripts/99-cleanup-laptop.sh` removes keys, the generated SSH config and gcloud credentials. Then decide with them where `terraform.tfstate` goes.
11. **Their laptop may be Windows / locked down** → Cloud Shell (Plan B). Its egress IP isn't the office's, so `allowed_ssh_cidrs` or IAP must account for it.
11a. **The site's network may block outbound TCP 22,** which is common on corporate networks. Then SSH to the bastion times out even with the right CIDR. The fix is IAP mode (tunnel over 443). A web proxy can also make `curl ifconfig.me` show a different IP than SSH would use.
11b. **A new project has a `default` VPC with SSH open to the world** (created along with the Compute API). We don't use it. *Report* it to the "client" and recommend deletion; don't delete it yourself. Pointing this out is the kind of thing that impresses a security team.
12. **Keyboard/editor:**
    - A Hebrew/US layout switch mid-command and an unfamiliar editor cost real minutes.
    - Know `nano` basics (Ctrl-O save, Ctrl-X exit) and `vim` (`i`, `Esc`, `:wq`).

## C. Technical traps (the repo handles them; you must be able to explain them)

13. **ADC vs gcloud login:** Terraform uses *Application Default Credentials*. `gcloud auth login` alone is not enough: `gcloud auth application-default login`.
14. **New project = APIs off,** with 1-2 minutes of propagation after enabling. Hence preflight enables Compute first.
15. **No external IP = no internet.** Cloud NAT is the only egress for the private node.
16. **K3s CIDRs** (`10.42.0.0/16` pods, `10.43.0.0/16` services) must not overlap the VPC.
17. **Port-forward traffic arrives from 127.0.0.1 inside the pod.** A `pg_hba` rule restricted to `10.42.0.0/16` would silently break the approved path.
18. **TLS through a tunnel:** `verify-full` needs the cert's hostname. Use libpq `host` + `hostaddr`. Don't downgrade to `require`.
19. **CNPG's default `pg_hba` accepts non-TLS logins** (`host all all all scram-sha-256`). Our `hostnossl … reject` closes that, and the validator proves it.
20. **local-path ignores PVC sizes,** and all 3 replicas share one disk. Never call this node-level HA.
21. **Debian 12 blocks `pip install` system-wide** (PEP 668) → venv.
22. **Startup scripts run on every boot** → they must be idempotent.
23. **The default compute service account often has Editor** → we attach none.
24. **Network tags can be added by anyone with setTags** → SA-based rules in production; org-level hierarchical firewall policies are evaluated before VPC rules.
25. **`-/+` on the K3s VM in a plan means data loss.** Read plans; production uses `prevent_destroy`.
26. **The CNPG in-tree Barman backup is deprecated** (removed in 1.31) → the Barman Cloud plugin.
27. **The admin kubeconfig on the bastion is cluster-admin.** The validator runs with an 8-hour, read-only token instead.
28. **The Terraform state describes the client's infrastructure.** It's sensitive; hand it over properly.

## D. Process (career side, outside the repo)

29. **The salary band.** If you still don't know it, ask in the same message as the logistics questions. It decides how much more prep is worth.
30. **Time cap.** The repo removes most of the build time, so spend the remaining hours on rehearsal and explanation, not on adding features. Stop at 16 hours total.
31. **Debrief right after the exercise,** while you remember it. Use the debrief prompt in [14](14-better-prompts.md).
