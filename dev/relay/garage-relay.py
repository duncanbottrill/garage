#!/usr/bin/env python3
"""Garage relay: raw TCP passthrough from LISTEN_PORT to TARGET (host:port).

No TLS here: the car's mTLS session terminates on the Green. Standard library
only, so it runs on the stock python3 of any Oracle Linux / Ubuntu image.
"""
import asyncio
import os
import sys

LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "443"))
TARGET = os.environ.get("TARGET", "")
if ":" not in TARGET:
    sys.exit("TARGET must be host:port")
TARGET_HOST, TARGET_PORT = TARGET.rsplit(":", 1)
CONNECT_TIMEOUT = 10
BUF = 65536


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(BUF)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.IncompleteReadError, OSError):
        pass
    finally:
        try:
            writer.close()
        except OSError:
            pass


async def handle(client_reader, client_writer):
    try:
        target_reader, target_writer = await asyncio.wait_for(
            asyncio.open_connection(TARGET_HOST, int(TARGET_PORT)), CONNECT_TIMEOUT
        )
    except (OSError, asyncio.TimeoutError) as exc:
        peer = client_writer.get_extra_info("peername")
        print(f"relay: target {TARGET} unreachable for {peer}: {exc}", flush=True)
        client_writer.close()
        return
    await asyncio.gather(pipe(client_reader, target_writer), pipe(target_reader, client_writer))


async def main():
    server = await asyncio.start_server(
        handle, "0.0.0.0", LISTEN_PORT, backlog=64, reuse_address=True
    )
    print(f"relay: listening on 0.0.0.0:{LISTEN_PORT} -> {TARGET}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
