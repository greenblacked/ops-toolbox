- `git_ssh_doctor.py`, `git_signing_doctor.py`, `git_remote_doctor.py` and
  `git_ignore_doctor.py` take `--json`. Each prints one JSON object with the
  exit code and every finding (level, section, message), so CI can keep the
  diagnosis that `--quiet` throws away and attach it to a job summary. Exit
  codes are unchanged, every line is recorded after the doctor's redaction so
  a token in a URL never reaches the JSON, and `--json` with `--quiet` is a
  usage error.
