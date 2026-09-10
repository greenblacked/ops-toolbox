- `changelog.d/changelog.sh preview` printed two lines and exited 141. Its
  preamble reader exited at the first `###` heading while the writer was
  still pushing the section body into the pipe, so the writer died of SIGPIPE,
  `pipefail` promoted it, and `set -e` aborted the script with no message. The
  section only had to outgrow one pipe buffer, which it already had. It reads
  all of its input now.
