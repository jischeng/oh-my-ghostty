#!/usr/bin/env python3
"""Create a persistent private signing identity and verify OMG release signatures."""

import argparse
import getpass
import os
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import sys
import tempfile

RELEASE_ID = "com.jischeng.omg"
MODES = ("self-signed", "developer-id", "development", "ad-hoc")


def run(*args, **kwargs):
    # Never echo commands: security import/unlock accept passwords in argv.
    return subprocess.run(args, check=True, capture_output=True, **kwargs)


def policy(environ=None):
    env = os.environ if environ is None else environ
    mode = env.get("OMG_SIGNING_MODE", "self-signed")
    identity = env.get("OMG_SIGNING_IDENTITY", "")
    if mode not in MODES:
        raise ValueError(f"unsupported signing mode: {mode}")
    if mode == "ad-hoc":
        if identity != "-":
            raise ValueError("ad-hoc mode requires identity -")
    elif not identity or identity == "-":
        raise ValueError("persistent signing requires OMG_SIGNING_IDENTITY; no ad-hoc fallback")
    if mode == "self-signed" and not re.fullmatch(r"[0-9a-fA-F]{40}", identity):
        raise ValueError("self-signed identity must be the pinned certificate SHA-1 fingerprint")
    return mode, identity.upper() if mode == "self-signed" else identity


def requirement(identity):
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", identity):
        raise ValueError("invalid certificate fingerprint")
    # SHA-1 here is Apple's certificate identifier, not a file integrity hash.
    return f'identifier "{RELEASE_ID}" and certificate leaf = H"{identity.upper()}"'


def components(app):
    sparkle = app / "Contents/Frameworks/Sparkle.framework/Versions/B"
    return [
        sparkle / "Sparkle",
        sparkle / "XPCServices/Downloader.xpc",
        sparkle / "XPCServices/Installer.xpc",
        sparkle / "Autoupdate",
        sparkle / "Updater.app",
        app / "Contents/PlugIns/DockTilePlugin.plugin",
    ]


def verify(app, previous=None):
    mode, identity = policy()
    if mode not in ("self-signed", "developer-id"):
        raise ValueError("public release verification requires self-signed or developer-id mode")
    with (app / "Contents/Info.plist").open("rb") as stream:
        if plistlib.load(stream).get("CFBundleIdentifier") != RELEASE_ID:
            raise ValueError("not an OMG release bundle")
    run("codesign", "--verify", "--deep", "--strict", str(app))
    dr_result = run("codesign", "-d", "-r-", str(app))
    dr_output = (dr_result.stdout + dr_result.stderr).decode()
    match = re.search(r"^(?:# )?designated => (.+)$", dr_output, re.MULTILINE)
    if not match or "cdhash" in match[1]:
        raise ValueError("missing or code-hash-bound designated requirement")
    dr = match[1]
    if mode == "self-signed":
        expected = requirement(identity)
        with tempfile.TemporaryDirectory(prefix="omg-requirements-") as temp:
            actual_file, expected_file = Path(temp) / "actual", Path(temp) / "expected"
            run("csreq", "-r", "=" + dr, "-b", str(actual_file))
            run("csreq", "-r", "=" + expected, "-b", str(expected_file))
            if actual_file.read_bytes() != expected_file.read_bytes():
                raise ValueError("release DR does not pin the expected certificate and bundle ID")
        signer = f'certificate leaf = H"{identity}"'
    else:
        # Developer ID has a real Team ID; Apple Development is not release signing.
        signer = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        if "anchor apple generic" not in dr or "certificate leaf[subject.OU]" not in dr:
            raise ValueError("Developer ID DR must bind the Apple anchor and Team ID")
        detail = run("codesign", "-dv", "--verbose=4", str(app)).stderr.decode()
        team = re.search(r"^TeamIdentifier=([A-Z0-9]{10})$", detail, re.MULTILINE)
        if not team:
            raise ValueError("missing Developer ID Team ID")
        signer += f' and certificate leaf[subject.OU] = "{team[1]}"'
    for code in [app, *components(app)]:
        if not code.exists():
            continue
        run("codesign", "--verify", "--strict", "-R", "=" + signer, str(code))
        if mode == "self-signed":
            detail = run("codesign", "-dv", "--verbose=4", str(code)).stderr.decode()
            if re.search(r"^CodeDirectory .*flags=.*runtime", detail, re.MULTILINE):
                raise ValueError("self-signed releases must disable hardened runtime/library validation")
    if previous:
        # Supply a prior persistent release, not the legacy ad-hoc bridge.
        old_result = run("codesign", "-d", "-r-", str(previous))
        old_output = (old_result.stdout + old_result.stderr).decode()
        old_match = re.search(r"^(?:# )?designated => (.+)$", old_output, re.MULTILINE)
        if not old_match or "cdhash" in old_match[1]:
            raise ValueError("previous identity is ad-hoc; this is a one-time authorization migration")
        run("codesign", "--verify", "--strict", "-R", "=" + old_match[1], str(app))
        run("codesign", "--verify", "--strict", "-R", "=" + dr, str(previous))
    return dr


def create_identity(destination, password):
    """One-time provisioning. Never rotate or overwrite an existing identity."""
    if sys.platform != "darwin":
        raise ValueError("identity provisioning requires macOS")
    if not password or "\n" in password or "\r" in password:
        raise ValueError("a non-empty single-line password is required")
    destination = destination.expanduser().resolve()
    repository = Path(__file__).resolve().parents[2]
    if destination.is_relative_to(repository):
        raise ValueError("private signing material must be stored outside the repository")
    if destination.exists():
        raise ValueError("signing directory already exists; reuse/restore it, do not regenerate")
    destination.mkdir(mode=0o700, parents=True)
    keychain = destination / "release.keychain-db"
    certificate = destination / "certificate.pem"
    backup = destination / "identity.p12"
    # create-keychain can affect the search list. Restore it even on failure.
    search_list = shlex.split(run("security", "list-keychains", "-d", "user").stdout.decode())
    old_umask = os.umask(0o077)
    try:
        with tempfile.TemporaryDirectory(prefix="provision-", dir=destination) as temp:
            temp = Path(temp)
            secret = temp / "password"
            export_secret = temp / "export-password"
            secret.write_text(password + "\n")
            # LibreSSL shares a BIO for identical passin/passout filenames and
            # consumes the first line; separate files work on both OpenSSL variants.
            export_secret.write_text(password + "\n")
            key, config = temp / "key.pem", temp / "openssl.cnf"
            config.write_text(
                "[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=extensions\n"
                "[dn]\nCN=OMG Release Signing\n"
                "[extensions]\nbasicConstraints=critical,CA:FALSE\n"
                "keyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\n"
                "subjectKeyIdentifier=hash\n"
            )
            run("/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:3072",
                "-sha256", "-days", "3650", "-config", str(config),
                "-keyout", str(key), "-out", str(certificate), "-passout", "file:" + str(secret))
            run("/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(key),
                "-in", str(certificate), "-out", str(backup),
                "-passin", "file:" + str(secret), "-passout", "file:" + str(export_secret))
            fingerprint = run("/usr/bin/openssl", "x509", "-in", str(certificate),
                              "-noout", "-fingerprint", "-sha1").stdout.decode()
            identity = fingerprint.strip().split("=", 1)[1].replace(":", "").upper()
            requirement(identity)  # Validate before importing anything.
            run("security", "create-keychain", "-p", password, str(keychain))
            run("security", "unlock-keychain", "-p", password, str(keychain))
            run("security", "import", str(backup), "-k", str(keychain),
                "-P", password, "-T", "/usr/bin/codesign")
            run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                "-s", "-k", password, str(keychain))
            # Do not use -v: a private self-signed issuer is intentionally not
            # Apple-trusted. Matching identities still proves the private key exists.
            identities = run("security", "find-identity", "-p", "codesigning",
                             str(keychain)).stdout.decode()
            if identity not in identities:
                raise ValueError("created certificate has no matching private key; preserve directory for diagnosis")
        env = {
            "OMG_SIGNING_MODE": "self-signed",
            "OMG_SIGNING_IDENTITY": identity,
            "OMG_SIGNING_KEYCHAIN": str(keychain),
        }
        (destination / "signing.env").write_text("".join(
            f"export {name}={shlex.quote(value)}\n" for name, value in env.items()))
        return destination / "signing.env"
    finally:
        try:
            run("security", "list-keychains", "-d", "user", "-s", *search_list)
        finally:
            os.umask(old_umask)
    # Failed partial provisioning is deliberately preserved, never silently rotated.


def unlock_signing_keychain(password=None):
    mode, identity = policy()
    if mode != "self-signed":
        raise ValueError("automatic unlock is for the private self-signed release Keychain")
    value = os.environ.get("OMG_SIGNING_KEYCHAIN", "")
    if not value:
        raise ValueError("source signing.env to configure OMG_SIGNING_KEYCHAIN")
    path = Path(value).expanduser().resolve()
    from omg_keychain import store_password, unlock
    if password is not None:
        store_password(path, identity, password)
        return "credential-stored"
    return unlock(path, identity)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("policy")
    commands.add_parser("requirement")
    commands.add_parser("store-password")
    commands.add_parser("unlock")
    check = commands.add_parser("verify")
    check.add_argument("app", type=Path)
    check.add_argument("--previous", type=Path)
    create = commands.add_parser("create")
    create.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "create":
            if not sys.stdin.isatty():
                raise ValueError("run identity creation in an interactive terminal; passwords must not be echoed")
            password = getpass.getpass("New signing keychain / encrypted backup password: ")
            if password != getpass.getpass("Confirm password: "):
                raise ValueError("passwords do not match")
            config = create_identity(args.directory, password)
            print(f"Created persistent identity. Source {shlex.quote(str(config))} before release signing.")
            print("Back up identity.p12 and certificate.pem; store the password separately. No system trust was installed.")
        elif args.command == "store-password":
            if not sys.stdin.isatty():
                raise ValueError("run store-password in your terminal; no password arguments or files are accepted")
            password = getpass.getpass("Existing signing Keychain password (saved only in login Keychain): ")
            unlock_signing_keychain(password)
            print("Signing credential saved in login Keychain; no password was printed or written to a file.")
        elif args.command == "unlock":
            print("signing_keychain=" + unlock_signing_keychain())
        elif args.command == "verify":
            print(verify(args.app, args.previous))
        else:
            mode, identity = policy()
            print(requirement(identity) if args.command == "requirement" else mode)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    except (OSError, subprocess.CalledProcessError):
        # Subprocess arguments may contain a password; never stringify CalledProcessError.
        print("Signing operation failed. Check identity, keychain unlock, and inputs; "
              "do not regenerate an existing identity to bypass a failure.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
