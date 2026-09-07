#!/usr/bin/env python3
"""Send bounded pointer/Escape plans to the signed DockDoor debug process."""

import argparse
import ctypes as C
import json
from pathlib import Path


def load_plan(path):
    steps = json.loads(Path(path).read_text())
    if not isinstance(steps, list) or not 1 <= len(steps) <= 120:
        raise ValueError("Expected 1–120 steps")
    total = 0
    for step in steps:
        if step.get("action") not in ("move", "escape", "wait"):
            raise ValueError("Only pointer movement, Escape, and waits are supported")
        duration = step.get("wait", 0)
        if not isinstance(duration, (int, float)) or not 0 <= duration <= 5:
            raise ValueError("Each wait must be between 0 and 5 seconds")
        total += duration
        if step["action"] == "move":
            for key in ("x", "y"):
                if not isinstance(step.get(key), (int, float)) or not -20000 <= step[key] <= 20000:
                    raise ValueError("Movement requires finite screen coordinates")
    if total > 30:
        raise ValueError("Trials are limited to 30 seconds")
    return steps


def send(action, payload=None):
    C.CDLL("/System/Library/Frameworks/Foundation.framework/Foundation")
    objc = C.CDLL("/usr/lib/libobjc.A.dylib")
    objc.objc_getClass.argtypes = [C.c_char_p]
    objc.objc_getClass.restype = C.c_void_p
    objc.sel_registerName.argtypes = [C.c_char_p]
    objc.sel_registerName.restype = C.c_void_p
    address = C.cast(objc.objc_msgSend, C.c_void_p).value
    call = C.CFUNCTYPE(C.c_void_p, C.c_void_p, C.c_void_p)(address)
    make_string = C.CFUNCTYPE(C.c_void_p, C.c_void_p, C.c_void_p, C.c_char_p)(address)
    post = C.CFUNCTYPE(None, C.c_void_p, C.c_void_p, C.c_void_p, C.c_void_p, C.c_void_p, C.c_bool)(address)
    sel = lambda name: objc.sel_registerName(name.encode())
    pool = call(objc.objc_getClass(b"NSAutoreleasePool"), sel("new"))
    try:
        center = call(objc.objc_getClass(b"NSDistributedNotificationCenter"), sel("defaultCenter"))
        string_class = objc.objc_getClass(b"NSString")
        name = make_string(string_class, sel("stringWithUTF8String:"), ("com.ethanbills.DockDoor.debug." + action).encode())
        obj = make_string(string_class, sel("stringWithUTF8String:"), json.dumps(payload).encode()) if payload is not None else None
        post(center, sel("postNotificationName:object:userInfo:deliverImmediately:"), name, obj, None, True)
        print("Request sent to signed DockDoor. Verify execution in its diagnostic log.")
    finally:
        call(pool, sel("drain"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", nargs="?", help="JSON plan using observed native UI coordinates")
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--targets", action="store_true", help="Export Dock and preview geometry to /tmp/DockDoor-InputTargets.json")
    args = parser.parse_args()
    if args.targets:
        send("previewInputTargets")
    else:
        if not args.plan:
            parser.error("A plan is required unless --targets is selected")
        plan = load_plan(args.plan)
        if args.validate_only:
            print(f"Valid plan: {len(plan)} steps; {sum(s.get('wait', 0) for s in plan):.3f} seconds")
        else:
            send("previewInputPlan", plan)
