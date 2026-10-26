# Deploy to ngris — GitHub Action

Build and deploy a **preview to the [ngris](https://ngris.com) edge on every pull request**, and get its URL commented back on the PR. Every push replaces the preview.

**Pull requests never change your production site.** A pull request gets a preview that is not live; only a push to your default branch deploys to production.

Previews are **private** by default: only members of your ngris account can open them. See [Who can open a preview](#who-can-open-a-preview).

```yaml
# .github/workflows/ngris.yml
name: ngris
on:
  pull_request:
    types: [opened, synchronize, reopened, closed]   # closed: turns the PR's preview off
  push:
    branches: [main]                                 # your default branch: deploys to production
permissions:
  contents: read
  pull-requests: write        # so the action can comment the URL
jobs:
  deploy:
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

Only want previews? Leave out the `push:` trigger.

---

## Setup (2 minutes)

1. **Create an API key.** In the ngris dashboard → **Settings → API keys**, create a key (it starts with `ngk_`).
2. **Add it as a repo secret.** Repo → Settings → Secrets and variables → Actions → New secret → name it `NGRIS_API_KEY`.
3. **Add the workflow** above to `.github/workflows/ngris.yml`.

That's all — the app is created automatically on the first run.

## Previews and production

| Run | What it deploys |
|---|---|
| Pull request opened, pushed to or reopened | A **preview**, not live: production is unchanged. The PR's previous preview is turned off. |
| Pull request closed or merged | Nothing. The PR's preview is turned off. |
| Push to the default branch | A **production** deploy. It goes live when the build is ready, unless the app has **Require manual promotion** on: then you promote it from the app's **Deploys** tab. |
| Any other run (another branch, a tag, a manual run) | A preview, unless you set `production: true`. |

- To deploy to production from a release tag or a manual run, set `production: true`. It is refused on pull requests.
- To put a preview live by hand, open the app's **Deploys** tab in the dashboard and choose **Promote to production**.
- Each pull request keeps one preview, so your previews stay within your plan's preview limit. Keep `closed` in the `pull_request` types: without it, the last preview of every closed PR stays on and counts toward the limit until you revoke it in the dashboard (**Deploys** tab → **Revoke preview URL**).

## Who can open a preview

- Previews are **private** by default: only members of your ngris account can open them, after they sign in to ngris.
- To let anyone with the link open your previews, open the application in the dashboard → **Settings → Visibility**, set **Deploy previews** to **Public** and save.
- The protections you set on your production endpoints (WAF, sign-in, rate limits, bot and geo rules, edge functions) **do not apply to preview URLs**. A public preview can be opened by anyone who has its link, so keep previews private if what you build must stay behind sign-in.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `api-key` | ✅ | — | Your ngris API key (`ngk_…`). Store it as a repo secret. |
| `app` | | repo name | The ngris application to deploy to, by its exact name (created if missing). |
| `dir` | | `dist` | The build-output directory to deploy. Set to `build`, `out`, `public`, etc. as your framework requires. |
| `build-command` | | — | Command to run before deploying, e.g. `npm ci && npm run build`. Omit if you build in a previous step. |
| `production` | | `auto` | `auto`: only a push to the default branch deploys to production. `true`: this run deploys to production (refused on pull requests). `false`: always a preview. |
| `comment` | | `true` | Comment the preview URL on the PR (upserts one comment). Set `false` to disable. |
| `api-url` | | `https://api.ngris.com` | ngris API base URL. |
| `github-token` | | `${{ github.token }}` | Token used to comment. The default workflow token works with `pull-requests: write`. |

## Outputs

| Output | Description |
|---|---|
| `preview-url` | The preview URL of this deploy (private unless you made previews public). |
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
2. Zips `dir` and uploads it as a new deploy to your ngris app (found by its exact name; created on the first run). On a pull request the deploy is not live.
3. Waits for the build to be ready.
4. Turns off the previous preview of the same pull request (or of production), then turns on this deploy's preview URL.
5. Upserts a single comment on the PR with the URL.

It uses only the public ngris API (`/api/applications…`) with your API key — no extra credentials, nothing stored.

## Notes & limits

- This deploys **static / framework build output** (a folder of files). For **managed backends** (Go/Node/Python/Dockerfile) use git-connected auto-preview in the dashboard.
- Requires `curl`, `jq`, `zip` — all present on `ubuntu-latest`.
- Upgrading from v1.0.x: older versions deployed every pull request to production and never turned previews off. If you are at your plan's preview limit, revoke the old previews in the dashboard (**Deploys** tab → **Revoke preview URL**). See the [changelog](CHANGELOG.md).

## Links

- ngris: https://ngris.com · Docs: https://ngris.com/docs · Dashboard: https://dashboard.ngris.com
- Prefer GitLab? The same flow works as a GitLab CI job — see the docs.

MIT © ngris
