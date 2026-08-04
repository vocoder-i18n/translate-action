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
    steps:
      - uses: actions/checkout@v4
      - uses: vocoder-i18n/translate-action@v1
        with:
          api-key: ${{ secrets.VOCODER_API_KEY }}
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `api-key` | Yes | — | Vocoder project API key |
| `commit-mode` | No | `pr` | How to commit translated files: `pr` (open a pull request) or `direct` (push to current branch). The commit mode configured on your Vocoder project takes precedence over this input when set. |
| `working-directory` | No | `.` | Path to the app directory containing `vocoder.config.ts` |
| `cli-version` | No | `latest` | Pin a specific `@vocoder/cli` version for reproducible builds |

## Setup

- Run `npx @vocoder/cli init` in your repository to generate `vocoder.config.ts` and get your API key.
- Add `VOCODER_API_KEY` as a repository secret: GitHub repo → Settings → Secrets and variables → Actions → New repository secret.

## Multi-app repos

If `vocoder.config.ts` is not at the repository root, set `working-directory` to the path of the app directory:

```yaml
- uses: vocoder-i18n/translate-action@v1
  with:
    api-key: ${{ secrets.VOCODER_API_KEY }}
    working-directory: apps/web
```

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
