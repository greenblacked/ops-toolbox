# Pull request

## What changed

<!-- One or two sentences. What does this add or fix, and for which package? -->

## Which suites did you run

<!-- Delete the ones you did not run. CI runs the same ./run-tests.sh. -->

- [ ] `./run-tests.sh` (git + macos + linux + k8s + python + static + windows)
- [ ] `LINUX_DISTROS=all ./run-tests.sh linux`
- [ ] `./run-tests.sh windows`
- [ ] `./run-tests.sh k8s`
- [ ] `./run-tests.sh all` (adds the RouterOS CHR suite)
- [ ] Not applicable — documentation only

## Dry-run output

<!--
For a new or changed script that touches a machine, paste its --dry-run output.
A dry run must write nothing; that is the promise this repository makes.
-->

```text

```

## Checklist

- [ ] `--help` works and exits 0, before any preflight check
- [ ] An unknown flag exits 3
- [ ] Running it twice is safe and produces the same result
- [ ] Anything destructive is behind an explicit opt-in flag
- [ ] The folder README and the root README were updated
