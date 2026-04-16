# Patches (post-install only after branch-workflow migration)

**As of 2026-04-16 the source-patch workflow is retired.** Customizations live as commits on the `pix/main` branch in the fork (`aliceisjustplaying/piclaw`). This directory now only contains:

- `post-install/` — shell scripts applied after `bun install` to patch *dependencies* (not PiClaw source). These stay active; see `piclaw-update.sh` → `apply_post_install_patches`.
- `archive/` — historical source patches (`01-*.patch` through `62-*.patch`) plus their retired siblings, the old manifest, and the verify/audit/watch tooling. Kept for history and blame-trace. **Do not edit or apply these — they are informational only.**

## How customizations work now

Fork: `https://github.com/aliceisjustplaying/piclaw.git`
Customization branch: `pix/main`
Upstream: `https://github.com/rcarmo/piclaw.git` → `main`

Every customization is a commit on `pix/main` on top of upstream `main`. The deployment path (`scripts/piclaw-update.sh`) clones `pix/main` directly and builds from it — no more `git apply` step.

### Common operations

```bash
# See the customization set (commits ahead of upstream main):
cd /workspace/src/piclaw-fork
git fetch upstream
git log upstream/main..pix/main --oneline

# Drop a merged-upstream customization:
git rebase -i upstream/main   # delete the subsumed commit

# Add a new customization:
git checkout pix/main
# ...make changes, commit...
git push origin pix/main

# Stage an upstream PR:
git checkout -b upstream-ready/NN-short-name pix/main
# rebase / cherry-pick / force-push to the upstream-ready branch
# open the PR on GitHub against rcarmo/piclaw main
```

### Auditing vs. upstream

Instead of `./patches/audit-upstream.sh`, use plain git:

```bash
cd /workspace/src/piclaw-fork
git fetch upstream
git log upstream/main..pix/main --oneline   # what we carry
git log pix/main..upstream/main --oneline   # what upstream has that we don't (for rebase planning)
```

### Regression check

`scripts/piclaw-ci-check.sh` runs the patch-area test suite and filters pre-existing baseline failures. Run it before pushing to `pix/main` and before deploying.

## Post-install patches (still active)

Applied after `bun install` to patch dependencies.

| # | Script | Purpose |
|---|--------|---------|
| 01 | `01-jiti-trynative-bun-runtime.sh` | Disable jiti `tryNative` under Bun (fixes extension module resolution) |
| 02 | `02-context-usage-from-session-context.sh` | Context usage from session context |

## Archive

`archive/` preserves the pre-migration state:
- `[0-9]*.patch` — the 17 source patches that were active on 2026-04-16, now as commits on `pix/main`.
- `retired/` — patches that were superseded/merged upstream before the migration.
- `manifest.json` — upstream-PR mapping at migration time.
- `audit-upstream.sh` / `verify-patches.sh` / `watch-upstream-prs.sh` / `regenerate-patches.sh` — the old tooling.

Mapping of source patch number → commit on `pix/main`:

```bash
cd /workspace/src/piclaw-fork
git log --oneline upstream/main..pix/main --reverse
```
