#!/usr/bin/env python3
"""
Airis Core - Day-1 validation and handover artifact.

Run it FROM THE BASTION. It proves three things to the client's security team:

  1. APPROVED PATH WORKS
     bastion -> Kubernetes API (private IP, TLS, RBAC, audited)
             -> kubectl port-forward -> Postgres (TLS, certificate verified, SCRAM password)

  2. THE DATABASE IS HEALTHY
     CNPG reports healthy, every instance Ready, primary is writable, replicas are
     streaming, and a row written on the primary appears on a replica.

  3. NOTHING ELSE IS EXPOSED
     no LoadBalancer / NodePort / Ingress / hostNetwork / hostPort, Postgres is not
     reachable on the node's IP, the pod network is not routable from the bastion,
     and a plaintext (non-TLS) login is rejected by the server.

Exit codes: 0 = every critical check passed, 1 = a critical check failed, 2 = setup error.
No secret value is ever printed or written to the JSON report.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import asdict, dataclass
from typing import Any, Callable, Dict, List, Optional, Tuple

try:
    import psycopg
except ImportError:  # handled in main() with a clear message
    psycopg = None  # type: ignore[assignment]

VERSION = "1.0.0"
PASS, FAIL, WARN, SKIP = "PASS", "FAIL", "WARN", "SKIP"


# --------------------------------------------------------------------------- #
# Small building blocks
# --------------------------------------------------------------------------- #
class Forbidden(Exception):
    """kubectl said 'forbidden': the identity lacks permission (expected for least-privilege runs)."""


class NotFound(Exception):
    """kubectl said the object does not exist."""


@dataclass
class Result:
    id: str
    title: str
    status: str
    detail: str
    critical: bool
    seconds: float = 0.0


class Kube:
    """Thin wrapper around kubectl. Using the CLI (not the Python client) keeps the
    dependency list at one package and reuses the exact auth the operator uses."""

    def __init__(self, kubectl: str, kubeconfig: Optional[str], namespace: str, timeout: int):
        self.kubectl = kubectl
        self.kubeconfig = kubeconfig
        self.namespace = namespace
        self.timeout = timeout

    def base(self, namespace: Optional[str] = None) -> List[str]:
        cmd = [self.kubectl, f"--request-timeout={self.timeout}s"]
        if self.kubeconfig:
            cmd += ["--kubeconfig", self.kubeconfig]
        cmd += ["-n", namespace or self.namespace]
        return cmd

    def run(self, args: List[str], namespace: Optional[str] = None) -> str:
        proc = subprocess.run(
            self.base(namespace) + args,
            capture_output=True, text=True, timeout=self.timeout + 10,
        )
        if proc.returncode != 0:
            err = (proc.stderr or proc.stdout).strip()
            low = err.lower()
            if "forbidden" in low:
                raise Forbidden(err.splitlines()[-1] if err else "forbidden")
            if "notfound" in low or "not found" in low:
                raise NotFound(err.splitlines()[-1] if err else "not found")
            raise RuntimeError(err.splitlines()[-1] if err else f"kubectl exit {proc.returncode}")
        return proc.stdout

    def json(self, args: List[str], namespace: Optional[str] = None) -> Dict[str, Any]:
        return json.loads(self.run(args + ["-o", "json"], namespace))


def text(value: Any) -> Any:
    """psycopg returns bytes for text columns when a database uses SQL_ASCII encoding.
    CNPG databases are UTF8, but the report must never crash on an unexpected encoding."""
    return value.decode(errors="replace") if isinstance(value, (bytes, bytearray)) else value


def free_local_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


def tcp_probe(host: str, port: int, timeout: float) -> Tuple[bool, str]:
    """True if a TCP handshake completes. 'timeout' usually means a firewall DROP."""
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True, "open"
    except ConnectionRefusedError:
        return False, "refused"
    except socket.timeout:
        return False, f"timeout after {timeout:.0f}s (dropped)"
    except OSError as exc:
        return False, exc.strerror or str(exc)


class PortForward:
    """`kubectl port-forward svc/<name> <local>:5432` bound to 127.0.0.1 only.
    Traffic is tunnelled inside the authenticated Kubernetes API connection (TLS)."""

    def __init__(self, kube: Kube, target: str, remote_port: int = 5432, wait: float = 20.0):
        self.kube, self.target, self.remote_port, self.wait = kube, target, remote_port, wait
        self.port = 0
        self.proc: Optional[subprocess.Popen] = None
        self._stderr = tempfile.TemporaryFile(mode="w+")

    def __enter__(self) -> "PortForward":
        self.port = free_local_port()
        cmd = self.kube.base() + [
            "port-forward", self.target, f"{self.port}:{self.remote_port}", "--address", "127.0.0.1",
        ]
        # stdout -> DEVNULL: kubectl prints a line per connection and a full pipe would block it.
        self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=self._stderr, text=True)
        deadline = time.time() + self.wait
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(f"port-forward to {self.target} exited: {self._err()}")
            if tcp_probe("127.0.0.1", self.port, 1.0)[0]:
                return self
            time.sleep(0.3)
        self.close()
        raise RuntimeError(f"port-forward to {self.target} not ready after {self.wait:.0f}s: {self._err()}")

    def _err(self) -> str:
        self._stderr.seek(0)
        text = self._stderr.read().strip()
        return text.splitlines()[-1] if text else "no error output"

    def close(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    def __exit__(self, *exc: Any) -> None:
        self.close()
        self._stderr.close()


# --------------------------------------------------------------------------- #
# The validator
# --------------------------------------------------------------------------- #
class Validator:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.kube = Kube(args.kubectl, args.kubeconfig, args.namespace, args.timeout)
        self.cluster = args.cluster
        self.ns = args.namespace
        self.results: List[Result] = []
        self.facts: Dict[str, Any] = {}
        self.cluster_obj: Dict[str, Any] = {}
        self.pods: List[Dict[str, Any]] = []
        self.creds: Dict[str, str] = {}
        self.ca_file: Optional[str] = None
        self.fwd_rw: Optional[PortForward] = None
        self.rw_tls_mode = "verify-full"

    # -- framework ---------------------------------------------------------- #
    def check(self, cid: str, title: str, fn: Callable[[], Tuple[str, str]], critical: bool = True) -> Result:
        t0 = time.time()
        try:
            status, detail = fn()
        except Forbidden as exc:
            status, detail = (FAIL if critical else SKIP), f"no permission for this identity: {exc}"
        except Exception as exc:  # a broken check must never crash the whole run
            status, detail = FAIL, f"{type(exc).__name__}: {exc}"
        res = Result(cid, title, status, detail, critical, round(time.time() - t0, 2))
        self.results.append(res)
        self._print(res)
        return res

    def _print(self, r: Result) -> None:
        colors = {PASS: "32", FAIL: "31", WARN: "33", SKIP: "90"}
        tag = r.status if not sys.stdout.isatty() else f"\033[{colors[r.status]}m{r.status}\033[0m"
        crit = "" if r.critical else " (info)"
        print(f"  [{tag}] {r.title}{crit}\n         {r.detail}")

    def section(self, name: str) -> None:
        print(f"\n== {name}")

    # -- helpers ------------------------------------------------------------ #
    def node_ip(self) -> Optional[str]:
        if self.args.node_ip:
            return self.args.node_ip
        for pod in self.pods:
            ip = pod.get("status", {}).get("hostIP")
            if ip:
                return ip
        return None

    def primary_pod(self) -> Optional[Dict[str, Any]]:
        primary = self.cluster_obj.get("status", {}).get("currentPrimary")
        for pod in self.pods:
            labels = pod["metadata"].get("labels", {})
            if pod["metadata"]["name"] == primary or labels.get("cnpg.io/instanceRole") == "primary" \
                    or labels.get("role") == "primary":
                return pod
        return None

    def connect(self, port: int, service: str, sslmode: str):
        params: Dict[str, Any] = dict(
            host=f"{service}.{self.ns}.svc",  # name checked against the server certificate
            hostaddr="127.0.0.1",             # where the bytes actually go (the port-forward)
            port=port,
            dbname=self.creds["dbname"],
            user=self.creds["username"],
            password=self.creds["password"],  # passed in-process: never on a command line or in env
            sslmode=sslmode,
            connect_timeout=10,
            application_name="airis-validator",
        )
        if sslmode in ("verify-ca", "verify-full"):
            params["sslrootcert"] = self.ca_file
        return psycopg.connect(**params)

    def connect_tls(self, port: int, service: str):
        """verify-full first (CA + hostname). Fall back to verify-ca only if the
        certificate does not list the service name - and report that as WARN."""
        try:
            return self.connect(port, service, "verify-full"), "verify-full"
        except psycopg.OperationalError as exc:
            msg = str(exc).lower()
            if "does not match host name" in msg or "server certificate for" in msg:
                return self.connect(port, service, "verify-ca"), "verify-ca"
            raise

    # -- checks: Kubernetes ------------------------------------------------- #
    def c_api(self) -> Tuple[str, str]:
        out = self.kube.run(["get", "--raw", "/readyz"]).strip()
        server = "unknown"
        try:
            server = self.kube.run(["config", "view", "--minify", "-o",
                                    "jsonpath={.clusters[0].cluster.server}"]).strip()
        except Exception as exc:  # informational only - never fail the check on this
            server = f"unknown ({type(exc).__name__})"
        self.facts["kube_api"] = server
        return (PASS, f"API {server} says '{out}'") if out == "ok" else (FAIL, f"/readyz returned '{out}'")

    def c_operator(self) -> Tuple[str, str]:
        data = self.kube.json(["get", "deploy", "-l", "app.kubernetes.io/name=cloudnative-pg"],
                              namespace="cnpg-system")
        items = data.get("items", [])
        if not items:
            return FAIL, "no CNPG operator Deployment in cnpg-system"
        dep = items[0]
        avail = dep.get("status", {}).get("availableReplicas", 0) or 0
        image = dep["spec"]["template"]["spec"]["containers"][0]["image"]
        self.facts["operator_image"] = image
        return (PASS, f"{dep['metadata']['name']} available={avail} image={image}") if avail >= 1 \
            else (FAIL, f"{dep['metadata']['name']} has no available replica")

    def c_cluster(self) -> Tuple[str, str]:
        self.cluster_obj = self.kube.json(["get", "clusters.postgresql.cnpg.io", self.cluster])
        st = self.cluster_obj.get("status", {})
        want = int(self.cluster_obj.get("spec", {}).get("instances", 0))
        ready = int(st.get("readyInstances", 0) or 0)
        phase = st.get("phase", "")
        cur, tgt = st.get("currentPrimary"), st.get("targetPrimary")
        self.facts.update(instances=want, ready_instances=ready, phase=phase, primary=cur,
                          image=self.cluster_obj.get("spec", {}).get("imageName", "operator default"))
        detail = f"phase='{phase}' ready={ready}/{want} primary={cur}"
        problems = []
        if "healthy" not in phase.lower():
            problems.append("phase is not healthy")
        if ready != want:
            problems.append("not all instances ready")
        if cur != tgt:
            problems.append(f"switchover in progress ({cur} -> {tgt})")
        return (FAIL, detail + " | " + "; ".join(problems)) if problems else (PASS, detail)

    def c_pods(self) -> Tuple[str, str]:
        data = self.kube.json(["get", "pods", "-l", f"cnpg.io/cluster={self.cluster}"])
        # instance pods only (exclude initdb/join job pods)
        self.pods = [p for p in data.get("items", [])
                     if p["metadata"].get("labels", {}).get("cnpg.io/podRole", "instance") == "instance"
                     and "job-name" not in p["metadata"].get("labels", {})]
        not_ready, restarts = [], 0
        for p in self.pods:
            cs = p.get("status", {}).get("containerStatuses", [])
            restarts += sum(int(c.get("restartCount", 0)) for c in cs)
            if not cs or not all(c.get("ready") for c in cs):
                not_ready.append(p["metadata"]["name"])
        want = self.facts.get("instances") or len(self.pods)
        prim = self.primary_pod()
        detail = (f"{len(self.pods) - len(not_ready)}/{want} Ready, primary pod="
                  f"{prim['metadata']['name'] if prim else '?'}, total restarts={restarts}")
        if not_ready or len(self.pods) != want:
            return FAIL, detail + f" | not ready: {', '.join(not_ready) or 'missing pods'}"
        return (WARN if restarts else PASS), detail + (" (restarts > 0: check logs)" if restarts else "")

    def c_services(self) -> Tuple[str, str]:
        items = self.kube.json(["get", "services"]).get("items", [])
        exposed = [f"{s['metadata']['name']}({s['spec'].get('type')})" for s in items
                   if s["spec"].get("type") in ("LoadBalancer", "NodePort") or s["spec"].get("externalIPs")]
        listing = ", ".join(f"{s['metadata']['name']}:{s['spec'].get('type')}" for s in items)
        return (FAIL, f"externally exposed: {', '.join(exposed)}") if exposed \
            else (PASS, f"all ClusterIP (internal only): {listing}")

    def c_ingress(self) -> Tuple[str, str]:
        items = self.kube.json(["get", "ingresses.networking.k8s.io"]).get("items", [])
        return (FAIL, f"{len(items)} Ingress object(s) publish this namespace") if items \
            else (PASS, "no Ingress objects (and no ingress controller: traefik disabled)")

    def c_host_exposure(self) -> Tuple[str, str]:
        items = self.kube.json(["get", "pods"]).get("items", [])
        bad = []
        for p in items:
            spec = p.get("spec", {})
            if spec.get("hostNetwork"):
                bad.append(f"{p['metadata']['name']}: hostNetwork")
            for c in spec.get("containers", []):
                for port in c.get("ports", []) or []:
                    if port.get("hostPort"):
                        bad.append(f"{p['metadata']['name']}: hostPort {port['hostPort']}")
        return (FAIL, "; ".join(bad)) if bad else (PASS, f"{len(items)} pods, none use hostNetwork/hostPort")

    # -- checks: network boundaries (run from the bastion) ------------------- #
    def c_node_api(self) -> Tuple[str, str]:
        ip = self.node_ip()
        if not ip:
            return SKIP, "node IP unknown (pass --node-ip)"
        okay, how = tcp_probe(ip, 6443, self.args.probe_timeout)
        return (PASS, f"{ip}:6443 {how} - the approved management path") if okay \
            else (WARN, f"{ip}:6443 {how} (kubeconfig may point elsewhere)")

    def c_node_pg_closed(self) -> Tuple[str, str]:
        ip = self.node_ip()
        if not ip:
            return SKIP, "node IP unknown (pass --node-ip)"
        okay, how = tcp_probe(ip, 5432, self.args.probe_timeout)
        return (FAIL, f"{ip}:5432 is OPEN from the bastion - Postgres is exposed on the node") if okay \
            else (PASS, f"{ip}:5432 not reachable ({how})")

    def c_pod_net_unroutable(self) -> Tuple[str, str]:
        prim = self.primary_pod()
        ip = prim.get("status", {}).get("podIP") if prim else None
        if not ip:
            return SKIP, "primary pod IP unknown"
        okay, how = tcp_probe(ip, 5432, self.args.probe_timeout)
        return (FAIL, f"pod IP {ip}:5432 reachable from here - are you running this ON the node?") if okay \
            else (PASS, f"pod network {ip}:5432 not routable from the bastion ({how})")

    # -- checks: credentials & TLS material ----------------------------------- #
    def c_credentials(self) -> Tuple[str, str]:
        sec = self.kube.json(["get", "secret", f"{self.cluster}-app"])
        data = sec.get("data", {})
        for key in ("username", "password", "dbname"):
            if key not in data:
                return FAIL, f"secret {self.cluster}-app has no '{key}'"
            self.creds[key] = base64.b64decode(data[key]).decode()
        return PASS, f"user={self.creds['username']} db={self.creds['dbname']} (password loaded, not shown)"

    def c_ca(self) -> Tuple[str, str]:
        pem, source, status = None, "", PASS
        try:
            cm = self.kube.json(["get", "configmap", f"{self.cluster}-ca-public"])
            pem, source = cm.get("data", {}).get("ca.crt"), f"configmap/{self.cluster}-ca-public"
        except (NotFound, Forbidden):
            sec = self.kube.json(["get", "secret", f"{self.cluster}-ca"])
            pem = base64.b64decode(sec["data"]["ca.crt"]).decode()
            source, status = f"secret/{self.cluster}-ca", WARN
        if not pem or "BEGIN CERTIFICATE" not in pem:
            return FAIL, "no CA certificate found"
        fd, path = tempfile.mkstemp(prefix="airis-ca-", suffix=".crt")  # created 0600
        with os.fdopen(fd, "w") as f:
            f.write(pem)
        self.ca_file = path
        note = "" if status == PASS else " - fell back to the CA secret (holds the CA private key; publish the cert instead)"
        return status, f"cluster CA certificate from {source}{note}"

    # -- checks: database ------------------------------------------------------ #
    def c_rw(self) -> Tuple[str, str]:
        if not self.creds or not self.ca_file:
            return FAIL, "skipped: credentials or CA missing"
        self.fwd_rw = PortForward(self.kube, f"svc/{self.cluster}-rw").__enter__()
        conn, mode = self.connect_tls(self.fwd_rw.port, f"{self.cluster}-rw")
        self.rw_tls_mode = mode
        with conn:
            row = conn.execute(
                "SELECT current_setting('server_version'), pg_is_in_recovery(), s.ssl, s.version, s.cipher, "
                "current_user, current_database() FROM pg_stat_ssl s WHERE s.pid = pg_backend_pid()"
            ).fetchone()
        ver, in_recovery, ssl_on, tls_ver, cipher, user, db = (text(v) for v in row)
        self.facts.update(postgres_version=ver, tls_version=tls_ver, tls_cipher=cipher, tls_verification=mode)
        detail = (f"PostgreSQL {ver} as {user}@{db}; TLS={ssl_on} {tls_ver} {cipher}; "
                  f"cert check={mode}; writable={not in_recovery}")
        if in_recovery:
            return FAIL, detail + " | -rw service points at a replica"
        if not ssl_on:
            return FAIL, detail + " | session is not encrypted"
        return (PASS if mode == "verify-full" else WARN), detail

    def c_plaintext_rejected(self) -> Tuple[str, str]:
        if not self.fwd_rw:
            return FAIL, "skipped: no connection path"
        try:
            conn = self.connect(self.fwd_rw.port, f"{self.cluster}-rw", "disable")
            conn.close()
            return FAIL, "a NON-TLS login with valid credentials was ACCEPTED"
        except psycopg.OperationalError as exc:
            msg = str(exc).strip().splitlines()[0] if str(exc).strip() else str(exc)
            if "no encryption" in msg.lower() or "pg_hba.conf rejects" in msg.lower():
                return PASS, f"server refused plaintext: \"{msg}\""
            return WARN, f"plaintext failed, but for another reason: {msg}"

    def c_replication(self) -> Tuple[str, str]:
        want = int(self.facts.get("instances") or 1) - 1
        if want <= 0:
            return SKIP, "single instance: no replicas expected"
        if not self.fwd_rw:
            return FAIL, "skipped: no connection path"
        conn, _ = self.connect_tls(self.fwd_rw.port, f"{self.cluster}-rw")
        with conn:
            total, streaming = conn.execute(
                "SELECT count(*), count(*) FILTER (WHERE state = 'streaming') FROM pg_stat_replication"
            ).fetchone()
        self.facts["replicas_connected"] = total
        detail = f"{total}/{want} replicas connected to the primary"
        if streaming:
            detail += f", {streaming} streaming"
        elif total:
            detail += " (state hidden: app user lacks pg_read_all_stats - expected, least privilege)"
        return (PASS, detail) if total >= want else (FAIL, detail)

    def c_roundtrip(self) -> Tuple[str, str]:
        if self.args.read_only:
            return SKIP, "--read-only: no write performed"
        if not self.fwd_rw:
            return FAIL, "skipped: no connection path"
        token = str(uuid.uuid4())
        rw, _ = self.connect_tls(self.fwd_rw.port, f"{self.cluster}-rw")
        with rw:
            rw.execute("CREATE TABLE IF NOT EXISTS public.airis_validator_probe ("
                       "id text PRIMARY KEY, created_at timestamptz NOT NULL DEFAULT now())")
            rw.execute("INSERT INTO public.airis_validator_probe (id) VALUES (%s)", (token,))
            rw.commit()
        t_written = time.time()
        try:
            with PortForward(self.kube, f"svc/{self.cluster}-ro") as fwd_ro:
                ro, mode = self.connect_tls(fwd_ro.port, f"{self.cluster}-ro")
                with ro:
                    ro.autocommit = True
                    if not ro.execute("SELECT pg_is_in_recovery()").fetchone()[0]:
                        return FAIL, "-ro service reached a writable instance (should be a replica)"
                    deadline = t_written + self.args.replication_wait
                    while time.time() < deadline:
                        if ro.execute("SELECT 1 FROM public.airis_validator_probe WHERE id = %s",
                                      (token,)).fetchone():
                            lag = time.time() - t_written
                            self.facts["observed_replication_visibility_s"] = round(lag, 2)
                            return PASS, (f"row written on primary visible on replica after {lag:.2f}s "
                                          f"(replica is read-only, cert check={mode})")
                        time.sleep(0.25)
                    return FAIL, f"row not visible on a replica within {self.args.replication_wait:.0f}s"
        finally:
            rw2, _ = self.connect_tls(self.fwd_rw.port, f"{self.cluster}-rw")
            with rw2:
                rw2.execute("DELETE FROM public.airis_validator_probe WHERE id = %s", (token,))
                rw2.commit()

    # -- run --------------------------------------------------------------- #
    def run(self) -> int:
        print(f"Airis Core validator {VERSION} | cluster={self.ns}/{self.cluster} | "
              f"host={socket.gethostname()} | {dt.datetime.now(dt.timezone.utc):%Y-%m-%d %H:%M:%SZ}")
        try:
            self.section("1. Approved management path")
            api = self.check("k8s.api", "Kubernetes API reachable from the bastion", self.c_api)
            if api.status == FAIL:
                print("\nCannot reach the Kubernetes API - nothing else can be checked.")
                return self.finish()
            self.check("k8s.operator", "CNPG operator running", self.c_operator, critical=False)

            self.section("2. Cluster health (control plane view)")
            self.check("cnpg.cluster", "CNPG cluster status", self.c_cluster)
            self.check("cnpg.pods", "Postgres instance pods", self.c_pods)

            self.section("3. Exposure (nothing published outside the cluster)")
            self.check("exposure.services", "Services are internal only", self.c_services)
            self.check("exposure.ingress", "No Ingress", self.c_ingress)
            self.check("exposure.host", "No hostNetwork / hostPort", self.c_host_exposure)
            self.check("net.node_api", "Node API port reachable (approved path)", self.c_node_api, critical=False)
            self.check("net.node_pg_closed", "Postgres NOT reachable on the node IP", self.c_node_pg_closed)
            self.check("net.pod_net", "Pod network NOT routable from the bastion", self.c_pod_net_unroutable)

            self.section("4. Database (data plane, through the approved path)")
            self.check("db.credentials", "App credentials from Kubernetes Secret", self.c_credentials)
            self.check("db.ca", "Cluster CA certificate for TLS verification", self.c_ca)
            self.check("db.rw", "Primary: TLS connection, writable", self.c_rw)
            self.check("db.no_plaintext", "Plaintext (non-TLS) login rejected", self.c_plaintext_rejected)
            self.check("db.replication", "Replicas connected to the primary", self.c_replication)
            self.check("db.roundtrip", "Write on primary -> read on replica", self.c_roundtrip)
        finally:
            if self.fwd_rw:
                self.fwd_rw.__exit__(None, None, None)
            if self.ca_file and os.path.exists(self.ca_file):
                os.unlink(self.ca_file)
        return self.finish()

    def finish(self) -> int:
        counts = {s: sum(1 for r in self.results if r.status == s) for s in (PASS, FAIL, WARN, SKIP)}
        critical_fail = [r for r in self.results if r.critical and r.status == FAIL]
        verdict = "NOT READY FOR HANDOVER" if critical_fail else "READY FOR HANDOVER"
        print(f"\n== Summary: {counts[PASS]} pass, {counts[FAIL]} fail, {counts[WARN]} warn, "
              f"{counts[SKIP]} skip  ->  {verdict}")
        for r in critical_fail:
            print(f"   critical: {r.id} - {r.detail}")
        if self.args.report:
            report = {
                "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                "validator_version": VERSION,
                "run_from_host": socket.gethostname(),
                "namespace": self.ns,
                "cluster": self.cluster,
                "verdict": verdict,
                "summary": counts,
                "facts": self.facts,
                "checks": [asdict(r) for r in self.results],
            }
            os.makedirs(os.path.dirname(os.path.abspath(self.args.report)), exist_ok=True)
            with open(self.args.report, "w") as f:
                json.dump(report, f, indent=2, default=str)
            print(f"   report: {self.args.report} (no secrets inside)")
        return 1 if critical_fail else 0


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    ts = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    p = argparse.ArgumentParser(description="Validate the Airis Core data layer from the bastion.")
    p.add_argument("--namespace", default="airis")
    p.add_argument("--cluster", default="airis-core", help="CNPG Cluster name")
    p.add_argument("--kubeconfig", default=os.environ.get("KUBECONFIG"),
                   help="default: $KUBECONFIG or ~/.kube/config")
    p.add_argument("--kubectl", default="kubectl", help="kubectl binary")
    p.add_argument("--node-ip", default=None, help="K3s node IP (default: taken from the pods' hostIP)")
    p.add_argument("--timeout", type=int, default=15, help="kubectl request timeout (s)")
    p.add_argument("--probe-timeout", type=float, default=3.0, help="TCP probe timeout (s)")
    p.add_argument("--replication-wait", type=float, default=15.0, help="max seconds to see the row on a replica")
    p.add_argument("--read-only", action="store_true", help="skip the write/read round trip")
    p.add_argument("--report", default=os.path.expanduser(f"~/airis/reports/validation-{ts}.json"),
                   help="JSON report path ('' to disable)")
    return p.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    if psycopg is None:
        print("psycopg is not installed: ~/airis/.venv/bin/pip install -r validator/requirements.txt", file=sys.stderr)
        return 2
    try:
        subprocess.run([args.kubectl, "version", "--client"], capture_output=True, check=True, timeout=10)
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        print(f"kubectl not usable: {args.kubectl}", file=sys.stderr)
        return 2
    return Validator(args).run()


if __name__ == "__main__":
    sys.exit(main())
