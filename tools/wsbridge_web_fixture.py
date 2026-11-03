"""Fixture for app/test/browser/ws_ticket_web_test.dart: a real Bridge on 18702 with a throwaway key and
no upstream (allowlist and parse answers need none), plus a CORS side door on 18703 that mints a
ticket, since the test page is cross-origin to the bridge."""
import asyncio
import json
import secrets
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from compat import wsbridge  # noqa: E402

BRIDGE_PORT, MINT_PORT = 18702, 18703


def no_upstream():
    raise wsbridge.UpstreamUnavailable("fixture")


async def main():
    bridge = wsbridge.Bridge(key=secrets.token_urlsafe(16), discover=no_upstream)

    async def side_door(reader, writer):
        await reader.readuntil(b"\r\n\r\n")
        body = json.dumps({"ticket": bridge.tickets.mint()}).encode()
        writer.write(b"HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n"
                     b"Content-Length: %d\r\n\r\n%s" % (len(body), body))
        await writer.drain()
        writer.close()

    await bridge.serve("127.0.0.1", BRIDGE_PORT)
    door = await asyncio.start_server(side_door, "127.0.0.1", MINT_PORT)
    print(f"bridge {BRIDGE_PORT}, mint {MINT_PORT}", flush=True)
    async with door:
        await door.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
