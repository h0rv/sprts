# Streaming / Live Updates

How live score updates work, and why it's split the way it is.

## Two separate problems

Don't solve these with the same mechanism, they're not the same problem:

1. **Server → ESPN.** This has to be polling. ESPN doesn't push anything to
   us, there's no way around it.
2. **Server → clients.** This can be genuinely event-driven, via SSE
   (Server-Sent Events), regardless of the fact that layer 1 is polling.

A client should never have to re-request to get an update. The server
should push it the moment it knows.

## Server → ESPN: subscriber-gated polling

Only poll a given league/game when at least one client is actually
subscribed to it.

- Last subscriber disconnects → polling for that resource stops.
- A client connects again → polling resumes.
- Poll interval depends on state: ~10-15s for games in progress, much less
  often (or not at all) for scheduled/final games that aren't going to
  change.

This is the actual bandwidth/request savings. Ten people watching the same
game costs the same one ESPN poll as one person watching, not ten, because
they all subscribe to one cached, current state rather than each triggering
their own fetch.

## Server → clients: SSE, not polling, not WebSockets

SSE over WebSockets because traffic here is one-directional (server tells
client the score changed, client never needs to talk back), so there's no
reason to pay for the extra complexity of a bidirectional protocol.

SSE is just a normal HTTP response with `Content-Type: text/event-stream`
that the server keeps open and writes `data: ...\n\n` chunks to over time.
One connection, server pushes, done. Request count for a connected client
is effectively zero after the initial connect, this is a real structural
difference from polling, not polling in disguise.

### It works with plain curl, no special client needed

```
curl -N https://sprts.horv.co/nba
```

`-N` / `--no-buffer` matters here, otherwise curl can hold chunks before
printing them.

To get an in-place redraw (clear and repaint) instead of new blocks of text
scrolling down the terminal, the server prefixes each event with a
clear-screen escape sequence (`\x1b[2J\x1b[H`) before the redrawn text.
Plain `curl -N` then redraws live with zero client-side logic, the terminal
is just interpreting escape codes it received. curl has no idea anything
special is happening.

### The naive fallback, if SSE isn't available for some client/environment

```
watch -n 5 curl sprts.horv.co/nba
```

A real new request every interval, per client. Fine as a fallback, not the
default.

## Future problem, not today's problem

This whole design assumes one process is the source of truth for a given
resource's cached state and poll timer. If this ever runs as multiple
instances or goes multi-region, that assumption breaks, every instance
would otherwise re-poll ESPN independently. The fix at that point is
centralizing per-resource state (e.g. a Cloudflare Durable Object per
league/game) rather than solving it in-process. Not a concern at current
scale.
