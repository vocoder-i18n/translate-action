# Vocoder Translate

Translate i18n strings via Vocoder before build.

## Usage

Add this workflow to `.github/workflows/vocoder.yml` in your repository:

```yaml
name: Vocoder Translate
on:
  push:
    branches: [main]
jobs:
  translate:
    runs-on: ubuntu-latest
    if: github.actor != 'vocoder-bot[bot]'
    permissions:
      contents: write
      pull-requests: write   # omit when commit-mode is direct
    steps:
      - uses: actions/checkout@v4
      - uses: vocoder-i18n/translate-action@v1
        with:
          api-key: ${{ secrets.VOCODER_API_KEY }}
```

The `if: github.actor != 'vocoder-bot[bot]'` guard prevents the workflow from re-triggering on the commits Vocoder pushes back with translated locale files.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `api-key` | Yes | — | Vocoder project API key |
| `commit-mode` | No | `pr` | How to commit translated files: `pr` (open a pull request) or `direct` (push to current branch). The server-returned commit mode from the translate result takes precedence over this input when present. |
| `on-failure` | No | `proceed` | `proceed` (continue the workflow with stale or source-language strings) or `fail` (halt the workflow) when translation fails. |
| `cli-version` | No | `latest` | Pin a specific `@vocoder/cli` version for reproducible builds |

## Commit mode

| `commit-mode` | Behavior | Permissions needed |
|---|---|---|
| `pr` (default) | Opens a pull request with the updated locale files | `contents: write`, `pull-requests: write` |
| `direct` | Pushes locale files directly to the current branch | `contents: write` |

Choose `pr` to review translation changes before they merge. Choose `direct` when immediate application fits your pipeline better — for example, CI that already gates on other checks before deploying.

```yaml
- uses: vocoder-i18n/translate-action@v1
  with:
    api-key: ${{ secrets.VOCODER_API_KEY }}
    commit-mode: direct
```

## Failure behavior

By default the action proceeds even when translation fails — the build continues with stale or source-language strings. To halt the workflow instead, set `on-failure` to `fail`:

```yaml
- uses: vocoder-i18n/translate-action@v1
  with:
    api-key: ${{ secrets.VOCODER_API_KEY }}
    on-failure: fail
```

## Setup

- Run `npx @vocoder/cli init` in your repository to generate `vocoder.config.ts` and get your API key.
- Add `VOCODER_API_KEY` as a repository secret: GitHub repo → Settings → Secrets and variables → Actions → New repository secret.

## Multi-app repos

The action itself always runs from the repository root — there is no per-invocation directory input. For repos with multiple apps, declare app directories in `vocoder.config.ts` at the repo root instead; the single workflow above handles every app automatically:

```ts
// vocoder.config.ts
import { defineConfig } from '@vocoder/config';

export default defineConfig({
  apps: [
    { appDir: 'apps/web' },
    { appDir: 'apps/admin' },
  ],
});
```

`vocoder init` generates this file automatically for monorepos. For single-app repos, omit `apps` entirely — no `vocoder.config.ts` is needed unless you want to customize extraction settings.

## Pinning a version

By default the action runs the latest `@vocoder/cli` release. To pin a specific version for reproducible builds, set the `cli-version` input:

```yaml
- uses: vocoder-i18n/translate-action@v1
  with:
    api-key: ${{ secrets.VOCODER_API_KEY }}
    cli-version: '1.2.3'
```

## License

[MIT](LICENSE)
