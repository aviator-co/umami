---
description: How to drive the umami preview — signing in with the admin secrets, where things live, what demo data exists, and what a preview cannot exercise. Load before writing or running any scenario against this app.
---

# Driving the umami preview

umami is a self-hosted, privacy-focused web analytics app (an alternative to
Google Analytics). The preview serves the full Next.js UI, backed by a
PostgreSQL database running on the same sandbox.

Everything except `/login` requires authentication. Sign in first.

## Signing in

1. Navigate to the preview URL. You will be redirected to `/login`.
2. Wait for the form to appear. The login page is **fully client-rendered** —
   the initial HTML contains no `<form>` and no inputs at all — so acting on the
   first response finds nothing.
3. Fill `[data-test="input-username"] input` with
   `{{ secrets.UMAMI_ADMIN_USERNAME }}`.
4. Fill `[data-test="input-password"] input` with
   `{{ secrets.UMAMI_ADMIN_PASSWORD }}`.
5. Click `[data-test="button-submit"]`.

**The trailing ` input` on those two selectors is required.** `data-test` sits on
a wrapper `<div>`, not on the field — verified against the rendered DOM, where
`[data-test="input-username"]` is a `DIV` containing exactly one `<input>`.
umami's own tests do the same thing
(`getByTestId('input-username').locator('input')`, `tests/e2e/login.spec.ts`).
Targeting the wrapper directly types nothing and looks like a broken login.
`button-submit` is the real `<button>`, so click it directly.

You land on `/`, which renders `null` and then client-redirects to `/websites` —
the websites list. Wait for `/websites`; asserting on `/` catches an empty page.
The websites table hydrates a beat after the route settles, so wait for its rows
rather than reading it immediately.

Carry the `{{ secrets.* }}` placeholders into the sign-in step verbatim. The
collector substitutes the real values at call time and fences them to the
preview origin. Never put a literal credential in a scenario.

The session token is kept in **localStorage**, not a cookie, and is sent as an
`Authorization: Bearer` header. A page reload keeps you signed in; clearing site
data or opening a fresh browser context does not — sign in again.

## Getting around

The left nav covers the main areas. Useful routes:

| Route | What is there |
| --- | --- |
| `/websites` | The websites list — the post-login landing page |
| `/websites/<id>` | One site's overview, and the parent of everything below |
| `/websites/<id>/{realtime,sessions,events,replays,segments,cohorts,compare}` | Per-site views |
| `/websites/<id>/{funnels,retention,journeys,goals,revenue,attribution,breakdown,utm,performance,heatmaps}` | The reports. Note they are **per-website** — there is no top-level `/reports` |
| `/dashboard` | The cross-website dashboard |
| `/boards` | Custom boards |
| `/links` , `/pixels` | Short links and tracking pixels |
| `/settings/{preferences,profile,websites,teams}` | Settings (`/settings` redirects to `/settings/preferences`) |
| `/admin/{users,websites,teams}` | Admin management (`/admin` redirects to `/admin/users`) |
| `/teams` | Teams |

Website ids are uuids assigned at seed time, so read them off the websites list
rather than hardcoding one.

## Demo data

The preview seeds two websites with roughly 30 days of traffic, so charts,
tables and reports all have something in them:

- **Demo Blog** — `blog.example.com`, low traffic, with `newsletter_signup`,
  `share_click` and `scroll_depth` events.
- **Demo SaaS** — `app.example.com`, higher traffic (~15k sessions, ~45k
  events), with a signup funnel (`signup_started` / `signup_completed`),
  `purchase` revenue events, `demo_requested`, `feature_viewed`, `cta_click`
  and `docs_search`.

The seed is baked into the image, so its dates would drift as the image ages.
The setup script shifts every seeded timestamp forward at each launch so the
data always ends **today** — the default *Last 24 hours* range is populated, and
you do not need to widen it. The shift is a whole number of days, which keeps
the seed's hour-of-day traffic peaks intact, so the newest event can be up to a
day old (always inside the default window).

The nav sections that the analytics seed leaves empty are filled over umami's
own API at launch:

| Section | Seeded |
| --- | --- |
| Links | *Docs shortlink* (`/docs`), *Pricing shortlink* (`/pricing`) |
| Pixels | *Newsletter open pixel* |
| Boards | *Demo SaaS overview* |
| Reports (Demo SaaS) | *Signup funnel* (a real funnel over `signup_started` → `signup_completed`), *Retention* |
| Reports (Demo Blog) | *Newsletter signups* (a goal on `newsletter_signup`) |

Teams and Segments are **not** seeded and open on empty states — that is
expected, not a regression.

Realtime views are also genuinely and permanently empty: nothing generates live
traffic into the preview. Do not write scenarios against them.

## What is observable as evidence

This is a real app driven through a browser, so the DOM, rendered text, computed
styles, network responses from `/api/*`, and browser console output are all fair
game. Data written through the UI (creating a website, editing a report, adding
a user) persists in PostgreSQL for the life of the sandbox, so multi-step
scenarios work.

## What a preview does NOT exercise

Do not write scenarios that depend on any of these — they cannot pass here:

- **Incoming tracking traffic.** `/script.js` is served, but no external site
  loads it, and the agent's browser is fenced to the preview origin. All
  analytics you see is seeded, not live.
- **ClickHouse, Redis, Kafka.** Unset, so umami runs in its plain PostgreSQL
  mode. Clustered/cloud-only code paths are inactive.
- **Email and outbound integrations.** Nothing is configured.
- **Telemetry and update checks.** `DISABLE_TELEMETRY` and `DISABLE_UPDATES` are
  set, so the update banner never appears.
- **Accurate geolocation.** The GeoLite2 database is present, but seeded
  locations are synthetic.
- **Anything at a second origin** — OAuth, embeds, external redirects.
