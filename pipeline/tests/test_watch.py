import json
import os
import subprocess
import time
from datetime import datetime, timedelta, timezone

import pytest

HOUR = 3600
LOGS = ["tpp-run.log", "nav-run.log", "last-run.log"]


def stamp(minutes_ago):
    return (datetime.now(timezone.utc) - timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def publish(home, *minutes_ago):
    """Writes the weather index a file:// address serves, one source checked at each age; None is a source never checked."""
    (home / "pub" / "wx").mkdir(parents=True, exist_ok=True)
    checked = {f"source{n}": None if age is None else stamp(age) for n, age in enumerate(minutes_ago)}
    (home / "pub" / "wx" / "index.json").write_text(json.dumps({"version": 1, "checked_at": checked}))


def age_log(home, name, hours):
    when = time.time() - hours * HOUR
    os.utime(home / name, (when, when))


@pytest.fixture
def watched(server):
    """A server where every job ran lately and the weather index is five minutes old; notify keeps a subject-and-detail line per call."""
    home, env = server
    (home / "bin" / "notify").write_text(
        '#!/bin/bash\n'
        f'printf \'%s\\t%s\\n\' "$1" "$2" >> "{home}/alert-log"\n')
    env["CHARTPIPE_PUBLIC_URL"] = f"file://{home}/pub"
    for name in LOGS:
        (home / name).write_text("done\n")
    publish(home, 5)
    return home, env


def watch(home, env):
    done = subprocess.run(["bash", str(home / "deploy" / "watch.sh")], env=env, capture_output=True, text=True)
    assert (done.returncode, done.stderr) == (0, "")
    return done


def sent(home):
    """Every alert so far, as (subject, detail)."""
    said = (home / "alert-log").read_text() if (home / "alert-log").exists() else ""
    return [tuple(line.split("\t", 1)) for line in said.splitlines()]


def test_fresh_jobs_and_a_fresh_index_say_nothing(watched):
    home, env = watched
    # Another source may be old or never checked: the newest check counts.
    publish(home, 29, 600, None)
    age_log(home, "nav-run.log", 25)
    watch(home, env)
    assert sent(home) == [] and (home / "watch.state").read_text() == ""


def test_an_index_with_no_recent_check_alerts_once(watched):
    home, env = watched
    publish(home, 45, 90)
    watch(home, env)
    watch(home, env)
    assert sent(home) == [("Weather mirror not publishing",
                           f"the newest check in file://{home}/pub/wx/index.json is 45 minutes old")]


def test_an_index_that_cannot_be_read_alerts(watched):
    home, env = watched
    (home / "pub" / "wx" / "index.json").unlink()
    watch(home, env)
    [(subject, detail)] = sent(home)
    assert subject == "Weather mirror not publishing"
    assert detail.startswith(f"cannot read file://{home}/pub/wx/index.json: ")


def test_an_index_that_is_not_one_alerts(watched):
    home, env = watched
    (home / "pub" / "wx" / "index.json").write_text("<html>")
    watch(home, env)
    assert sent(home) == [("Weather mirror not publishing", f"file://{home}/pub/wx/index.json lists no check times")]


def test_with_no_public_address_the_index_check_alerts(watched):
    home, env = watched
    del env["CHARTPIPE_PUBLIC_URL"]
    watch(home, env)
    assert sent(home) == [("Weather mirror not publishing", "CHARTPIPE_PUBLIC_URL is not set")]


def test_the_site_file_names_the_public_address(watched):
    home, env = watched
    del env["CHARTPIPE_PUBLIC_URL"]
    (home / "deploy" / "site.env").write_text(f"CHARTPIPE_PUBLIC_URL=file://{home}/pub/\n")
    watch(home, env)
    assert sent(home) == []


@pytest.mark.parametrize("name, subject", [("tpp-run.log", "Plates pipeline not running"),
                                           ("nav-run.log", "Nav pipeline not running"),
                                           ("last-run.log", "Chart pipeline not running")])
def test_a_daily_log_nobody_wrote_for_two_days_alerts_and_one_missed_day_does_not(watched, name, subject):
    home, env = watched
    age_log(home, name, 30)
    watch(home, env)
    assert sent(home) == []
    age_log(home, name, 51)
    watch(home, env)
    assert sent(home) == [(subject, f"{name} has not been written in over 50 hours")]
    (home / name).unlink()
    (home / "watch.state").unlink()
    watch(home, env)
    assert sent(home)[1:] == [(subject, f"{name} is missing")]


def test_a_stale_check_repeats_every_six_hours_and_not_before(watched):
    home, env = watched
    publish(home, 90)
    watch(home, env)
    assert len(sent(home)) == 1
    # The state line is the check's name and the time of its last alert.
    for hours_ago, total in ((5.9, 1), (6.1, 2)):
        (home / "watch.state").write_text(f"wx {int(time.time() - hours_ago * HOUR)}\n")
        watch(home, env)
        assert len(sent(home)) == total
    watch(home, env)
    assert len(sent(home)) == 2


def test_a_recovered_check_says_nothing_and_alerts_again_when_it_goes_stale_again(watched):
    home, env = watched
    publish(home, 90)
    age_log(home, "tpp-run.log", 60)
    watch(home, env)
    assert len(sent(home)) == 2
    publish(home, 2)
    watch(home, env)
    assert len(sent(home)) == 2
    # Only the log is still stale, and still known.
    assert (home / "watch.state").read_text().startswith("tpp-run.log ")
    age_log(home, "tpp-run.log", 1)
    watch(home, env)
    assert (home / "watch.state").read_text() == ""
    publish(home, 90)
    watch(home, env)
    assert [subject for subject, _ in sent(home)][2:] == ["Weather mirror not publishing"]


def test_a_failing_alert_command_stops_nothing_and_is_tried_again_next_turn(watched):
    home, env = watched
    (home / "bin" / "notify").write_text(
        '#!/bin/bash\n'
        f'printf \'%s\\t%s\\n\' "$1" "$2" >> "{home}/alert-log"\n'
        f'[ -e "{home}/works" ]\n')
    publish(home, 90)
    age_log(home, "nav-run.log", 60)
    watch(home, env)
    assert [subject for subject, _ in sent(home)] == ["Weather mirror not publishing", "Nav pipeline not running"]
    assert (home / "watch.state").read_text() == ""
    (home / "works").write_text("")
    watch(home, env)
    assert len(sent(home)) == 4
    watch(home, env)
    assert len(sent(home)) == 4


def test_with_no_alert_command_the_script_still_runs_and_remembers(watched):
    home, env = watched
    del env["CHARTPIPE_NOTIFY"]
    age_log(home, "last-run.log", 60)
    watch(home, env)
    assert (home / "watch.state").read_text().startswith("last-run.log ")
    assert sent(home) == []


def test_a_state_that_cannot_be_written_keeps_the_last_one(watched):
    home, env = watched
    publish(home, 90)
    kept = f"wx {int(time.time() - HOUR)}\n"
    (home / "watch.state").write_text(kept)
    # As on a full disk: no file takes a byte.
    full = 'trap "" XFSZ; ulimit -f 0; exec bash "$0"'
    done = subprocess.run(["bash", "-c", full, str(home / "deploy" / "watch.sh")], env=env, capture_output=True, text=True)
    assert done.returncode != 0
    assert (home / "watch.state").read_text() == kept
    assert not (home / "watch.state.new").exists()
    watch(home, env)
    assert sent(home) == []
