#!/usr/bin/env python3
"""
nvim-jupyter bridge (cooperative loop; JSON-only on stdout; ANSI preserved).
Adds stdin support: forwards input_request -> Neovim and accepts stdin_reply.
"""
import base64, json, os, select, signal, sys, tempfile, traceback
from collections import deque
from jupyter_client import KernelManager

# ---- unbuffered, consistent IO ----
try:
    sys.stdin.reconfigure(encoding="utf-8")
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")
except Exception:
    pass

km = None
kc = None
_current = None            # {"seq": int, "msg_id": str}
_queue = deque()
_outbox = []               # batched messages

def send(obj):
    _outbox.append(obj)

def flush_outbox():
    global _outbox
    if _outbox:
        sys.stdout.write("\n".join(json.dumps(x) for x in _outbox) + "\n")
        sys.stdout.flush()
        _outbox.clear()

def _b64_to_file(payload_b64, suffix):
    fd, path = tempfile.mkstemp(suffix=suffix); os.close(fd)
    with open(path, "wb") as f: f.write(base64.b64decode(payload_b64))
    return path

def _safe_stop_channels():
    global kc
    try:
        if kc is not None:
            kc.stop_channels()
    except Exception:
        pass

def _safe_shutdown_kernel(now=True):
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

def _signal_kernel(signame):
    if not hasattr(signal, signame):
        return False, "{} unsupported on this platform".format(signame)
    if km is None:
        return False, "Kernel not running"
    sig = getattr(signal, signame)

    # Prefer the jupyter_client helper if available
    if hasattr(km, "signal_kernel"):
        try:
            km.signal_kernel(sig)
        except Exception as exc:
            return False, str(exc)
        return True, None

    # Fallback: direct os.kill on the managed kernel PID (older clients)
    proc = getattr(km, "kernel", None)
    pid = getattr(proc, "pid", None)
    if not pid:
        return False, "Kernel PID unavailable"
    try:
        os.kill(pid, sig)
    except Exception as exc:
        return False, str(exc)
    return True, None

# ---------- kernel mgmt ----------
def _start_kernel(kernel, cwd):
    global km, kc
    if cwd:
        try: os.chdir(cwd)
        except Exception: pass
    km = KernelManager(kernel_name=(kernel or "python3"))
    extra_env = os.environ.copy()
    extra_env["PATH"] = "/Library/TeX/texbin:" + extra_env.get("PATH", "")
    km.start_kernel(env = extra_env)
    kc = km.client()
    kc.start_channels()
    kc.wait_for_ready(timeout=30)
    send({"type": "ready"})

def _restart_kernel():
    global kc, _current, _queue
    _safe_stop_channels()
    _current = None
    _queue.clear()
    km.restart_kernel(now=True)
    kc = km.client()
    kc.start_channels()
    kc.wait_for_ready(timeout=30)
    send({"type": "ready"})

def _shutdown():
    global km, kc, _current
    _current = None
    _safe_stop_channels()
    _safe_shutdown_kernel(now=True)
    km = None
    kc = None

def _sigterm(_sig, _frm):
    _shutdown()
    raise SystemExit(0)

signal.signal(signal.SIGTERM, _sigterm)
signal.signal(signal.SIGINT,  _sigterm)

# ---------- IOPub / STDIN draining ----------
def _drain_iopub_once():
    global _current
    if not _current or not _kernel_ready():
        return
    try:
        msg = kc.get_iopub_msg(timeout=0.05)
    except Exception:
        return
    if not msg:
        return

    parent = msg.get("parent_header", {})
    if parent.get("msg_id") != _current["msg_id"]:
        return

    mtype   = msg["header"]["msg_type"]
    content = msg.get("content", {})

    if mtype in ("execute_result", "display_data"):
        data = content.get("data", {})
        if "image/png" in data:
            path = _b64_to_file(data["image/png"], ".png")
            send({"type": "image", "seq": _current["seq"], "path": path})
        elif "image/svg+xml" in data:
            fd, path = tempfile.mkstemp(suffix=".svg"); os.close(fd)
            with open(path, "w", encoding="utf-8") as f: f.write(data["image/svg+xml"])
            send({"type": "image", "seq": _current["seq"], "path": path})
        elif "text/markdown" in data:
            send({"type": "markdown", "seq": _current["seq"], "value": data["text/markdown"]})
        elif "text/plain" in data:
            send({"type": "result", "seq": _current["seq"], "value": data["text/plain"]})

    elif mtype == "stream":
        send({"type": "stream", "seq": _current["seq"],
              "name": content.get("name"), "text": content.get("text", "")})

    elif mtype == "error":
        tb_list = content.get("traceback", []) or []
        tb_text = "\n".join(tb_list)
        send({"type": "error", "seq": _current["seq"],
              "ename": content.get("ename", "Error"),
              "evalue": content.get("evalue", ""),
              "traceback": tb_text})

    elif mtype == "status" and content.get("execution_state") == "idle":
        send({"type": "done", "seq": _current["seq"]})
        _current = None

def _drain_stdin_once():
    """Forward input_request to Neovim."""
    if not _kernel_ready():
        return
    ch = getattr(kc, "stdin_channel", None)
    if ch is None:
        return
    try:
        msg = ch.get_msg(timeout=0.0)
    except Exception:
        return
    if not msg:
        return
    if msg.get("header", {}).get("msg_type") == "input_request":
        c = msg.get("content", {}) or {}
        send({
            "type": "stdin_request",
            "seq": _current["seq"] if _current else None,
            "prompt": c.get("prompt", ""),
            "password": bool(c.get("password", False)),
        })

def _maybe_start_next():
    global _current
    if _current or not _queue or not _kernel_ready():
        return
    seq, code = _queue.popleft()
    msg_id = kc.execute(code, store_history=True, allow_stdin=True)
    _current = {"seq": seq, "msg_id": msg_id}

# ---------- command handling ----------
def _handle_command(req):
    typ = req.get("type")
    try:
        if typ == "start":
            _start_kernel(req.get("kernel") or "python3", req.get("cwd"))
        elif typ == "execute":
            _queue.append((req["seq"], req["code"]))
        elif typ == "stdin_reply":
            kc.input(req.get("text", ""))
        elif typ == "interrupt":
            send({"type": "interrupted"})
            if km:
                try: km.interrupt_kernel()
                except Exception: pass
        elif typ == "pause":
            ok, err = _signal_kernel("SIGSTOP")
            if ok:
                send({"type": "paused"})
            else:
                send({"type": "pause_failed", "message": err})
        elif typ == "resume":
            ok, err = _signal_kernel("SIGCONT")
            if ok:
                send({"type": "resumed"})
            else:
                send({"type": "resume_failed", "message": err})
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
def main():
    buf = ""
    stdin_fd = sys.stdin.fileno()
    while True:
        rlist, _, _ = select.select([stdin_fd], [], [], 0.05)
        if rlist:
            chunk = os.read(stdin_fd, 4096).decode("utf-8", "replace")
            if chunk == "":
                _shutdown()
                break
            buf += chunk
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
                        flush_outbox()
                        return
        _maybe_start_next()
        _drain_iopub_once()
        _drain_stdin_once()
        flush_outbox()

if __name__ == "__main__":
    try:
        main()
    finally:
        _shutdown()
