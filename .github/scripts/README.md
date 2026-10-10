# Workflow scripts

[Ops Toolbox](../../README.md) / **Workflow scripts**

Helpers that the GitHub Actions workflows run with `bash`. They are not
command-line tools: they read their input from environment variables set by
the workflow, so they have no `--help` and are not executable.

## `stage-stale.sh`

Decides whether a stage deploy is stale, that is, whether the stage address
already serves a commit that includes the build's own. `docs.yml` runs it
twice: in the `check-stage` job and again in the `deploy` job. It writes
`stale=true` or `stale=false` to `GITHUB_OUTPUT`. See
[Deployment](../../docs/contributing/deployment.md).
