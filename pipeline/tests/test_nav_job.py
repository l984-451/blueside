import subprocess
from pathlib import Path

SERVER = Path(__file__).parent.parent / "deploy"


def test_the_daily_job_is_capped_and_alerts_on_failure():
    script = (SERVER / "nav-run.sh").read_text()
    for part in ("--cpus=12", "--cpu-shares=512", "--memory=24g", "--name chartpipe-nav", "--env-file",
                 "--entrypoint python3 chartpipe -m navpipe --work /work/nav",
                 '$CHARTPIPE_NOTIFY "Nav pipeline failed"'):
        assert part in script
    assert subprocess.run(["bash", "-n", str(SERVER / "nav-run.sh")]).returncode == 0


def test_the_schedule_runs_the_daily_job_once_a_day():
    jobs = [line for line in (SERVER / "chartpipe-nav.cron").read_text().splitlines()
            if line and not line.startswith("#")]
    assert jobs == ["0 4 * * * bash /srv/chartpipe/deploy/nav-run.sh"]
