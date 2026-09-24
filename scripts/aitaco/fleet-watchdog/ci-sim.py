#!/usr/bin/env python3
"""Run the suite the way a CI runner would, from a machine that is not one.

Two ambient facts about hip made tests pass here and fail on GitHub within one
pull request: the fleet `buzz` is on PATH, and the box has been up for weeks.
A runner has neither, so `main()`'s PATH preflight refuses a --post run and its
`--min-uptime` grace returns before anything is written. Neither is visible
from a passing local run, and both cost a red push.

    python3 ci-sim.py          # same suite, runner-shaped environment

It is not a substitute for CI. It is the cheapest way to find out, before
pushing, whether a test is reading the machine instead of the code.
"""

import os
import runpy
import sys
import tempfile

os.environ["PATH"] = tempfile.mkdtemp(prefix="ci-sim-no-buzz-") + ":/usr/bin:/bin"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import watchdog  # noqa: E402  — imported so the stub below lands before the suite

watchdog.uptime_secs = lambda: 30.0

sys.argv = ["test_watchdog.py"]
runpy.run_path(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_watchdog.py"),
    run_name="__main__",
)
