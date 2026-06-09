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


def test_validator_rejects_missing_host_time_sample_retiming():
    assert_validator_rejects_mutation(
        "Extension/ExtensionProvider.swift",
        """        let assetPresentationTime = CMTimeAdd(presentationTime, timestampOffset)
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

        guard let adjustedPresentationTime = hostPresentationTime(for: hostScaledAssetPresentationTime,
                                                                  currentHostTime: currentHostTime) else {
            logger.error("Skipping sample buffer with non-finite host presentation timestamp")
            return
        }

        guard let hostTimeInNanoseconds = hostTimeInNanoseconds(from: adjustedPresentationTime) else {
            logger.error("Skipping sample buffer with non-finite host-time nanoseconds")
            return
        }""",
        """        let adjustedPresentationTime = CMTimeAdd(presentationTime, timestampOffset)
        let hostTimeInNanoseconds = UInt64(0)""",
        "extension should retime emitted sample timestamps into the advertised host-time clock domain",
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
        """if isinstance(value, str) and value:
    print(value)
""",
        """if value:
    print(value)
""",
        "runtime diagnostics should reject non-string Info.plist metadata values",
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


def test_validator_rejects_missing_runtime_diagnostics_fallback_scalar_app_group_guard():
    assert_validator_rejects_mutation(
        "scripts/collect_runtime_diagnostics.sh",
        '    if ! plistbuddy_output="$(/usr/libexec/PlistBuddy -x -c "Print :${APP_GROUP_ENTITLEMENT}" "$entitlements_file" 2>/dev/null)"; then',
        '    if ! plistbuddy_output="$(/usr/libexec/PlistBuddy -c "Print :${APP_GROUP_ENTITLEMENT}" "$entitlements_file" 2>/dev/null)"; then',
        "runtime diagnostics should reject non-array or non-string app-group entitlements in the PlistBuddy fallback parser",
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


def test_validator_rejects_raw_extension_executable_metadata():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """            guard let executableName = Self.infoPlistString(in: extensionBundle, key: "CFBundleExecutable") else {
                throw ExtensionRequestError.missingExtensionExecutable(extensionURL.path)
            }
""",
        """            guard let executableName = extensionBundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
                  !executableName.isEmpty else {
                throw ExtensionRequestError.missingExtensionExecutable(extensionURL.path)
            }
""",
        "host app should require trimmed string embedded extension executable and CMIO metadata",
    )


def test_validator_rejects_raw_extension_cmio_metadata():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        """        let trimmedMachServiceName = machServiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedMachServiceName.isEmpty ? nil : trimmedMachServiceName
""",
        """        return machServiceName
""",
        "host app should require trimmed string embedded extension executable and CMIO metadata",
    )


def test_validator_rejects_missing_host_mp4_sample_count_guard():
    assert_validator_rejects_mutation(
        "GarethVideoCam/ContentView.swift",
        "if sampleCount > 0, sampleDelta > 0, timescale % sampleDelta == 0",
        "if sampleDelta > 0, timescale % sampleDelta == 0",
        "host app should only accept positive-sample MP4 timing entries when parsing bundled-video frame rate",
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


def test_validator_rejects_missing_make_gate_aliases():
    assert_validator_rejects_mutation(
        "Makefile",
        "\nlint test build: check\n",
        "\n",
        "Makefile should expose lint, test, build, and check validation entry points",
    )


def test_validator_rejects_missing_build_product_info_plist_string_type_guard():
    assert_validator_rejects_mutation(
        "scripts/verify_build_products.sh",
        "if isinstance(value, str) and value:",
        "if value:",
        "build-product verifier should reject non-string Info.plist display and privacy strings",
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
    test_truncated_stts_entry_count_does_not_report_frame_rate()
    test_zero_stsd_entry_count_does_not_report_dimensions()
    test_truncated_png_signature_does_not_raise()
    test_non_ihdr_png_header_does_not_report_dimensions()
    test_malformed_icon_size_metadata_does_not_raise()
    test_tracked_fixture_validates()
    test_validator_rejects_missing_indefinite_stream_duration_guard()
    test_validator_rejects_missing_non_finite_sample_time_guard()
    test_validator_rejects_missing_adjusted_decode_time_guard()
    test_validator_rejects_missing_host_time_sample_retiming()
    test_validator_rejects_missing_unknown_signature_state()
    test_validator_rejects_missing_all_architecture_signature_validation()
    test_validator_rejects_missing_signing_information_unknown_guard()
    test_validator_rejects_missing_host_team_identifier_shape_guard()
    test_validator_rejects_numeric_boolean_entitlement_acceptance()
    test_validator_rejects_missing_runtime_diagnostics_all_architecture_details()
    test_validator_rejects_missing_runtime_diagnostics_all_architecture_entitlements()
    test_validator_rejects_missing_runtime_diagnostics_scalar_boolean_entitlement_guard()
    test_validator_rejects_missing_runtime_diagnostics_info_plist_string_guard()
    test_validator_rejects_missing_runtime_diagnostics_all_architecture_application_groups()
    test_validator_rejects_missing_runtime_diagnostics_non_string_app_group_guard()
    test_validator_rejects_missing_runtime_diagnostics_fallback_scalar_app_group_guard()
    test_validator_rejects_loose_team_id_prefix_lengths()
    test_validator_rejects_bare_application_group_acceptance()
    test_validator_rejects_missing_extension_load_failure_detail_row()
    test_validator_rejects_missing_unsigned_build_configuration_guard()
    test_validator_rejects_raw_extension_executable_metadata()
    test_validator_rejects_raw_extension_cmio_metadata()
    test_validator_rejects_missing_host_mp4_sample_count_guard()
    test_validator_rejects_missing_host_mp4_complete_stts_entry_guard()
    test_validator_rejects_missing_host_mp4_stsd_entry_count_guard()
    test_validator_rejects_missing_png_ihdr_guard()
    test_validator_rejects_missing_icon_size_metadata_guard()
    test_validator_rejects_missing_host_mp4_mdhd_version_guard()
    test_validator_rejects_missing_host_mp4_full_box_version_guards()
    test_validator_rejects_missing_host_mp4_video_track_dimension_gate()
    test_validator_rejects_missing_partial_ci_log_scan()
    test_validator_rejects_root_level_unsigned_build_logs()
    test_validator_rejects_missing_build_product_python_resolver()
    test_validator_rejects_missing_build_product_configuration_guard()
    test_validator_rejects_missing_build_product_expected_video_metadata_guard()
    test_validator_rejects_missing_make_gate_aliases()
    test_validator_rejects_missing_build_product_info_plist_string_type_guard()
    test_validator_rejects_missing_packaged_file_byte_count_verifier()
    print("Project validator tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
