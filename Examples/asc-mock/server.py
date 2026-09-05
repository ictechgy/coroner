#!/usr/bin/env python3
"""Minimal App Store Connect mock for verifying `coroner asc-dsym` end-to-end.

Serves the same chain the real API uses: GET /v1/builds (with buildBundles
included) and the dSYMUrl target zip. See verify.sh.
"""
import http.server, json, sys, pathlib

PORT = int(sys.argv[1])
ZIP = pathlib.Path(sys.argv[2]).read_bytes()

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/v1/builds"):
            body = json.dumps({
                "data": [{"id": "b1", "type": "builds"}],
                "included": [
                    {"id": "bb1", "type": "buildBundles",
                     "attributes": {"includesSymbols": True,
                                    "dSYMUrl": f"http://127.0.0.1:{PORT}/dsym.zip"}},
                ],
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/dsym.zip":
            self.send_response(200)
            self.send_header("Content-Length", str(len(ZIP)))
            self.end_headers()
            self.wfile.write(ZIP)
        else:
            self.send_error(404)
    def log_message(self, *a):
        pass

http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
