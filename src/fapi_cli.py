"""CLI bridge so the Pawa-Lite(Beta)V2 UI (Tauri) can drive the FAPI.

Usage:
    python fapi_cli.py attach
    python fapi_cli.py execute <script.lua>
    python fapi_cli.py execute --stdin   (read script from stdin)
    python fapi_cli.py status            (print injected state as json)

Exit codes: 0 = ok, 1 = Roblox not open / not injected, 2 = usage error.
Stdout carries human-readable status lines; errors go to stdout too
(prefixed with ERROR:) so the Tauri sidecar can forward them.
"""

import argparse
import json
import sys


def cmd_attach() -> int:
    import FAPI

    try:
        if not FAPI.roblox_open():
            print("ERROR: Roblox is not open")
            return 1
    except Exception as e:  # noqa: BLE001
        print(f"ERROR: roblox check failed: {e}")
        return 1

    try:
        executor = FAPI.Executor()
    except Exception as e:  # noqa: BLE001
        print(f"ERROR: executor init failed: {e}")
        return 1

    try:
        if executor.injected:
            print("OK: already injected")
            return 0
    except Exception:  # noqa: BLE001
        pass

    try:
        executor.inject()
    except Exception as e:  # noqa: BLE001
        print(f"ERROR: inject failed: {e}")
        return 1

    try:
        if executor.injected:
            print("OK: injected")
            return 0
    except Exception:  # noqa: BLE001
        pass

    print("ERROR: inject did not confirm (join a game with players first?)")
    return 1


def cmd_execute(script: str) -> int:
    import FAPI

    try:
        executor = FAPI.Executor()
    except Exception as e:  # noqa: BLE001
        print(f"ERROR: executor init failed: {e}")
        return 1

    try:
        if not executor.injected:
            print("ERROR: not injected (attach first)")
            return 1
    except Exception as e:  # noqa: BLE001
        print(f"ERROR: inject-state check failed: {e}")
        return 1

    try:
        executor.execute(script)
    except Exception as e:  # noqa: BLE001
        print(f"ERROR: execute failed: {e}")
        return 1

    print(f"OK: executed {len(script)} chars")
    return 0


def cmd_status() -> int:
    import FAPI

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
    print(json.dumps(state))
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Pawa-Lite(Beta)V2 FAPI CLI")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("attach", help="inject into running Roblox")

    p_exec = sub.add_parser("execute", help="execute a script (needs injection)")
    src = p_exec.add_mutually_exclusive_group(required=True)
    src.add_argument("script_file", nargs="?", help="path to .lua/.luau file")
    src.add_argument("--stdin", action="store_true", help="read script from stdin")

    sub.add_parser("status", help="print roblox/injected state as json")

    args = parser.parse_args(argv)

    if args.command == "attach":
        return cmd_attach()
    if args.command == "status":
        return cmd_status()
    if args.command == "execute":
        if args.stdin:
            script = sys.stdin.read()
        else:
            try:
                with open(args.script_file, "r", encoding="utf-8") as f:
                    script = f.read()
            except OSError as e:
                print(f"ERROR: cannot read script file: {e}")
                return 2
        if not script.strip():
            print("ERROR: empty script")
            return 2
        return cmd_execute(script)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
