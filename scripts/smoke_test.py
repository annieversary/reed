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
# An empty shell whose script writes the article, as single-page apps do.
rendered = b"""<!doctype html><html><head><title>Built on arrival</title></head><body><article id="post"></article>
<script>document.getElementById("post").innerHTML = "<h1>Built on arrival</h1>" +
  Array.from({length: 8}, (_, i) => "<p>Paragraph " + i + " was written by the page's own script after it loaded, the way many blogs assemble their posts in the browser instead of sending them whole.</p>").join("");</script>
</body></html>"""


def pdf(lines):
    """A one-page PDF of (font, size, x, y, text) lines, in the standard fonts so nothing is embedded."""
    fonts = sorted({font for font, *_ in lines})
    escape = lambda text: text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
    stream = "".join(f"BT /F{fonts.index(font)} {size} Tf {x} {y} Td ({escape(text)}) Tj ET\n" for font, size, x, y, text in lines).encode()
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               ("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << "
                + " ".join(f"/F{i} {5 + i} 0 R" for i in range(len(fonts))) + " >> >> >>").encode(),
               b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"endstream"]
    objects += [f"<< /Type /Font /Subtype /Type1 /BaseFont /{font} >>".encode() for font in fonts]
    out, offsets = bytearray(b"%PDF-1.4\n"), []
    for number, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1) + b"".join(b"%010d 00000 n \n" % o for o in offsets)
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
    return bytes(out)

sentence = "A paper set for print reads here as an article, in paragraphs that follow the reader's type."
paper = pdf([("Times-Bold", 22, 72, 700, "Reading Papers Offline"), ("Times-Bold", 12, 72, 660, "1 Introduction")]
            + [("Times-Roman", 10, 72, 640 - 12 * i, sentence) for i in range(8)]
            + [("Times-Roman", 10, 72, 530 - 12 * i, sentence) for i in range(6)])
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
            "/rendered": (rendered, 200, "text/html; charset=utf-8"),
            "/image.png": (image, 200, "image/png"),
            "/document.pdf": (b"%PDF", 200, "application/pdf"),
            "/paper.pdf": (paper, 200, "application/pdf"),
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
    command = ["open", "-n", "-W", str(args.app.resolve()), "--args", "-ApplePersistenceIgnoreState", "YES", "--smoke-test", "--library-root", str(scratch / "library"), "--smoke-report", str(report),
               "--smoke-book", str(ROOT / "Tests/ReedCoreTests/Fixtures/book-epub3.epub")] + extra
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
