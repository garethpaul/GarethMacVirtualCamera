#!/usr/bin/env python3
import importlib.util
import struct
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True


ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts" / "validate_project.py"


def load_validator():
    spec = importlib.util.spec_from_file_location("validate_project", VALIDATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def atom(atom_type, payload=b""):
    return struct.pack(">I4s", 8 + len(payload), atom_type.encode("ascii")) + payload


def test_malformed_mdhd_atom_does_not_raise():
    validator = load_validator()
    malformed_mp4 = atom("moov", atom("trak", atom("mdia", atom("mdhd"))))

    with tempfile.NamedTemporaryFile(suffix=".mp4", delete=False) as fixture:
        fixture.write(malformed_mp4)
        fixture_path = Path(fixture.name)

    try:
        metadata = validator.mp4_video_metadata(fixture_path)
    finally:
        fixture_path.unlink(missing_ok=True)

    if metadata != {"dimensions": None, "frame_rate": None, "duration_seconds": None}:
        raise AssertionError(f"Unexpected malformed mdhd metadata: {metadata}")


def main():
    test_malformed_mdhd_atom_does_not_raise()
    print("Project validator tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
