---
hide:
  - toc
---

<!-- markdownlint-disable MD033 -->
<!-- markdownlint-disable-next-line MD026 -->
# Find the right script. See what it changes first. { .rpt-title }

<div class="rpt-hero" markdown>

<div class="rpt-rule" aria-hidden="true"></div>

<p class="rpt-lede">Practical tools for macOS, Linux, Windows, Git, MikroTik,
Kubernetes and dotfiles. Start with a task, inspect the report, then decide
whether to make a change.</p>

<div class="rpt-home-search">

<button type="button" class="rpt-search-trigger" data-rpt-open-search
        aria-label="Open documentation search">
  <span class="rpt-search-icon" aria-hidden="true">⌕</span>
  <span>Search scripts, commands and runbooks</span>
  <span class="rpt-search-hint" aria-hidden="true">Search ↗</span>
</button>

</div>

<div class="rpt-actions" markdown>

[Browse every script](scripts/index.md){ .md-button .md-button--primary }
[Quick start](getting-started/quick-start.md){ .md-button }

</div>

</div>

## Start with a task

<div class="rpt-task-grid">

<a class="rpt-task-link" href="runbooks/linux-low-disk/">
  <span class="rpt-task-eyebrow">Investigate</span>
  <strong>Recover disk space</strong>
  <span>Find the cause before cleaning Linux or Windows.</span>
</a>

<a class="rpt-task-link" href="runbooks/linux-network-unreachable/">
  <span class="rpt-task-eyebrow">Diagnose</span>
  <strong>Fix a network issue</strong>
  <span>Trace interfaces, routes and DNS step by step.</span>
</a>

<a class="rpt-task-link" href="platforms/mikrotik/">
  <span class="rpt-task-eyebrow">Monitor</span>
  <strong>Check a MikroTik router</strong>
  <span>Backups, audits and alerts, plus version compatibility.</span>
</a>

<a class="rpt-task-link" href="runbooks/kubernetes-unhealthy-pods/">
  <span class="rpt-task-eyebrow">Troubleshoot</span>
  <strong>Inspect unhealthy pods</strong>
  <span>Check cluster context, then triage workloads safely.</span>
</a>

</div>

## Choose a platform

<nav class="rpt-platform-links" aria-label="Browse tools by platform">
  <a href="platforms/macos/">macOS</a>
  <a href="platforms/linux/">Linux</a>
  <a href="platforms/windows/">Windows</a>
  <a href="platforms/git/">Git</a>
  <a href="platforms/mikrotik/">MikroTik</a>
  <a href="platforms/kubernetes/">Kubernetes</a>
  <a href="platforms/dotfiles/">Dotfiles</a>
</nav>

## Report → Preview → Apply

Most changes should start with a read-only report and a preview. This example
uses the shipped `macos_defaults.sh` script from the
`macos-initial-setup/` directory. Each command has a distinct safety
contract.

<div class="rpt-stages" markdown>

<div class="rpt-stage rpt-stage--report" markdown>
<span class="stage stage-report">1 · Report · read-only</span>

Inspect the current macOS settings without changing them.

```{ .bash .rpt-report title="Report" }
./macos_defaults.sh
```

<p class="rpt-command-meta"><strong>Requires:</strong> macOS and a local shell.<br>
<strong>Changes:</strong> none.<br>
<strong>Rollback:</strong> not needed.</p>

</div>

<div class="rpt-stage rpt-stage--preview" markdown>
<span class="stage stage-preview">2 · Preview · dry run</span>

Print what applying the defaults would do before deciding.

```{ .bash .rpt-preview title="Preview" }
./macos_defaults.sh --apply --dry-run
```

<p class="rpt-command-meta"><strong>Requires:</strong> same host and script.<br>
<strong>Changes:</strong> none; commands are printed.<br>
<strong>Rollback:</strong> not needed.</p>

</div>

<div class="rpt-stage rpt-stage--apply" markdown>
<span class="stage stage-apply">3 · Apply · modifies state</span>

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

The MikroTik test suite boots a verified CHR image and checks script/API
behavior before a candidate RouterOS release is proposed. It **does not**
test physical Wi-Fi, switch silicon or RouterBOOT.

[See version pins, latest recorded results and hardware limits](platforms/routeros-compatibility.md){ .md-button }

## About this toolkit

The scripts are small, reviewable and intended to be used individually.
[Read the principles](getting-started/philosophy.md), browse
[runbooks](runbooks/index.md), or inspect the
[GitHub repository](https://github.com/greenblacked/ops-toolbox).

!!! warning "Test before you trust"
    CI validates the repository in supported test environments. It cannot
    verify your actual workstation, router or cluster. Review the report,
    preview and rollback path before applying anything.

<!-- markdownlint-enable MD033 -->
