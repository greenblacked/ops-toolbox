# Review: REA (Reverse Engineer Anything)

[Ops Toolbox](../../README.md) / [AI tooling notes](../README.md) / **REA**

**Status:** conditional adopt for authorized reverse-engineering and malware
analysis workflows  
**Reviewed:** 2026-10-26  
**Official sources only:**
[github.com/morluto/rea](https://github.com/morluto/rea),
[rea.tools](https://rea.tools/), npm package
[`rea-agents`](https://www.npmjs.com/package/rea-agents)

## Summary

REA is an MIT-licensed local CLI and MCP server that lets coding agents
inspect software without source by driving existing reverse-engineering and
inspection tools. It does not decompile on its own: it wraps providers such as
Ghidra, Hopper, IDA, JADX, and built-in static inspectors, and returns
evidence-backed findings (pseudocode, assembly, module maps, call
relationships) with explicit limits on what was proven.

For Staff DevOps / Platform work it is useful as an **agent bridge** into a
local analysis toolchain, not as a replacement for Ghidra/IDA expertise or a
safe sandbox for untrusted binaries.

## What it is

| Aspect | Detail |
| --- | --- |
| Distribution | npm `rea-agents`; MCP registry id `io.github.morluto/rea` |
| Runtime | Node.js 22.x (≥22.23.4), 24.x (≥24.22.1), or 26.12.1+; npm |
| Interfaces | MCP for agents (Claude Code, Codex, Cursor, Gemini CLI, and others); CLI (`npx rea-agents …` or global `rea`) |
| Execution model | Local only; results go to the connected agent (subject to that agent's model-provider policy) |
| Native deep analysis | Requires a local Hopper, Ghidra, or IDA install (and a legal license for commercial tools) |
| Lighter targets | Static JavaScript/Electron, .NET metadata, many artifact formats, and other inspectors work without a native decompiler |

Primary project docs: [README](https://github.com/morluto/rea/blob/main/README.md),
[DISCLAIMER.md](https://github.com/morluto/rea/blob/main/DISCLAIMER.md),
[SECURITY.md](https://github.com/morluto/rea/blob/main/SECURITY.md).

## How it works

1. You install or invoke `rea-agents` and run `npx rea-agents setup` (or pin a
   version and register MCP manually).
2. Setup proposes MCP registration and matching investigation instructions for
   selected agents; you review and approve before config changes apply.
3. The agent (or CLI) asks REA to open a **local** target path.
4. REA selects a provider or built-in inspector, runs analysis with your OS
   user permissions, and returns structured findings plus evidence and
   unknowns.
5. The agent uses those findings to explain behavior or to implement a
   separate reconstruction; REA output is not original source code.

Hopper/Ghidra bridges use per-session capability tokens and private IPC
(Unix sockets on POSIX; authenticated loopback TCP with a user-scoped DACL on
Windows Ghidra). That authenticates the bridge process; it is **not** a
sandbox.

## Strengths

- **Evidence-oriented contract.** Results are expected to carry references and
  stated limitations, which fits audit and handoff better than opaque agent
  guesses.
- **Broad target surface.** Native binaries, JS/Electron, .NET, APKs,
  firmware handoffs, model artifacts, captures, and more through one CLI/MCP
  surface (requirements vary by target).
- **Fits existing agent workflows.** One setup path for several coding
  agents; CLI available for scripting and CI-adjacent labs.
- **Local analysis path.** Targets are not uploaded by REA itself; trust then
  shifts to your agent/model provider and any network the target process opens
  if you run it.
- **Explicit lawful-use stance.** Project disclaimer and community policy
  reject DRM circumvention, cheats, unauthorized access, and similar abuse.

## Risks and mitigations

| Risk | Why it matters | Mitigation |
| --- | --- | --- |
| **Supply-chain / impostor packages** | High visibility attracted fake repos and packages that can ship malware. A similar name or copied README is not proof of authenticity. | Install only from [morluto/rea](https://github.com/morluto/rea), [rea.tools](https://rea.tools/), or npm `rea-agents`. Pin exact versions in durable MCP configs. Prefer checksum/provenance checks for any third-party installer. |
| **Not a sandbox** | Opening an untrusted binary delegates parsing and analysis to Ghidra/Hopper/IDA/JADX/etc. with the current user's permissions. Malicious same-user processes are out of scope. | Analyze untrusted samples in an isolated VM or dedicated lab account. Do not point REA at production workstations that hold secrets. |
| **Runtime and device workflows** | Some flows execute or observe programs, browsers, network captures, or attached devices. Authorization to *read* a file is not authorization to *run* or intercept. | Prefer static inspection first. Review agent plans before approve. Use disposable environments for dynamic work. |
| **Legal / license exposure** | Reverse engineering and tool licenses are jurisdiction- and contract-specific. Commercial engines (IDA, Hopper, JEB) need separate, lawful licenses; cracked tools are explicitly out of bounds. | Restrict use to owned or authorized targets. Keep written authorization for third-party software. Do not bypass vendor license checks. |
| **Incomplete or wrong reconstruction** | Decompilation and heuristics can miss obfuscation, packers, and control-flow tricks. Agents may over-claim. | Treat outputs as leads. Verify consequential conclusions against evidence. Do not ship reconstructed logic without review. |
| **Agent config and skill writes** | Setup modifies agent MCP config and may install workflow instructions; optional Hopper install can involve package managers as root/`pkexec`. | Always review the setup plan. Back up configs (setup claims to). Run first installs on a throwaway profile. |
| **Data leaving the host via the agent** | REA stays local; the coding agent may still send tool results to a cloud model. | Use local/offline agents for sensitive binaries, or redact paths and strip secrets from sessions. |

## Recommended use cases

- Malware triage and incident analysis on **authorized** samples in a lab VM.
- Interoperability and debugging of software you own or are contracted to
  examine.
- Security research and coordinated disclosure under an agreed scope.
- Education / CTF labs where the binary is intended for analysis.
- Platform engineering reviews of internal Electron/desktop packaging,
  certificate/import layouts, or crash dumps when source is unavailable.

## What to avoid

- DRM, license-check, or anti-cheat circumvention.
- Game cheats, unauthorized online-service tampering, or access-control
  bypass on systems you are not authorized to test.
- Copying proprietary code or assets into products based only on REA output.
- Installing from unofficial mirrors, Telegram “releases”, or renamed forks.
- Running untrusted binaries through REA on a daily-driver machine with
  production credentials, browser profiles, or SSH keys.
- Treating pseudocode as redistributable original source.

## Setup notes (ops view)

```bash
# Prerequisites: supported Node.js + npm; optional Hopper/Ghidra/IDA/JADX
# for the targets you care about.
npx rea-agents@latest setup
```

- Review the proposed MCP and skill changes; restart the agent afterward.
- For durable registrations, pin an exact `rea-agents` version (setup does
  this when it writes config).
- Linux: some workflows need a procps-compatible `ps` on `PATH` (see upstream
  installation docs).
- Native analysis: configure `GHIDRA_INSTALL_DIR` / provider docs as needed;
  raise startup timeouts for large binaries if required
  (`REA_GHIDRA_STARTUP_TIMEOUT_MS`, `REA_HOPPER_STARTUP_TIMEOUT_MS`).
- Keep REA updated (`rea update` for global installs, or re-run
  `npx rea-agents@latest setup`).
- Report vulnerabilities privately per upstream
  [SECURITY.md](https://github.com/morluto/rea/blob/main/SECURITY.md); do not
  paste private binaries or project files into public issues.

## Recommendation

**Conditional adopt** for teams that already run a reverse-engineering lab and
need agent-assisted investigation of **authorized** targets.

Adopt when:

- You have a clear authorization model and an isolated analysis environment.
- You will pin official `rea-agents` releases and treat impostor packages as a
  first-class threat.
- Operators understand that REA amplifies local tools; it does not replace
  them or contain malware.

Defer or refuse when:

- The ask is DRM/cheat/unauthorized access adjacent.
- There is no isolation plan for untrusted binaries.
- The only available package source is unofficial.

Ops Toolbox does not vendor or install REA. This review is guidance only;
follow upstream DISCLAIMER and SECURITY documents and your legal counsel for
production policy.
