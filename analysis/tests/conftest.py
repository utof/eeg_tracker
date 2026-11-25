import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "analysis"))


def pytest_configure(config):
    config.addinivalue_line("markers", "slow: runs the recorder with the fake headband for about 2.5 minutes")
    config.addinivalue_line(
        "markers",
        "realtime: waits on the wall clock (fake headband and board timers); fails on a loaded machine and passes "
        "alone: run apart, after the rest (`pytest -m realtime`, one process)",
    )
