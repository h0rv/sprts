# sprts

## What this is

An open source, self-hostable service that shows live sports scores and schedules with zero bloat: no ads, no tracking, no account walls, no bloated app funnel.
It should load instantly and work equally well from a browser, a script hitting a JSON API, or a terminal (including plain `curl`, no special client required).
Whether that ends up rendered as plain HTML, markdown-derived HTML, or something else internally doesn't matter, the result just needs to be simple and fast either way.

Inspired by https://plaintextsports.com/ and https://wttr.in/ (https://github.com/chubin/wttr.in).

## The one thing this has to nail

The reference point for this whole project is wttr.in for weather: you can `curl` it and get a legible, well-formatted result in your terminal with zero setup, no flags, no account, nothing installed.
That is the single most important experience here.
The web page and the JSON API both matter, but if `curl spr.ts/mlb` doesn't just work and look good by default, the project has missed its own point.

## Goals

- Cover every major sport/league from the start, not just one. Adding a new sport should never require rethinking the product.
- One backend, server-rendered only. No client-side app framework doing the rendering.
- One JSON API, first-class, not an afterthought. The same data the web page shows, so anyone (a script, someone's own mobile app, a personal dashboard) can build on it exactly the same way the web page does.
- Plain `curl` gets a good, legible default. Nothing stops someone from writing their own shell script or CLI on top of the JSON API that reads their terminal's size and capabilities client-side and renders it however they want, more prettily or otherwise.
- Trivial date navigation: browsing yesterday's results or next week's schedule should be a non-event, not a buried feature. Self-hostable by anyone with minimal setup.
- Open source, freely licensed, structured so outside contributors can reasonably add a new sport or fix a data quirk.
- Data comes from public sports sources. Whether that means proxying one source directly or pulling from a few and caching aggressively is entirely up to whoever builds it, whatever's worthwhile and keeps it fast.
- First data source is: site.api.espn.com (OpenAPI https://github.com/pseudo-r/Public-ESPN-API or https://github.com/aaronweldy/espn-openapi), but ensure it's built as an adapater pattern to swap or allow multiple sources in the app.

## Non-goals

No sign-in, no accounts, no ads, no betting odds. If it starts needing any of those, it's stopped being this project.

## Who it's for

Developers and sports fans who want scores without friction, people who want to self-host their own instance, and anyone building a script, dashboard, or terminal habit on top of a stable, boring, free data source.

## Success looks like

- Someone can self-host this in a few minutes.
- `curl`-ing it gives legible, correctly formatted scores immediately, no setup, the wttr.in feeling.
- The JSON output is stable enough that someone would build a personal script or dashboard on top of it without hesitation.
- Adding a new sport is routine, not a rewrite.

## Everything else is the implementer's call

We will use Zig 0.16.0 (managed by mise) with https://github.com/christianhelle/openapi2zig with my library, https://github.com/h0rv/zschema. We can vendor a clients package in a mono-repo to be used in the same app. Storage, rendering approach, exact routes, styling, how many data sources and how caching works. All open. Optimize for simplicity and for someone else being able to read the code and understand it quickly.

