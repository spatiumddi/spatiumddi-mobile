#!/usr/bin/env python3
"""Terminate TLS in front of a control plane that only speaks HTTP.

The app is HTTPS-only by design: a bearer token in cleartext is a credential
handed to anyone on the path. Lab installs behind Docker often still speak plain
HTTP, so this puts the dev certificate in front of one and forwards everything
through — the app sees a self-signed HTTPS server, exercises the real trust flow,
and talks to the real API behind it.

Development only. The right answer for a real deployment is TLS on the server
(Tailscale, a reverse proxy, or a certificate from the site's own CA).

    ./scripts/dev-tls-proxy.py <port> <cert.pem> <key.pem> <upstream-url>
"""
from __future__ import annotations

import http.server
import ssl
import sys
import urllib.error
import urllib.request

# Headers that describe one hop and must not be forwarded to the next.
HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "host", "content-length",
    # urllib transparently decodes the body, so the upstream's encoding header
    # would describe bytes we are no longer sending.
    "content-encoding",
}


def make_handler(upstream: str) -> type[http.server.BaseHTTPRequestHandler]:
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _forward(self) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else None
            headers = {
                key: value
                for key, value in self.headers.items()
                if key.lower() not in HOP_BY_HOP
            }

            request = urllib.request.Request(
                upstream + self.path, data=body, headers=headers, method=self.command
            )
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    payload, status, out_headers = response.read(), response.status, response.headers
            except urllib.error.HTTPError as error:
                payload, status, out_headers = error.read(), error.code, error.headers
            except Exception as error:  # upstream unreachable
                self._respond(502, {"Content-Type": "text/plain"}, str(error).encode())
                return

            self._respond(
                status,
                {k: v for k, v in out_headers.items() if k.lower() not in HOP_BY_HOP},
                payload,
            )

        def _respond(self, status: int, headers: dict[str, str], payload: bytes) -> None:
            self.send_response(status)
            for key, value in headers.items():
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = _forward

        def log_message(self, fmt: str, *args: object) -> None:
            sys.stderr.write("PROXY " + (fmt % args) + "\n")
            sys.stderr.flush()

    return Handler


def main(argv: list[str]) -> int:
    if len(argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2

    port, cert, key, upstream = int(argv[1]), argv[2], argv[3], argv[4].rstrip("/")

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)

    server = http.server.ThreadingHTTPServer(("0.0.0.0", port), make_handler(upstream))
    server.socket = context.wrap_socket(server.socket, server_side=True)

    sys.stderr.write(f"proxying https://localhost:{port} -> {upstream}\n")
    sys.stderr.flush()
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
