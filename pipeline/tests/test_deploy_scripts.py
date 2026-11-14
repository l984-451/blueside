import os
import shutil
import subprocess
from pathlib import Path

import pytest

DEPLOY = Path(__file__).parent.parent / "deploy"
# Script, failing turns before it alerts, alert subject, log file.
JOBS = [("run.sh", 1, "Chart pipeline failed", "last-run.log"),
        ("nav-run.sh", 1, "Nav pipeline failed", "nav-run.log"),
        ("wx-run.sh", 3, "Weather mirror failing", "wx-run.log"),
        ("tpp-run.sh", 1, "Plates pipeline failed", "tpp-run.log")]
SAID = "one\ntwo\nthree\nfour\n"


def fail(home, env, script, turns):
    """Runs a job whose docker exits 7, as many turns as it takes to alert."""
    (home / "docker-exit").write_text("7")
    (home / "docker-says").write_text(SAID)
    return [subprocess.run(["bash", str(home / "deploy" / script)], env=env, capture_output=True, text=True)
            for _ in range(turns)]


def test_no_file_carries_the_paths_of_one_machine():
    if shutil.which("git") is None:
        pytest.skip("needs git")
    root = DEPLOY.parent
    listed = subprocess.run(["git", "ls-files", "-co", "--exclude-standard", "-z"], cwd=root, capture_output=True)
    if listed.returncode != 0:
        pytest.skip("not a git checkout")
    # Spelled in halves so this file passes its own check.
    words = [b"un" b"raid", b"em" b"http", b"/mnt" b"/user", b"/boot" b"/config"]
    files = [root / name for name in listed.stdout.decode().split("\0") if name]
    found = [(str(file), word.decode()) for file in files if file.is_file()
             for word in words if word in file.read_bytes().lower()]
    assert found == []


@pytest.mark.parametrize("script", [job[0] for job in JOBS])
def test_with_nothing_set_a_job_uses_the_default_folder_and_env_file(server, script):
    home, env = server
    if Path("/srv/chartpipe").exists():
        pytest.skip("this machine uses the default folder for real")
    # The default folder is absent and stays absent, so docker never starts: the shell trace shows its command line.
    for name in ("mkdir", "flock"):
        tool = home / "bin" / name
        tool.write_text("#!/bin/bash\nexit 0\n")
        tool.chmod(0o755)
    bare = {key: value for key, value in env.items() if not key.startswith("CHARTPIPE_")}
    trace = subprocess.run(["bash", "-x", str(home / "deploy" / script)], env=bare,
                           capture_output=True, text=True).stderr
    command = next(line for line in trace.splitlines() if line.startswith("+ docker run "))
    assert "--env-file /srv/chartpipe/r2.env -v /srv/chartpipe/work:/work " in command
    assert "unbound variable" not in trace and "command not found" not in trace
    assert not (home / "runs").exists() and not (home / "alerts").exists()


@pytest.mark.parametrize("script, turns, subject, log", JOBS)
def test_the_environment_names_the_folder_and_the_env_file_follows_it(server, script, turns, subject, log):
    home, env = server
    del env["CHARTPIPE_ENV"]
    assert subprocess.run(["bash", str(home / "deploy" / script)], env=env).returncode == 0
    assert f"--env-file {home}/r2.env -v {home}/work:/work " in (home / "runs").read_text()
    assert (home / log).exists() and not (home / "alerts").exists()


@pytest.mark.parametrize("script, turns, subject, log", JOBS)
def test_a_failing_job_alerts_with_a_subject_and_a_detail_and_exits_as_the_job_did(
        server, last_alert, script, turns, subject, log):
    home, env = server
    assert [done.returncode for done in fail(home, env, script, turns)] == [7] * turns
    assert (home / "alerts").read_text().count("alert") == 1
    assert last_alert() == [subject, "two\nthree\nfour"]


@pytest.mark.parametrize("script, turns, subject, log", JOBS)
def test_with_no_alert_command_a_failing_job_exits_the_same_and_complains_about_nothing(
        server, script, turns, subject, log):
    home, env = server
    del env["CHARTPIPE_NOTIFY"]
    turned = fail(home, env, script, turns)
    assert [(done.returncode, done.stderr) for done in turned] == [(7, "")] * turns
    assert not (home / "alerts").exists()


@pytest.mark.parametrize("script, turns, subject, log", JOBS)
def test_a_site_file_beside_the_script_sets_the_folder_the_env_file_and_the_alert_command(
        server, last_alert, script, turns, subject, log):
    home, env = server
    site = home / "site"
    # The environment still names the other folder and a plain notify: the site file wins.
    (home / "deploy" / "site.env").write_text(
        f'CHARTPIPE_HOME={site}\nCHARTPIPE_ENV={home}/keys.env\nCHARTPIPE_NOTIFY="{home}/bin/notify --loud"\n')
    assert fail(home, env, script, turns)[-1].returncode == 7
    assert f"--env-file {home}/keys.env -v {site}/work:/work " in (home / "runs").read_text()
    assert (site / log).read_text() == SAID and not (home / log).exists()
    assert last_alert() == ["--loud", subject, "two\nthree\nfour"]


@pytest.mark.parametrize("script", ["run.sh", "nav-run.sh", "tpp-run.sh"])
def test_a_build_leaves_quietly_while_another_build_runs(server, script):
    home, env = server
    assert "docker ps -q --filter name=chartpipe)" in (DEPLOY / script).read_text()
    (home / "docker-ps").write_text("0123abcd\n")
    (home / "docker-exit").write_text("7")
    assert subprocess.run(["bash", str(home / "deploy" / script)], env=env).returncode == 0
    assert not (home / "runs").exists() and not (home / "alerts").exists()


def test_the_schedule_runs_the_chart_build_once_a_day():
    jobs = [line for line in (DEPLOY / "chartpipe.cron").read_text().splitlines()
            if line and not line.startswith("#")]
    assert jobs == ["0 5 * * * bash /srv/chartpipe/deploy/run.sh"]


def test_the_plates_job_drops_its_downloads_only_after_a_good_run(server):
    home, env = server
    pdfs = home / "work" / "tpp" / "pdf"
    pdfs.mkdir(parents=True)
    fail(home, env, "tpp-run.sh", 1)
    assert pdfs.exists()
    (home / "docker-exit").write_text("0")
    assert subprocess.run(["bash", str(home / "deploy" / "tpp-run.sh")], env=env).returncode == 0
    assert not (home / "work" / "tpp").exists()


def test_every_script_parses_and_the_example_lists_every_setting():
    for script in ("run.sh", "nav-run.sh", "wx-run.sh", "tpp-run.sh", "watch.sh", "remote.sh"):
        assert subprocess.run(["bash", "-n", str(DEPLOY / script)]).returncode == 0
    example = (DEPLOY / "site.env.example").read_text()
    for setting in ("CHARTPIPE_HOME=/srv/chartpipe", "CHARTPIPE_ENV=/srv/chartpipe/r2.env", "CHARTPIPE_NOTIFY=",
                    "CHARTPIPE_PUBLIC_URL=", "CHARTPIPE_HOST=", "CHARTPIPE_REMOTE_HOME=/srv/chartpipe",
                    "CHARTPIPE_REMOTE_ENV=/srv/chartpipe/r2.env"):
        assert setting in example
    ignored = (DEPLOY.parent.parent / ".gitignore").read_text().splitlines()
    assert "pipeline/deploy/site.env" in ignored


def test_the_sync_script_uses_the_default_server_folder_until_told_another(tmp_path):
    root = tmp_path / "pipeline"
    (root / "deploy").mkdir(parents=True)
    shutil.copy(DEPLOY / "remote.sh", root / "deploy")
    for folder in ("chartpipe", "navpipe", "tppipe", "wxpipe", "tests"):
        (root / folder).mkdir()
    for name in ("Dockerfile", "requirements.txt"):
        (root / name).write_text("")
    tools = tmp_path / "bin"
    tools.mkdir()
    # A stand-in ssh: keeps each command and the names in the archive it is sent.
    (tools / "ssh").write_text(
        f'#!/bin/bash\necho "$*" >> "{tmp_path}/ssh"\ntar -tzf - >> "{tmp_path}/sent" 2>/dev/null\nexit 0\n')
    (tools / "ssh").chmod(0o755)
    bare = {key: value for key, value in os.environ.items() if not key.startswith("CHARTPIPE_")}
    bare["PATH"] = f"{tools}:{bare['PATH']}"

    def publish(**settings):
        for record in ("ssh", "sent"):
            (tmp_path / record).unlink(missing_ok=True)
        done = subprocess.run(["bash", str(root / "deploy" / "remote.sh"), "publish", "--all"],
                              env={**bare, **settings}, stdin=subprocess.DEVNULL, capture_output=True, text=True)
        said = (tmp_path / "ssh").read_text().splitlines() if (tmp_path / "ssh").exists() else []
        return done, said

    done, said = publish()
    assert done.returncode != 0 and "CHARTPIPE_HOST" in done.stderr and said == []

    done, said = publish(CHARTPIPE_HOST="box")
    assert done.returncode == 0 and len(said) == 2
    assert said[0].startswith("box mkdir -p /srv/chartpipe/src /srv/chartpipe/work && ")
    assert "--name chartpipe-manual " in said[1]
    assert said[1].endswith(" --env-file /srv/chartpipe/r2.env -v /srv/chartpipe/work:/work chartpipe --all")
    sent = sorted(line.rstrip("/") for line in (tmp_path / "sent").read_text().splitlines())
    assert sent == ["Dockerfile", "chartpipe", "navpipe", "requirements.txt", "tests", "tppipe", "wxpipe"]

    done, said = publish(CHARTPIPE_HOST="box", CHARTPIPE_REMOTE_HOME="/data/charts")
    assert said[1].endswith(" --env-file /data/charts/r2.env -v /data/charts/work:/work chartpipe --all")

    (root / "deploy" / "site.env").write_text(
        "CHARTPIPE_HOST=other\nCHARTPIPE_REMOTE_HOME=/data/site\nCHARTPIPE_REMOTE_ENV=/keys/site.env\n")
    done, said = publish(CHARTPIPE_HOST="box", CHARTPIPE_REMOTE_HOME="/data/charts")
    assert said[0].startswith("other mkdir -p /data/site/src /data/site/work && ")
    assert said[1].endswith(" --env-file /keys/site.env -v /data/site/work:/work chartpipe --all")


@pytest.mark.parametrize("script", ["run.sh", "nav-run.sh", "wx-run.sh", "tpp-run.sh", "watch.sh"])
def test_a_site_file_that_cannot_be_read_stops_the_job_before_it_runs_anything(server, script):
    home, env = server
    # An unclosed quote: the shell cannot load it.
    (home / "deploy" / "site.env").write_text('CHARTPIPE_HOME="/somewhere\n')
    done = subprocess.run(["bash", str(home / "deploy" / script)], env=env, capture_output=True, text=True)
    assert done.returncode == 78
    assert not (home / "runs").exists()


def test_a_production_build_sends_the_last_commit_and_refuses_uncommitted_changes(tmp_path):
    if shutil.which("git") is None:
        pytest.skip("needs git")
    root = tmp_path / "repo" / "pipeline"
    (root / "deploy").mkdir(parents=True)
    shutil.copy(DEPLOY / "remote.sh", root / "deploy")
    for folder in ("chartpipe", "navpipe", "tppipe", "wxpipe", "tests"):
        (root / folder).mkdir()
        (root / folder / "__init__.py").write_text("")
    for name in ("Dockerfile", "requirements.txt"):
        (root / name).write_text("")
    (root / ".gitignore").write_text("*.pyc\n")
    who = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
    for args in (["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "one"]):
        subprocess.run(["git", "-C", str(root.parent), *args], check=True, capture_output=True, env={**os.environ, **who})
    tools, got = tmp_path / "bin", tmp_path / "got"
    tools.mkdir()
    # A stand-in ssh: keeps each command and unpacks the archive it is sent.
    (tools / "ssh").write_text(f'#!/bin/bash\necho "$*" >> "{tmp_path}/ssh"\n'
                               f'case "$*" in *"tar -xzf"*) mkdir -p "{got}" && tar -xzf - -C "{got}" ;; esac\nexit 0\n')
    (tools / "ssh").chmod(0o755)
    bare = {key: value for key, value in os.environ.items() if not key.startswith("CHARTPIPE_")}
    bare.update(PATH=f"{tools}:{bare['PATH']}", CHARTPIPE_HOST="box")

    def build(**settings):
        (tmp_path / "ssh").unlink(missing_ok=True)
        shutil.rmtree(got, ignore_errors=True)
        done = subprocess.run(["bash", str(root / "deploy" / "remote.sh"), "build"], env={**bare, **settings},
                              stdin=subprocess.DEVNULL, capture_output=True, text=True)
        return done, (tmp_path / "ssh").read_text().splitlines() if (tmp_path / "ssh").exists() else []

    (root / "wxpipe" / "__init__.py").write_text("edited")
    done, said = build()
    assert done.returncode == 2 and "uncommitted" in done.stderr and said == []
    done, said = build(CHARTPIPE_DEV="1")
    assert done.returncode == 0 and said[-1].endswith("docker build -q -t chartpipe-dev .")
    assert (got / "wxpipe" / "__init__.py").read_text() == "edited"
    (root / "wxpipe" / "__init__.py").write_text("")
    (root / "wxpipe" / "stray.pyc").write_text("never committed")
    done, said = build()
    assert done.returncode == 0 and said[-1].endswith("docker build -q -t chartpipe .")
    assert sorted(p.name for p in got.iterdir()) == ["Dockerfile", "chartpipe", "navpipe", "requirements.txt",
                                                     "tests", "tppipe", "wxpipe"]
    assert not (got / "wxpipe" / "stray.pyc").exists()
