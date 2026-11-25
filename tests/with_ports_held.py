#!/usr/bin/env python3
"""Run a command while this project's well-known ports are all taken.

usage: python3 tests/with_ports_held.py [--ports 8765-8768,8770-8772] -- CMD [ARGS...]

The ports of the app and the laptop scripts are fixed: 8765 (the phone's Share on Wi-Fi, with 8766-8768 as its
spare ports), 8770 (page_server), 8771 (phone_link's pairing), 8772 (the push receiver). A test that binds one of
them fails as soon as the real thing runs on the same machine (the owner's laptop) or a second lane runs the suite
on one host. This holds all of them, then runs CMD: a suite that stays green here takes its ports from the OS.

It does this inside a private network namespace (`unshare -rn`, no sudo): the ports are taken only there, so a
program of anyone else on this machine never notices, and nothing outside can reach what CMD starts. The exit status
is CMD's; 77 = this machine does not allow a private network namespace (nothing was run).
"""

import os
import socket
import subprocess
import sys

DEFAULT_PORTS = "8765-8768,8770-8772"
NAMESPACE_ENV = "EEG_PORTS_HELD_IN_NAMESPACE"


def parse_ports(spec: str) -> list[int]:
    ports: list[int] = []
    for part in spec.split(","):
        first, _, last = part.partition("-")
        ports.extend(range(int(first), int(last or first) + 1))
    return ports


def hold(ports: list[int]) -> list[socket.socket]:
    """A listening socket on every port, on every IPv4 address: nothing else can bind it, loopback or not."""
    held = []
    for p in ports:
        s = socket.socket()
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("0.0.0.0", p))
        s.listen(16)
        held.append(s)
    return held


def split_args(argv: list[str]) -> tuple[str, list[str]]:
    if "--" not in argv:
        raise SystemExit(__doc__)
    cut = argv.index("--")
    head, command = argv[:cut], argv[cut + 1 :]
    spec = DEFAULT_PORTS
    if len(head) == 2 and head[0] == "--ports":
        spec = head[1]
    elif head:
        raise SystemExit(__doc__)
    if not command:
        raise SystemExit(__doc__)
    return spec, command


def main(argv: list[str]) -> int:
    spec, command = split_args(argv)
    if os.environ.get(NAMESPACE_ENV) != "1":
        again = ["unshare", "-rn", sys.executable, os.path.abspath(__file__), *argv]
        probe = subprocess.run(["unshare", "-rn", "true"], capture_output=True)
        if probe.returncode != 0:
            print("no private network namespace here (unshare -rn failed): nothing run", file=sys.stderr)
            return 77
        return subprocess.run(again, env={**os.environ, NAMESPACE_ENV: "1"}).returncode
    subprocess.run(["ip", "link", "set", "lo", "up"], check=True)
    held = hold(parse_ports(spec))
    print(f"holding {len(held)} ports ({spec}) in a private network namespace", file=sys.stderr, flush=True)
    return subprocess.run(command).returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
