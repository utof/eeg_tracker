"""The push check's own receiver port (app/tool/push_smoke.py): never the real receiver's 8772 unless asked.

The owner's laptop holds 8772 for his phone (`phone_link.py --keep`); a check that listened there as well
failed on his laptop, and knocked on the real receiver when it was not (the run of 2026-11-25 01:07)."""
from __future__ import annotations

import socket
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "app" / "tool"))
import push_smoke as ps  # noqa: E402

REAL_RECEIVER_PORT = 8772


def test_without_a_push_port_the_check_takes_a_free_one_and_not_the_real_receivers() -> None:
    ports = {ps.push_port_from(["app.apk"]) for _ in range(5)}
    assert REAL_RECEIVER_PORT not in ports
    for port in ports:
        with socket.socket() as s:
            s.bind(("127.0.0.1", port))  # nothing holds it now


def test_the_push_port_flag_is_kept() -> None:
    assert ps.push_port_from(["app.apk", "--replay", "r.apk", "--push-port", "18772"]) == 18772


def test_asking_for_the_real_receivers_port_is_still_possible() -> None:
    assert ps.push_port_from(["app.apk", "--push-port", str(REAL_RECEIVER_PORT)]) == REAL_RECEIVER_PORT
