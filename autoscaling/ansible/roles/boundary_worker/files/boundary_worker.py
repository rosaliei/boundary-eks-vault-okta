# Datadog custom check: reports how many sessions this Boundary worker is
# proxying, which is what the autoscaling monitors watch.
#
# Reads /metrics, NOT /health. `active_session_count` on the health endpoint is
# always 0 on Boundary v1.0.1+ent even with live traffic, so scaling on it means
# scaling on a constant. See item 14 in notes/Issues.md.
#
# The gauge only moves for sessions where the client reaches this worker
# DIRECTLY. Over the multi-hop reverse connection nothing is counted, so the
# worker needs a public address and the target needs an ingress filter.
#
#   /etc/datadog-agent/checks.d/boundary_worker.py
#   /etc/datadog-agent/conf.d/boundary_worker.d/conf.yaml

import requests
from datadog_checks.base import AgentCheck

SESSIONS = "boundary_worker_proxy_websocket_active_connections"
BYTES_IN = "boundary_worker_proxy_websocket_received_bytes_total"
BYTES_OUT = "boundary_worker_proxy_websocket_sent_bytes_total"


class BoundaryWorkerCheck(AgentCheck):
    SERVICE_CHECK = "boundary.worker.health"

    def check(self, instance):
        base = instance.get("ops_url", "http://127.0.0.1:9203")
        tags = list(instance.get("tags", []))

        try:
            health = self._get_json(base + "/health?worker_info=1")
            metrics = self._get_metrics(base + "/metrics")
        except Exception as exc:  # noqa: BLE001 - any failure means CRITICAL
            self.service_check(self.SERVICE_CHECK, AgentCheck.CRITICAL, tags=tags, message=str(exc))
            return

        info = health.get("worker_process_info", {})
        state = info.get("state", "unknown")
        upstream = info.get("upstream_connection_state", "unknown")
        tags = tags + ["state:" + state, "upstream:" + upstream]

        # Always emit, as 0 when idle. The scale-in monitor uses
        # notify_no_data=false, so a MISSING metric reads as silence rather than
        # "idle" and the pool would never scale back down.
        self.gauge("boundary.worker.active_sessions", metrics.get(SESSIONS, 0), tags=tags)

        if BYTES_IN in metrics:
            self.monotonic_count("boundary.worker.received_bytes", metrics[BYTES_IN], tags=tags)
        if BYTES_OUT in metrics:
            self.monotonic_count("boundary.worker.sent_bytes", metrics[BYTES_OUT], tags=tags)

        status = AgentCheck.OK if state == "active" else AgentCheck.WARNING
        self.service_check(self.SERVICE_CHECK, status, tags=tags,
                           message="state=%s upstream=%s" % (state, upstream))

    def _get_json(self, url):
        resp = requests.get(url, timeout=3)
        resp.raise_for_status()
        return resp.json()

    def _get_metrics(self, url):
        """Prometheus text is `name value` per line. Every metric we want is
        unlabelled, so matching the first field is enough."""
        resp = requests.get(url, timeout=3)
        resp.raise_for_status()
        wanted = {SESSIONS, BYTES_IN, BYTES_OUT}
        found = {}
        for line in resp.text.splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[0] in wanted:
                found[parts[0]] = float(parts[1])
        return found
