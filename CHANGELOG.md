# Changelog

## v1.1.0 — 2026-10-26

Security fix: **pull requests no longer change your production site.**

- A pull-request run now uploads a preview that is **not live**: production stays as it is. Before, every pull-request run put its build live (unless the app had Require manual promotion on).
- Production deploys happen only on a push to the repository's default branch, or on a non-PR run with the new `production: true` input. A push to another branch, a tag or a manual run is now a preview unless you set `production: true`. `production: true` is refused on pull requests.
- Each pull request keeps one preview: its previous preview is turned off before the new one is turned on, so previews no longer use up your plan's preview limit. Add `closed` to the `pull_request` types and a PR's preview is turned off when it is closed or merged (see the README workflow).
- The application is found by its exact name across all your applications (before, only the first page was read, so the action could fail on accounts with many applications). If a parallel run creates the application first, the action uses it.
- Errors from ngris (for example the preview limit) are shown in the log.
- The PR comment and the README no longer say that previews are behind your endpoints' WAF and sign-in rules: they are not. Previews are private to your ngris account by default; the README says how to make them public.
- Deploys are labelled `pr-<number>-<commit>`, `prod-<commit>` or `ref-<branch>-<commit>`.

Upgrading: previews turned on by v1.0.x stay on. If you are at your plan's preview limit, revoke them in the dashboard (the app's **Deploys** tab → **Revoke preview URL**).

## v1.0.1 — 2026-09-04

- Fix: turning on the preview URL failed on every run.

## v1.0.0 — 2026-09-04

- First release: preview deploys on every pull request, with the URL commented on the PR.
