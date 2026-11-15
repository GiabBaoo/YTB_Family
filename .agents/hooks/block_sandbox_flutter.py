import json
import os
import re
import sys

COMMAND_SPLIT_RE = re.compile(r"&&|\|\||[;\r\n|&]+")
TARGET_BASENAMES = {"flutter", "flutter.bat", "dart", "dart.bat", "dart.exe"}


def _invokes_flutter_or_dart(command_line: str) -> bool:
    for segment in COMMAND_SPLIT_RE.split(command_line):
        seg = segment.strip().lstrip("{(").strip()
        if not seg:
            continue
        if seg.lower().startswith("call "):
            seg = seg[5:].strip()
        elif seg.startswith(". "):
            seg = seg[2:].strip()

        if not seg:
            continue

        if seg[0] in ('"', "'"):
            quote = seg[0]
            end = seg.find(quote, 1)
            token = seg[1:end] if end != -1 else seg[1:]
        else:
            token = seg.split(None, 1)[0]

        basename = os.path.basename(token.replace("\\", "/")).lower()
        if basename in TARGET_BASENAMES:
            return True
    return False


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        print("{}")
        return

    tool_call = payload.get("toolCall") or {}
    if tool_call.get("name") != "run_command":
        print("{}")
        return

    args = tool_call.get("args") or {}
    if args.get("BypassSandbox") is True:
        print("{}")
        return

    command_line = args.get("CommandLine") or ""
    if _invokes_flutter_or_dart(command_line):
        print(
            json.dumps(
                {
                    "decision": "deny",
                    "reason": (
                        "Blocked sandboxed flutter/dart command: on Windows, "
                        "flutter.bat/dart.bat calls shared.bat which loops infinitely on "
                        "C:\\flutter\\bin\\cache\\flutter.bat.lock (Access Denied in sandbox). "
                        "Re-run with BypassSandbox: true."
                    ),
                }
            )
        )
        return

    print("{}")


if __name__ == "__main__":
    main()

