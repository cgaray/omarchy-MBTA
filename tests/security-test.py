#!/usr/bin/env python3
import importlib.machinery
import importlib.util
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parent.parent
FETCH = ROOT / "bin" / "mbta-fetch"


def run(command, env=None):
    return subprocess.run(command, capture_output=True, check=False, timeout=10, env=env)


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def load_fetch_module():
    sys.dont_write_bytecode = True
    loader = importlib.machinery.SourceFileLoader("mbta_fetch_test", str(FETCH))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def main():
    rejected_urls = [
        "https://user@api-v3.mbta.com/predictions",
        "https://api-v3.mbta.com:4443/predictions",
        "http://api-v3.mbta.com/predictions",
        "https://example.com/predictions",
    ]
    for url in rejected_urls:
        result = run([str(FETCH), "1024", "1", url])
        require(result.returncode == 2, f"unsafe URL was not rejected before I/O: {url}")

    fetch_module = load_fetch_module()
    with tempfile.TemporaryDirectory() as directory:
        previous_runtime = os.environ.get("XDG_RUNTIME_DIR")
        os.environ["XDG_RUNTIME_DIR"] = directory
        try:
            for _ in range(fetch_module.MBTA_RATE_LIMIT):
                require(fetch_module.reserve_mbta_request(20),
                        "requests inside the local MBTA budget should be admitted")
            require(not fetch_module.reserve_mbta_request(20),
                    "requests beyond the local MBTA budget should be rejected before I/O")
            state = pathlib.Path(directory) / "omarchy-mbta-api-rate.json"
            require(state.stat().st_mode & 0o077 == 0,
                    "MBTA rate state must remain private")
        finally:
            if previous_runtime is None:
                os.environ.pop("XDG_RUNTIME_DIR", None)
            else:
                os.environ["XDG_RUNTIME_DIR"] = previous_runtime

    with tempfile.TemporaryDirectory() as directory:
        home = pathlib.Path(directory)
        plugins = home / ".config" / "omarchy" / "plugins"
        plugins.mkdir(parents=True)
        env = dict(os.environ, HOME=str(home))
        result = run([str(ROOT / "dev-sync.sh")], env=env)
        require(result.returncode == 0, "sync into a private plugin root should succeed")

        destination = plugins / "io.github.cgaray.mbta"
        shutil.rmtree(destination)
        outside = home / "outside"
        outside.mkdir()
        sentinel = outside / "keep"
        sentinel.write_text("keep", encoding="utf-8")
        destination.symlink_to(outside, target_is_directory=True)
        result = run([str(ROOT / "dev-sync.sh")], env=env)
        require(result.returncode == 2, "symlink destination should be rejected")
        require(sentinel.read_text(encoding="utf-8") == "keep",
                "rejected sync must not modify the symlink target")

    print("security helper tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
