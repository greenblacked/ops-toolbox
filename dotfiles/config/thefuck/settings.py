# thefuck. Read from ~/.config/thefuck/settings.py; every setting also has
# a THEFUCK_* environment variable. Defaults from thefuck/const.py of 3.32.
#
# thefuck itself has had no release since 2022 and does not import on
# Python 3.12+ (it uses the removed imp module). It runs under a 3.11 tool
# environment - `uv tool install thefuck --python 3.11` - or can be swapped
# for pay-respects, which reads no config. This file is harmless either way.
from thefuck.const import DEFAULT_RULES

# Keep the prompt. The corrected command may be `sudo rm`, a force push or
# a `kubectl delete`; Enter runs it and Ctrl-C does not.
require_confirmation = True

# Seconds to wait when re-running the failed command to read its output.
# The default 3 is too short for kubectl, gcloud or aws against a slow API.
wait_command = 8
wait_slow_command = 30
slow_commands = [
    "lein", "react-native", "gradle", "./gradlew", "vagrant",
    "terraform", "tofu", "terragrunt", "helm", "kubectl", "gcloud", "aws",
    "docker", "docker-compose", "mvn", "go",
]

# All bundled rules, minus the ones that are dangerous for an ops shell.
rules = DEFAULT_RULES
exclude_rules = [
    "rm_root",           # never let a tool "fix" an rm on /
    "git_push_force",    # --force-with-lease is typed on purpose or not at all
    "sudo",              # auto-prepending sudo hides a permissions mistake
]

# Lower is tried first; the default is 1000. Typo correction is the common
# case and cheap.
priority = {
    "git_branch_exists": 100,
    "git_checkout": 200,
    "no_command": 900,
}

# Only the recent history is searched for the failed command.
history_limit = 5000
# Replace the failed command in shell history with the fixed one.
alter_history = True
num_close_matches = 5
# Skip slow mounts when searching PATH for candidates.
excluded_search_path_prefixes = ["/Volumes/", "/mnt/"]
