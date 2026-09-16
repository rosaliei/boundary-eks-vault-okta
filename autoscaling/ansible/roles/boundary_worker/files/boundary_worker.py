# Datadog Agent custom check: boundary_worker
# Reads the worker's ops listener and emits the one gauge the autoscaling
# monitors watch, plus a service check for the dashboard.
#
# Installed to /etc/datadog-agent/checks.d/boundary_worker.py
# Config     at /etc/datadog-agent/conf.d/boundary_worker.d/conf.yaml

import requests
from datadog_checks.base import AgentCheck


class BoundaryWorkerCheck(AgentCheck):
    SERVICE_CHECK = "boundary.worker.health"

    def check(self, instance):
        url = instance.get("url", "http://127.0.0.1:9203/health?worker_info=1")
        tags = list(instance.get("tags", []))

        try:
            resp = requests.get(url, timeout=3)
            resp.raise_for_status()
            body = resp.json()
        except Exception as exc:  # noqa: BLE001 - any failure is CRITICAL
            self.service_check(self.SERVICE_CHECK, AgentCheck.CRITICAL, tags=tags, message=str(exc))
            return

        # Boundary nests the fields under worker_process_info; tolerate a flat body too.
        info = body.get("worker_process_info", body)
        state = info.get("state", "unknown")
        sessions = int(info.get("active_session_count", 0))

        self.gauge("boundary.worker.active_sessions", sessions, tags=tags + ["state:" + state])
        status = AgentCheck.OK if state == "active" else AgentCheck.WARNING
        self.service_check(self.SERVICE_CHECK, status, tags=tags, message="state=" + state)
