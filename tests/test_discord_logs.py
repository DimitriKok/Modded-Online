"""The server half of sending desync logs to Discord (server/server.py).

The server reassembles a log a player opted to send and posts it to the Discord
channel its operator configured, with a bot (token + channel id) or a webhook. These
cover everything that does not need a socket: redaction, the message and filename,
the configuration, the exact HTTP request, and how failures are reported. Nothing
here talks to Discord; the HTTP opener is a fake.

The UDP upload itself is exercised end to end in server/test_server.py.

Run:  python -m pytest tests/test_discord_logs.py -q
"""

from __future__ import annotations

import io
import json
import pathlib
import sys
import urllib.error

PACK = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PACK / "server"))

import server as srv  # noqa: E402

TOKEN = "MTIz.fake-token.never-real"


class FakeResponse:
    def __init__(self, status=200):
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeOpener:
    """Answers each request with the next scripted outcome and records it."""

    def __init__(self, *outcomes):
        self.outcomes = list(outcomes)
        self.requests = []

    def __call__(self, request, timeout=None):
        self.requests.append(request)
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, BaseException):
            raise outcome
        return FakeResponse(outcome)


def http_error(code, body=b""):
    return urllib.error.HTTPError("https://discord.com/x", code, "err", {}, io.BytesIO(body))


def bot(opener=None, sleeps=None):
    slept = sleeps if sleeps is not None else []
    return srv.DiscordForwarder(bot_token=TOKEN, channel_id="1234567890", opener=opener,
                                sleep=slept.append)


# ------------------------------------------------------------------ redaction

def test_addresses_and_the_windows_account_are_taken_out():
    data = (b"server=26.186.94.66:26000 (v1.0.12)\n"
            b"peer 192.168.1.20 sent\n"
            b"C:\\Users\\mimik\\AppData\\Local\\x\n"
            b"c:/users/Someone Else/Desktop\n")
    out = srv.redact_log(data)
    assert b"26.186.94.66" not in out and b"192.168.1.20" not in out
    assert out.count(b"x.x.x.x") == 2
    assert b"mimik" not in out and b"Someone Else" not in out
    assert b"C:\\Users\\<user>\\AppData" in out


def test_versions_seeds_and_clocks_are_left_alone():
    data = b"=== Modded Online 2.0.0-dev65 v1.0.13 seed=036AEAA9-D53A4E4B [20:25:58 15:0] 1.2.3.4.5\n"
    assert srv.redact_log(data) == data


# ------------------------------------------------------------- message + file

def test_the_message_cannot_ping_or_break_out_of_code():
    meta = {"reason": "FLOOR DESYNC seq 15 @everyone", "version": "2.0.0`x`",
            "seed": "036AEAA9-D53A4E4B", "mods": "fyi.hdmod:200"}
    text = srv.describe_log(meta, "@here `name`", "BITO", 2, False)
    assert "@everyone" not in text.replace("@\u200beveryone", "")
    assert "`name`" not in text and "'name'" in text
    assert "FLOOR DESYNC seq 15" in text and "BITO" in text and "036AEAA9-D53A4E4B" in text
    assert len(text) <= srv.DISCORD_CONTENT_MAX


def test_a_huge_field_is_cut_short():
    text = srv.describe_log({"reason": "r" * 5000, "mods": "m" * 5000}, "n", "ROOM", 1, True)
    assert len(text) <= srv.DISCORD_CONTENT_MAX and "world host" in text


def test_the_filename_is_safe():
    name = srv.log_filename("BI/TO", 2, "../../evil name", when=0)
    assert name == "desync_BITO_s2_evilname_19700101-000000.txt"


# -------------------------------------------------------------- configuration

def test_nothing_is_forwarded_unless_configured():
    assert srv.DiscordForwarder().enabled is False
    assert srv.ModdedOnlineServer().discord.enabled is False


def test_a_bot_needs_its_channel():
    fwd = srv.DiscordForwarder(bot_token=TOKEN)
    assert fwd.enabled is False and "channel id" in fwd.problem


def test_a_bad_channel_id_or_webhook_is_refused():
    assert srv.DiscordForwarder(bot_token=TOKEN, channel_id="#general").enabled is False
    hook = srv.DiscordForwarder(webhook_url="https://evil.example/api/webhooks/1/x")
    assert hook.enabled is False and "webhook" in hook.problem


def test_the_environment_wins_over_the_file(tmp_path):
    (tmp_path / srv.DISCORD_CONFIG_FILE).write_text(
        json.dumps({"bot_token": "from-file", "channel_id": "111"}), encoding="utf-8")
    fwd = srv.DiscordForwarder.from_environment(str(tmp_path), environ={"MO_DISCORD_CHANNEL_ID": "222"})
    assert fwd.enabled and fwd.bot_token == "from-file" and fwd.channel_id == "222"


def test_a_webhook_from_the_file(tmp_path):
    url = "https://discord.com/api/webhooks/123/abc"
    (tmp_path / srv.DISCORD_CONFIG_FILE).write_text(json.dumps({"webhook_url": url}), encoding="utf-8")
    fwd = srv.DiscordForwarder.from_environment(str(tmp_path), environ={})
    assert fwd.enabled and fwd.webhook_url == url


def test_a_broken_file_is_reported_not_fatal(tmp_path):
    (tmp_path / srv.DISCORD_CONFIG_FILE).write_text("{not json", encoding="utf-8")
    fwd = srv.DiscordForwarder.from_environment(str(tmp_path), environ={})
    assert fwd.enabled is False and "could not read" in fwd.problem


def test_the_token_is_never_described():
    assert TOKEN not in bot().describe()


# ---------------------------------------------------------------- the request

def test_a_bot_posts_to_its_channel_as_the_bot():
    req = bot().build_request("hello", "desync.txt", b"line one\nline two\n")
    assert req.full_url == "https://discord.com/api/v10/channels/1234567890/messages"
    assert req.get_method() == "POST"
    assert req.get_header("Authorization") == f"Bot {TOKEN}"
    assert req.get_header("User-agent").startswith("DiscordBot (")
    ctype = req.get_header("Content-type")
    assert ctype.startswith("multipart/form-data; boundary=")
    boundary = ctype.split("boundary=")[1].encode()
    body = req.data
    parts = body.split(b"--" + boundary)
    assert body.endswith(b"--" + boundary + b"--\r\n")
    payload = parts[1].split(b"\r\n\r\n", 1)[1].rsplit(b"\r\n", 1)[0]
    meta = json.loads(payload)
    assert meta["content"] == "hello"
    assert meta["allowed_mentions"] == {"parse": []}
    assert meta["attachments"] == [{"id": 0, "filename": "desync.txt"}]
    assert b'name="files[0]"; filename="desync.txt"' in parts[2]
    assert parts[2].split(b"\r\n\r\n", 1)[1] == b"line one\nline two\n\r\n"


def test_a_webhook_posts_without_a_token_and_waits_for_the_message():
    fwd = srv.DiscordForwarder(webhook_url="https://discord.com/api/webhooks/1/abc")
    req = fwd.build_request("hi", "f.txt", b"x")
    assert req.full_url == "https://discord.com/api/webhooks/1/abc?wait=true"
    assert req.get_header("Authorization") is None


# ----------------------------------------------------------------- outcomes

def test_a_posted_log():
    opener = FakeOpener(200)
    assert bot(opener).post("m", "f.txt", b"x") == (True, "posted")


def test_the_rate_limit_is_waited_out():
    slept = []
    opener = FakeOpener(http_error(429, b'{"retry_after": 1.5}'), 200)
    assert bot(opener, slept).post("m", "f.txt", b"x") == (True, "posted")
    assert slept == [1.5] and len(opener.requests) == 2


def test_discord_saying_no_is_reported_without_the_token():
    opener = FakeOpener(http_error(403, b'{"message": "Missing Permissions", "code": 50013}'))
    ok, why = bot(opener).post("m", "f.txt", b"x")
    assert ok is False and why == "Discord answered HTTP 403: Missing Permissions"
    assert TOKEN not in why


def test_an_unreachable_discord_is_tried_three_times():
    slept = []
    opener = FakeOpener(*(urllib.error.URLError("no route") for _ in range(3)))
    ok, why = bot(opener, slept).post("m", "f.txt", b"x")
    assert ok is False and why == "could not reach Discord: no route"
    assert len(opener.requests) == 3 and slept == [2.0, 2.0]


def test_an_endless_rate_limit_gives_up():
    opener = FakeOpener(*(http_error(429, b'{"retry_after": 0.1}') for _ in range(4)))
    ok, why = bot(opener, []).post("m", "f.txt", b"x")
    assert ok is False and "rate-limiting" in why


def test_an_unconfigured_forwarder_refuses_to_post():
    assert srv.DiscordForwarder().post("m", "f", b"x")[0] is False
