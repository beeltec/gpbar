#!/usr/bin/env python3
"""Run one suite phase and stop its own process group on cancellation."""
import argparse
import os
import signal
import subprocess
import sys
import time


parser = argparse.ArgumentParser()
parser.add_argument('--cwd')
parser.add_argument('command', nargs=argparse.REMAINDER)
arguments = parser.parse_args()
child = None
interrupted = None


def forward(signum, _frame):
    global interrupted
    interrupted = signum
    if child is not None:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass


for signum in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]:
    signal.signal(signum, forward)
child = subprocess.Popen(arguments.command, cwd=arguments.cwd, start_new_session=True)
if interrupted is not None:
    forward(interrupted, None)
while child.poll() is None and interrupted is None:
    time.sleep(0.05)
if interrupted is not None:
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
try:
    os.killpg(child.pid, signal.SIGTERM)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        child.poll()
        os.killpg(child.pid, 0)
        time.sleep(0.05)
    os.killpg(child.pid, signal.SIGKILL)
except ProcessLookupError:
    pass
status = child.wait()
sys.exit(128 + interrupted if interrupted is not None else status if status >= 0 else 128 - status)
