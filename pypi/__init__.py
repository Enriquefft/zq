"""zq-json: An agents-first jq alternative."""

import os
import sys

__version__ = "0.0.0"  # Stamped by publish.sh


def _get_binary_path():
    bin_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_bin")
    name = "zq.exe" if sys.platform == "win32" else "zq"
    path = os.path.join(bin_dir, name)
    if not os.path.isfile(path):
        raise FileNotFoundError(
            f"zq binary not found at {path}. "
            "Try reinstalling: pip install --force-reinstall zq-json"
        )
    return path


def main():
    binary = _get_binary_path()
    args = [binary] + sys.argv[1:]
    if sys.platform == "win32":
        import subprocess

        raise SystemExit(subprocess.call(args))
    else:
        os.execv(binary, args)


if __name__ == "__main__":
    main()
