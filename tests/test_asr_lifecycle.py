from __future__ import annotations

import asyncio
import threading
import time
from unittest.mock import AsyncMock, patch

from server.handlers.asr_handler import AsrHandler


class _BlockingASRManager:
    def __init__(self) -> None:
        self._backend_name = "qwen3_asr"
        self.is_ready = True
        self.entered = threading.Event()
        self.cancelled = threading.Event()
        self.calls = 0
        self.concurrent = 0
        self.max_concurrent = 0
        self._lock = threading.Lock()

    def listen_for_speech(self, max_retries: int = 0) -> None:
        del max_retries
        with self._lock:
            self.calls += 1
            self.concurrent += 1
            self.max_concurrent = max(self.max_concurrent, self.concurrent)
            self.cancelled.clear()
        self.entered.set()
        self.cancelled.wait(timeout=2.0)
        with self._lock:
            self.concurrent -= 1
        return None

    def cancel_listening(self) -> None:
        self.cancelled.set()

    def close(self) -> None:
        self.cancelled.set()


def test_concurrent_start_requests_create_one_listener() -> None:
    async def run() -> None:
        manager = _BlockingASRManager()

        def delayed_factory() -> _BlockingASRManager:
            time.sleep(0.05)
            return manager

        handler = AsrHandler()
        handler.configure(asr_manager_factory=delayed_factory)
        handler.schedule_unload = lambda delay_seconds=None: None

        with patch("server.handlers.asr_handler.bus.emit", new=AsyncMock()):
            first, second = await asyncio.gather(
                handler.start_listening({}),
                handler.start_listening({}),
            )
            assert {first["status"], second["status"]} == {
                "listening",
                "already_listening",
            }
            assert await asyncio.to_thread(manager.entered.wait, 1.0)
            await handler.stop_listening()

        assert manager.calls == 1
        assert manager.max_concurrent == 1

    asyncio.run(run())


def test_stop_joins_worker_before_a_new_start() -> None:
    async def run() -> None:
        manager = _BlockingASRManager()
        handler = AsrHandler()
        handler.configure(asr_manager=manager)
        handler.schedule_unload = lambda delay_seconds=None: None

        with patch("server.handlers.asr_handler.bus.emit", new=AsyncMock()):
            await handler.start_listening({})
            assert await asyncio.to_thread(manager.entered.wait, 1.0)
            await handler.stop_listening()

            manager.entered.clear()
            await handler.start_listening({})
            assert await asyncio.to_thread(manager.entered.wait, 1.0)
            await handler.stop_listening()

        assert manager.calls == 2
        assert manager.max_concurrent == 1

    asyncio.run(run())
