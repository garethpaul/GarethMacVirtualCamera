#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import shutil
import struct
import subprocess
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


def write_metadata_fixture(mp4_data):
    with tempfile.NamedTemporaryFile(suffix=".mp4", delete=False) as fixture:
        fixture.write(mp4_data)
        return Path(fixture.name)


def write_png_fixture(png_data):
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as fixture:
        fixture.write(png_data)
        return Path(fixture.name)


@contextlib.contextmanager
def tracked_fixture_repo():
    with tempfile.TemporaryDirectory() as temporary_directory:
        fixture_root = Path(temporary_directory) / "repo"
        fixture_root.mkdir()

        tracked_files = subprocess.run(
            ["git", "ls-files", "-z"],
            cwd=ROOT,
            check=True,
            capture_output=True,
        ).stdout.decode("utf-8").split("\0")

        for relative_name in tracked_files:
            if not relative_name:
                continue

            source_path = ROOT / relative_name
            fixture_path = fixture_root / relative_name
            fixture_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source_path, fixture_path)

        yield fixture_root


def run_validator(fixture_root):
    validator = load_validator()
    validator.ROOT = fixture_root
    output = io.StringIO()

    with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
        status = validator.main()

    return status, output.getvalue()


def replace_once(path, old, new):
    source = path.read_text(encoding="utf-8")
    count = source.count(old)

    if count != 1:
        raise AssertionError(f"Expected exactly one replacement target in {path}, found {count}.")

    path.write_text(source.replace(old, new, 1), encoding="utf-8")


def assert_validator_rejects_mutation(relative_path, old, new, expected_failure):
    with tracked_fixture_repo() as fixture_root:
        replace_once(fixture_root / relative_path, old, new)
        status, output = run_validator(fixture_root)

    if status == 0:
        raise AssertionError(f"Validator accepted mutation in {relative_path}.")

    if expected_failure not in output:
        raise AssertionError(
            f"Validator output did not include expected failure for {relative_path}.\n"
            f"Expected: {expected_failure}\n"
            f"Output:\n{output}"
        )


def test_malformed_mdhd_atom_does_not_raise():
    validator = load_validator()
    malformed_mp4 = atom("moov", atom("trak", atom("mdia", atom("mdhd"))))

    fixture_path = write_metadata_fixture(malformed_mp4)

    try:
        metadata = validator.mp4_video_metadata(fixture_path)
    finally:
        fixture_path.unlink(missing_ok=True)

    if metadata != {"dimensions": None, "frame_rate": None, "duration_seconds": None}:
        raise AssertionError(f"Unexpected malformed mdhd metadata: {metadata}")


def test_unsupported_mdhd_version_does_not_report_duration():
    validator = load_validator()
    mdhd_payload = b"\2\0\0\0" + b"\0" * 8 + struct.pack(">II", 24_000, 24_000)
    hdlr_payload = b"\0" * 8 + b"vide"
    minimal_mp4 = atom(
        "moov",
        atom(
            "trak",
            atom(
                "mdia",
                atom("mdhd", mdhd_payload) + atom("hdlr", hdlr_payload),
            ),
        ),
    )

    fixture_path = write_metadata_fixture(minimal_mp4)

    try:
        metadata = validator.mp4_video_metadata(fixture_path)
    finally:
        fixture_path.unlink(missing_ok=True)

    if metadata["duration_seconds"] is not None:
        raise AssertionError(f"Unexpected duration for unsupported mdhd version: {metadata}")


def test_unsupported_hdlr_version_does_not_report_duration():
    validator = load_validator()
    mdhd_payload = b"\0\0\0\0" + b"\0" * 8 + struct.pack(">II", 24_000, 24_000)
    hdlr_payload = b"\1\0\0\0" + b"\0" * 4 + b"vide"
    minimal_mp4 = atom(
        "moov",
        atom(
            "trak",
            atom(
                "mdia",
                atom("mdhd", mdhd_payload) + atom("hdlr", hdlr_payload),
            ),
        ),
    )

    fixture_path = write_metadata_fixture(minimal_mp4)

    try:
        metadata = validator.mp4_video_metadata(fixture_path)
    finally:
        fixture_path.unlink(missing_ok=True)

    if metadata["duration_seconds"] is not None:
        raise AssertionError(f"Unexpected duration for unsupported hdlr version: {metadata}")


def test_unsupported_stts_version_does_not_report_frame_rate():
    validator = load_validator()
    mdhd_payload = b"\0\0\0\0" + b"\0" * 8 + struct.pack(">II", 24_000, 24_000)
    hdlr_payload = b"\0" * 8 + b"vide"
    stts_payload = b"\1\0\0\0" + struct.pack(">I", 1) + struct.pack(">II", 24, 1_000)
    minimal_mp4 = atom(
        "moov",
        atom(
            "trak",
            atom(
                "mdia",
                atom("mdhd", mdhd_payload)
                + atom("hdlr", hdlr_payload)
                + atom("minf", atom("stbl", atom("stts", stts_payload))),
            ),
        ),
    )

    fixture_path = write_metadata_fixture(minimal_mp4)

    try:
        metadata = validator.mp4_video_metadata(fixture_path)
    finally:
        fixture_path.unlink(missing_ok=True)

    if metadata["frame_rate"] is not None:
        raise AssertionError(f"Unexpected frame rate for unsupported stts version: {metadata}")


def test_unsupported_stsd_version_does_not_report_dimensions():
    validator = load_validator()
    mdhd_payload = b"\0\0\0\0" + b"\0" * 8 + struct.pack(">II", 24_000, 24_000)
    hdlr_payload = b"\0" * 8 + b"vide"
    sample_description = atom("avc1", b"\0" * 24 + struct.pack(">HH", 1280, 720))
    stsd_payload = b"\1\0\0\0" + struct.pack(">I", 1) + sample_description
    minimal_mp4 = atom(
        "moov",
        atom(
            "trak",
            atom(
                "mdia",
                atom("mdhd", mdhd_payload)
                + atom("hdlr", hdlr_payload)
                + atom("minf", atom("stbl", atom("stsd", stsd_payload))),
            ),
        ),
    )

    fixture_path = write_metadata_fixture(minimal_mp4)

    try:
        metadata = validator.mp4_video_metadata(fixture_path)
    finally:
        fixture_path.unlink(missing_ok=True)

    if metadata["dimensions"] is not None:
        raise AssertionError(f"Unexpected dimensions for unsupported stsd version: {metadata}")


def test_non_video_track_stsd_does_not_report_dimensions():
    validator = load_validator()
    mdhd_payload = b"\0\0\0\0" + b"\0" * 8 + struct.pack(">II", 24_000, 24_000)
    hdlr_payload = b"\0" * 8 + b"soun"
    sample_description = atom("avc1", b"\0" * 24 + struct.pack(">HH", 1280, 720))
    stsd_payload = b"\0\0\0\0" + struct.pack(">I", 1) + sample_description
    minimal_mp4 = atom(
        "moov",
        atom(
            "trak",
            atom(
                "mdia",
                atom("mdhd", mdhd_payload)
                + atom("hdlr", hdlr_payload)
                + atom("minf", atom("stbl", atom("stsd", stsd_payload))),
            ),
        ),
    )

    fixture_path = write_metadata_fixture(minimal_mp4)

    try:
        metadata = validator.mp4_video_metadata(fixture_path)
    finally:
        fixture_path.unlink(missing_ok=True)

    if metadata["dimensions"] is not None:
        raise AssertionError(f"Unexpected dimensions for non-video track stsd: {metadata}")


def test_zero_sample_count_stts_does_not_report_frame_rate():
    validator = load_validator()
    mdhd_payload = b"\0\0\0\0" + b"\0" * 8 + struct.pack(">II", 24_000, 24_000)
    hdlr_payload = b"\0" * 8 + b"vide"
    stts_payload = b"\0\0\0\0" + struct.pack(">I", 1) + struct.pack(">II", 0, 1_000)
    minimal_mp4 = atom(
        "moov",
        atom(
            "trak",
            atom(
                "mdia",
                atom("mdhd", mdhd_payload)
                + atom("hdlr", hdlr_payload)
                + atom("minf", atom("stbl", atom("stts", stts_payload))),
            ),
        ),
    )

    fixture_path = write_metadata_fixture(minimal_mp4)

    try:
        metadata = validator.mp4_video_metadata(fixture_path)
    finally:
        fixture_path.unlink(missing_ok=True)

    if metadata["frame_rate"] is not None:
        raise AssertionError(f"Unexpected frame rate for zero-sample stts entry: {metadata}")


def test_non_integer_stts_rate_does_not_report_frame_rate():
    validator = load_validator()
    mdhd_payload = b"\0\0\0\0" + b"\0" * 8 + struct.pack(">II", 24_000, 24_000)
    hdlr_payload = b"\0" * 8 + b"vide"
    stts_payload = b"\0\0\0\0" + struct.pack(">I", 1) + struct.pack(">II", 24, 1_001)
    minimal_mp4 = atom(
        "moov",
        atom(
            "trak",
            atom(
                "mdia",
                atom("mdhd", mdhd_payload)
                + atom("hdlr", hdlr_payload)
                + atom("minf", atom("stbl", atom("stts", stts_payload))),
            ),
        ),
    )

    fixture_path = write_metadata_fixture(minimal_mp4)

    try:
        metadata = validator.mp4_video_metadata(fixture_path)
    finally:
        fixture_path.unlink(missing_ok=True)

    if metadata["frame_rate"] is not None:
        raise AssertionError(f"Unexpected frame rate for non-integer stts timing: {metadata}")


def test_truncated_stts_entry_count_does_not_report_frame_rate():
    validator = load_validator()
    mdhd_payload = b"\0\0\0\0" + b"\0" * 8 + struct.pack(">II", 24_000, 24_000)
    hdlr_payload = b"\0" * 8 + b"vide"
    stts_payload = b"\0\0\0\0" + struct.pack(">I", 2) + struct.pack(">II", 24, 1_000)
    minimal_mp4 = atom(
        "moov",
        atom(
            "trak",
            atom(
                "mdia",
                atom("mdhd", mdhd_payload)
                + atom("hdlr", hdlr_payload)
                + atom("minf", atom("stbl", atom("stts", stts_payload))),
            ),
        ),
    )

    fixture_path = write_metadata_fixture(minimal_mp4)

    try:
        metadata = validator.mp4_video_metadata(fixture_path)
    finally:
        fixture_path.unlink(missing_ok=True)

    if metadata["frame_rate"] is not None:
        raise AssertionError(f"Unexpected frame rate for truncated stts entries: {metadata}")


def test_zero_stsd_entry_count_does_not_report_dimensions():
    validator = load_validator()
    mdhd_payload = b"\0\0\0\0" + b"\0" * 8 + struct.pack(">II", 24_000, 24_000)
    hdlr_payload = b"\0" * 8 + b"vide"
    sample_description = atom("avc1", b"\0" * 24 + struct.pack(">HH", 1280, 720))
    stsd_payload = b"\0\0\0\0" + struct.pack(">I", 0) + sample_description
    minimal_mp4 = atom(
        "moov",
        atom(
            "trak",
            atom(
                "mdia",
                atom("mdhd", mdhd_payload)
                + atom("hdlr", hdlr_payload)
                + atom("minf", atom("stbl", atom("stsd", stsd_payload))),
            ),
        ),
    )

    fixture_path = write_metadata_fixture(minimal_mp4)

    try:
        metadata = validator.mp4_video_metadata(fixture_path)
    finally:
        fixture_path.unlink(missing_ok=True)

    if metadata["dimensions"] is not None:
        raise AssertionError(f"Unexpected dimensions for zero-entry stsd table: {metadata}")


def test_truncated_png_signature_does_not_raise():
    validator = load_validator()
    fixture_path = write_png_fixture(b"\x89PNG\r\n\x1a\n" + b"\0" * 8)

    try:
        dimensions = validator.png_dimensions(fixture_path)
    finally:
        fixture_path.unlink(missing_ok=True)

    if dimensions is not None:
        raise AssertionError(f"Unexpected dimensions for truncated PNG header: {dimensions}")


def test_non_ihdr_png_header_does_not_report_dimensions():
    validator = load_validator()
    png_header = b"\x89PNG\r\n\x1a\n" + struct.pack(">I4sII", 13, b"IDAT", 128, 128)
    fixture_path = write_png_fixture(png_header)

    try:
        dimensions = validator.png_dimensions(fixture_path)
    finally:
        fixture_path.unlink(missing_ok=True)

    if dimensions is not None:
        raise AssertionError(f"Unexpected dimensions for non-IHDR PNG header: {dimensions}")


def test_malformed_icon_size_metadata_does_not_raise():
    validator = load_validator()
    malformed_entries = [
        {"size": "large", "scale": "2x"},
        {"size": "16x32", "scale": "1x"},
        {"size": "16x16", "scale": "0x"},
        {"size": "16x16", "scale": "1"},
        {"size": " 16x16", "scale": "1x"},
        {"size": "16x16", "scale": " 1x"},
        {"size": "+16x16", "scale": "1x"},
        {"size": "1_6x16", "scale": "1x"},
        {"size": "16x16", "scale": "+1x"},
        {"size": "16x16", "scale": "1_x"},
        {"size": 16, "scale": "1x"},
    ]

    for entry in malformed_entries:
        expected_size = validator.expected_icon_pixel_size(entry)
        if expected_size is not None:
            raise AssertionError(f"Unexpected icon size for malformed metadata {entry}: {expected_size}")


def test_tracked_fixture_validates():
    with tracked_fixture_repo() as fixture_root:
        status, output = run_validator(fixture_root)

    if status != 0:
        raise AssertionError(f"Tracked fixture should validate cleanly.\n{output}")


def test_directory_video_fixture_reports_validation_failure():
    with tracked_fixture_repo() as fixture_root:
        video_path = fixture_root / "Extension" / "video.mp4"
        video_path.unlink()
        video_path.mkdir()
        status, output = run_validator(fixture_root)

    if status == 0:
        raise AssertionError("Validator accepted a directory in place of Extension/video.mp4.")

    if "Extension/video.mp4 is missing, empty, or not a file" not in output:
        raise AssertionError(f"Validator did not report the non-file video fixture cleanly.\n{output}")


def test_validator_rejects_missing_source_video_file_guard():
    assert_validator_rejects_mutation(
        "scripts/validate_project.py",
        """    require(video_path.is_file() and video_path.stat().st_size > 0,
            "Extension/video.mp4 is missing, empty, or not a file",
            failures)
    video_metadata = mp4_video_metadata(video_path) if video_path.is_file() else {}
""",
        """    require(video_path.exists() and video_path.stat().st_size > 0,
            "Extension/video.mp4 is missing or empty",
            failures)
    video_metadata = mp4_video_metadata(video_path) if video_path.exists() else {}
""",
        "project validator should reject non-file source video fixtures without a traceback",
    )


def test_directory_icon_fixture_reports_validation_failure():
    with tracked_fixture_repo() as fixture_root:
        icon_path = fixture_root / "GarethVideoCam" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-16.png"
        icon_path.unlink()
        icon_path.mkdir()
        status, output = run_validator(fixture_root)

    if status == 0:
        raise AssertionError("Validator accepted a directory in place of an app icon PNG.")

    if "app icon file is missing, empty, or not a file: AppIcon-16.png" not in output:
        raise AssertionError(f"Validator did not report the non-file app icon fixture cleanly.\n{output}")


def test_validator_rejects_missing_icon_file_guard():
    assert_validator_rejects_mutation(
        "scripts/validate_project.py",
        """            require(icon_path.is_file() and icon_path.stat().st_size > 0,
                    f"app icon file is missing, empty, or not a file: {icon_filename}",
                    failures)
            if icon_path.is_file():
""",
        """            require(icon_path.exists() and icon_path.stat().st_size > 0,
                    f"app icon file is missing or empty: {icon_filename}",
                    failures)
            if icon_path.exists():
""",
        "project validator should reject non-file app icon fixtures without a traceback",
    )


def test_validator_rejects_missing_indefinite_stream_duration_guard():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """        if let frameDuration = streamProperties.frameDuration {
            guard frameDuration.isNumeric,
                  frameDuration.flags.contains(.valid),
                  !frameDuration.flags.contains(.indefinite),
                  CMTimeCompare(frameDuration, CameraExtensionConfiguration.frameDuration) == 0 else {""",
        """        if let frameDuration = streamProperties.frameDuration {
            guard frameDuration.isNumeric,
                  frameDuration.flags.contains(.valid),
                  CMTimeCompare(frameDuration, CameraExtensionConfiguration.frameDuration) == 0 else {""",
        "extension stream should reject unsupported, indefinite, or non-finite frame-duration requests",
    )


def test_validator_rejects_missing_non_finite_stream_duration_guard():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """        if let frameDuration = streamProperties.frameDuration {
            guard frameDuration.isNumeric,
                  frameDuration.flags.contains(.valid),
                  !frameDuration.flags.contains(.indefinite),
                  CMTimeCompare(frameDuration, CameraExtensionConfiguration.frameDuration) == 0 else {""",
        """        if let frameDuration = streamProperties.frameDuration {
            guard frameDuration.flags.contains(.valid),
                  !frameDuration.flags.contains(.indefinite),
                  CMTimeCompare(frameDuration, CameraExtensionConfiguration.frameDuration) == 0 else {""",
        "extension stream should reject unsupported, indefinite, or non-finite frame-duration requests",
    )


def test_validator_rejects_missing_non_finite_asset_duration_guard():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """        guard duration.isNumeric,
              duration.flags.contains(.valid),
              !duration.flags.contains(.indefinite),
              CMTimeCompare(duration, .zero) > 0 else {""",
        """        guard duration.flags.contains(.valid),
              !duration.flags.contains(.indefinite),
              CMTimeCompare(duration, .zero) > 0 else {""",
        "extension should reject non-finite bundled-video durations before loop scheduling",
    )


def test_validator_rejects_reader_loop_while_reading():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """        case .reading:
            return
        case .completed:""",
        """        case .reading:
            break
        case .completed:""",
        "extension should loop bundled video only after the asset reader completes",
    )


def test_validator_rejects_reader_loop_before_completion():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """        case .completed:
            break
        case .failed:""",
        """        case .completed:
            return
        case .failed:""",
        "extension should loop bundled video only after the asset reader completes",
    )


def test_validator_rejects_missing_cancelled_preparation_reader_cleanup():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """            if Task.isCancelled {
                readerState.assetReader.cancelReading()
                return
            }""",
        """            if Task.isCancelled {
                return
            }""",
        "extension should cancel a prepared asset reader when stream preparation is cancelled",
    )


def test_validator_rejects_missing_stale_completion_reader_cleanup():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """                guard self.isCurrentStreamPreparation(generation: generation, videoURL: videoURL) else {
                    readerState.assetReader.cancelReading()
                    logger.debug("Ignoring stale stream preparation completion")""",
        """                guard self.isCurrentStreamPreparation(generation: generation, videoURL: videoURL) else {
                    logger.debug("Ignoring stale stream preparation completion")""",
        "extension should cancel a prepared asset reader when its queued completion becomes stale",
    )


def test_validator_rejects_missing_released_source_reader_cleanup():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """                guard let self else {
                    readerState.assetReader.cancelReading()
                    return
                }""",
        """                guard let self else {
                    return
                }""",
        "extension should cancel a prepared asset reader when its device source is released",
    )


def test_validator_rejects_stale_reader_plan_status_regression():
    assert_validator_rejects_mutation(
        "docs/plans/2026-06-12-stale-reader-cancellation.md",
        "status: completed",
        "status: planned",
        "stale reader cancellation plan should record completed status and actual verification",
    )


def test_validator_rejects_stale_reader_plan_evidence_regression():
    assert_validator_rejects_mutation(
        "docs/plans/2026-06-12-stale-reader-cancellation.md",
        "Pull-request run `27393152277`",
        "Pull-request run `00000000000`",
        "stale reader cancellation plan should record completed status and actual verification",
    )


def test_validator_rejects_transactional_timing_plan_status_regression():
    assert_validator_rejects_mutation(
        "docs/plans/2026-06-13-transactional-sample-timing.md",
        "status: completed",
        "status: planned",
        "transactional sample timing plan should record completed status and actual verification",
    )


def test_validator_rejects_transactional_timing_plan_evidence_regression():
    assert_validator_rejects_mutation(
        "docs/plans/2026-06-13-transactional-sample-timing.md",
        "early timestamp offset mutation failed",
        "early timestamp offset mutation passed unexpectedly",
        "transactional sample timing plan should record completed status and actual verification",
    )


def test_validator_rejects_all_branch_ci_plan_status_regression():
    assert_validator_rejects_mutation(
        "docs/plans/2026-06-13-all-branch-hosted-validation.md",
        "status: completed",
        "status: planned",
        "all-branch hosted validation plan should record completed status and actual verification",
    )


def test_validator_rejects_all_branch_ci_plan_evidence_regression():
    assert_validator_rejects_mutation(
        "docs/plans/2026-06-13-all-branch-hosted-validation.md",
        "The main-only push mutation failed",
        "The push trigger was inspected",
        "all-branch hosted validation plan should record completed status and actual verification",
    )


def test_validator_rejects_main_only_push_validation():
    assert_validator_rejects_mutation(
        ".github/workflows/macos-build.yml",
        """  push:
  pull_request:
""",
        """  push:
    branches:
      - main
  pull_request:
""",
        "macOS build workflow should validate pushes and pull requests for every branch",
    )


def test_validator_rejects_main_only_pull_request_validation():
    assert_validator_rejects_mutation(
        ".github/workflows/macos-build.yml",
        """  pull_request:
  workflow_dispatch:
""",
        """  pull_request:
    branches:
      - main
  workflow_dispatch:
""",
        "macOS build workflow should validate pushes and pull requests for every branch",
    )


def test_validator_rejects_missing_pull_request_validation():
    assert_validator_rejects_mutation(
        ".github/workflows/macos-build.yml",
        "  pull_request:\n",
        "",
        "macOS build workflow should validate pushes and pull requests for every branch",
    )


def test_validator_rejects_caller_relative_makefile():
    assert_validator_rejects_mutation(
        "Makefile",
        "override ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))",
        "ROOT := $(CURDIR)",
        "Makefile should protect its root and expose lint, test, build, and check validation entry points",
    )


def test_validator_rejects_overrideable_makefile_root():
    assert_validator_rejects_mutation(
        "Makefile",
        "override ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))",
        "ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))",
        "Makefile should protect its root and expose lint, test, build, and check validation entry points",
    )


def test_validator_rejects_missing_check_project_root():
    assert_validator_rejects_mutation(
        "scripts/check_project.sh",
        '''ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
''',
        "",
        "check_project should enter its repository root before running relative commands",
    )


def test_validator_rejects_location_independent_make_plan_status_regression():
    assert_validator_rejects_mutation(
        "docs/plans/2026-06-13-location-independent-make.md",
        "status: completed",
        "status: planned",
        "location-independent Make plan should record completed status and actual verification",
    )


def test_validator_rejects_location_independent_make_plan_evidence_regression():
    assert_validator_rejects_mutation(
        "docs/plans/2026-06-13-location-independent-make.md",
        "caller-relative Makefile mutation failed",
        "caller-relative Makefile mutation inspected",
        "location-independent Make plan should record completed status and actual verification",
    )


def test_validator_rejects_location_independent_make_documentation_regression():
    assert_validator_rejects_mutation(
        "README.md",
        "absolute Makefile path",
        "loaded build file path",
        "README and CHANGES should document location-independent project verification",
    )


def test_validator_rejects_missing_video_dimension_unwrap_guard():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """        guard let displayDimensions = Self.displayDimensions(naturalSize: naturalSize,
                                                             preferredTransform: preferredTransform) else {
            throw CameraExtensionError.invalidVideoDimensions
        }
""",
        """        let displayDimensions = Self.displayDimensions(naturalSize: naturalSize,
                                                        preferredTransform: preferredTransform)!""",
        "extension should reject non-finite or out-of-range bundled-video dimensions before integer conversion",
    )


def test_validator_rejects_missing_finite_video_dimension_guard():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """        guard roundedWidth.isFinite,
              roundedHeight.isFinite,
              roundedWidth <= CGFloat(Int32.max),
              roundedHeight <= CGFloat(Int32.max) else {
            return nil
        }

""",
        "",
        "extension should reject non-finite or out-of-range bundled-video dimensions before integer conversion",
    )


def test_validator_rejects_missing_non_finite_video_frame_rate_guard():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """        guard nominalFrameRate.isFinite,
              nominalFrameRate > 0,
              abs(nominalFrameRate - Float(CameraExtensionConfiguration.frameRate)) < 0.01 else {""",
        """        guard nominalFrameRate > 0,
              abs(nominalFrameRate - Float(CameraExtensionConfiguration.frameRate)) < 0.01 else {""",
        "extension should reject non-finite bundled-video frame rates before streaming",
    )


def test_validator_rejects_missing_non_finite_sample_time_guard():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """        guard Self.isFiniteTime(presentationTime) else {
            logger.error("Skipping sample buffer with invalid, indefinite, or infinite presentation timestamp")
            return
        }""",
        """        guard presentationTime.flags.contains(.valid) else {
            logger.error("Skipping sample buffer with invalid presentation timestamp")
            return
        }""",
        "extension should reject non-finite sample and host times before retiming",
    )


def test_validator_rejects_missing_adjusted_decode_time_guard():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """            let decodeOffset = CMTimeSubtract(timing.decodeTimeStamp, originalPresentationTime)
            let adjustedDecodeTime = CMTimeAdd(adjustedPresentationTime, decodeOffset)
            guard Self.isFiniteTime(adjustedDecodeTime) else {
                logger.error("Skipping sample buffer with non-finite adjusted decode timestamp")
                return nil
            }

            timing.decodeTimeStamp = adjustedDecodeTime""",
        """            let decodeOffset = CMTimeSubtract(timing.decodeTimeStamp, originalPresentationTime)
            timing.decodeTimeStamp = CMTimeAdd(adjustedPresentationTime, decodeOffset)""",
        "extension should reject non-finite sample and host times before retiming",
    )


def test_validator_rejects_missing_sample_count_retiming_guard():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """        guard CMSampleBufferGetNumSamples(sampleBuffer) == 1 else {
            logger.error("Skipping sample buffer with unexpected sample count")
            return nil
        }

""",
        "",
        "extension should require one-sample buffers and CoreMedia retiming calls to succeed before streaming",
    )


def test_validator_rejects_missing_sample_timing_status_guard():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """        guard timingStatus == noErr else {
            logger.error("Failed to read sample timing info: \\(timingStatus, privacy: .public)")
            return nil
        }""",
        """        if timingStatus != noErr {
            logger.error("Failed to read sample timing info: \\(timingStatus, privacy: .public)")
        }""",
        "extension should require one-sample buffers and CoreMedia retiming calls to succeed before streaming",
    )


def test_validator_rejects_missing_retimed_copy_status_guard():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """        guard copyStatus == noErr, let retimedSampleBuffer = copiedSampleBuffer else {
            logger.error("Failed to retime sample buffer: \\(copyStatus, privacy: .public)")
            return nil
        }""",
        """        guard let retimedSampleBuffer = copiedSampleBuffer else {
            logger.error("Failed to retime sample buffer: \\(copyStatus, privacy: .public)")
            return nil
        }""",
        "extension should require one-sample buffers and CoreMedia retiming calls to succeed before streaming",
    )


def test_validator_rejects_missing_host_time_sample_retiming():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """        let assetPresentationTime = CMTimeAdd(presentationTime, candidateTimestampOffset)
        guard Self.isFiniteTime(assetPresentationTime) else {
            logger.error("Skipping sample buffer with non-finite adjusted presentation timestamp")
            return
        }

        let hostScaledAssetPresentationTime = CMTimeConvertScale(assetPresentationTime,
                                                                 timescale: CMTimeScale(NSEC_PER_SEC),
                                                                 method: .roundTowardZero)
        guard Self.isFiniteTime(hostScaledAssetPresentationTime) else {
            logger.error("Skipping sample buffer with non-finite host-scaled presentation timestamp")
            return
        }

        guard let currentHostTime = currentHostTime() else {
            logger.error("Skipping sample buffer because host clock time is unavailable")
            return
        }

        guard let hostTiming = hostPresentationTime(for: hostScaledAssetPresentationTime,
                                                    currentHostTime: currentHostTime,
                                                    timebase: hostPresentationTimebase) else {
            logger.error("Skipping sample buffer with non-finite host presentation timestamp")
            return
        }

        guard let hostTimeInNanoseconds = hostTimeInNanoseconds(from: hostTiming.presentationTime) else {
            logger.error("Skipping sample buffer with non-finite host-time nanoseconds")
            return
        }""",
        """        let adjustedPresentationTime = CMTimeAdd(presentationTime, candidateTimestampOffset)
        let hostTimeInNanoseconds = UInt64(0)""",
        "extension should retime emitted sample timestamps into the advertised host-time clock domain",
    )


def test_validator_rejects_early_timestamp_offset_commit():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """        let assetPresentationTime = CMTimeAdd(presentationTime, candidateTimestampOffset)""",
        """        timestampOffset = candidateTimestampOffset
        let assetPresentationTime = CMTimeAdd(presentationTime, candidateTimestampOffset)""",
        "extension should commit sample timing state only after retiming succeeds",
    )


def test_validator_rejects_early_last_presentation_commit():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """        let assetPresentationTime = CMTimeAdd(presentationTime, candidateTimestampOffset)""",
        """        lastPresentationTime = presentationTime
        let assetPresentationTime = CMTimeAdd(presentationTime, candidateTimestampOffset)""",
        "extension should commit sample timing state only after retiming succeeds",
    )


def test_validator_rejects_missing_transactional_timing_validator():
    assert_validator_rejects_mutation(
        "scripts/validate_project.py",
        '''        "extension should commit sample timing state only after retiming succeeds",
        failures,
    )''',
        '''        "transactional timing validation removed",
        failures,
    )''',
        "validate_project should enforce transactional sample timing state",
    )


def test_source_requires_strictly_increasing_sample_timestamps():
    extension_source = (ROOT / "Extension/ExtensionProvider.swift").read_text(encoding="utf-8")

    assert "SampleTimestampValidator.strictlyAdvances" in extension_source, (
        "extension should reject duplicate or regressing sample timestamps before retiming"
    )


def test_reader_restart_precedes_loop_timing_commit():
    extension_source = (ROOT / "Extension/ExtensionProvider.swift").read_text(encoding="utf-8")
    restart_index = extension_source.find("let nextReaderState = try makeAssetReader")
    loop_commit_index = extension_source.find("advanceLoopTiming(by: assetDuration)")
    install_index = extension_source.find("installAssetReaderState(nextReaderState)")

    assert min(restart_index, loop_commit_index, install_index) >= 0, (
        "extension should expose the transactional reader restart sequence"
    )
    assert restart_index < loop_commit_index < install_index, (
        "extension should not commit loop timing until the replacement reader starts successfully"
    )


def test_reader_start_failure_cancels_partial_reader():
    extension_source = (ROOT / "Extension/ExtensionProvider.swift").read_text(encoding="utf-8")

    assert """            guard nextAssetReader.startReading() else {
                let failureDescription = nextAssetReader.error?.localizedDescription ?? "unknown error"
                nextAssetReader.cancelReading()
                throw CameraExtensionError.assetReaderFailedToStart(failureDescription)
            }""" in extension_source, (
        "extension should cancel a partially started reader before propagating startup failure"
    )


def test_validator_rejects_non_strict_sample_timestamp_comparison():
    assert_validator_rejects_mutation(
        "Extension/SampleTimestampValidator.swift",
        "return CMTimeCompare(presentationTime, previousPresentationTime) > 0",
        "return CMTimeCompare(presentationTime, previousPresentationTime) >= 0",
        "extension should reject duplicate or regressing source and host timestamps",
    )


def test_validator_rejects_missing_host_timestamp_guard():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """        guard SampleTimestampValidator.strictlyAdvances(hostTiming.presentationTime,
                                                        after: lastHostPresentationTime) else {
            logger.error("Skipping sample buffer with a duplicate or regressing host presentation timestamp")
            return
        }

""",
        "",
        "extension should reject duplicate or regressing source and host timestamps",
    )


def test_validator_rejects_early_loop_timing_commit():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """            let nextReaderState = try makeAssetReader(asset: asset, videoTrack: videoTrack)
            advanceLoopTiming(by: assetDuration)
            installAssetReaderState(nextReaderState)""",
        """            advanceLoopTiming(by: assetDuration)
            let nextReaderState = try makeAssetReader(asset: asset, videoTrack: videoTrack)
            installAssetReaderState(nextReaderState)""",
        "extension should start the replacement reader before committing loop timing state",
    )


def test_validator_rejects_missing_synthetic_timestamp_unit_gate():
    assert_validator_rejects_mutation(
        "scripts/check_project.sh",
        'swift test --scratch-path "$SWIFT_TEST_SCRATCH"\n',
        "",
        "project checks should compile and run the synthetic sample timestamp unit tests",
    )


def test_validator_rejects_missing_failed_reader_cancellation():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        "                nextAssetReader.cancelReading()\n",
        "",
        "extension should cancel a partially started reader before propagating startup failure",
    )


def test_validator_rejects_missing_unknown_signature_state():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """    enum CodeSigningStatus: Equatable {
        case valid(String, String?, Set<String>, Set<String>)
        case invalid(String)
        case unknown(String)

""",
        """    enum CodeSigningStatus: Equatable {
        case valid(String, String?, Set<String>, Set<String>)
        case invalid(String)

""",
        "host app should distinguish unknown and invalid code-signing states, validate all architecture slices, and preserve detailed validation errors before submitting system-extension requests",
    )


def test_validator_rejects_missing_all_architecture_signature_validation():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """        let validationFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        var validationError: Unmanaged<CFError>?
        let checkStatus = SecStaticCodeCheckValidityWithErrors(staticCode, validationFlags, nil, &validationError)
        guard checkStatus == errSecSuccess else {
            let validationErrorDetail = validationError?.takeRetainedValue()
            return .invalid(errorMessage(for: checkStatus, error: validationErrorDetail))
        }
        validationError?.release()""",
        """        let checkStatus = SecStaticCodeCheckValidityWithErrors(staticCode, SecCSFlags(), nil, nil)""",
        "host app should distinguish unknown and invalid code-signing states, validate all architecture slices, and preserve detailed validation errors before submitting system-extension requests",
    )


def test_validator_rejects_missing_signing_information_unknown_guard():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """        guard let signingDictionary = signingInformation(for: staticCode) else {
            return .unknown("The code signature is valid, but signing information could not be read.")
        }

""",
        """        let signingDictionary = signingInformation(for: staticCode)
""",
        "host app should distinguish unknown and invalid code-signing states, validate all architecture slices, and preserve detailed validation errors before submitting system-extension requests",
    )


def test_validator_rejects_missing_host_team_identifier_shape_guard():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """              !teamIdentifier.isEmpty,
              isTeamIdentifier(teamIdentifier) else {
""",
        """              !teamIdentifier.isEmpty else {
""",
        "host app should validate signing Team IDs before comparing app and extension signatures",
    )


def test_validator_rejects_missing_host_whole_regex_match_guard():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        "        return range == value.startIndex..<value.endIndex\n",
        "        return true\n",
        "host app should require whole-string regex matches for Team IDs, app groups, and CMIO Mach services",
    )


def test_validator_rejects_numeric_boolean_entitlement_acceptance():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """        return Set(entitlementDictionary.compactMap { key, value in
            guard let isEnabled = value as? Bool else {
                return nil
            }

            return isEnabled ? key : nil
        })""",
        """        return Set(entitlementDictionary.compactMap { key, value in
            if let isEnabled = value as? Bool {
                return isEnabled ? key : nil
            }

            if let number = value as? NSNumber {
                return number.boolValue ? key : nil
            }

            return nil
        })""",
        "host app should only accept boolean signed entitlement values",
    )


def test_validator_rejects_missing_runtime_diagnostics_all_architecture_details():
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        '  /usr/bin/codesign -d --all-architectures -v "$APP_PATH" 2>&1 || true',
        '  /usr/bin/codesign -dv "$APP_PATH" 2>&1 || true',
        "runtime diagnostics script should print signing details across all architecture slices",
    )


def test_validator_rejects_missing_runtime_diagnostics_all_architecture_entitlements():
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        """    if ! /usr/bin/codesign -d --architecture "$architecture" --entitlements :- "$bundle_path" >"$entitlements_file" 2>/dev/null; then
      /bin/rm -f "$entitlements_file"
      printf 'unknown\\n'
      return
    fi""",
        """    if ! /usr/bin/codesign -d --entitlements :- "$bundle_path" >"$entitlements_file" 2>/dev/null; then
      /bin/rm -f "$entitlements_file"
      printf 'unknown\\n'
      return
    fi""",
        "runtime diagnostics script should read boolean entitlements across all executable architecture slices",
    )


def test_validator_rejects_missing_runtime_diagnostics_executable_name_guard():
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        """  if is_executable_name "$executable_name" && [ -f "$executable_path" ] && [ -x "$executable_path" ]; then
""",
        """  if [ -n "$executable_name" ] && [ -f "$executable_path" ] && [ -x "$executable_path" ]; then
""",
        "runtime diagnostics should reject path-like executable names before readiness and path reporting",
    )
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        """  if is_executable_name "$executable_name"; then
    printf '%s\\n' "${bundle_path}/Contents/MacOS/${executable_name}"
  fi""",
        """  if [ -n "$executable_name" ]; then
    printf '%s\\n' "${bundle_path}/Contents/MacOS/${executable_name}"
  fi""",
        "runtime diagnostics should reject path-like executable names before readiness and path reporting",
    )


def test_validator_rejects_missing_runtime_diagnostics_scalar_boolean_entitlement_guard():
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        """value = entitlements.get(sys.argv[2], False)
if not isinstance(value, bool):
    sys.exit(1)

print("yes" if value else "no")
""",
        """value = bool(entitlements.get(sys.argv[2], False))

print("yes" if value else "no")
""",
        "runtime diagnostics should reject scalar boolean entitlement values",
    )
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        '    if ! plistbuddy_output="$(/usr/libexec/PlistBuddy -x -c "Print :${entitlement}" "$entitlements_file" 2>/dev/null)"; then',
        '    if ! plistbuddy_output="$(/usr/libexec/PlistBuddy -c "Print :${entitlement}" "$entitlements_file" 2>/dev/null)"; then',
        "runtime diagnostics should reject scalar boolean entitlement values",
    )


def test_validator_rejects_missing_runtime_diagnostics_info_plist_string_guard():
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        """if isinstance(value, str):
    trimmed_value = value.strip()
    if "\\n" in value or "\\r" in value:
        sys.exit(0)
    if trimmed_value and trimmed_value == value:
        print(value)
""",
        """if value:
    print(value)
""",
        "runtime diagnostics should reject non-string, blank, untrimmed, or multiline Info.plist metadata values",
    )


def test_validator_rejects_missing_runtime_diagnostics_blank_info_plist_guard():
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        "if trimmed_value and trimmed_value == value:",
        "if value:",
        "runtime diagnostics should reject non-string, blank, untrimmed, or multiline Info.plist metadata values",
    )


def test_validator_rejects_missing_runtime_diagnostics_untrimmed_info_plist_guard():
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        "if trimmed_value and trimmed_value == value:",
        "if trimmed_value:",
        "runtime diagnostics should reject non-string, blank, untrimmed, or multiline Info.plist metadata values",
    )
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        """      if (trimmed_value != value) {
        invalid = 1
      } else if (trimmed_value != "") {
        print value
      }""",
        """      if (trimmed_value != "") {
        print value
      }""",
        "runtime diagnostics should reject non-string, blank, untrimmed, or multiline Info.plist metadata values",
    )


def test_validator_rejects_missing_runtime_diagnostics_multiline_info_plist_guard():
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        """    if "\\n" in value or "\\r" in value:
        sys.exit(0)
""",
        "",
        "runtime diagnostics should reject non-string, blank, untrimmed, or multiline Info.plist metadata values",
    )


def test_validator_rejects_missing_runtime_diagnostics_zero_parser_metadata_guard():
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        """def metadata_field_value(value):
    return "" if value is None else value

print(f"MP4 parser pixel width = {width}")
print(f"MP4 parser pixel height = {height}")
print(f"MP4 parser frame rate = {metadata_field_value(metadata.get('frame_rate'))}")
print(f"MP4 parser duration seconds = {metadata_field_value(metadata.get('duration_seconds'))}")""",
        """print(f"MP4 parser pixel width = {width}")
print(f"MP4 parser pixel height = {height}")
print(f"MP4 parser frame rate = {metadata.get('frame_rate') or ''}")
print(f"MP4 parser duration seconds = {metadata.get('duration_seconds') or ''}")""",
        "runtime diagnostics should preserve zero-valued parser video metadata instead of treating it as missing",
    )


def test_validator_rejects_missing_runtime_diagnostics_checksum_failure_guard():
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        """/usr/bin/shasum -a 256 "$file_path" 2>/dev/null | /usr/bin/awk '{ print $1 }' || true""",
        """/usr/bin/shasum -a 256 "$file_path" | /usr/bin/awk '{ print $1 }'""",
        "runtime diagnostics should report unknown video checksums without exiting when checksum commands fail",
    )


def test_validator_rejects_missing_runtime_diagnostics_all_architecture_application_groups():
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        '  common_application_groups_for_architectures "$architecture_groups" "$architecture_count"',
        '  printf \'%s\\n\' "$architecture_groups"',
        "runtime diagnostics script should require app-group values across all executable architecture slices",
    )


def test_validator_rejects_missing_runtime_diagnostics_non_string_app_group_guard():
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        """    if not isinstance(group, str):
        sys.exit(1)
""",
        "",
        "runtime diagnostics should reject non-string app-group entitlement array members",
    )


def test_validator_rejects_missing_runtime_diagnostics_untrimmed_app_group_guard():
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        """    if group.strip() != group:
        sys.exit(1)
""",
        "",
        "runtime diagnostics should reject untrimmed app-group entitlement strings",
    )


def test_validator_rejects_missing_runtime_diagnostics_multiline_app_group_guard():
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        """    if "\\n" in group or "\\r" in group:
        sys.exit(1)
""",
        "",
        "runtime diagnostics should reject multiline app-group entitlement strings",
    )


def test_validator_rejects_missing_runtime_diagnostics_fallback_scalar_app_group_guard():
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        '    if ! plistbuddy_output="$(/usr/libexec/PlistBuddy -x -c "Print :${APP_GROUP_ENTITLEMENT}" "$entitlements_file" 2>/dev/null)"; then',
        '    if ! plistbuddy_output="$(/usr/libexec/PlistBuddy -c "Print :${APP_GROUP_ENTITLEMENT}" "$entitlements_file" 2>/dev/null)"; then',
        "runtime diagnostics should reject non-array or non-string app-group entitlements in the PlistBuddy fallback parser",
    )


def test_validator_rejects_missing_runtime_diagnostics_fallback_untrimmed_app_group_guard():
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        """          if (trimmed_group != group) {
            invalid = 1
            next
          }
""",
        "",
        "runtime diagnostics should reject untrimmed app-group entitlement strings",
    )


def test_validator_rejects_missing_runtime_diagnostics_fallback_encoded_multiline_app_group_guard():
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        """          if (group ~ /&#([xX]0*[Aa]|0*10);/ || group ~ /&#([xX]0*[Dd]|0*13);/) {
            invalid = 1
            next
          }
""",
        "",
        "runtime diagnostics should reject encoded multiline app-group entitlement strings in the PlistBuddy fallback parser",
    )


def test_validator_rejects_loose_team_id_prefix_lengths():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """        let escapedBaseIdentifier = NSRegularExpression.escapedPattern(for: baseIdentifier)
        let teamPrefixedPattern = "^[A-Za-z0-9]{10}\\\\.\\(escapedBaseIdentifier)$"
""",
        """        let escapedBaseIdentifier = NSRegularExpression.escapedPattern(for: baseIdentifier)
        let teamPrefixedPattern = "^[A-Za-z0-9]+\\\\.\\(escapedBaseIdentifier)$"
""",
        "host app should restrict Team-ID-prefixed app groups and CMIO Mach services to 10-character Team IDs",
    )
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        """    if [[ "$team_prefix" =~ ^[[:alnum:]]{10}$ ]]; then
      printf 'yes\\n'
""",
        """    if [[ "$team_prefix" =~ ^[[:alnum:]]+$ ]]; then
      printf 'yes\\n'
""",
        "runtime diagnostics should restrict Team-ID-prefixed app groups and CMIO Mach services to 10-character Team IDs",
    )


def test_validator_rejects_bare_application_group_acceptance():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """    private static func isExpectedApplicationGroupIdentifier(_ groupIdentifier: String, baseIdentifier: String) -> Bool {
        let escapedBaseIdentifier = NSRegularExpression.escapedPattern(for: baseIdentifier)
""",
        """    private static func isExpectedApplicationGroupIdentifier(_ groupIdentifier: String, baseIdentifier: String) -> Bool {
        if groupIdentifier == baseIdentifier {
            return true
        }

        let escapedBaseIdentifier = NSRegularExpression.escapedPattern(for: baseIdentifier)
""",
        "host app should require Team-ID-prefixed app-group identifiers rather than bare group names",
    )
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        """  if [[ "$application_group" == *"$team_prefixed_suffix" ]]; then
""",
        """  if [ "$application_group" = "$APP_GROUP_BASE_ID" ]; then
    return 0
  fi

  if [[ "$application_group" == *"$team_prefixed_suffix" ]]; then
""",
        "runtime diagnostics should require Team-ID-prefixed app-group identifiers rather than bare group names",
    )


def test_validator_rejects_untrimmed_signed_app_group_values():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """            let trimmedGroupIdentifier = groupIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedGroupIdentifier.isEmpty,
                  groupIdentifier.rangeOfCharacter(from: .newlines) == nil,
                  trimmedGroupIdentifier == groupIdentifier else {
                return []
            }

""",
        "",
        "host app should reject blank, untrimmed, or multiline signed app-group entitlement values",
    )


def test_validator_rejects_multiline_signed_app_group_values():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        "                  groupIdentifier.rangeOfCharacter(from: .newlines) == nil,\n",
        "",
        "host app should reject blank, untrimmed, or multiline signed app-group entitlement values",
    )


def test_validator_rejects_missing_extension_load_failure_detail_row():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        '                    DetailRow(title: "Extension Load Failure", value: extensionLoadFailureDetail)\n',
        "",
        "host app should preserve the last readiness, extension-load, or request failure in details and copied diagnostics",
    )


def test_validator_rejects_missing_header_action_buttons():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """    private var headerActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                headerActionButtons
            }

            VStack(alignment: .leading, spacing: 10) {
                headerActionButtons
            }
        }
    }

    @ViewBuilder
    private var headerActionButtons: some View {
        Button(action: manager.refreshStatus) {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .help("Refresh app, extension, signing, and readiness status.")

        Button(action: manager.copyActivationChecklist) {
            Label("Copy Checklist", systemImage: "checklist")
        }
        .buttonStyle(.bordered)
        .help("Copy the signed runtime activation checklist.")

        Button(action: manager.copyDiagnostics) {
            Label("Copy Diagnostics", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .help("Copy the current readiness and diagnostics snapshot.")
    }
""",
        "",
        "host app header should surface the current request readiness detail and primary refresh, checklist, and diagnostics actions",
    )


def test_validator_rejects_missing_activity_limit():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """        if activity.count > maximumActivityItems {
            activity.removeLast(activity.count - maximumActivityItems)
        }
""",
        "",
        "host app should cap request activity so long troubleshooting sessions stay bounded",
    )


def test_validator_rejects_missing_unsigned_build_configuration_guard():
    assert_validator_rejects_mutation(
        "scripts/build_unsigned.sh",
        """for configuration in "${configurations[@]}"; do
  validate_configuration_name "$configuration"
done

""",
        "",
        "unsigned build script should perform Debug and Release app target builds without code signing",
    )


def test_validator_rejects_missing_unsigned_build_architecture_guard():
    assert_validator_rejects_mutation(
        "scripts/build_unsigned.sh",
        """validate_build_arch_name "$BUILD_ARCH"

""",
        "",
        "unsigned build script should perform Debug and Release app target builds without code signing",
    )


def test_validator_rejects_raw_extension_executable_metadata():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """        guard let executableName = Self.infoPlistString(in: extensionBundle, key: "CFBundleExecutable") else {
            throw ExtensionRequestError.missingExtensionExecutable(extensionURL.path)
        }
""",
        """        guard let executableName = extensionBundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
              !executableName.isEmpty else {
            throw ExtensionRequestError.missingExtensionExecutable(extensionURL.path)
        }
""",
        "host app should reject blank, untrimmed, or multiline embedded extension Info.plist and CMIO metadata strings",
    )


def test_validator_rejects_missing_host_executable_name_shape_guard():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """    private static func isExecutableName(_ executableName: String) -> Bool {
        return !executableName.isEmpty
            && executableName != "."
            && executableName != ".."
            && !executableName.contains("/")
    }
""",
        """    private static func isExecutableName(_ executableName: String) -> Bool {
        return executableName != "."
            && executableName != ".."
            && !executableName.contains("/")
    }
""",
        "host app should reject blank or path-like embedded extension executable names",
    )
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """        guard Self.isExecutableName(executableName) else {
            throw ExtensionRequestError.invalidExtensionExecutableName(executableName, extensionURL.path)
        }
""",
        "",
        "host app should reject blank or path-like embedded extension executable names",
    )


def test_validator_rejects_missing_host_duplicate_extension_guard():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """        guard extensionBundleURLs.count == 1 else {
            throw ExtensionRequestError.multipleBundledExtensions(extensionBundleURLs.map(\\.lastPathComponent).joined(separator: ", "))
        }

""",
        "",
        "host app should reject ambiguous products with multiple bundled system extensions",
    )


def test_validator_rejects_directory_runtime_diagnostics_script_resource():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: scriptURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }

        return scriptURL.path
""",
        """        return FileManager.default.fileExists(atPath: scriptURL.path) ? scriptURL.path : nil
""",
        "host app should only expose a bundled runtime diagnostics command for a file resource",
    )


def test_validator_rejects_untrimmed_host_info_plist_metadata():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty,
              value.rangeOfCharacter(from: .newlines) == nil,
              trimmedValue == value else {
            return nil
        }

        return value
""",
        """        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
""",
        "host app should reject blank, untrimmed, or multiline embedded extension Info.plist and CMIO metadata strings",
    )


def test_validator_rejects_multiline_host_info_plist_metadata():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        "              value.rangeOfCharacter(from: .newlines) == nil,\n",
        "",
        "host app should reject blank, untrimmed, or multiline embedded extension Info.plist and CMIO metadata strings",
    )


def test_validator_rejects_raw_extension_cmio_metadata():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """        let trimmedMachServiceName = machServiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMachServiceName.isEmpty,
              machServiceName.rangeOfCharacter(from: .newlines) == nil,
              trimmedMachServiceName == machServiceName else {
            return nil
        }

        return machServiceName
""",
        """        return machServiceName
""",
        "host app should reject blank, untrimmed, or multiline embedded extension Info.plist and CMIO metadata strings",
    )


def test_validator_rejects_untrimmed_host_cmio_metadata():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """        let trimmedMachServiceName = machServiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMachServiceName.isEmpty,
              machServiceName.rangeOfCharacter(from: .newlines) == nil,
              trimmedMachServiceName == machServiceName else {
            return nil
        }

        return machServiceName
""",
        """        let trimmedMachServiceName = machServiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedMachServiceName.isEmpty ? nil : trimmedMachServiceName
""",
        "host app should reject blank, untrimmed, or multiline embedded extension Info.plist and CMIO metadata strings",
    )


def test_validator_rejects_multiline_host_cmio_metadata():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        "              machServiceName.rangeOfCharacter(from: .newlines) == nil,\n",
        "",
        "host app should reject blank, untrimmed, or multiline embedded extension Info.plist and CMIO metadata strings",
    )


def test_validator_rejects_missing_host_mp4_sample_count_guard():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        "if sampleCount > 0, sampleDelta > 0, timescale % sampleDelta == 0",
        "if sampleDelta > 0, timescale % sampleDelta == 0",
        "host app should only accept positive-sample MP4 timing entries when parsing bundled-video frame rate",
    )


def test_validator_rejects_missing_host_mp4_integer_frame_rate_guard():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        "if sampleCount > 0, sampleDelta > 0, timescale % sampleDelta == 0",
        "if sampleCount > 0, sampleDelta > 0",
        "host app should only report MP4 frame rates with exact integer sample timing",
    )
    assert_validator_rejects_mutation(
        "scripts/validate_project.py",
        "if sample_count and sample_delta and timescale % sample_delta == 0:",
        "if sample_count and sample_delta:",
        "host app should only report MP4 frame rates with exact integer sample timing",
    )


def test_validator_rejects_missing_host_mp4_complete_stts_entry_guard():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """        guard Int(entryCount) <= maxEntryCount else {
            return []
        }

""",
        "",
        "host app should reject incomplete MP4 timing and sample-description tables",
    )


def test_validator_rejects_missing_host_mp4_stsd_entry_count_guard():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """        let sampleDescriptions = atoms(in: data, start: payloadStart + 8, end: payloadEnd)
        guard Int(entryCount) <= sampleDescriptions.count else {
            return nil
        }

        for atom in sampleDescriptions.prefix(Int(entryCount)) {""",
        """        let sampleDescriptions = atoms(in: data, start: payloadStart + 8, end: payloadEnd)
        for atom in sampleDescriptions {""",
        "host app should reject incomplete MP4 timing and sample-description tables",
    )


def test_validator_rejects_missing_png_ihdr_guard():
    assert_validator_rejects_mutation(
        "scripts/validate_project.py",
        """    if len(header) < 24 or struct.unpack(">I", header[8:12])[0] != 13 or header[12:16] != b"IHDR":
        return None

""",
        "",
        "app icon validator should reject malformed PNG headers without raising",
    )


def test_validator_rejects_missing_icon_size_metadata_guard():
    assert_validator_rejects_mutation(
        "scripts/validate_project.py",
        "require(expected_size is not None and png_dimensions(icon_path) == (expected_size, expected_size),",
        "require(png_dimensions(icon_path) == (expected_size, expected_size),",
        "app icon validator should reject malformed icon catalog size metadata without raising",
    )


def test_validator_rejects_missing_icon_scale_suffix_guard():
    assert_validator_rejects_mutation(
        "scripts/validate_project.py",
        """    if not scale_value.endswith("x"):
        return None

""",
        "",
        "app icon validator should reject malformed icon catalog size metadata without raising",
    )


def test_validator_rejects_untrimmed_icon_size_metadata():
    assert_validator_rejects_mutation(
        "scripts/validate_project.py",
        """    if size.strip() != size or scale_value.strip() != scale_value:
        return None

""",
        "",
        "app icon validator should reject malformed icon catalog size metadata without raising",
    )


def test_validator_rejects_permissive_icon_integer_metadata():
    assert_validator_rejects_mutation(
        "scripts/validate_project.py",
        """    scale_digits = scale_value.removesuffix("x")
    if not re.fullmatch(r"[0-9]+", size_parts[0]) or not re.fullmatch(r"[0-9]+", size_parts[1]) or not re.fullmatch(r"[0-9]+", scale_digits):
        return None

""",
        """    scale_digits = scale_value.removesuffix("x")
""",
        "app icon validator should reject malformed icon catalog size metadata without raising",
    )


def test_validator_rejects_missing_host_mp4_mdhd_version_guard():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """        guard version == 0 else {
            return nil
        }

""",
        "",
        "host app should parse bundled MP4 video dimensions, frame rate, and duration for readiness",
    )


def test_validator_rejects_missing_host_mp4_full_box_version_guards():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """        guard data[payloadStart] == 0 else {
            return nil
        }

        return String(data: data.subdata(in: (payloadStart + 8)..<(payloadStart + 12)),
                      encoding: .isoLatin1)""",
        """        return String(data: data.subdata(in: (payloadStart + 8)..<(payloadStart + 12)),
                      encoding: .isoLatin1)""",
        "host app should parse bundled MP4 video dimensions, frame rate, and duration for readiness",
    )


def test_validator_rejects_missing_host_mp4_video_track_dimension_gate():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        "trackDimensions = dimensions",
        "videoMetadata.dimensions = dimensions",
        "host app should parse bundled MP4 video dimensions, frame rate, and duration for readiness",
    )


def test_validator_rejects_broad_appintents_log_ignore():
    assert_validator_rejects_mutation(
        "scripts/scan_build_log.py",
        """    (
        "appintentsmetadataprocessor",
        "warning:",
        "Metadata extraction skipped. No AppIntents.framework dependency found.",
    ),
""",
        """    (
        "appintentsmetadataprocessor",
        "Metadata extraction skipped. No AppIntents.framework dependency found.",
    ),
""",
        "build-log scanner should fail on warnings, errors, build/analyze/clean/install/test-failed banners, build/test failure summaries, and nonzero Xcode command failures while narrowly ignoring known Xcode AppIntents metadata noise",
    )


def test_validator_rejects_missing_install_failed_banner_scan():
    assert_validator_rejects_mutation(
        "scripts/scan_build_log.py",
        r"""    r"warning:|error:|failed with a nonzero exit code|the following build commands failed:|testing failed:|\*\* BUILD FAILED \*\*|\*\* ARCHIVE FAILED \*\*|\*\* ANALYZE FAILED \*\*|\*\* CLEAN FAILED \*\*|\*\* INSTALL FAILED \*\*|\*\* TEST FAILED \*\*",""",
        r"""    r"warning:|error:|failed with a nonzero exit code|the following build commands failed:|testing failed:|\*\* BUILD FAILED \*\*|\*\* ARCHIVE FAILED \*\*|\*\* ANALYZE FAILED \*\*|\*\* CLEAN FAILED \*\*|\*\* TEST FAILED \*\*",""",
        "build-log scanner should fail on warnings, errors, build/analyze/clean/install/test-failed banners, build/test failure summaries, and nonzero Xcode command failures while narrowly ignoring known Xcode AppIntents metadata noise",
    )


def test_validator_rejects_missing_appintents_ignore_disqualifier():
    assert_validator_rejects_mutation(
        "scripts/scan_build_log.py",
        """    if IGNORED_LINE_DISQUALIFYING_PATTERN.search(line):
        return False

""",
        "",
        "build-log scanner should not hide additional warnings or failures on ignored AppIntents warning lines",
    )


def test_validator_rejects_missing_appintents_same_line_warning_disqualifier():
    assert_validator_rejects_mutation(
        "scripts/scan_build_log.py",
        r"""    r"warning:.*warning:|error:|failed with a nonzero exit code|the following build commands failed:|testing failed:|\*\* BUILD FAILED \*\*|\*\* ARCHIVE FAILED \*\*|\*\* ANALYZE FAILED \*\*|\*\* CLEAN FAILED \*\*|\*\* INSTALL FAILED \*\*|\*\* TEST FAILED \*\*",""",
        r"""    r"error:|failed with a nonzero exit code|the following build commands failed:|testing failed:|\*\* BUILD FAILED \*\*|\*\* ARCHIVE FAILED \*\*|\*\* ANALYZE FAILED \*\*|\*\* CLEAN FAILED \*\*|\*\* INSTALL FAILED \*\*|\*\* TEST FAILED \*\*",""",
        "build-log scanner should not hide additional warnings or failures on ignored AppIntents warning lines",
    )


def test_validator_rejects_missing_partial_ci_log_scan():
    assert_validator_rejects_mutation(
        ".github/workflows/macos-build.yml",
        """        if: always() && hashFiles('.build/Xcode/Logs/build-*.log') != ''
        run: ./scripts/scan_build_log.py .build/Xcode/Logs/build-*.log""",
        "        run: ./scripts/scan_build_log.py .build/Xcode/Logs/build-Debug.log .build/Xcode/Logs/build-Release.log",
        "macOS build workflow should scan any captured Debug or Release xcodebuild output even after failed build steps",
    )


def test_validator_rejects_floating_checkout_action():
    assert_validator_rejects_mutation(
        ".github/workflows/macos-build.yml",
        "actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10",
        "actions/checkout@v6",
        "macOS build workflow should pin the Node 24-capable checkout action",
    )


def test_validator_rejects_duplicate_checkout_action():
    assert_validator_rejects_mutation(
        ".github/workflows/macos-build.yml",
        """      - name: Select Xcode 26.5
""",
        """      - name: Duplicate checkout
        uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10 # v6.0.3
        with:
          persist-credentials: false

      - name: Select Xcode 26.5
""",
        "macOS build workflow should contain exactly one checkout action step",
    )


def test_validator_rejects_incorrect_checkout_release_annotation():
    assert_validator_rejects_mutation(
        ".github/workflows/macos-build.yml",
        "# v6.0.3",
        "# v6.0.2",
        "macOS build workflow should label the checkout action with its exact release",
    )


def test_validator_rejects_missing_checkout_credential_guard():
    assert_validator_rejects_mutation(
        ".github/workflows/macos-build.yml",
        """        with:
          persist-credentials: false
""",
        "",
        "macOS build workflow checkout should disable persisted credentials exactly once in the checkout step",
    )


def test_validator_rejects_duplicate_checkout_credential_guard():
    assert_validator_rejects_mutation(
        ".github/workflows/macos-build.yml",
        """        with:
          persist-credentials: false
""",
        """        with:
          persist-credentials: false
          persist-credentials: false
""",
        "macOS build workflow checkout should disable persisted credentials exactly once in the checkout step",
    )


def test_validator_rejects_relocated_checkout_credential_guard():
    assert_validator_rejects_mutation(
        ".github/workflows/macos-build.yml",
        """env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true
""",
        """env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true
  persist-credentials: false
""",
        "macOS build workflow checkout should disable persisted credentials exactly once in the checkout step",
    )


def test_validator_rejects_contradictory_checkout_credential_guard():
    assert_validator_rejects_mutation(
        ".github/workflows/macos-build.yml",
        """        with:
          persist-credentials: false
""",
        """        with:
          persist-credentials: false
          persist-credentials: true
""",
        "macOS build workflow checkout should disable persisted credentials exactly once in the checkout step",
    )


def test_validator_rejects_floating_artifact_action():
    assert_validator_rejects_mutation(
        ".github/workflows/macos-build.yml",
        "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
        "actions/upload-artifact@v7.0.1",
        "macOS build workflow should upload captured Xcode build logs for later inspection",
    )


def test_validator_rejects_incorrect_artifact_release_annotation():
    assert_validator_rejects_mutation(
        ".github/workflows/macos-build.yml",
        "# v7.0.1",
        "# v7.0.0",
        "macOS build workflow should label the upload-artifact action with its exact release",
    )


def test_validator_rejects_missing_unreadable_build_log_guard():
    assert_validator_rejects_mutation(
        "scripts/scan_build_log.py",
        """    except OSError as error:
        raise BuildLogReadError(build_log_path, error) from error
""",
        "",
        "build-log scanner should report unreadable log files without a traceback",
    )


def test_validator_rejects_root_level_unsigned_build_logs():
    assert_validator_rejects_mutation(
        "scripts/build_unsigned.sh",
        'tee "$BUILD_LOG_PATH/build-${configuration}.log"',
        'tee "build-${configuration}.log"',
        "unsigned build script should capture Debug and Release logs under the configured build output path",
    )


def test_validator_rejects_missing_build_product_python_resolver():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        'PYTHON3_BIN="$(python3_command)"',
        'PYTHON3_BIN=python3',
        "build-product verifier should resolve one explicit Python 3 interpreter before parsing plists or bundled-video metadata",
    )


def test_validator_rejects_missing_build_product_configuration_guard():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        """for configuration in "${configurations[@]}"; do
  validate_configuration_name "$configuration"
done

""",
        "",
        "build-product verifier should reject invalid configuration names before resolving Python or product paths",
    )


def test_validator_rejects_missing_build_product_expected_video_metadata_guard():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        """validate_positive_integer "width" "$EXPECTED_VIDEO_WIDTH"
validate_positive_integer "height" "$EXPECTED_VIDEO_HEIGHT"
validate_positive_integer "frame rate" "$EXPECTED_VIDEO_FRAME_RATE"

""",
        "",
        "build-product verifier should reject invalid expected video metadata before resolving Python or product paths",
    )


def test_validator_rejects_missing_build_product_duplicate_extension_guard():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        """  verify_exactly_one_embedded_system_extension "$configuration" "$app_path"

""",
        "",
        "build-product verifier should reject duplicate embedded system extensions",
    )


def test_validator_rejects_directory_only_embedded_extension_count():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        "find \"$system_extensions_path\" -maxdepth 1 -name '*.systemextension' -print",
        "find \"$system_extensions_path\" -maxdepth 1 -type d -name '*.systemextension' -print",
        "build-product verifier should count every top-level .systemextension path",
    )


def test_validator_rejects_missing_build_product_video_file_guard():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        """  if [ ! -f "$video_path" ] || [ ! -s "$video_path" ]; then
    printf 'Missing or empty %s bundled video resource: %s\\n' "$configuration" "$video_path" >&2
    exit 1
  fi""",
        """  if [ ! -s "$video_path" ]; then
    printf 'Missing or empty %s bundled video resource: %s\\n' "$configuration" "$video_path" >&2
    exit 1
  fi""",
        "build-product verifier should reject non-file bundled video resources before parsing metadata",
    )


def test_validator_rejects_missing_build_product_diagnostics_file_guards():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        """  if [ ! -f "$script_path" ]; then
    printf 'Missing %s app runtime diagnostics script: %s\\n' "$configuration" "$script_path" >&2
    exit 1
  fi""",
        """  if [ ! -e "$script_path" ]; then
    printf 'Missing %s app runtime diagnostics script: %s\\n' "$configuration" "$script_path" >&2
    exit 1
  fi""",
        "build-product verifier should reject non-file runtime diagnostics resources",
    )
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        """  if [ ! -f "$parser_path" ]; then
    printf 'Missing %s app runtime diagnostics parser: %s\\n' "$configuration" "$parser_path" >&2
    exit 1
  fi""",
        """  if [ ! -e "$parser_path" ]; then
    printf 'Missing %s app runtime diagnostics parser: %s\\n' "$configuration" "$parser_path" >&2
    exit 1
  fi""",
        "build-product verifier should reject non-file runtime diagnostics resources",
    )


def test_validator_rejects_missing_build_product_executable_name_guard():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        """  [ -n "$executable_name" ] \\
    && [ "$executable_name" != "." ] \\""",
        """  [ "$executable_name" != "." ] \\""",
        "build-product verifier should reject blank or path-like CFBundleExecutable values",
    )
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        """  if ! is_executable_name "$executable_name"; then
    printf 'Invalid %s %s CFBundleExecutable: %s\\n' "$configuration" "$bundle_label" "$executable_name" >&2
    exit 1
  fi

""",
        "",
        "build-product verifier should reject blank or path-like CFBundleExecutable values",
    )


def test_validator_rejects_missing_make_gate_aliases():
    assert_validator_rejects_mutation(
        "Makefile",
        "\nlint test build: check\n",
        "\n",
        "Makefile should protect its root and expose lint, test, build, and check validation entry points",
    )


def test_validator_rejects_missing_build_product_info_plist_string_type_guard():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        """if isinstance(value, str):
    if "\\n" in value or "\\r" in value:
        sys.exit(0)
    trimmed_value = value.strip()
    if trimmed_value and trimmed_value == value:
        print(value)""",
        "if value:",
        "build-product verifier should reject non-string, blank, untrimmed, or multiline Info.plist display and privacy strings",
    )


def test_validator_rejects_missing_build_product_blank_info_plist_guard():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        "if trimmed_value and trimmed_value == value:",
        "if value:",
        "build-product verifier should reject non-string, blank, untrimmed, or multiline Info.plist display and privacy strings",
    )


def test_validator_rejects_missing_build_product_untrimmed_info_plist_guard():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        "if trimmed_value and trimmed_value == value:",
        "if trimmed_value:",
        "build-product verifier should reject non-string, blank, untrimmed, or multiline Info.plist display and privacy strings",
    )


def test_validator_rejects_missing_build_product_multiline_info_plist_guard():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        "    if \"\\n\" in value or \"\\r\" in value:\n        sys.exit(0)\n",
        "",
        "build-product verifier should reject non-string, blank, untrimmed, or multiline Info.plist display and privacy strings",
    )


def test_validator_rejects_missing_build_product_blank_cmio_guard():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        "if trimmed_mach_service_name and trimmed_mach_service_name == mach_service_name:",
        "if mach_service_name:",
        "build-product verifier should reject non-string, blank, untrimmed, or multiline CMIO Mach-service metadata as missing",
    )


def test_validator_rejects_missing_build_product_cmio_string_type_guard():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        """if isinstance(mach_service_name, str):
    if "\\n" in mach_service_name or "\\r" in mach_service_name:
        sys.exit(0)
    trimmed_mach_service_name = mach_service_name.strip()
    if trimmed_mach_service_name and trimmed_mach_service_name == mach_service_name:
        print(mach_service_name)""",
        """if mach_service_name:
    print(mach_service_name)""",
        "build-product verifier should reject non-string, blank, untrimmed, or multiline CMIO Mach-service metadata as missing",
    )


def test_validator_rejects_missing_build_product_untrimmed_cmio_guard():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        "if trimmed_mach_service_name and trimmed_mach_service_name == mach_service_name:",
        "if trimmed_mach_service_name:",
        "build-product verifier should reject non-string, blank, untrimmed, or multiline CMIO Mach-service metadata as missing",
    )


def test_validator_rejects_missing_build_product_multiline_cmio_guard():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        "    if \"\\n\" in mach_service_name or \"\\r\" in mach_service_name:\n        sys.exit(0)\n",
        "",
        "build-product verifier should reject non-string, blank, untrimmed, or multiline CMIO Mach-service metadata as missing",
    )


def test_validator_rejects_missing_packaged_file_byte_count_verifier():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        """  verify_app_diagnostics_self_test "$configuration" "$app_path" "$script_path" "file-byte-count" "file-byte-count" \\
    "File byte count fixture: 5" \\
    "Video SHA-256: unknown"

""",
        "",
        "build-product verifier should run the bundled runtime diagnostics file-byte-count self-test",
    )


def test_validator_rejects_missing_packaged_multiline_info_plist_verifier():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        '    "Info.plist multiline string metadata fixture: missing" \\\n',
        "",
        "build-product verifier should run the bundled runtime diagnostics application-identity self-test",
    )


def test_validator_rejects_missing_packaged_multiline_app_group_verifier():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        '    "Application group multiline entitlements readable fixture: no" \\\n',
        "",
        "build-product verifier should run the bundled runtime diagnostics application-group self-test",
    )


def test_validator_rejects_missing_packaged_fallback_encoded_multiline_app_group_verifier():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        '    "Application group fallback encoded multiline entitlements readable fixture: no" \\\n',
        "",
        "build-product verifier should run the bundled runtime diagnostics application-group self-test",
    )


def main():
    test_malformed_mdhd_atom_does_not_raise()
    test_unsupported_mdhd_version_does_not_report_duration()
    test_unsupported_hdlr_version_does_not_report_duration()
    test_unsupported_stts_version_does_not_report_frame_rate()
    test_unsupported_stsd_version_does_not_report_dimensions()
    test_non_video_track_stsd_does_not_report_dimensions()
    test_zero_sample_count_stts_does_not_report_frame_rate()
    test_non_integer_stts_rate_does_not_report_frame_rate()
    test_truncated_stts_entry_count_does_not_report_frame_rate()
    test_zero_stsd_entry_count_does_not_report_dimensions()
    test_truncated_png_signature_does_not_raise()
    test_non_ihdr_png_header_does_not_report_dimensions()
    test_malformed_icon_size_metadata_does_not_raise()
    test_tracked_fixture_validates()
    test_directory_video_fixture_reports_validation_failure()
    test_validator_rejects_missing_source_video_file_guard()
    test_directory_icon_fixture_reports_validation_failure()
    test_validator_rejects_missing_icon_file_guard()
    test_validator_rejects_missing_indefinite_stream_duration_guard()
    test_validator_rejects_missing_non_finite_stream_duration_guard()
    test_validator_rejects_missing_non_finite_asset_duration_guard()
    test_validator_rejects_reader_loop_while_reading()
    test_validator_rejects_reader_loop_before_completion()
    test_validator_rejects_missing_cancelled_preparation_reader_cleanup()
    test_validator_rejects_missing_stale_completion_reader_cleanup()
    test_validator_rejects_missing_released_source_reader_cleanup()
    test_validator_rejects_stale_reader_plan_status_regression()
    test_validator_rejects_stale_reader_plan_evidence_regression()
    test_validator_rejects_transactional_timing_plan_status_regression()
    test_validator_rejects_transactional_timing_plan_evidence_regression()
    test_validator_rejects_all_branch_ci_plan_status_regression()
    test_validator_rejects_all_branch_ci_plan_evidence_regression()
    test_validator_rejects_main_only_push_validation()
    test_validator_rejects_main_only_pull_request_validation()
    test_validator_rejects_missing_pull_request_validation()
    test_validator_rejects_caller_relative_makefile()
    test_validator_rejects_missing_check_project_root()
    test_validator_rejects_location_independent_make_plan_status_regression()
    test_validator_rejects_location_independent_make_plan_evidence_regression()
    test_validator_rejects_location_independent_make_documentation_regression()
    test_validator_rejects_missing_video_dimension_unwrap_guard()
    test_validator_rejects_missing_finite_video_dimension_guard()
    test_validator_rejects_missing_non_finite_video_frame_rate_guard()
    test_validator_rejects_missing_non_finite_sample_time_guard()
    test_validator_rejects_missing_adjusted_decode_time_guard()
    test_validator_rejects_missing_sample_count_retiming_guard()
    test_validator_rejects_missing_sample_timing_status_guard()
    test_validator_rejects_missing_retimed_copy_status_guard()
    test_validator_rejects_missing_host_time_sample_retiming()
    test_validator_rejects_early_timestamp_offset_commit()
    test_validator_rejects_early_last_presentation_commit()
    test_validator_rejects_missing_transactional_timing_validator()
    test_source_requires_strictly_increasing_sample_timestamps()
    test_reader_restart_precedes_loop_timing_commit()
    test_reader_start_failure_cancels_partial_reader()
    test_validator_rejects_non_strict_sample_timestamp_comparison()
    test_validator_rejects_missing_host_timestamp_guard()
    test_validator_rejects_early_loop_timing_commit()
    test_validator_rejects_missing_synthetic_timestamp_unit_gate()
    test_validator_rejects_missing_failed_reader_cancellation()
    test_validator_rejects_missing_unknown_signature_state()
    test_validator_rejects_missing_all_architecture_signature_validation()
    test_validator_rejects_missing_signing_information_unknown_guard()
    test_validator_rejects_missing_host_team_identifier_shape_guard()
    test_validator_rejects_missing_host_whole_regex_match_guard()
    test_validator_rejects_numeric_boolean_entitlement_acceptance()
    test_validator_rejects_missing_runtime_diagnostics_all_architecture_details()
    test_validator_rejects_missing_runtime_diagnostics_all_architecture_entitlements()
    test_validator_rejects_missing_runtime_diagnostics_executable_name_guard()
    test_validator_rejects_missing_runtime_diagnostics_scalar_boolean_entitlement_guard()
    test_validator_rejects_missing_runtime_diagnostics_info_plist_string_guard()
    test_validator_rejects_missing_runtime_diagnostics_blank_info_plist_guard()
    test_validator_rejects_missing_runtime_diagnostics_untrimmed_info_plist_guard()
    test_validator_rejects_missing_runtime_diagnostics_multiline_info_plist_guard()
    test_validator_rejects_missing_runtime_diagnostics_zero_parser_metadata_guard()
    test_validator_rejects_missing_runtime_diagnostics_checksum_failure_guard()
    test_validator_rejects_missing_runtime_diagnostics_all_architecture_application_groups()
    test_validator_rejects_missing_runtime_diagnostics_non_string_app_group_guard()
    test_validator_rejects_missing_runtime_diagnostics_untrimmed_app_group_guard()
    test_validator_rejects_missing_runtime_diagnostics_multiline_app_group_guard()
    test_validator_rejects_missing_runtime_diagnostics_fallback_scalar_app_group_guard()
    test_validator_rejects_missing_runtime_diagnostics_fallback_untrimmed_app_group_guard()
    test_validator_rejects_missing_runtime_diagnostics_fallback_encoded_multiline_app_group_guard()
    test_validator_rejects_loose_team_id_prefix_lengths()
    test_validator_rejects_bare_application_group_acceptance()
    test_validator_rejects_untrimmed_signed_app_group_values()
    test_validator_rejects_multiline_signed_app_group_values()
    test_validator_rejects_missing_extension_load_failure_detail_row()
    test_validator_rejects_missing_header_action_buttons()
    test_validator_rejects_missing_activity_limit()
    test_validator_rejects_missing_unsigned_build_configuration_guard()
    test_validator_rejects_missing_unsigned_build_architecture_guard()
    test_validator_rejects_missing_host_duplicate_extension_guard()
    test_validator_rejects_directory_runtime_diagnostics_script_resource()
    test_validator_rejects_raw_extension_executable_metadata()
    test_validator_rejects_missing_host_executable_name_shape_guard()
    test_validator_rejects_untrimmed_host_info_plist_metadata()
    test_validator_rejects_multiline_host_info_plist_metadata()
    test_validator_rejects_raw_extension_cmio_metadata()
    test_validator_rejects_untrimmed_host_cmio_metadata()
    test_validator_rejects_multiline_host_cmio_metadata()
    test_validator_rejects_missing_host_mp4_sample_count_guard()
    test_validator_rejects_missing_host_mp4_integer_frame_rate_guard()
    test_validator_rejects_missing_host_mp4_complete_stts_entry_guard()
    test_validator_rejects_missing_host_mp4_stsd_entry_count_guard()
    test_validator_rejects_missing_png_ihdr_guard()
    test_validator_rejects_missing_icon_size_metadata_guard()
    test_validator_rejects_missing_icon_scale_suffix_guard()
    test_validator_rejects_untrimmed_icon_size_metadata()
    test_validator_rejects_permissive_icon_integer_metadata()
    test_validator_rejects_missing_host_mp4_mdhd_version_guard()
    test_validator_rejects_missing_host_mp4_full_box_version_guards()
    test_validator_rejects_missing_host_mp4_video_track_dimension_gate()
    test_validator_rejects_broad_appintents_log_ignore()
    test_validator_rejects_missing_appintents_ignore_disqualifier()
    test_validator_rejects_missing_appintents_same_line_warning_disqualifier()
    test_validator_rejects_missing_install_failed_banner_scan()
    test_validator_rejects_missing_partial_ci_log_scan()
    test_validator_rejects_floating_checkout_action()
    test_validator_rejects_duplicate_checkout_action()
    test_validator_rejects_incorrect_checkout_release_annotation()
    test_validator_rejects_missing_checkout_credential_guard()
    test_validator_rejects_duplicate_checkout_credential_guard()
    test_validator_rejects_relocated_checkout_credential_guard()
    test_validator_rejects_contradictory_checkout_credential_guard()
    test_validator_rejects_floating_artifact_action()
    test_validator_rejects_incorrect_artifact_release_annotation()
    test_validator_rejects_missing_unreadable_build_log_guard()
    test_validator_rejects_root_level_unsigned_build_logs()
    test_validator_rejects_missing_build_product_python_resolver()
    test_validator_rejects_missing_build_product_configuration_guard()
    test_validator_rejects_missing_build_product_expected_video_metadata_guard()
    test_validator_rejects_missing_build_product_duplicate_extension_guard()
    test_validator_rejects_directory_only_embedded_extension_count()
    test_validator_rejects_missing_build_product_video_file_guard()
    test_validator_rejects_missing_build_product_diagnostics_file_guards()
    test_validator_rejects_missing_build_product_executable_name_guard()
    test_validator_rejects_missing_make_gate_aliases()
    test_validator_rejects_missing_build_product_info_plist_string_type_guard()
    test_validator_rejects_missing_build_product_blank_info_plist_guard()
    test_validator_rejects_missing_build_product_untrimmed_info_plist_guard()
    test_validator_rejects_missing_build_product_multiline_info_plist_guard()
    test_validator_rejects_missing_build_product_blank_cmio_guard()
    test_validator_rejects_missing_build_product_cmio_string_type_guard()
    test_validator_rejects_missing_build_product_untrimmed_cmio_guard()
    test_validator_rejects_missing_build_product_multiline_cmio_guard()
    test_validator_rejects_missing_packaged_file_byte_count_verifier()
    test_validator_rejects_missing_packaged_multiline_info_plist_verifier()
    test_validator_rejects_missing_packaged_multiline_app_group_verifier()
    test_validator_rejects_missing_packaged_fallback_encoded_multiline_app_group_verifier()
    print("Project validator tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
