---
hide:
  - toc
---

<!-- markdownlint-disable MD033 -->
# Scripts and runbooks { #find-the-right-script-for-the-job .rpt-title }

<div class="rpt-hero" markdown="1">

<p class="rpt-lede">Maintenance and troubleshooting for macOS, Linux,
Windows, Git, MikroTik and Kubernetes.</p>

<div class="rpt-actions rpt-home-actions" markdown="1">

[Browse scripts](scripts/index.md){ .md-button .md-button--primary }
[Quick start](getting-started/quick-start.md){ .md-button }

<div class="rpt-home-search" hidden>
  <button type="button" class="md-button rpt-search-trigger" data-rpt-open-search>
    Search docs
  </button>
</div>

</div>

</div>

## Start with a task

<div class="rpt-task-grid" markdown="1">

<div class="rpt-task-card" markdown="1">

### Recover disk space

Identify what is using storage before choosing a cleanup command.

[Linux disk space](runbooks/linux-low-disk.md)
[Windows disk space](runbooks/windows-low-disk.md)

</div>

<div class="rpt-task-card" markdown="1">

### Diagnose a network issue

Check interfaces, routes and DNS when a Linux host cannot connect.

[Linux network runbook](runbooks/linux-network-unreachable.md)

</div>

<div class="rpt-task-card" markdown="1">

### Check a MikroTik router

Find health checks, backups, alerts and tested RouterOS versions.

[MikroTik guide](platforms/mikrotik.md)
[RouterOS compatibility](platforms/routeros-compatibility.md)

</div>

<div class="rpt-task-card" markdown="1">

### Inspect unhealthy pods

Confirm your Kubernetes context, then check events, logs and restarts.

[Kubernetes pod runbook](runbooks/kubernetes-unhealthy-pods.md)

</div>

</div>

[View all runbooks](runbooks/index.md)

## Choose a platform { #choose-a-platform }

<nav class="rpt-platform-links" aria-labelledby="choose-a-platform" markdown="1">

- [macOS](platforms/macos.md)
- [Linux](platforms/linux.md)
- [Windows](platforms/windows.md)
- [Git](platforms/git.md)
- [MikroTik](platforms/mikrotik.md)
- [Kubernetes](platforms/kubernetes.md)
- [Dotfiles](platforms/dotfiles.md)

</nav>

## Report → Preview → Apply

Most changes should start with a read-only report and a preview. This example
uses the shipped `macos_defaults.sh` script from the
`macos-initial-setup/` directory of a local checkout.

<div class="rpt-stages" markdown>

<div class="rpt-stage rpt-stage--report" markdown>
<span class="stage stage-report">Report · read-only</span>

Inspect the current macOS settings without changing them.

```{ .bash .rpt-report title="Report" }
./macos_defaults.sh
```

<p class="rpt-command-meta"><strong>Requires:</strong> macOS and a local shell.<br>
<strong>Changes:</strong> none.<br>
<strong>Rollback:</strong> not needed.</p>

</div>

<div class="rpt-stage rpt-stage--preview" markdown>
<span class="stage stage-preview">Preview · dry run</span>

Print what applying the defaults would do before deciding.

```{ .bash .rpt-preview title="Preview" }
./macos_defaults.sh --apply --dry-run
```

<p class="rpt-command-meta"><strong>Requires:</strong> same host and script.<br>
<strong>Changes:</strong> none; commands are printed.<br>
<strong>Rollback:</strong> not needed.</p>

</div>

<div class="rpt-stage rpt-stage--apply" markdown>
<span class="stage stage-apply">Apply · modifies state</span>

Apply the reviewed settings. The script saves previous values.

```{ .bash .rpt-apply title="Apply" }
./macos_defaults.sh --apply
```

<p class="rpt-command-meta"><strong>Requires:</strong> a reviewed preview.<br>
<strong>Changes:</strong> macOS preferences; previous values backed up.<br>
<strong>Rollback:</strong> <code>./macos_defaults.sh --revert</code>.</p>

</div>

</div>

[Read the full execution guide](getting-started/quick-start.md) and check
each script's own flags. A dry run only covers what that script documents.

## RouterOS compatibility

The CHR suite checks script and API behavior in a virtual router. For tested
versions and physical hardware limits, see the
[RouterOS compatibility guide](platforms/routeros-compatibility.md).

## About this toolkit

The scripts are small, reviewable and intended to be used individually.
[Read the principles](getting-started/philosophy.md) or inspect the
[GitHub repository](https://github.com/greenblacked/ops-toolbox).

<!-- markdownlint-enable MD033 -->
