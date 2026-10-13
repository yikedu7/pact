# Pact delivery relay (`guild-relay`)

Public HTTPS proxy so **buyers and experts negotiate without sharing Cursor webhook secrets**.
Outsiders POST JSON to a stable URL per bot; the Edge Function looks up the bot’s webhook URL and
server-held `webhook_key`, then forwards with `Authorization: Bearer …`.

Deployed on Supabase project **OmniCrypto** (`hpdffdsglxedgtoxykdt`). Hackathon demo record:
[`docs/demos/2026-10-13-dfcb9220/`](../docs/demos/2026-10-13-dfcb9220/).

## Public URL shape

```text
POST https://<project-ref>.supabase.co/functions/v1/guild-relay/<botId>
```

- **No** `Authorization` header required on the public path (Free-tier anon key is not needed).
- Body must be a `guild.negotiate/v0.1` envelope or a `guild.escrow/v0.1` next-step cue
  (see negotiation record in the demo folder, and the escrow commands in the repo README).
- Rate limit: **30 requests / hour / client IP / bot** (see `guild_relay_rate_limits`).

Admin registration (service operators only):

```text
POST https://<project-ref>.supabase.co/functions/v1/guild-relay/_admin/register
Header: x-guild-admin: <GUILD_RELAY_ADMIN secret>
Body: { "bot_id", "webhook_url", "webhook_key", "enabled"?: true }
```

`GUILD_RELAY_ADMIN` is set only as a **Supabase Edge secret**, never in git.

## Source layout

| Path | Role |
| --- | --- |
| `supabase/functions/guild-relay/index.ts` | Edge Function entry (Deno) |

## Database tables (Postgres, service_role only)

Create these in the Supabase SQL editor. **Do not** expose these tables via RLS to `anon` or
`authenticated`; only the Edge Function’s service role should read/write them.

```sql
-- Registered bots: Cursor (or other) webhook endpoints + secrets held server-side
create table if not exists public.guild_bots (
  bot_id text primary key,
  webhook_url text not null,
  webhook_key text not null,
  enabled boolean not null default true,
  updated_at timestamptz not null default now()
);

-- Per-IP hourly counters for public POST /guild-relay/<botId>
create table if not exists public.guild_relay_rate_limits (
  id bigint generated always as identity primary key,
  bot_id text not null references public.guild_bots (bot_id) on delete cascade,
  client_ip text not null,
  window_start timestamptz not null,
  hit_count int not null default 1,
  unique (bot_id, client_ip, window_start)
);

create index if not exists guild_relay_rate_limits_bot_window
  on public.guild_relay_rate_limits (bot_id, window_start);
```

## Deploy (Supabase CLI)

From a machine with the [Supabase CLI](https://supabase.com/docs/guides/cli) linked to the project:

```bash
cd relay
# One-time: supabase link --project-ref <project-ref>
supabase secrets set GUILD_RELAY_ADMIN="<generate-a-long-random-token>"
# SUPABASE_URL and service role are provided automatically in Edge runtime;
# legacy SUPABASE_SERVICE_ROLE_KEY or SUPABASE_SECRET_KEYS still work per index.ts.
supabase functions deploy guild-relay --no-verify-jwt
```

`--no-verify-jwt` keeps the relay callable without a Supabase anon JWT (matches the public demo).

After deploy, register each bot via `_admin/register`. Share only:

`https://<project-ref>.supabase.co/functions/v1/guild-relay/<botId>`

## What NOT to commit

- Cursor webhook keys (`crsr_…` or any `webhook_key` value)
- `GUILD_RELAY_ADMIN` or real `x-guild-admin` tokens
- Supabase `service_role` / secret keys
- Privy `PRIVY_APP_SECRET` or wallet credentials

The function never logs full keys; registration responses only return `key_len`.
