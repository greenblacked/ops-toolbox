- `linux/status.sh` asked systemd about `stay-fresh.timer`, a unit nothing
  installs. `systemd/stay_fresh_timer.sh` sets `NAME="ops-toolbox-stay-fresh"`
  and builds every unit path and `systemctl` call from it, so the section could
  never reach its ok branch: on a machine with the timer installed, enabled and
  running it told you to install the thing that was already installed. The
  branch is `info` rather than `warn`, so it moved no exit code and no test
  noticed.
