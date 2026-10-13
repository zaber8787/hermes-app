"""Isolated lifecycle regression for the cron bridge recovery worker."""
import asyncio
import tempfile
from pathlib import Path
from unittest.mock import patch

from compat import cron_delivery_store as store


async def main():
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        calls = []

        def drain(path):
            calls.append(Path(path))
            return {"delivered": 1, "deduped": 0, "queued": 0, "failed": 0}

        with patch.object(store, "drain_home", side_effect=drain):
            loop = asyncio.get_running_loop()
            store.arm_loop(loop, home)
            store.arm_loop(loop, home)
            for _ in range(100):
                if calls:
                    break
                await asyncio.sleep(0.01)
            assert calls == [home], calls
            health = store.liveness()
            assert health["state"] == "armed" and health["passes"] >= 1, health
            store.reset()
            await asyncio.sleep(0)
    print("PASS cron drainer: reload idempotent, immediate pass, liveness")


if __name__ == "__main__":
    asyncio.run(main())
