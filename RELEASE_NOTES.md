# CodeEdit v0.4.0 — Community Bug-Fix Release

> Based on upstream `main` @ `cec6287a` (2026-07), which already contains everything shipped since v0.3.6 (2025-08-26).
> This release adds 6 verified bug fixes for long-standing open issues, produced and cross-verified by an agentic fix/verify/audit pipeline.

## Bug Fixes

### Source Control

- **Git commands no longer pick up shell-profile output** ([#2151]) — `8e0c2dea`
  Git plumbing (branch detection, status, config) now runs through `zsh -c` instead of a login-interactive shell (`zsh -lic`), so `echo` statements in `.zprofile`/`.zshrc` can no longer pollute parsed git output (e.g. the branch name shown in the toolbar). LSP package managers keep the login shell so they still see your profile `PATH`.

- **"Discard All Changes" now actually discards everything** ([#1786]) — `52e2dc90`
  Previously only unstaged tracked edits were reverted. Now: staged changes are unstaged and restored (`git restore --staged .` + `git restore .`), and untracked files are moved to the **Trash** (recoverable, GitHub-Desktop-style) instead of being left behind. Per-file discard correctly distinguishes untracked vs tracked files, and failures surface as alerts instead of being silently ignored.

### Stability

- **Fixed crash when submitting a bug report / feedback without a GitHub account** ([#2174]) — `bb183f40`
  The feedback form force-unwrapped the first configured GitHub account. With no account (or a stale keychain token) the app crashed. It now falls back to opening a pre-filled GitHub "new issue" page in your browser.

### Project Navigator

- **New files/folders start in inline rename mode** ([#2029], also covers [#1595]) — `c25c0761`
  Creating a file or folder from the context menu or the toolbar "+" button now immediately selects the name for editing, matching Finder/Xcode behavior, instead of silently creating "untitled".

### Search / Navigation

- **Quick Open honors Settings → Search glob exclusions** ([#1824]) — `17cd11d0`
  `⌘⇧O` results now filter out files matching your ignore patterns (e.g. `node_modules`, `*.log`), using `fnmatch` semantics: slash-free patterns match at any depth (including whole subtrees), slash patterns anchor to the workspace root.

### Terminal

- **Terminal font & size changes apply immediately** ([#2143]) — `6d480f0e`
  Changing the terminal font in Settings now updates open terminals live (font was the only appearance property not re-applied on settings changes; everything else — colors, cursor, appearance — already was).

## Verification

Each fix was implemented by a dedicated agent and reviewed by an independent verifier agent (adversarial review: full-diff + surrounding-context read, call-site regression scan, issue-scope check, `swiftc -parse` on every changed file; `#1824`'s glob matcher additionally validated by a compiled 22-case test harness; `#2143`'s SwiftTerm behavior verified against the pinned fork revision). A final fully independent auditor then re-checked all six fixes together: **no blocking findings** — 2× PASS, 4× PASS-WITH-NOTES, all 14 changed files syntax-clean, cross-fix interactions verified (including independently reproducing and clearing a potential path-resolution hazard in the `#1786` trash step).

**Limitation:** this machine has no Xcode.app (Command Line Tools only), so the branch could not be compiled into a runnable app here. All verification is static (syntax + deep code review). Building `CodeEdit.xcodeproj` with Xcode is the remaining step before distributing binaries.

[#2151]: https://github.com/CodeEditApp/CodeEdit/issues/2151
[#1786]: https://github.com/CodeEditApp/CodeEdit/issues/1786
[#2174]: https://github.com/CodeEditApp/CodeEdit/issues/2174
[#2029]: https://github.com/CodeEditApp/CodeEdit/issues/2029
[#1595]: https://github.com/CodeEditApp/CodeEdit/issues/1595
[#1824]: https://github.com/CodeEditApp/CodeEdit/issues/1824
[#2143]: https://github.com/CodeEditApp/CodeEdit/issues/2143
