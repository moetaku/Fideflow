"""Opt-in public search smoke test; no account, cookie or credentials required."""
import json
import os
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request

with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
environment = dict(os.environ, NCM_HOST="127.0.0.1", NCM_PORT=str(port))
environment.pop("CORS_ALLOW_ORIGIN", None)
process = subprocess.Popen([sys.argv[1]], env=environment,
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    creationflags=0x08000000 if os.name == "nt" else 0)
try:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    base = f"http://127.0.0.1:{port}"
    deadline = time.monotonic() + 10
    while True:
        try:
            with opener.open(base + "/", timeout=1) as response:
                assert json.load(response)["code"] == 200
            break
        except OSError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.05)
    query = urllib.parse.urlencode({"keywords": "晴天", "limit": 1, "type": 1})
    with opener.open(base + "/cloudsearch?" + query, timeout=25) as response:
        document = json.load(response)
    assert document.get("code") == 200, document.get("code")
    songs = document["result"]["songs"]
    assert songs, "guest search returned no songs"
    print(json.dumps({"probe": "ncm-guest-search", "code": 200,
                      "songs": len(songs), "failures": []}))
finally:
    process.kill()
    process.wait(timeout=10)
