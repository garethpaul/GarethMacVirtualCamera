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

    with tempfile.NamedTemporaryFile(suffix=".mp4", delete=False) as fixture:
        fixture.write(malformed_mp4)
        fixture_path = Path(fixture.name)

    try:
        metadata = validator.mp4_video_metadata(fixture_path)
    finally:
        fixture_path.unlink(missing_ok=True)

    if metadata != {"dimensions": None, "frame_rate": None, "duration_seconds": None}:
        raise AssertionError(f"Unexpected malformed mdhd metadata: {metadata}")


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


def test_validator_rejects_missing_partial_ci_log_scan():
    assert_validator_rejects_mutation(
        ".github/workflows/macos-build.yml",
        """        if: always() && hashFiles('build-*.log') != ''
        run: ./scripts/scan_build_log.py build-*.log""",
        "        run: ./scripts/scan_build_log.py build-Debug.log build-Release.log",
        "macOS build workflow should scan any captured Debug or Release xcodebuild output even after failed build steps",
    )


def test_validator_rejects_missing_build_product_python_resolver():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        'PYTHON3_BIN="$(python3_command)"',
        'PYTHON3_BIN=python3',
        "build-product verifier should resolve one explicit Python 3 interpreter before parsing plists or bundled-video metadata",
    )


def main():
    test_malformed_mdhd_atom_does_not_raise()
    test_tracked_fixture_validates()
    test_validator_rejects_missing_indefinite_stream_duration_guard()
    test_validator_rejects_missing_unknown_signature_state()
    test_validator_rejects_missing_all_architecture_signature_validation()
    test_validator_rejects_missing_runtime_diagnostics_all_architecture_details()
    test_validator_rejects_missing_runtime_diagnostics_all_architecture_entitlements()
    test_validator_rejects_missing_runtime_diagnostics_all_architecture_application_groups()
    test_validator_rejects_missing_extension_load_failure_detail_row()
    test_validator_rejects_missing_unsigned_build_configuration_guard()
    test_validator_rejects_missing_partial_ci_log_scan()
    test_validator_rejects_missing_build_product_python_resolver()
    print("Project validator tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
