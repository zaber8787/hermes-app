"""S4: live artifact bytes are bounded across stores and released on use/TTL."""
from __future__ import annotations

import os
import multiprocessing
import time
from pathlib import Path
from types import SimpleNamespace


def _race_upload(home: str, label: str, barrier, out):
    from gateway.browser_control_artifacts import ArtifactStore, ArtifactTooLarge
    store = ArtifactStore(Path(home) / label, max_bytes=64)
    scope = SimpleNamespace(principal_id=label, transport_family="api")
    barrier.wait(timeout=10)
    try:
        store.store(b"x" * 8, filename="tiny.bin",
                    content_type="application/octet-stream", scope=scope)
        out.put("accepted")
    except ArtifactTooLarge:
        out.put("denied")


async def case_artifact_quota(args, server, check):
    from gateway.browser_control_artifacts import ArtifactStore, ArtifactTooLarge

    home = Path(os.environ["HERMES_HOME"])
    os.environ["HERMES_ARTIFACT_PRINCIPAL_LIVE_BYTES"] = "12"
    os.environ["HERMES_ARTIFACT_GLOBAL_LIVE_BYTES"] = "20"
    a = SimpleNamespace(principal_id="quota-a", transport_family="api")
    b = SimpleNamespace(principal_id="quota-b", transport_family="api")
    c = SimpleNamespace(principal_id="quota-c", transport_family="api")
    first = ArtifactStore(home / "artifacts-a", max_bytes=64)
    second = ArtifactStore(home / "artifacts-b", max_bytes=64)

    def put(store, scope, size=8):
        return store.store(b"x" * size, filename="tiny.bin",
                           content_type="application/octet-stream", scope=scope)

    one = put(first, a)
    try:
        put(second, a)
    except ArtifactTooLarge:
        pass
    else:
        check(False, "S4 second 8-byte upload exceeds 12-byte principal live quota")
    check(first.count() == 1 and second.count() == 0,
          "principal quota rejects before creating a second artifact")

    two = put(second, b)
    try:
        put(second, c)
    except ArtifactTooLarge:
        pass
    else:
        check(False, "S4 third 8-byte upload exceeds 20-byte global live quota")
    check(second.count() == 1, "global quota rejects before writing another artifact")

    payload, _ = first.load(one.artifact_id, scope=a)
    check(payload == b"x" * 8, "one-shot receipt still returns the original bytes")
    three = put(first, c)
    check(three.size_bytes == 8, "consumption releases principal and global live bytes")

    expiring = ArtifactStore(home / "artifacts-expiring", ttl_seconds=1, max_bytes=64)
    # Make room for a short-lived reservation, then let its TTL release it.
    second.load(two.artifact_id, scope=b)
    short = put(expiring, b)
    time.sleep(1.1)
    check(expiring.prune_expired() == 1, "the short-lived artifact expires")
    again = put(second, a)
    check(again.size_bytes == 8, "TTL expiry releases global live bytes")

    race_home = home / "quota-race"
    race_home.mkdir()
    os.environ["HERMES_HOME"] = str(race_home)
    os.environ["HERMES_ARTIFACT_GLOBAL_LIVE_BYTES"] = "12"
    context = multiprocessing.get_context("fork")
    barrier = context.Barrier(2)
    out = context.Queue()
    racers = [context.Process(target=_race_upload,
                              args=(str(race_home), str(i), barrier, out)) for i in range(2)]
    try:
        for racer in racers:
            racer.start()
        for racer in racers:
            racer.join(timeout=15)
        check(all(racer.exitcode == 0 for racer in racers)
              and sorted([out.get(timeout=2), out.get(timeout=2)]) == ["accepted", "denied"],
              "two processes atomically reserve one 8-byte slot under a 12-byte global cap")
    finally:
        os.environ["HERMES_HOME"] = str(home)
        for racer in racers:
            if racer.is_alive():
                racer.terminate()
                racer.join(timeout=2)
