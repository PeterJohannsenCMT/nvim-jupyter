#!/usr/bin/env python3
"""
nvim-jupyter bridge (cooperative event loop, ANSI preserved).

Commands from Neovim (one JSON per line):
  {"type":"start", "kernel":"python3", "cwd":"/path/optional"}
  {"type":"execute", "seq":<int>, "code":"..."}
  {"type":"interrupt"}
  {"type":"restart"}
  {"type":"shutdown"}

Events to Neovim (one JSON per line):
  {"type":"ready"}
  {"type":"stream",   "seq":n, "name":"stdout|stderr", "text":"..."}   # ANSI kept
  {"type":"result",   "seq":n, "value":"text/plain"}
  {"type":"markdown", "seq":n, "value":"..."}
  {"type":"image",    "seq":n, "path":"/tmp/....png|.svg"}
  {"type":"error",    "seq":n, "ename":"...", "evalue":"...", "traceback":"..."}  # ANSI kept
  {"type":"done",     "seq":n}
  {"type":"interrupted"}  # ack when an interrupt is requested
  {"type":"bye"}          # after shutdown
"""
import base64
import json
import os
import select
import signal
import sys
import tempfile
import time
import traceback
from collections import deque

from jupyter_client import KernelManager

km = None
kc = None

# execution state
current = None             # {"seq": int, "msg_id": str}
queue = deque()

# ---------- helpers ----------

def send(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

def _b64_to_file(payload_b64: str, suffix: str) -> str:
    fd, path = tempfile.mkstemp(suffix=suffix); os.close(fd)
    with open(path, "wb") as f:
        f.write(base64.b64decode(payload_b64))
    return path

def _safe_stop_channels():
    global kc
    try:
        if kc is not None:
            kc.stop_channels()
    except Exception:
        pass

def _safe_shutdown_kernel(now: bool = True):
    global km
    try:
        if km is not None:
            km.shutdown_kernel(now=now)
    except Exception:
        pass
    try:
        if km is not None and hasattr(km, "cleanup_resources"):
            km.cleanup_resources()
    except Exception:
        pass

def _kernel_ready():
    return km is not None and kc is not None

def _start_kernel(kernel: str, cwd: str | None):
    global km, kc
    if cwd:
        try: os.chdir(cwd)
        except Exception: pass
    # jupyter_client ≥ 8: pass kernel_name at construction
    km = KernelManager(kernel_name=(kernel or "python3"))
    km.start_kernel()
    kc = km.client()
    kc.start_channels()
    kc.wait_for_ready(timeout=30)
    send({"type": "ready"})

def _restart_kernel():
    global kc, current, queue
    _safe_stop_channels()
    current = None
    queue.clear()
    km.restart_kernel(now=True)
    kc = km.client()
    kc.start_channels()
    kc.wait_for_ready(timeout=30)
    send({"type": "ready"})

def _shutdown():
    global km, kc, current
    current = None
    _safe_stop_channels()
    _safe_shutdown_kernel(now=True)
    km = None
    kc = None

def _sigterm(_sig, _frm):
    _shutdown()
    raise SystemExit(0)

signal.signal(signal.SIGTERM, _sigterm)
signal.signal(signal.SIGINT,  _sigterm)

# ---------- IOPub draining ----------

def _drain_iopub_once() -> None:
    """Drain at most one IOPub message for the current execution."""
    global current
    if not current or not _kernel_ready():
        return
    try:
        # short timeout keeps loop responsive to stdin (interrupt/shutdown)
        msg = kc.get_iopub_msg(timeout=0.05)
    except Exception:
        return
    if not msg:
        return

    # Only forward messages for our current execution
    parent = msg.get("parent_header", {})
    if parent.get("msg_id") != current["msg_id"]:
        return

    mtype   = msg["header"]["msg_type"]
    content = msg.get("content", {})

    if mtype in ("execute_result", "display_data"):
        data = content.get("data", {})
        if "image/png" in data:
            path = _b64_to_file(data["image/png"], ".png")
            send({"type": "image", "seq": current["seq"], "path": path})
        elif "image/svg+xml" in data:
            fd, path = tempfile.mkstemp(suffix=".svg"); os.close(fd)
            with open(path, "w", encoding="utf-8") as f:
                f.write(data["image/svg+xml"])
            send({"type": "image", "seq": current["seq"], "path": path})
        elif "text/markdown" in data:
            send({"type": "markdown", "seq": current["seq"], "value": data["text/markdown"]})
        elif "text/plain" in data:
            send({"type": "result", "seq": current["seq"], "value": data["text/plain"]})

    elif mtype == "stream":
        # Keep ANSI; Neovim will colorize via baleia.nvim
        send({"type": "stream", "seq": current["seq"],
              "name": content.get("name"),
              "text": content.get("text", "")})

    elif mtype == "error":
        # Keep ANSI; Neovim will colorize via baleia.nvim
        tb_list = content.get("traceback", []) or []
        tb_text = "\n".join(tb_list)
        send({"type": "error", "seq": current["seq"],
              "ename": content.get("ename", "Error"),
              "evalue": content.get("evalue", ""),
              "traceback": tb_text})

    elif mtype == "status" and content.get("execution_state") == "idle":
        send({"type": "done", "seq": current["seq"]})
        current = None  # finished

def _maybe_start_next():
    """If idle and queue has work, start the next execution."""
    global current
    if current or not queue or not _kernel_ready():
        return
    seq, code = queue.popleft()
    msg_id = kc.execute(code, store_history=True, allow_stdin=False)
    current = {"seq": seq, "msg_id": msg_id}

# ---------- command handling ----------

def _handle_command(req: dict) -> bool:
    """Process a single command. Return False to exit."""
    typ = req.get("type")
    try:
        if typ == "start":
            _start_kernel(req.get("kernel") or "python3", req.get("cwd"))
        elif typ == "execute":
            # enqueue; loop will start it when idle
            queue.append((req["seq"], req["code"]))
        elif typ == "interrupt":
            send({"type": "interrupted"})
            if km:
                try: km.interrupt_kernel()
                except Exception: pass
        elif typ == "restart":
            if km: _restart_kernel()
        elif typ == "shutdown":
            _shutdown(); send({"type": "bye"}); return False
    except Exception as e:
        send({"type": "error", "seq": req.get("seq"),
              "ename": e.__class__.__name__,
              "evalue": str(e),
              "traceback": traceback.format_exc()})
    return True

# ---------- main loop ----------

def main() -> None:
    """Cooperative loop: poll stdin for commands, interleave with IOPub draining."""
    buf = ""
    stdin_fd = sys.stdin.fileno()
    while True:
        # 1) Poll stdin (non-blocking, ~50ms)
        rlist, _, _ = select.select([stdin_fd], [], [], 0.05)
        if rlist:
            chunk = os.read(stdin_fd, 4096).decode("utf-8", "replace")
            if chunk == "":
                _shutdown()
                break
            buf += chunk
            # process complete lines
            while True:
                nl = buf.find("\n")
                if nl < 0: break
                line = buf[:nl].strip()
                buf = buf[nl+1:]
                if line:
                    try:
                        req = json.loads(line)
                    except Exception as e:
                        send({"type":"error","seq":None,"ename":e.__class__.__name__,"evalue":str(e),
                              "traceback": traceback.format_exc()})
                        continue
                    if not _handle_command(req):
                        return

        # 2) If idle, start next execute
        _maybe_start_next()
        # 3) Drain one IOPub message (keeps progress live)
        _drain_iopub_once()

if __name__ == "__main__":
    try:
        main()
    finally:
        _shutdown()
