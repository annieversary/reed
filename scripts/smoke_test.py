#!/usr/bin/env python3
"""Launch the real Mac app twice; the second run has no article server available."""
import argparse
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path, default=ROOT / "build/Build/Products/Debug/Reed.app")
args = parser.parse_args()
fixture = (ROOT / "Tests/ReedCoreTests/Fixtures/article.html").read_bytes()
image = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
requests = []

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append(self.path)
        if self.path == "/article":
            self.send_response(302)
            self.send_header("Location", "/story")
            self.end_headers()
            return
        payload, status, mime = {
            "/story": (fixture, 200, "text/html; charset=utf-8"),
            "/image.png": (image, 200, "image/png"),
            "/document.pdf": (b"%PDF", 200, "application/pdf"),
            "/unavailable": (b"Unavailable", 503, "text/plain"),
        }.get(self.path, (b"Not found", 404, "text/plain"))
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass

if not args.app.exists():
    raise SystemExit(f"Build the Mac app first: {args.app}")
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
scratch = Path(tempfile.mkdtemp(prefix="reed-smoke-"))
print(f"Test artifacts: {scratch}", flush=True)

def run(phase, extra):
    report = scratch / f"{phase}.json"
    command = ["open", "-n", "-W", str(args.app.resolve()), "--args", "-ApplePersistenceIgnoreState", "YES", "--smoke-test", "--library-root", str(scratch / "library"), "--smoke-report", str(report)] + extra
    log_file = (scratch / f"{phase}.log").open("w")
    process = subprocess.Popen(command, stdout=log_file, stderr=log_file)
    deadline = time.monotonic() + 120
    while not report.exists() and process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.2)
    if not report.exists():
        process.terminate()
        process.wait(timeout=10)
        log_file.close()
        raise RuntimeError(f"{phase}: app did not write a report within 120 seconds")
    process.wait(timeout=10)
    log_file.close()
    result = json.loads(report.read_text())
    print(f"{phase}: {json.dumps(result, indent=2)}", flush=True)
    if not result["passed"]:
        raise RuntimeError(f"{phase}: {result['error']}")

try:
    run("online", ["--smoke-url", f"http://127.0.0.1:{server.server_port}", "--smoke-snapshot", str(scratch / "reader.png")])
finally:
    server.shutdown()
    server.server_close()
assert "/tracking" not in requests, "Publisher resources were fetched during extraction"
run("offline", [])
print("PASS: saved article and images remain readable after restarting the app with the source server stopped.")
