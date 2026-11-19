#!/usr/bin/env python3
"""Loopback-only profile server; live generations are published by the manager."""

import argparse
import hashlib
import json
import re
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{32,128}$")


class Handler(BaseHTTPRequestHandler):
    root: Path
    # Bound request line/header processing and idle keep-alive sockets.
    timeout = 10

    def log_message(self, fmt: str, *args: object) -> None:
        # Never log request paths because they contain bearer tokens.
        print(f"subscription request from {self.client_address[0]}: {args[1]}")

    def do_HEAD(self) -> None:
        self._serve(False)

    def do_GET(self) -> None:
        self._serve(True)

    def _serve(self, include_body: bool) -> None:
        if len(self.path) > 512:
            self.send_error(414)
            return
        request_url = urlsplit(self.path)
        prefix = "/sub/"
        if not request_url.path.startswith(prefix):
            self.send_error(404)
            return
        token = request_url.path[len(prefix) :]
        if not TOKEN_RE.fullmatch(token):
            self.send_error(404)
            return
        formats = parse_qs(request_url.query, keep_blank_values=True).get("format", [None])
        if len(formats) != 1 or formats[0] not in {None, "sing-box", "substore", "xray", "mihomo", "compatibility"}:
            self.send_error(400, "Unsupported subscription format")
            return
        digest = hashlib.sha256(token.encode()).hexdigest()
        meta_path = self.root / f"{digest}.meta.json"
        status = 200
        excluded = 0
        userinfo = None
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            live = meta.get("live") is True
            expires = meta["expires_at_epoch"]
            mode = meta["mode"]
            if mode not in {"mixed", "tun", "xray", "mihomo"}:
                raise ValueError("invalid subscription mode")
            if expires is None and not live:
                raise ValueError("only live subscriptions may have no expiry")
            if expires is not None and int(expires) <= int(time.time()):
                self.send_error(410, "Subscription expired")
                return
            output_format = formats[0] or (mode if mode in {"xray", "mihomo"} else "sing-box")
            content_type = "text/plain; charset=utf-8" if output_format == "substore" else "application/json; charset=utf-8"
            user_scoped = isinstance(meta.get("user_id"), str)
            if user_scoped:
                bundle_path = self.root / f"{digest}.user.json"
            else:
                bundle_path = self.root / ("live.json" if live else f"{digest}.bundle.json")
            if bundle_path.is_file():
                bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
                info = bundle.get("userinfo")
                if isinstance(info, dict):
                    userinfo = "; ".join(f"{key}={max(0, int(info.get(key) or 0))}"
                                         for key in ("upload", "download", "total", "expire"))
                report = bundle.get("compatibility", [])
                if not isinstance(report, list):
                    raise ValueError("invalid compatibility report")
                report_format = {"sing-box": "singbox", "substore": "uri"}.get(output_format, output_format)
                excluded = sum(item.get("format") == report_format and item.get("supported") is False
                               for item in report if isinstance(item, dict))
                if output_format == "compatibility":
                    data = json.dumps(report, ensure_ascii=False).encode("utf-8")
                elif output_format == "substore":
                    if not bundle.get("substore"):
                        status = 422
                        content_type = "application/json; charset=utf-8"
                        data = json.dumps({"error": "No compatible share links; use native Xray JSON.",
                                           "compatibility": [item for item in report if item.get("format") == "uri"]}, ensure_ascii=False).encode("utf-8")
                    else:
                        data = bundle["substore"].encode("utf-8")
                else:
                    profile_key = (mode if mode in {"mixed", "tun"} else "mixed") if output_format == "sing-box" else output_format
                    profile = bundle["profiles"].get(profile_key)
                    if not isinstance(profile, dict):
                        status = 422
                        data = json.dumps({"error": bundle.get("errors", {}).get(profile_key, "This client format is unavailable."),
                                           "format": output_format,
                                           "compatibility": [item for item in report if item.get("format") == report_format]}, ensure_ascii=False).encode("utf-8")
                    else:
                        data = json.dumps(profile, ensure_ascii=False).encode("utf-8")
            elif user_scoped:
                raise ValueError("missing user generation")
            elif not live:
                # Existing snapshot tokens retain their original files. New
                # formats require a new snapshot instead of returning the
                # wrong client's JSON under a different format name.
                if output_format == "substore":
                    data = (self.root / f"{digest}.substore.txt").read_bytes()
                elif output_format == "sing-box" and mode in {"mixed", "tun"}:
                    data = (self.root / f"{digest}.profile.json").read_bytes()
                else:
                    status = 422
                    data = json.dumps({"error": "This older snapshot does not contain the requested format; create a new subscription."}).encode("utf-8")
            else:
                raise ValueError("missing live generation")
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            self.send_error(404)
            return
        if len(data) > 10 * 1024 * 1024:
            self.send_error(500)
            return
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if excluded:
            self.send_header("X-SB-Excluded-Entries", str(excluded))
        if userinfo:
            # De-facto header read by Clash/mihomo, sing-box clients and Sub-Store.
            self.send_header("Subscription-Userinfo", userinfo)
        self.end_headers()
        if include_body:
            self.wfile.write(data)


class LimitedThreadingHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 32

    def __init__(self, *args: object, max_workers: int = 32, **kwargs: object) -> None:
        super().__init__(*args, **kwargs)
        self._slots = threading.BoundedSemaphore(max_workers)

    def process_request(self, request: socket.socket, client_address: object) -> None:
        if not self._slots.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self._slots.release()
            raise

    def process_request_thread(self, request: socket.socket, client_address: object) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._slots.release()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", required=True, type=int)
    args = parser.parse_args()
    if args.listen not in {"127.0.0.1", "::1"}:
        raise SystemExit("subscription server may only bind loopback")
    Handler.root = Path(args.root).resolve(strict=True)
    server = LimitedThreadingHTTPServer((args.listen, args.port), Handler)
    server.timeout = 10
    server.serve_forever()


if __name__ == "__main__":
    main()
