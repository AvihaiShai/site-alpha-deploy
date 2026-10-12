# The validator: logic flow, failure points and security implications

`validator/validate.py` is the Day-1 handover artifact for the client's security team.
This page documents its **logic flow**, its **failure points** and its **security implications**.

## Why it's built this way

- **It runs on the bastion,** because that's the only approved vantage point. It proves what an operator there can and cannot reach.
- **Its only dependency is `psycopg`.** Kubernetes calls go through the `kubectl` CLI, so it uses the same authentication the operator uses and no heavy Python client is needed.
- **It tests negatives as well as positives.** A security team cares as much about what's *blocked* as about what works.
- **Exit codes:** `0` = ready for handover, `1` = a critical check failed, `2` = setup problem. Usable in a pipeline.
- **The JSON report** has facts (versions, TLS version, primary, observed replication time) and results. It contains **no secrets**.

## Logic flow

```
main()
 ├─ check psycopg + kubectl exist ............................. else exit 2
 └─ Validator.run()
     1. Approved management path
        k8s.api        kubectl get --raw /readyz == "ok"            (if FAIL → stop: nothing else is meaningful)
        k8s.operator   CNPG Deployment available (info; SKIP if the identity can't see cnpg-system)
     2. Cluster health (control plane view)
        cnpg.cluster   phase contains "healthy", readyInstances == instances, currentPrimary == targetPrimary
        cnpg.pods      every instance pod Ready; counts restarts (WARN if > 0); finds the primary pod
     3. Exposure
        exposure.services   no LoadBalancer / NodePort / externalIPs
        exposure.ingress    no Ingress objects
        exposure.host       no hostNetwork / hostPort pods
        net.node_api        TCP node:6443 open (info - it's the approved path)
        net.node_pg_closed  TCP node:5432 must FAIL  (refused/timeout = PASS)
        net.pod_net         TCP primaryPodIP:5432 must FAIL (pod network not routable from the VPC)
     4. Database (data plane)
        db.credentials  Secret airis-core-app → user/password/db (password kept in memory only)
        db.ca           ConfigMap airis-core-ca-public → CA cert to a 0600 temp file
                        (fallback: Secret airis-core-ca → WARN, because that Secret also holds the CA private key)
        db.rw           port-forward svc/airis-core-rw → connect TLS verify-full
                        (host = airis-core-rw.airis.svc for the cert check, hostaddr = 127.0.0.1 for the socket)
                        → server version, pg_is_in_recovery() == false, pg_stat_ssl.ssl == true, TLS version
        db.no_plaintext same path, sslmode=disable, valid password → must be REJECTED by the server
        db.replication  count(pg_stat_replication) >= instances - 1
        db.roundtrip    INSERT a UUID on the primary → port-forward svc/airis-core-ro →
                        replica must be in recovery (read-only) → poll until the UUID appears (measures lag)
                        → DELETE the row (finally-block, always)
     finally: stop port-forwards, delete the temp CA file
 └─ finish(): summary, verdict, JSON report, exit code
```

## TLS verification through a port-forward: `host` + `hostaddr`

- **The problem:** through a port-forward we connect to `127.0.0.1`, but the server certificate is issued for `airis-core-rw.airis.svc`. A naive `verify-full` connection to `127.0.0.1` fails the hostname check, and people "fix" that by dropping to `require`, which skips verification entirely.
- **libpq's answer:** give **both**.
  - `hostaddr=127.0.0.1` is where the TCP connection goes.
  - `host=airis-core-rw.airis.svc` is the name checked against the certificate.
- **Result:** full verification (CA *and* hostname) even through a tunnel. If the cert lacks that name, the validator falls back to `verify-ca` and reports **WARN** rather than silently weakening.

## Failure points (and what you'd see)

| Failure point | Symptom in output | Cause / fix |
|---|---|---|
| kubeconfig wrong/expired | `k8s.api FAIL … Unauthorized` | Token expired (8h): re-run `40-validator-kubeconfig.sh` |
| Bastion can't reach 6443 | `k8s.api FAIL … i/o timeout` | Firewall rule 2, or wrong server IP in kubeconfig |
| Identity lacks a permission | `… no permission for this identity` | Expected for operator check (SKIP); for others fix `30-validator-rbac.yaml` |
| port-forward fails | `port-forward … exited: error upgrading connection` | Missing `pods/portforward` RBAC, or pod not Running |
| Local port taken | port-forward error | Random free port chosen each time (`free_local_port()`); retry |
| CA ConfigMap missing | `db.ca WARN` (fell back to the Secret) | Re-run step 5 of `30-deploy-db.sh` |
| Cert lacks the service name | `db.rw WARN cert check=verify-ca` | Investigate; still encrypted and CA-verified |
| Wrong password / user | `db.rw FAIL … password authentication failed` | Secret out of sync (rare) |
| A replica down / lagging | `db.replication FAIL 1/2` or `db.roundtrip FAIL not visible within 15s` | `kubectl cnpg status`, replica pod logs |
| The `-ro` service hits a primary | `db.roundtrip FAIL -ro reached a writable instance` | Service selector problem |
| psycopg missing | exit 2 with install hint | `bastion-setup.sh` |
| Run on the wrong host (node instead of bastion) | `net.pod_net FAIL … are you running this ON the node?` | Run it on the bastion |
| Write test not allowed (prod freeze) | n/a | `--read-only` skips the round trip |

## Security implications

1. **Credentials.**
   - The password is read from the Secret into memory and passed to libpq **in-process**: never on a command line (visible in `ps`), never in an environment variable, never printed, never in the report.
   - The test suite asserts the report contains no secret.
2. **Least privilege.**
   - It runs as ServiceAccount `airis-validator` with a **namespace-scoped Role**: get/list on clusters, pods, services; `get` on exactly **one** Secret (`resourceNames`); the public CA ConfigMap; `pods/portforward`.
   - It cannot list secrets, exec into pods, or modify anything.
   - The token is **short-lived (8h)** and created with `kubectl create token`, so there are no long-lived SA secrets.
3. **CA private key never touched.**
   - The validator reads the CA *certificate* from a ConfigMap we publish.
   - If it has to fall back to the CA Secret (which contains `ca.key`), it says so as WARN.
4. **Temp files.** The CA cert goes to a `mkstemp` file (mode 0600) and is deleted in `finally`.
5. **Port-forward bound to 127.0.0.1.** Other users or hosts can't piggyback on the tunnel, and the tunnel closes when the script exits.
6. **The write test is a real write.**
   - It touches only `public.airis_validator_probe`, uses a random UUID, and deletes it in a `finally` block.
   - `--read-only` disables it for environments where any write is forbidden.
7. **The admin kubeconfig is the biggest residual risk on the bastion,** not this script. Mitigation: short-lived credentials, or none at rest (phase 2).
8. **Supply chain.** One dependency, version-pinned (`psycopg[binary]==3.3.6`), installed in an isolated venv.

## How it was tested

`validator/tests/local_e2e.sh` builds a real PostgreSQL primary and **two streaming replicas** with:
- TLS 1.3;
- SCRAM;
- the same TLS-only `pg_hba` rules;
- certificates whose SANs are the CNPG service names.

`fake_kubectl.py` answers the validator's kubectl calls with CNPG-shaped JSON and implements `port-forward` as a TCP relay.

Eight scenarios, all behaving as expected:

| Scenario | Expected |
|---|---|
| healthy | exit 0, 16/16 PASS |
| NodePort service exists | exit 1 |
| CA ConfigMap missing → Secret fallback | exit 0, WARN |
| least-privilege identity can't see the operator | exit 0, SKIP |
| degraded cluster (2/3 ready, restarts) | exit 1 |
| hostname not in cert → verify-ca | exit 0, WARN |
| server accepts plaintext (CNPG default rule only) | exit 1 |
| a replica stopped | exit 1 |

Limit: in this test the Kubernetes side is simulated. Against a live cluster, the validator run itself is the test.
