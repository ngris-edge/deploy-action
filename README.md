# Deploy to ngris — GitHub Action

Build and deploy a **preview to the [ngris](https://ngris.com) edge on every pull request**, and get the live URL commented back on the PR. Every push updates the preview.

Your preview isn't just hosted — it's served **behind the ngris policy edge**, so you can put a WAF, OAuth/OIDC, mTLS, rate-limiting, JA3 bot rules, or geo/CIDR in front of it, per endpoint, whenever you want.

```yaml
# .github/workflows/preview.yml
name: Preview
on: pull_request
permissions:
  contents: read
  pull-requests: write        # so the action can comment the URL
jobs:
  preview:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - uses: ngris-edge/deploy-action@v1
        with:
          api-key: ${{ secrets.NGRIS_API_KEY }}
          build-command: npm ci && npm run build
          dir: dist
```

That's it. Open a PR and the action comments:

> ### ⚡ ngris preview deployed
> **🔗 https://&lt;deploy&gt;.ngris.dev**

---

## Setup (2 minutes)

1. **Create an API key.** In the ngris dashboard → **Settings → API keys**, create a key (it starts with `ngk_`).
2. **Add it as a repo secret.** Repo → Settings → Secrets and variables → Actions → New secret → name it `NGRIS_API_KEY`.
3. **Add the workflow** above to `.github/workflows/preview.yml`.

That's all — the app is created automatically on the first run.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `api-key` | ✅ | — | Your ngris API key (`ngk_…`). Store it as a repo secret. |
| `app` | | repo name | The ngris application to deploy to (created if missing). Every push adds a preview deploy to it. |
| `dir` | | `dist` | The build-output directory to deploy. Set to `build`, `out`, `public`, etc. as your framework requires. |
| `build-command` | | — | Command to run before deploying, e.g. `npm ci && npm run build`. Omit if you build in a previous step. |
| `comment` | | `true` | Comment the preview URL on the PR (upserts one comment). Set `false` to disable. |
| `api-url` | | `https://api.ngris.com` | ngris API base URL. |
| `github-token` | | `${{ github.token }}` | Token used to comment. The default workflow token works with `pull-requests: write`. |

## Outputs

| Output | Description |
|---|---|
| `preview-url` | The live preview URL for this deploy. |
| `deploy-uuid` | The deploy's UUID. |

Use them in later steps:

```yaml
      - uses: ngris-edge/deploy-action@v1
        id: ngris
        with:
          api-key: ${{ secrets.NGRIS_API_KEY }}
      - run: echo "Deployed to ${{ steps.ngris.outputs.preview-url }}"
```

## Common framework outputs

| Framework | `build-command` | `dir` |
|---|---|---|
| Vite / React (Vite) | `npm ci && npm run build` | `dist` |
| Create React App | `npm ci && npm run build` | `build` |
| Vue / Nuxt (generate) | `npm ci && npm run generate` | `.output/public` or `dist` |
| SvelteKit (static) | `npm ci && npm run build` | `build` |
| Astro | `npm ci && npm run build` | `dist` |
| Next.js (static export) | `npm ci && npm run build` | `out` |
| Hugo | `hugo` | `public` |
| Plain static | *(none)* | your folder |

## What it does

1. Runs your `build-command` (if given).
2. Zips `dir` and uploads it as a new deploy to your ngris app (creating the app on first run).
3. Waits for the build to be ready.
4. Enables the deploy's public preview URL.
5. Upserts a single comment on the PR with the URL.

It uses only the public ngris API (`/api/applications…`) with your API key — no extra credentials, nothing stored.

## Notes & limits

- This deploys **static / framework build output** (a folder of files). For **managed backends** (Go/Node/Python/Dockerfile) use git-connected auto-preview in the dashboard.
- The preview URL is a per-deploy public URL (the unguessable deploy id is the capability). Enable per-endpoint auth/WAF in the dashboard if you want the preview gated.
- Requires `curl`, `jq`, `zip` — all present on `ubuntu-latest`.

## Links

- ngris: https://ngris.com · Docs: https://ngris.com/docs · Dashboard: https://dashboard.ngris.com
- Prefer GitLab? The same flow works as a GitLab CI job — see the docs.

MIT © ngris
