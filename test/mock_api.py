#!/usr/bin/env python3
"""Local stand-in for the parts of the ngris API (and the GitHub issue-comments API)
that entrypoint.sh calls. It mirrors the api-server's contracts:

  GET    /api/applications?q=&page=&page_size=   paged, q = case-insensitive substring
  POST   /api/applications                        JSON only; 409 on a duplicate name
  POST   /api/applications/{app}/deploys          multipart: file, version, activate
  GET    /api/applications/{app}/deploys          paged, newest first
  POST   /api/applications/{app}/deploys/{d}/preview   JSON only; 403 at the account cap
  DELETE /api/applications/{app}/deploys/{d}/preview
  GET/POST /repos/{o}/{r}/issues/{n}/comments, PATCH /repos/{o}/{r}/issues/comments/{id}
  GET    /__state                                 the whole state, for assertions

Usage: mock_api.py SEED.json PORTFILE   (listens on 127.0.0.1, port written to PORTFILE)
"""
import json
import os
import re
import sys
import threading
import uuid as uuidlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

API_KEY = "ngk_test"
LOCK = threading.Lock()

STATE = {
    "preview_cap": 5,
    "max_page_size": 200,
    "default_page_size": 15,
    "race_create": False,   # another run creates the app just before this run's create
    "apps": [],             # {uuid, name, preview_visibility, require_manual_promotion, current_deploy_uuid}
    "deploys": [],          # {uuid, app_uuid, version, version_label, status, preview_enabled, auto_activate}
    "uploads": [],          # {app_uuid, fields}
    "calls": [],            # "METHOD /path?query"
    "comments": [],         # {id, issue, body}
}


def new_uuid():
    return str(uuidlib.uuid4())


def page_of(items, query):
    try:
        page = int(query.get("page", ["1"])[0])
    except ValueError:
        page = 1
    if page < 1:
        page = 1
    try:
        size = int(query.get("page_size", ["0"])[0])
    except ValueError:
        size = 0
    if size <= 0:
        size = STATE["default_page_size"]
    size = min(size, STATE["max_page_size"])
    start = (page - 1) * size
    return items[start:start + size], len(items), page, size


def parse_multipart(body, content_type):
    m = re.search(r'boundary="?([^";]+)"?', content_type or "")
    if not m:
        return None
    boundary = ("--" + m.group(1)).encode()
    fields = {}
    for part in body.split(boundary):
        if b"\r\n\r\n" not in part:
            continue
        head, _, value = part.partition(b"\r\n\r\n")
        nm = re.search(rb'name="([^"]+)"', head)
        if not nm:
            continue
        name = nm.group(1).decode()
        if value.endswith(b"\r\n"):
            value = value[:-2]
        if b"filename=" in head:
            fields[name] = {"filename": re.search(rb'filename="([^"]*)"', head).group(1).decode(), "size": len(value)}
        else:
            fields[name] = value.decode()
    return fields


def falsey(v):
    return str(v).strip().lower() in ("0", "false", "no", "off")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def handle_any(self, method):
        url = urlparse(self.path)
        path, query = url.path, parse_qs(url.query)
        raw = self.body()
        with LOCK:
            STATE["calls"].append(method + " " + self.path)
            if path == "/__state":
                return self.reply(200, STATE)
            if path.startswith("/repos/"):
                return self.github(method, path, raw)
            if self.headers.get("X-API-Key") != API_KEY:
                return self.reply(401, {"error": "unauthorized"})
            if method in ("POST", "PUT", "PATCH"):
                ct = (self.headers.get("Content-Type") or "").lower()
                if not ct.startswith("multipart/form-data") and not ct.startswith("application/json"):
                    return self.reply(415, {"error": "Content-Type must be application/json"})
            return self.ngris(method, path, query, raw)

    def ngris(self, method, path, query, raw):
        if path == "/api/applications" and method == "GET":
            q = (query.get("q", [""])[0]).strip().lower()
            apps = [a for a in reversed(STATE["apps"]) if q in a["name"].lower()]
            items, total, page, size = page_of(apps, query)
            return self.reply(200, {"applications": items, "total": total, "page": page, "page_size": size})
        if path == "/api/applications" and method == "POST":
            name = json.loads(raw or b"{}").get("name", "").strip()
            if STATE["race_create"]:
                STATE["race_create"] = False
                STATE["apps"].append(self.app(name))
            if any(a["name"].lower() == name.lower() for a in STATE["apps"]):
                return self.reply(409, {"error": "an application with that name already exists"})
            app = self.app(name)
            STATE["apps"].append(app)
            return self.reply(201, app)

        m = re.fullmatch(r"/api/applications/([^/]+)/deploys(?:/([^/]+)/preview)?", path)
        if not m:
            return self.reply(404, {"error": "not found"})
        app = next((a for a in STATE["apps"] if a["uuid"] == m.group(1)), None)
        if app is None:
            return self.reply(404, {"error": "application not found"})
        deploys = [d for d in STATE["deploys"] if d["app_uuid"] == app["uuid"]]

        if m.group(2) is None and method == "GET":
            newest = sorted(deploys, key=lambda d: d["version"], reverse=True)
            items, total, page, size = page_of(newest, query)
            return self.reply(200, {"deploys": items, "total": total, "page": page, "page_size": size})
        if m.group(2) is None and method == "POST":
            fields = parse_multipart(raw, self.headers.get("Content-Type"))
            if not fields or "file" not in fields:
                return self.reply(400, {"error": "missing 'file' (a .zip of your site)"})
            STATE["uploads"].append({"app_uuid": app["uuid"], "fields": fields})
            if "activate" in fields and fields["activate"].strip() != "":
                activate = not falsey(fields["activate"])
            else:
                activate = not app.get("require_manual_promotion", False)
            d = {
                "uuid": new_uuid(), "app_uuid": app["uuid"],
                "version": max([x["version"] for x in deploys] or [0]) + 1,
                "version_label": (fields.get("version") or "").strip()[:64] or None,
                "status": "ready", "preview_enabled": False, "auto_activate": activate,
            }
            STATE["deploys"].append(d)
            if activate:
                app["current_deploy_uuid"] = d["uuid"]
            return self.reply(202, dict(d, status="queued"))

        dep = next((d for d in deploys if d["uuid"] == m.group(2)), None)
        if dep is None:
            return self.reply(404, {"error": "deploy not found"})
        if method == "DELETE":
            dep["preview_enabled"] = False
            return self.reply(200, {"deploy_uuid": dep["uuid"], "preview_enabled": False, "preview_url": ""})
        if method == "POST":
            if not dep["preview_enabled"]:
                live = sum(1 for d in STATE["deploys"] if d["preview_enabled"])
                cap = STATE["preview_cap"]
                if live + 1 > cap:
                    noun = "live preview" if cap == 1 else "live previews"
                    return self.reply(403, {"error": "You've reached your plan's limit of %d %s — turn one off or upgrade your plan" % (cap, noun)})
                dep["preview_enabled"] = True
            return self.reply(200, {"deploy_uuid": dep["uuid"], "preview_enabled": True,
                                    "preview_url": "https://%s.ngris.dev" % dep["uuid"]})
        return self.reply(405, {"error": "method not allowed"})

    def app(self, name):
        return {"uuid": new_uuid(), "name": name, "preview_visibility": "private",
                "require_manual_promotion": False, "current_deploy_uuid": None}

    def github(self, method, path, raw):
        m = re.fullmatch(r"/repos/[^/]+/[^/]+/issues/(\d+)/comments", path)
        if m and method == "GET":
            return self.reply(200, [c for c in STATE["comments"] if c["issue"] == int(m.group(1))])
        if m and method == "POST":
            c = {"id": len(STATE["comments"]) + 1, "issue": int(m.group(1)), "body": json.loads(raw)["body"]}
            STATE["comments"].append(c)
            return self.reply(201, c)
        m = re.fullmatch(r"/repos/[^/]+/[^/]+/issues/comments/(\d+)", path)
        if m and method == "PATCH":
            for c in STATE["comments"]:
                if c["id"] == int(m.group(1)):
                    c["body"] = json.loads(raw)["body"]
                    return self.reply(200, c)
        return self.reply(404, {"message": "Not Found"})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_PATCH(self):
        self.handle_any("PATCH")

    def do_DELETE(self):
        self.handle_any("DELETE")


def main():
    seed_path, port_path = sys.argv[1], sys.argv[2]
    with open(seed_path) as f:
        STATE.update(json.load(f))
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(port_path + ".tmp", "w") as f:
        f.write(str(srv.server_address[1]))
    os.replace(port_path + ".tmp", port_path)
    srv.serve_forever()


if __name__ == "__main__":
    main()
