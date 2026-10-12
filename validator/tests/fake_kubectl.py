#!/usr/bin/env python3
"""
A stand-in for kubectl, used ONLY by tests/local_e2e.sh.

It answers the exact calls validate.py makes, with JSON shaped like a real CNPG
1.30 cluster, and implements `port-forward svc/<name>-rw|-ro` as a plain TCP
relay to a local PostgreSQL primary / replica. This lets the validator's logic
(TLS, plaintext rejection, replication, round trip, exposure checks) run
end-to-end on a laptop without Kubernetes.

Environment:
  FAKE_PRIMARY_PORT, FAKE_REPLICA_PORT  local Postgres ports
  FAKE_CA_FILE                          CA certificate (PEM)
  FAKE_APP_PASSWORD                     password of role 'airis'
  FAKE_NODE_IP                          IP reported as the node (hostIP)
  FAKE_SCENARIO                         happy | nodeport | no-cm | forbidden-operator | degraded
"""
import base64
import json
import os
import signal
import socket
import sys
import threading

SCENARIO = os.environ.get("FAKE_SCENARIO", "happy")
NODE_IP = os.environ.get("FAKE_NODE_IP", "127.0.0.3")
NAME = "airis-core"


def b64(s: str) -> str:
    return base64.b64encode(s.encode()).decode()


def err(kind: str, msg: str) -> None:
    sys.stderr.write(f"Error from server ({kind}): {msg}\n")
    sys.exit(1)


def pod(i: int, role: str) -> dict:
    return {
        "metadata": {"name": f"{NAME}-{i}", "labels": {
            "cnpg.io/cluster": NAME, "cnpg.io/instanceRole": role, "role": role,
            "cnpg.io/podRole": "instance"}},
        "spec": {"containers": [{"name": "postgres", "ports": [
            {"containerPort": 5432, "name": "postgresql"}, {"containerPort": 9187, "name": "metrics"}]}]},
        "status": {"hostIP": NODE_IP, "podIP": f"10.42.0.{10 + i}",
                   "containerStatuses": [{"name": "postgres", "ready": True, "restartCount": 0}]},
    }


def relay(listen_port: int, target_port: int) -> None:
    """Minimal bidirectional TCP relay: 127.0.0.1:listen_port -> 127.0.0.1:target_port."""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", listen_port))
    srv.listen(16)
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))

    def pipe(a: socket.socket, b: socket.socket) -> None:
        try:
            while True:
                data = a.recv(65536)
                if not data:
                    break
                b.sendall(data)
        except OSError:
            pass
        finally:
            for s in (a, b):
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    print(f"Forwarding from 127.0.0.1:{listen_port} -> 5432", flush=True)
    while True:
        client, _ = srv.accept()
        try:
            upstream = socket.create_connection(("127.0.0.1", target_port), timeout=5)
        except OSError:
            client.close()
            continue
        threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
        threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()


def main(argv: list) -> None:
    # strip global flags the validator always passes
    args, i = [], 0
    while i < len(argv):
        a = argv[i]
        if a.startswith("--request-timeout"):
            i += 1
            continue
        if a in ("--kubeconfig", "-n"):
            i += 2
            continue
        args.append(a)
        i += 1

    if args[:2] == ["version", "--client"]:
        print("Client Version: fake")
        return
    if args[:3] == ["get", "--raw", "/readyz"]:
        print("ok")
        return
    if args[:2] == ["config", "view"]:
        print(f"https://{NODE_IP}:6443", end="")
        return
    if args and args[0] == "port-forward":
        target, ports = args[1], args[2]
        local = int(ports.split(":")[0])
        port_env = "FAKE_PRIMARY_PORT" if target.endswith("-rw") else "FAKE_REPLICA_PORT"
        relay(local, int(os.environ[port_env]))
        return

    if not (args and args[0] == "get" and args[-2:] == ["-o", "json"]):
        err("BadRequest", f"fake_kubectl: unexpected call {args}")
    what = args[1]
    obj_name = args[2] if len(args) > 4 and not args[2].startswith("-") else None

    if what == "deploy":
        if SCENARIO == "forbidden-operator":
            err("Forbidden", 'deployments.apps is forbidden: User "system:serviceaccount:airis:airis-validator" '
                             'cannot list resource "deployments" in API group "apps" in the namespace "cnpg-system"')
        print(json.dumps({"items": [{"metadata": {"name": "cnpg-cloudnative-pg"},
                                     "spec": {"template": {"spec": {"containers": [
                                         {"image": "ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1"}]}}},
                                     "status": {"availableReplicas": 1}}]}))
    elif what.startswith("clusters"):
        ready = 2 if SCENARIO == "degraded" else 3
        phase = "Waiting for the instances to become active" if SCENARIO == "degraded" else "Cluster in healthy state"
        print(json.dumps({"spec": {"instances": 3, "imageName": "ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie"},
                          "status": {"phase": phase, "readyInstances": ready, "currentPrimary": f"{NAME}-1",
                                     "targetPrimary": f"{NAME}-1"}}))
    elif what == "pods":
        pods = [pod(1, "primary"), pod(2, "replica"), pod(3, "replica")]
        if SCENARIO == "degraded":
            pods[2]["status"]["containerStatuses"][0].update(ready=False, restartCount=4)
        print(json.dumps({"items": pods}))
    elif what == "services":
        svcs = [{"metadata": {"name": f"{NAME}-{s}"}, "spec": {"type": "ClusterIP"}} for s in ("r", "ro", "rw")]
        if SCENARIO == "nodeport":
            svcs.append({"metadata": {"name": "debug-db"}, "spec": {"type": "NodePort"}})
        print(json.dumps({"items": svcs}))
    elif what.startswith("ingresses"):
        print(json.dumps({"items": []}))
    elif what == "secret" and obj_name == f"{NAME}-app":
        print(json.dumps({"data": {"username": b64("airis"), "dbname": b64("airis"),
                                   "password": b64(os.environ["FAKE_APP_PASSWORD"])}}))
    elif what == "secret" and obj_name == f"{NAME}-ca":
        with open(os.environ["FAKE_CA_FILE"]) as f:
            print(json.dumps({"data": {"ca.crt": b64(f.read()), "ca.key": b64("NOT-A-REAL-KEY")}}))
    elif what == "configmap" and obj_name == f"{NAME}-ca-public":
        if SCENARIO == "no-cm":
            err("NotFound", f'configmaps "{NAME}-ca-public" not found')
        with open(os.environ["FAKE_CA_FILE"]) as f:
            print(json.dumps({"data": {"ca.crt": f.read()}}))
    else:
        err("NotFound", f"{what} {obj_name} not found")


if __name__ == "__main__":
    main(sys.argv[1:])
