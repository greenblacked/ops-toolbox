- `test-env/static/check_pin_age.sh` fails CI when a Dependabot-unwatched
  pin file (`k8s-toolbox/versions.env`, `.github/ci-tool-checksums.env`,
  `mikrotik/tests/routeros-version.env`) has no `# last-reviewed:
  YYYY-MM-DD` stamp, or that date is older than 90 days.
