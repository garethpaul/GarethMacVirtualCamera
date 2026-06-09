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


def test_tracked_fixture_validates():
    with tracked_fixture_repo() as fixture_root:
        status, output = run_validator(fixture_root)

    if status != 0:
        raise AssertionError(f"Tracked fixture should validate cleanly.\n{output}")


def test_validator_rejects_missing_indefinite_stream_duration_guard():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """        if let frameDuration = streamProperties.frameDuration {
            guard frameDuration.flags.contains(.valid),
                  !frameDuration.flags.contains(.indefinite),
                  CMTimeCompare(frameDuration, CameraExtensionConfiguration.frameDuration) == 0 else {""",
        """        if let frameDuration = streamProperties.frameDuration {
            guard frameDuration.flags.contains(.valid),
                  CMTimeCompare(frameDuration, CameraExtensionConfiguration.frameDuration) == 0 else {""",
        "extension stream should reject unsupported or indefinite frame-duration requests",
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


def test_validator_rejects_missing_runtime_diagnostics_all_architecture_application_groups():
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        '  common_application_groups_for_architectures "$architecture_groups" "$architecture_count"',
        '  printf \'%s\\n\' "$architecture_groups"',
        "runtime diagnostics script should require app-group values across all executable architecture slices",
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


def test_validator_rejects_missing_extension_load_failure_detail_row():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        '                    DetailRow(title: "Extension Load Failure", value: extensionLoadFailureDetail)\n',
        "",
        "host app should preserve the last readiness, extension-load, or request failure in details and copied diagnostics",
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


def test_validator_rejects_missing_host_mp4_sample_count_guard():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        "if sampleCount > 0, sampleDelta > 0, timescale % sampleDelta == 0",
        "if sampleDelta > 0, timescale % sampleDelta == 0",
        "host app should only accept positive-sample MP4 timing entries when parsing bundled-video frame rate",
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


def test_validator_rejects_missing_partial_ci_log_scan():
    assert_validator_rejects_mutation(
        ".github/workflows/macos-build.yml",
        """        if: always() && hashFiles('.build/Xcode/Logs/build-*.log') != ''
        run: ./scripts/scan_build_log.py .build/Xcode/Logs/build-*.log""",
        "        run: ./scripts/scan_build_log.py .build/Xcode/Logs/build-Debug.log .build/Xcode/Logs/build-Release.log",
        "macOS build workflow should scan any captured Debug or Release xcodebuild output even after failed build steps",
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


def test_validator_rejects_missing_packaged_file_byte_count_verifier():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        """  verify_app_diagnostics_self_test "$configuration" "$app_path" "$script_path" "file-byte-count" "file-byte-count" \\
    "File byte count fixture: 5"

""",
        "",
        "build-product verifier should run the bundled runtime diagnostics file-byte-count self-test",
    )


def main():
    test_malformed_mdhd_atom_does_not_raise()
    test_unsupported_mdhd_version_does_not_report_duration()
    test_unsupported_hdlr_version_does_not_report_duration()
    test_unsupported_stts_version_does_not_report_frame_rate()
    test_unsupported_stsd_version_does_not_report_dimensions()
    test_non_video_track_stsd_does_not_report_dimensions()
    test_zero_sample_count_stts_does_not_report_frame_rate()
    test_tracked_fixture_validates()
    test_validator_rejects_missing_indefinite_stream_duration_guard()
    test_validator_rejects_missing_unknown_signature_state()
    test_validator_rejects_missing_all_architecture_signature_validation()
    test_validator_rejects_missing_signing_information_unknown_guard()
    test_validator_rejects_missing_runtime_diagnostics_all_architecture_details()
    test_validator_rejects_missing_runtime_diagnostics_all_architecture_entitlements()
    test_validator_rejects_missing_runtime_diagnostics_all_architecture_application_groups()
    test_validator_rejects_loose_team_id_prefix_lengths()
    test_validator_rejects_bare_application_group_acceptance()
    test_validator_rejects_missing_extension_load_failure_detail_row()
    test_validator_rejects_missing_unsigned_build_configuration_guard()
    test_validator_rejects_missing_host_mp4_sample_count_guard()
    test_validator_rejects_missing_host_mp4_mdhd_version_guard()
    test_validator_rejects_missing_host_mp4_full_box_version_guards()
    test_validator_rejects_missing_host_mp4_video_track_dimension_gate()
    test_validator_rejects_missing_partial_ci_log_scan()
    test_validator_rejects_root_level_unsigned_build_logs()
    test_validator_rejects_missing_build_product_python_resolver()
    test_validator_rejects_missing_build_product_configuration_guard()
    test_validator_rejects_missing_packaged_file_byte_count_verifier()
    print("Project validator tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
