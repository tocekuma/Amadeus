"""Start the Electron-hosted wallpaper through the authenticated local protocol."""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import uuid

import aiohttp


async def start_wallpaper(*, port: int, token: str, timeout: float) -> dict[str, object]:
    request_id = uuid.uuid4().hex
    protocols = ["amadeus.local.v1", f"amadeus.auth.{token}"]
    client_timeout = aiohttp.ClientTimeout(total=timeout)
    async with aiohttp.ClientSession(timeout=client_timeout) as session:
        async with session.ws_connect(
            f"ws://127.0.0.1:{port}/ws",
            protocols=protocols,
            timeout=timeout,
        ) as websocket:
            await websocket.send_json(
                {
                    "type": "req",
                    "id": request_id,
                    "method": "wallpaper.start",
                    "params": {"slice_host": "electron"},
                }
            )
            while True:
                message = await websocket.receive(timeout=timeout)
                if message.type == aiohttp.WSMsgType.TEXT:
                    payload = json.loads(message.data)
                    if payload.get("type") == "res" and payload.get("id") == request_id:
                        result = payload.get("params") or {}
                        if not isinstance(result, dict):
                            raise RuntimeError("wallpaper.start returned a malformed response")
                        return result
                elif message.type in {
                    aiohttp.WSMsgType.CLOSE,
                    aiohttp.WSMsgType.CLOSED,
                    aiohttp.WSMsgType.ERROR,
                }:
                    raise RuntimeError("backend WebSocket closed before wallpaper.start completed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=17777)
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()

    token = os.environ.get("AMADEUS_BACKEND_TOKEN", "").strip()
    if not token:
        raise RuntimeError("AMADEUS_BACKEND_TOKEN is required")

    result = asyncio.run(start_wallpaper(port=args.port, token=token, timeout=args.timeout))
    if result.get("status") not in {"started", "already_running"}:
        raise RuntimeError(f"wallpaper.start failed: {result}")
    if result.get("sliceHost") != "electron":
        raise RuntimeError(f"wallpaper.start selected the wrong host: {result}")
    print(
        "wallpaper bridge ready: "
        f"status={result.get('status')} "
        f"asset_port={result.get('assetPort')} "
        f"bridge_port={result.get('bridgePort')}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
