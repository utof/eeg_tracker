"""The laptop recorders and everything they import stay standard library only (numpy segfaulted next to BrainBit's
SDK, DECISIONS 3): every import in the files, at the top or inside a function, followed through the repo's own
scripts. The only outside packages are each recorder's own driver, which its launcher (scripts/record_night.sh) adds.
"""
import ast
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
# the recorders' entry points, and night_files.py, which the hub imports for the Sleep page's report job
ENTRY = ("record_night.py", "record_ble.py", "record_diy.py", "recorder_hub.py", "night_files.py")
DRIVERS = {"neurosdk": "record_night.py's BrainBit SDK", "bleak": "brainbit_ble.py's Bluetooth",
           "serial": "diy_board.py's pyserial (DRIVER=diy)"}


def imported(path: Path) -> set[str]:
    """The top-level names of every module `path` imports anywhere (relative imports are not used in scripts/)."""
    names = set()
    for node in ast.walk(ast.parse(path.read_text(), str(path))):
        if isinstance(node, ast.Import):
            names |= {a.name.split(".")[0] for a in node.names}
        elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
            names.add(node.module.split(".")[0])
    return names


def closure() -> dict[str, set[str]]:
    """Each local script the recorders reach, with the outside modules it imports."""
    seen: dict[str, set[str]] = {}
    todo = [SCRIPTS / name for name in ENTRY]
    while todo:
        path = todo.pop()
        if path.name in seen:
            continue
        names = imported(path)
        local = {n for n in names if (SCRIPTS / f"{n}.py").is_file()}
        seen[path.name] = names - local
        todo += [SCRIPTS / f"{n}.py" for n in local]
    return seen


def test_the_recorders_import_only_the_standard_library_and_their_driver() -> None:
    reached = closure()
    assert {"recorder_hub.py", "night_files.py", "battery.py", "diy_board.py", "brainbit_ble.py"} <= set(reached)
    outside = {(f, n) for f, names in reached.items() for n in names
               if n not in sys.stdlib_module_names and n != "__future__" and n not in DRIVERS}
    assert outside == set(), f"not standard library: {sorted(outside)}"
    assert all(n not in names for names in reached.values() for n in ("numpy", "scipy", "mne", "torch"))


def test_the_check_sees_a_lazy_import(tmp_path: Path) -> None:
    """The walk finds an import inside a function too, so a lazy `import numpy` would fail the test above."""
    f = tmp_path / "x.py"
    f.write_text("import os\n\ndef f():\n    import numpy as np\n    from scipy import signal\n")
    assert imported(f) == {"os", "numpy", "scipy"}
