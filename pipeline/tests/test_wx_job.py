import subprocess
import time
from pathlib import Path

SERVER = Path(__file__).parent.parent / "deploy"


def turn(home, env):
    return subprocess.run(["bash", str(home / "deploy" / "wx-run.sh")], env=env).returncode


def test_the_worker_container_is_small_named_and_cannot_hang():
    script = (SERVER / "wx-run.sh").read_text()
    for part in ("--name wxpipe", "--cpus=2", "--cpu-shares=512", "--memory=4g", "--env-file",
                 "--entrypoint timeout chartpipe 240 python3 -m wxpipe --work /work/wx",
                 "flock -n", '$CHARTPIPE_NOTIFY "$1" "$2"'):
        assert part in script
    # The chart builds and the weather job never wait on each other.
    assert "docker ps" not in script
    assert subprocess.run(["bash", "-n", str(SERVER / "wx-run.sh")]).returncode == 0


def test_the_schedule_runs_the_worker_every_five_minutes():
    jobs = [line for line in (SERVER / "chartpipe-wx.cron").read_text().splitlines()
            if line and not line.startswith("#")]
    assert jobs == ["*/5 * * * * bash /srv/chartpipe/deploy/wx-run.sh"]


def test_three_failures_in_a_row_raise_one_alert(server, last_alert):
    home, env = server
    alerts = home / "alerts"

    def fail(code):
        (home / "docker-exit").write_text(str(code))
        return turn(home, env)

    assert [fail(1), fail(1)] == [1, 1] and not alerts.exists()
    assert fail(1) == 1 and alerts.read_text().count("alert") == 1
    assert last_alert() == ["Weather mirror failing", ""]
    assert fail(124) == 124 and alerts.read_text().count("alert") == 1
    assert fail(0) == 0 and not (home / "wx-run.failures").exists()
    assert [fail(1), fail(1), fail(1)] == [1, 1, 1] and alerts.read_text().count("alert") == 2


def test_a_new_set_of_failing_sources_alerts_again_and_a_long_failure_repeats(server, last_alert):
    home, env = server
    (home / "docker-exit").write_text("1")

    def alerts_after(turns, said):
        (home / "docker-says").write_text(f"failed sources: {said}\n")
        for _ in range(turns):
            turn(home, env)
        return (home / "alerts").read_text().count("alert")

    assert alerts_after(5, "radar") == 1
    # One odd turn is a blip. Three in a row with a new set is news.
    assert alerts_after(1, "metars, radar") == 1
    assert alerts_after(3, "radar") == 1
    assert alerts_after(2, "metars, radar") == 1
    assert alerts_after(1, "metars, radar") == 2
    assert last_alert() == ["Weather mirror failing", "failed sources: metars, radar"]
    assert alerts_after(1, "metars, radar") == 2
    # Thirteen turns so far. The alert repeats every 72 turns, six hours, while the failure lasts.
    assert alerts_after(61, "metars, radar") == 2
    assert alerts_after(1, "metars, radar") == 3


def test_a_failure_count_that_cannot_be_saved_alerts_at_once(server, last_alert):
    home, env = server
    (home / "docker-exit").write_text("1")
    (home / "wx-run.failures").mkdir()
    assert turn(home, env) == 1
    assert (home / "alerts").read_text().count("alert") == 1
    assert last_alert() == ["Weather mirror failing", f"cannot write {home}/wx-run.failures (disk full?)"]


def test_a_lock_held_for_three_turns_raises_one_alert(server, last_alert):
    home, env = server
    (home / "hold").write_text("")
    first = subprocess.Popen(["bash", str(home / "deploy" / "wx-run.sh")], env=env)
    try:
        deadline = time.monotonic() + 10
        while not (home / "runs").exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        codes = [turn(home, env) for _ in range(4)]
    finally:
        (home / "hold").unlink()
        first.wait(timeout=10)
    assert codes == [0, 0, 0, 0] and (home / "alerts").read_text().count("alert") == 1
    assert last_alert() == ["Weather mirror stuck", "the last run still holds the lock"]
    assert turn(home, env) == 0
    assert not (home / "wx-run.skips").exists()


def test_a_lock_that_cannot_be_taken_counts_as_a_failure_and_never_runs_unlocked(server):
    home, env = server
    broken = home / "bin" / "flock"
    broken.write_text("#!/bin/bash\nexit 127\n")
    broken.chmod(0o755)
    codes = [turn(home, env) for _ in range(3)]
    assert codes == [127, 127, 127]
    assert not (home / "runs").exists()
    assert (home / "alerts").read_text().count("alert") == 1


def test_a_turn_that_starts_while_the_last_one_runs_leaves_quietly(server):
    home, env = server
    runs = home / "runs"
    (home / "hold").write_text("")
    first = subprocess.Popen(["bash", str(home / "deploy" / "wx-run.sh")], env=env)
    try:
        deadline = time.monotonic() + 10
        while not runs.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert len(runs.read_text().splitlines()) == 1
        assert turn(home, env) == 0
        assert len(runs.read_text().splitlines()) == 1
    finally:
        (home / "hold").unlink()
        assert first.wait(timeout=10) == 0
    # The lock went with the first turn, so the next one runs.
    assert turn(home, env) == 0
    assert len(runs.read_text().splitlines()) == 2
    assert not (home / "wx-run.failures").exists()
