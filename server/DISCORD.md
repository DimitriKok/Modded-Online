# Desync logs to Discord

When an online run desyncs, players who switched **Send desync logs to the server's
Discord** on in the game send that run's desync log to the Modded Online server. The
server then posts it, as a `.txt` file, to a Discord channel you choose. The game
itself can only talk UDP to the server, so the server is the courier.

Nothing is posted unless **both** of these are true:

* The player ticked the option in the game. It's in Playlunky's options for Modded
  Online, and it's off by default.
* The server's operator configured Discord as described below. A server without it
  tells every client on join that it doesn't forward logs, and refuses any log it's
  sent.

## What a post contains

* **The file.** This is the desync log of that one run, from the player's own game.
  It holds the players' names in the room, the mod list, seeds, and per-floor and
  per-frame sync data.
  * The server replaces every IPv4 address in it with `x.x.x.x`.
  * It replaces the account name in any `C:\Users\<name>\...` path with `<user>`.
* **The message.** This says:
  * what desynced (e.g. `FLOOR DESYNC seq 15`);
  * the player's name, slot and room code;
  * the run seed;
  * both versions.
  Mentions are disabled on the post, so a player name can never ping anyone.

When one player's game sees a desync, it tells the rest of the room. Every player who
opted in then sends their side of the run. The two logs land next to each other,
with the same room code and seed, which is what you diff.

## Set up a bot (recommended)

1. **Create the bot.**
   1. Go to <https://discord.com/developers/applications> and choose **New Application**.
   2. Under **Bot**, choose **Reset Token** and copy the token.
   3. Treat the token like a password: anyone who has it can post as your bot.
2. **Invite it to your server.**
   1. Under **OAuth2 → URL Generator**, tick the scope **bot**.
   2. Tick the permissions **View Channels**, **Send Messages** and **Attach Files**.
   3. Open the generated URL and pick your server.
3. **Copy the channel id.**
   1. In Discord: **Settings → Advanced → Developer Mode** on.
   2. Right-click the channel the logs should go to → **Copy Channel ID**.
4. **Configure the Modded Online server.** Copy `discord_config.example.json` to
   `discord_config.json` in this folder and fill in:

   ```json
   {
       "bot_token": "your bot token",
       "channel_id": "123456789012345678"
   }
   ```

   `discord_config.json` is in `.gitignore`, so it can't be committed by accident.
   You can use environment variables instead: `MO_DISCORD_BOT_TOKEN` and
   `MO_DISCORD_CHANNEL_ID`. Environment variables win over the file.
5. **Restart the server.** Its startup log says where logs go:

   ```
   desync logs from players who opted in: posted to Discord by the bot, in channel 123456789012345678
   ```

   A mistake in the file is reported on the line before it, as `Discord: ...`.

The server that the game auto-launches when you host on `127.0.0.1` is this same
`server.py`, so this file is all it needs.

## Or use a webhook

**Channel settings → Integrations → Webhooks → New Webhook → Copy Webhook URL.** Put
it in `discord_config.json` as `"webhook_url"`, or in `MO_DISCORD_WEBHOOK_URL`.

A webhook needs no bot, but anyone with its URL can post to that channel, so keep the
URL as private as a token. If both a webhook and a bot are configured, the webhook is
used.

## Limits

| Limit | Value |
|---|---|
| Size of one log | 4 MB. The game trims a longer run to its start and its end, and says what it cut. |
| Logs per player | 6 an hour |
| Logs posting at once, server-wide | 4 |
| Discord rate limits | Waited out and retried a few times. Anything else (missing permissions, a deleted channel) is logged on the server and told to the player. |

A player who leaves the room before their log has gone keeps it, and it goes the next
time they're in a room on a server that forwards logs. If they quit the game first,
the log isn't sent; it's still on their disk as `desync_log.txt` (or
`desync_log.prev.txt` after the next launch).
