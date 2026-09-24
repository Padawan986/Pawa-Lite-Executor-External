"""Persistent FAPI daemon for the Pawa-Lite(Beta)V2 UI (Tauri).

Why a daemon and not one-shot CLI calls: the injected game fetches every
executed script back from us via HTTP (bridge server on 127.0.0.1:9475,
see FAPI/bridge.py `Handler.do_GET` serving `_target_source`). A one-shot
process exits right after toggling the update indicator, so the game finds
a dead server and every execute ends in `-- request error`. This daemon
stays alive, keeps the bridge server up, and serves attach/execute/status
commands until the UI quits.

Protocol (JSON lines over stdio):
    -> {"id": 1, "cmd": "attach"}
    -> {"id": 2, "cmd": "execute", "script": "print('hi')"}
    -> {"id": 3, "cmd": "status"}
    <- {"id": 1, "ok": true, "msg": "OK: injected"}
    <- {"id": 2, "ok": false, "msg": "ERROR: not injected (attach first)"}

Only lines starting with '{' on stdout are protocol responses; anything
else is log noise and must be ignored by the client. Run python with -u.
"""

import json
import sys


def _respond(resp_id, ok, msg):
    sys.stdout.write(json.dumps({"id": resp_id, "ok": ok, "msg": msg}) + "\n")
    sys.stdout.flush()


def main():
    # Force UTF-8 stdio even if the launcher forgot -X utf8 / PYTHONUTF8.
    # Windows locale encoding (cp1252) dies on emoji-heavy scripts.
    for _stream_name in ("stdin", "stdout", "stderr"):
        try:
            getattr(sys, _stream_name).reconfigure(encoding="utf-8")
        except Exception:  # noqa: BLE001
            pass

    # Import here (after stdio is set up) so import-time prints don't
    # interleave with the protocol in confusing ways; they are still
    # ignored by the client since they don't start with '{'.
    import FAPI
    from FAPI import offsets as _offsets
    from FAPI import bridge as _bridge
    import psutil as _psutil
    from threading import Thread as _Thread

    # Fetch newer inject payload in the background on every start.
    try:
        _bridge.check_remote_update_background()
    except Exception:  # noqa: BLE001
        pass

    # Rejoin persistence: keep one Executor and re-inject whenever the
    # game is open but our payload is gone (teleport / rejoin / new server).
    # inject() itself skips when already injected, unloaded, or lobby-empty.
    _watch = {"autoinject": True, "executor": None}

    def _watcher_loop():
        import time
        while True:
            time.sleep(3)
            try:
                if not _watch["autoinject"]:
                    continue
                if not FAPI.roblox_open():
                    _watch["executor"] = None
                    continue
                ex = _watch["executor"]
                if ex is None:
                    ex = FAPI.Executor()
                    _watch["executor"] = ex
                try:
                    alive = _psutil.pid_exists(ex.sdk.mem.process_id)
                except Exception:  # noqa: BLE001
                    alive = False
                if not alive:
                    ex = FAPI.Executor()
                    _watch["executor"] = ex
                if not ex.injected:
                    ex.inject()
            except Exception:  # noqa: BLE001
                _watch["executor"] = None

    try:
        _Thread(target=_watcher_loop, daemon=True).start()
    except Exception:  # noqa: BLE001
        pass

    # Never block on input() inside offsets.silent_exit(): our stdin is a
    # command pipe, so input() would hang forever. Fail with context instead.
    def _no_exit():
        ver = "unknown"
        try:
            import psutil

            for proc in psutil.process_iter(["name", "exe"]):
                try:
                    if (proc.info.get("name") or "").lower() == "robloxplayerbeta.exe":
                        exe = proc.info.get("exe") or ""
                        ver = exe.split("\\")[-2] if "\\" in exe else exe
                        break
                except Exception:  # noqa: BLE001
                    pass
        except Exception:  # noqa: BLE001
            pass
        raise RuntimeError(
            f"no offsets published for {ver} yet (Roblox just updated?) - "
            "dumpers usually publish within hours; restart the UI and attach again"
        )

    _offsets.silent_exit = _no_exit

    def do_attach():
        import time as _time

        try:
            if not FAPI.roblox_open():
                return False, "ERROR: Roblox is not open"
        except Exception as e:  # noqa: BLE001
            return False, f"ERROR: roblox check failed: {e}"

        # The client is often in a transitional state here (starting up,
        # teleporting, updating): memory reads fail with 299 until the
        # DataModel exists. Retry instead of failing instantly.
        last_err = "ERROR: inject did not confirm (join a game with players first?)"
        for _ in range(8):
            try:
                executor = FAPI.Executor()
            except Exception as e:  # noqa: BLE001
                last_err = f"ERROR: executor init failed: {e}"
                _time.sleep(2)
                continue

            try:
                if executor.injected:
                    return True, f"OK: already injected (init {_bridge.get_init_version()})"
            except Exception:  # noqa: BLE001
                pass

            try:
                executor.inject()
            except Exception as e:  # noqa: BLE001
                last_err = f"ERROR: inject failed: {e}"
                _time.sleep(2)
                continue

            try:
                if executor.injected:
                    return True, f"OK: injected (init {_bridge.get_init_version()})"
            except Exception:  # noqa: BLE001
                pass
            _time.sleep(2)
        return False, last_err

    def do_execute(script):
        if not script or not script.strip():
            return False, "ERROR: empty script"
        try:
            executor = FAPI.Executor()
        except Exception as e:  # noqa: BLE001
            return False, f"ERROR: executor init failed: {e}"

        try:
            if not executor.injected:
                return False, "ERROR: not injected (attach first)"
        except Exception as e:  # noqa: BLE001
            return False, f"ERROR: inject-state check failed: {e}"

        try:
            executor.execute(script)
        except Exception as e:  # noqa: BLE001
            return False, f"ERROR: execute failed: {e}"
        return True, f"OK: executed {len(script)} chars"

    def do_status():
        state = {"roblox_open": False, "injected": False}
        try:
            state["roblox_open"] = bool(FAPI.roblox_open())
        except Exception:  # noqa: BLE001
            pass
        if state["roblox_open"]:
            try:
                state["injected"] = bool(FAPI.Executor().injected)
            except Exception:  # noqa: BLE001
                pass
        return True, json.dumps(state)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        resp_id = req.get("id")
        cmd = req.get("cmd")
        try:
            if cmd == "attach":
                ok, msg = do_attach()
            elif cmd == "execute":
                ok, msg = do_execute(req.get("script", ""))
            elif cmd == "status":
                ok, msg = do_status()
            elif cmd == "update":
                try:
                    ok, msg = True, _bridge.check_remote_update()
                except Exception as e:  # noqa: BLE001
                    ok, msg = False, f"ERROR: {e}"
            elif cmd == "set_autoinject":
                raw = req.get("value", req.get("script", ""))
                _watch["autoinject"] = str(raw).lower() in ("1", "true", "yes", "on")
                ok = True
                msg = f"OK: autoinject {'on' if _watch['autoinject'] else 'off'}"
            else:
                ok, msg = False, f"ERROR: unknown cmd {cmd!r}"
        except Exception as e:  # noqa: BLE001 - never kill the daemon
            ok, msg = False, f"ERROR: {e}"
        _respond(resp_id, ok, msg)


if __name__ == "__main__":
    main()
