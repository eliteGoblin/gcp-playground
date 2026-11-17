import json
import logging
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any

from google.cloud import pubsub_v1
from prometheus_client import CONTENT_TYPE_LATEST, Counter, generate_latest

PROCESSED = Counter("orders_processed_total", "Orders handled", ["result"])


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry = {"severity": record.levelname, "message": record.getMessage()}
        entry.update(getattr(record, "fields", {}))
        return json.dumps(entry)


log = logging.getLogger("orders-worker")


def handle_message(message: Any) -> None:
    """Log one order and ack it. An unreadable message is logged and acked: there is no dead-letter topic."""
    try:
        order = json.loads(message.data)
        log.info("order received", extra={"fields": {"order": order}})
        PROCESSED.labels("ok").inc()
    except ValueError:
        log.error("invalid message", extra={"fields": {"message_id": message.message_id}})
        PROCESSED.labels("invalid").inc()
    message.ack()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/healthz":
            body, ctype = b'{"status": "ok"}', "application/json"
        elif self.path == "/metrics":
            body, ctype = generate_latest(), CONTENT_TYPE_LATEST
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args: Any) -> None:
        pass


def main() -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    log.addHandler(handler)
    log.setLevel(logging.INFO)

    server = HTTPServer(("", int(os.environ.get("HTTP_PORT", "8080"))), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    subscriber = pubsub_v1.SubscriberClient()
    path = subscriber.subscription_path(os.environ["GCP_PROJECT_ID"], os.environ["PUBSUB_SUBSCRIPTION"])
    flow = pubsub_v1.types.FlowControl(max_messages=10)
    future = subscriber.subscribe(path, callback=handle_message, flow_control=flow)
    log.info("worker started", extra={"fields": {"subscription": path}})
    with subscriber:
        future.result()


if __name__ == "__main__":
    main()
