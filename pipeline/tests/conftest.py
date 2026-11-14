import os
import shutil
from pathlib import Path

import pytest

DEPLOY = Path(__file__).parent.parent / "deploy"
# Takes the same kind of lock as the real tool, for machines that do not ship it.
STAND_IN_FLOCK = """#!/usr/bin/env python3
import fcntl, sys
try:
    fcntl.flock(int(sys.argv[-1]), fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)
"""


@pytest.fixture
def server(tmp_path):
    """A stand-in server: copies of the job scripts, a docker that exits as told and a notify that keeps its calls."""
    home = tmp_path
    tools = home / "bin"
    tools.mkdir()
    # Copies, so a site file on this machine never reaches a test.
    shutil.copytree(DEPLOY, home / "deploy", ignore=shutil.ignore_patterns("site.env"))
    (tools / "docker").write_text(
        '#!/bin/bash\n'
        f'if [ "$1" = ps ]; then cat "{home}/docker-ps" 2>/dev/null; exit 0; fi\n'
        f'echo "$*" >> "{home}/runs"\n'
        f'while [ -e "{home}/hold" ]; do sleep 0.1; done\n'
        f'cat "{home}/docker-says" 2>/dev/null\n'
        f'exit "$(cat "{home}/docker-exit")"\n')
    (tools / "notify").write_text(
        '#!/bin/bash\n'
        f'echo alert >> "{home}/alerts"\n'
        f'printf \'%s\\0\' "$@" > "{home}/alert-said"\n')
    if shutil.which("flock") is None:
        (tools / "flock").write_text(STAND_IN_FLOCK)
    for tool in tools.iterdir():
        tool.chmod(0o755)
    (home / "docker-exit").write_text("0")
    env = {**os.environ, "PATH": f"{tools}:{os.environ['PATH']}", "CHARTPIPE_HOME": str(home),
           "CHARTPIPE_NOTIFY": str(tools / "notify"), "CHARTPIPE_ENV": "/dev/null"}
    return home, env


@pytest.fixture
def last_alert(server):
    """Reads the arguments of the latest notify call."""
    return lambda: (server[0] / "alert-said").read_text().split("\0")[:-1]
