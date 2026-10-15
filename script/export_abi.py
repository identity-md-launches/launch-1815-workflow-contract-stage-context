#!/usr/bin/env python3
"""Export ABIs from an existing forge build; --check verifies committed exports without writing."""

import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    for name in ("LaunchToken", "HongbaoBox"):
        artifact = root / "out" / f"{name}.sol" / f"{name}.json"
        if not artifact.is_file():
            raise SystemExit(f"Missing {name} artifact: run forge build first.")
        abi = json.loads(artifact.read_text())["abi"]
        contents = json.dumps(abi, indent=2) + "\n"
        target = root / "docs" / "abi" / f"{name}.json"
        if args.check:
            if not target.is_file() or target.read_text() != contents:
                raise SystemExit(f"Stale ABI export: docs/abi/{name}.json")
            print(f"Verified docs/abi/{name}.json")
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(contents)
            print(f"Exported docs/abi/{name}.json")


if __name__ == "__main__":
    main()
