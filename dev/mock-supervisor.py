#!/usr/bin/env python3
"""Minimal mock of the Home Assistant Supervisor API, for local smoke
testing of bashio::config-based scripts outside a real HA Supervisor.

Serves exactly the one endpoint bashio::app.config() needs:
  GET /addons/self/options/config -> {"result":"ok","data": <options>}

Reads the add-on options from the path given as argv[1] (the same
options.json the container itself gets bind-mounted), on every request
(no caching), and binds to 0.0.0.0 so Colima's host.docker.internal can
reach it from inside the container.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

OPTIONS_PATH = sys.argv[1]
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8126


class Handler(BaseHTTPRequestHandler):
    def _options(self):
        with open(OPTIONS_PATH, "r", encoding="utf-8") as f:
            return json.load(f)

    def do_GET(self):  # noqa: N802
        if self.path == "/addons/self/options/config":
            body = json.dumps({"result": "ok", "data": self._options()}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"result":"error","message":"not found"}')

    def log_message(self, fmt, *args):  # silence default stderr logging
        pass


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    server.serve_forever()
