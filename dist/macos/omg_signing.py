#!/usr/bin/env python3
"""Create a persistent private signing identity and verify OMG release signatures."""

import argparse
import ctypes
import getpass
import hashlib
import json
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
CODE_SIGNING_POLICY_OID = "1.2.840.113635.100.1.16"
ADMIN_SYSTEM_KEYCHAIN = Path("/Library/Keychains/System.keychain")
DEFAULT_APP_PATH = Path("/Applications/OMG.app")
TRUST_DOMAIN_USER = 0
TRUST_DOMAIN_ADMIN = 1
TRUST_RESULT_TRUST_ROOT = 1
ERR_SEC_ITEM_NOT_FOUND = -25300


def run(*args, **kwargs):
    # Never echo commands: security import/unlock accept passwords in argv.
    kwargs.setdefault("capture_output", True)
    return subprocess.run(args, check=True, **kwargs)


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


def requirement(identity, identifier=RELEASE_ID):
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", identity):
        raise ValueError("invalid certificate fingerprint")
    if not identifier or not re.fullmatch(r"[A-Za-z0-9._-]+", identifier):
        raise ValueError("invalid code signing identifier")
    # SHA-1 here is Apple's certificate identifier, not a file integrity hash.
    return f'identifier "{identifier}" and certificate leaf = H"{identity.upper()}"'


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


def _bundle_identifier(path, default=None):
    for plist_path in (
        path / "Contents/Info.plist",
        path / "Resources/Info.plist",
        path / "Versions/Current/Resources/Info.plist",
    ):
        if plist_path.is_file():
            with plist_path.open("rb") as stream:
                bundle_id = plistlib.load(stream).get("CFBundleIdentifier")
                if bundle_id:
                    return bundle_id
    return default


def session_runtime_machos(app):
    runtime = app / "Contents/Resources/session-runtime"
    if not runtime.is_dir():
        return []
    targets = []
    directories = [runtime, *sorted(p for p in runtime.glob("macos-*") if p.is_dir())]
    for directory in directories:
        omgd = directory / "omgd"
        if omgd.is_file() and not omgd.is_symlink():
            targets.append((omgd, "com.jischeng.omg.omgd"))
        mobile_support = directory / "omg-mobile-support"
        if mobile_support.is_file() and not mobile_support.is_symlink():
            targets.append((mobile_support, "com.jischeng.omg.mobile-support"))
        for dylib in sorted(directory.glob("libghostty-vt*.dylib")):
            if dylib.is_file() and not dylib.is_symlink():
                targets.append((dylib, "com.jischeng.omg.libghostty-vt"))
    return targets


def component_targets(app):
    sparkle = app / "Contents/Frameworks/Sparkle.framework/Versions/B"
    defaults = {
        sparkle / "Sparkle": "org.sparkle-project.Sparkle",
        sparkle / "XPCServices/Downloader.xpc": "org.sparkle-project.DownloaderService",
        sparkle / "XPCServices/Installer.xpc": "org.sparkle-project.InstallerLauncher",
        sparkle / "Autoupdate": "com.jischeng.omg.sparkle.autoupdate",
        sparkle / "Updater.app": "org.sparkle-project.Sparkle.Updater",
        app / "Contents/PlugIns/DockTilePlugin.plugin": "com.jischeng.omg.dock-tile",
    }
    targets = [(app, RELEASE_ID)]
    for code in components(app):
        if not code.exists():
            continue
        expected_id = defaults[code] if code == sparkle / "Autoupdate" else _bundle_identifier(code, defaults[code])
        targets.append((code, expected_id))
    frameworks_dir = app / "Contents/Frameworks"
    if frameworks_dir.is_dir():
        for framework in sorted(frameworks_dir.glob("*.framework")):
            if framework.name == "Sparkle.framework":
                continue
            bundle_id = _bundle_identifier(framework)
            if bundle_id:
                targets.append((framework, bundle_id))
    targets.extend(session_runtime_machos(app))
    return targets


def _validate_askpass(app):
    askpass = app / "Contents/Resources/session-runtime/askpass"
    if not os.path.lexists(askpass):
        return
    if askpass.is_symlink() or not askpass.is_file():
        raise ValueError("session-runtime/askpass must be a regular file, not a symlink")
    if (askpass.stat().st_mode & 0o111) == 0:
        raise ValueError("session-runtime/askpass must be executable")
    code_resources = app / "Contents/_CodeSignature/CodeResources"
    if code_resources.is_file():
        with code_resources.open("rb") as stream:
            sealed = plistlib.load(stream)
        files = sealed.get("files2") or sealed.get("files") or {}
        if "Resources/session-runtime/askpass" not in files:
            raise ValueError("session-runtime/askpass is not sealed in CodeResources")


def _extract_designated_requirement(target):
    dr_result = run("codesign", "-d", "-r-", str(target))
    dr_output = (dr_result.stdout + dr_result.stderr).decode()
    match = re.search(r"^(?:# )?designated => (.+)$", dr_output, re.MULTILINE)
    if not match or "cdhash" in match[1]:
        raise ValueError(f"missing or code-hash-bound designated requirement for {target}")
    return match[1]


def verify(app, previous=None):
    mode, identity = policy()
    if mode not in ("self-signed", "developer-id"):
        raise ValueError("public release verification requires self-signed or developer-id mode")
    with (app / "Contents/Info.plist").open("rb") as stream:
        if plistlib.load(stream).get("CFBundleIdentifier") != RELEASE_ID:
            raise ValueError("not an OMG release bundle")
    run("codesign", "--verify", "--deep", "--strict", str(app))
    _validate_askpass(app)
    dr = _extract_designated_requirement(app)
    if mode == "self-signed":
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
    with tempfile.TemporaryDirectory(prefix="omg-requirements-") as temp:
        temp_dir = Path(temp)
        for index, (code, expected_id) in enumerate(component_targets(app)):
            run("codesign", "--verify", "--strict", "-R", "=" + signer, str(code))
            comp_dr = _extract_designated_requirement(code)
            detail = run("codesign", "-dv", "--verbose=4", str(code)).stderr.decode()
            id_match = re.search(r"^Identifier=(.+)$", detail, re.MULTILINE)
            if id_match and id_match[1] != expected_id:
                raise ValueError(f"unexpected signing identifier for {code}: {id_match[1]} != {expected_id}")
            if mode == "self-signed":
                expected = requirement(identity, expected_id)
                actual_file = temp_dir / f"actual-{index}"
                expected_file = temp_dir / f"expected-{index}"
                run("csreq", "-r", "=" + comp_dr, "-b", str(actual_file))
                run("csreq", "-r", "=" + expected, "-b", str(expected_file))
                if actual_file.read_bytes() != expected_file.read_bytes():
                    raise ValueError(f"DR for {code} does not pin {expected_id} and {identity}")
                if re.search(r"^CodeDirectory .*flags=.*runtime", detail, re.MULTILINE):
                    raise ValueError("self-signed releases must disable hardened runtime/library validation")
            else:
                if "anchor apple generic" not in comp_dr or "certificate leaf[subject.OU]" not in comp_dr:
                    raise ValueError(f"Developer ID DR for {code} must bind the Apple anchor and Team ID")
    if previous:
        # Supply a prior persistent release, not the legacy ad-hoc bridge.
        old_dr = _extract_designated_requirement(previous)
        run("codesign", "--verify", "--strict", "-R", "=" + old_dr, str(app))
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


def pin_signing_interpreter(directory, replace=False):
    """Non-secret runtime metadata; certificate/credentials remain unchanged."""
    pin = directory / "signing-python.pin"
    if pin.exists() and not replace:
        return
    executable = Path(sys.executable).resolve()
    digest = hashlib.sha256(executable.read_bytes()).hexdigest()
    # Atomic replacement, private permissions. No password or credential IDs.
    fd, temporary = tempfile.mkstemp(prefix=".signing-python-", dir=directory)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(f"{executable}\n{digest}\n")
        os.replace(temporary, pin)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


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
        pin_signing_interpreter(path.parent, replace=True)
        return "credential-stored"
    result = unlock(path, identity)
    # An already-unlocked keychain doesn't prove this executable has credential
    # access. Pin only after actual successful retrieval, or manual store above.
    if result == "unlocked":
        pin_signing_interpreter(path.parent)
    return result


def _resolve_cert_der(app=None, cert=None):
    if app is not None and cert is not None:
        raise ValueError("specify either --app or --cert, not both")
    if app is None and cert is None:
        if DEFAULT_APP_PATH.exists():
            app = DEFAULT_APP_PATH
        else:
            raise ValueError("specify --app APP or --cert CERT")
    if app is not None:
        app_path = Path(app)
        if not app_path.exists():
            raise ValueError(f"missing application bundle: {app_path}")
        with tempfile.TemporaryDirectory(prefix="omg-cert-extract-") as temp:
            prefix = Path(temp) / "cert-"
            run("codesign", "-d", f"--extract-certificates={prefix}", str(app_path))
            leaf = Path(f"{prefix}0")
            if not leaf.is_file():
                raise ValueError(f"no signing certificate embedded in {app_path}")
            return leaf.read_bytes()
    cert_path = Path(cert)
    if not cert_path.is_file():
        raise ValueError(f"missing certificate file: {cert_path}")
    raw = cert_path.read_bytes()
    if b"-----BEGIN CERTIFICATE-----" in raw:
        with tempfile.TemporaryDirectory(prefix="omg-cert-der-") as temp:
            out_der = Path(temp) / "cert.der"
            run("/usr/bin/openssl", "x509", "-in", str(cert_path), "-outform", "DER", "-out", str(out_der))
            return out_der.read_bytes()
    run("/usr/bin/openssl", "x509", "-inform", "DER", "-noout", input=raw)
    return raw


def _parse_x509_metadata(der_bytes):
    sha1 = hashlib.sha1(der_bytes).hexdigest().upper()
    text = run(
        "/usr/bin/openssl",
        "x509",
        "-inform",
        "DER",
        "-noout",
        "-text",
        "-certopt",
        "no_pubkey,no_sigdump",
        input=der_bytes,
    ).stdout.decode()
    subject_match = re.search(r"^\s*Subject:\s*(.+)$", text, re.MULTILINE)
    issuer_match = re.search(r"^\s*Issuer:\s*(.+)$", text, re.MULTILINE)
    subject = subject_match[1].strip() if subject_match else ""
    issuer = issuer_match[1].strip() if issuer_match else ""
    cn_match = re.search(r"(?:^|,)\s*CN\s*=\s*([^,/\n]+)", subject)
    common_name = cn_match[1].strip() if cn_match else (subject or None)
    eku_match = re.search(
        r"X509v3 Extended Key Usage:[^\n]*\n\s*(.+)",
        text,
    )
    has_code_signing_eku = bool(eku_match and "Code Signing" in eku_match[1])
    ca_true = bool(re.search(r"X509v3 Basic Constraints:[^\n]*\n\s*CA:TRUE", text))
    return {
        "common_name": common_name,
        "subject": subject,
        "issuer": issuer,
        "sha1": sha1,
        "self_signed": bool(subject and subject == issuer),
        "has_code_signing_eku": has_code_signing_eku,
        "is_ca": ca_true,
    }


class MacTrustInspector:
    """Query macOS Trust Settings and SecTrust evaluation for one DER leaf cert."""

    def __init__(self):
        if sys.platform != "darwin":
            raise ValueError("trust inspection requires macOS")
        self.cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        self.sec = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
        p = ctypes.c_void_p
        u32 = ctypes.c_uint32
        i32 = ctypes.c_int32
        u8 = ctypes.c_ubyte
        long_t = ctypes.c_long
        self.cf.CFRelease.argtypes = [p]
        self.cf.CFRelease.restype = None
        self.cf.CFGetTypeID.argtypes = [p]
        self.cf.CFGetTypeID.restype = ctypes.c_ulong
        self.cf.CFStringGetTypeID.argtypes = []
        self.cf.CFStringGetTypeID.restype = ctypes.c_ulong
        self.cf.CFArrayGetCount.argtypes = [p]
        self.cf.CFArrayGetCount.restype = long_t
        self.cf.CFArrayGetValueAtIndex.argtypes = [p, long_t]
        self.cf.CFArrayGetValueAtIndex.restype = p
        self.cf.CFArrayCreate.argtypes = [p, ctypes.POINTER(p), long_t, p]
        self.cf.CFArrayCreate.restype = p
        self.cf.CFDictionaryGetValue.argtypes = [p, p]
        self.cf.CFDictionaryGetValue.restype = p
        self.cf.CFStringCreateWithCString.argtypes = [p, ctypes.c_char_p, u32]
        self.cf.CFStringCreateWithCString.restype = p
        self.cf.CFStringGetCString.argtypes = [p, ctypes.c_char_p, long_t, u32]
        self.cf.CFStringGetCString.restype = u8
        self.cf.CFDataCreate.argtypes = [p, ctypes.c_char_p, long_t]
        self.cf.CFDataCreate.restype = p
        self.cf.CFDataGetLength.argtypes = [p]
        self.cf.CFDataGetLength.restype = long_t
        self.cf.CFDataGetBytePtr.argtypes = [p]
        self.cf.CFDataGetBytePtr.restype = p
        self.cf.CFNumberGetValue.argtypes = [p, long_t, ctypes.c_void_p]
        self.cf.CFNumberGetValue.restype = u8

        self.sec.SecCertificateCreateWithData.argtypes = [p, p]
        self.sec.SecCertificateCreateWithData.restype = p
        self.sec.SecCertificateCopyNormalizedSubjectSequence.argtypes = [p]
        self.sec.SecCertificateCopyNormalizedSubjectSequence.restype = p
        self.sec.SecCertificateCopyNormalizedIssuerSequence.argtypes = [p]
        self.sec.SecCertificateCopyNormalizedIssuerSequence.restype = p
        self.sec.SecTrustSettingsCopyTrustSettings.argtypes = [p, u32, ctypes.POINTER(p)]
        self.sec.SecTrustSettingsCopyTrustSettings.restype = i32
        self.sec.SecPolicyGetTypeID.argtypes = []
        self.sec.SecPolicyGetTypeID.restype = ctypes.c_ulong
        self.sec.SecPolicyCopyProperties.argtypes = [p]
        self.sec.SecPolicyCopyProperties.restype = p
        self.sec.SecPolicyCreateWithProperties.argtypes = [p, p]
        self.sec.SecPolicyCreateWithProperties.restype = p
        self.sec.SecPolicyCreateBasicX509.argtypes = []
        self.sec.SecPolicyCreateBasicX509.restype = p
        self.sec.SecPolicyCreateSSL.argtypes = [u8, p]
        self.sec.SecPolicyCreateSSL.restype = p
        self.sec.SecTrustCreateWithCertificates.argtypes = [p, p, ctypes.POINTER(p)]
        self.sec.SecTrustCreateWithCertificates.restype = i32
        self.sec.SecTrustEvaluateWithError.argtypes = [p, ctypes.POINTER(p)]
        self.sec.SecTrustEvaluateWithError.restype = u8

    def _cf_string(self, text):
        return self.cf.CFStringCreateWithCString(None, text.encode("utf-8"), 0x08000100)

    def _read_cf_string(self, ref):
        if not ref:
            return None
        if self.cf.CFGetTypeID(ref) != self.cf.CFStringGetTypeID():
            return None
        buf = ctypes.create_string_buffer(1024)
        if not self.cf.CFStringGetCString(ref, buf, len(buf), 0x08000100):
            return None
        return buf.value.decode("utf-8", errors="replace")

    def _domain_trust(self, cert, domain):
        arr = ctypes.c_void_p()
        rc = self.sec.SecTrustSettingsCopyTrustSettings(cert, domain, ctypes.byref(arr))
        if rc == ERR_SEC_ITEM_NOT_FOUND or rc != 0:
            return False, False
        try:
            if not arr.value:
                return True, True
            count = self.cf.CFArrayGetCount(arr)
            if count == 0:
                return True, True
            k_result = self._cf_string("kSecTrustSettingsResult")
            k_policy = self._cf_string("kSecTrustSettingsPolicy")
            k_app = self._cf_string("kSecTrustSettingsApplication")
            k_policy_str = self._cf_string("kSecTrustSettingsPolicyString")
            k_policy_oid = ctypes.c_void_p.in_dll(self.sec, "kSecPolicyOid")
            try:
                has_codesign = False
                has_unscoped = False
                for i in range(count):
                    entry = self.cf.CFArrayGetValueAtIndex(arr, i)
                    result_val = TRUST_RESULT_TRUST_ROOT
                    res_ref = self.cf.CFDictionaryGetValue(entry, k_result)
                    if res_ref:
                        num = ctypes.c_int32()
                        if self.cf.CFNumberGetValue(res_ref, 3, ctypes.byref(num)):
                            result_val = num.value
                    if result_val not in (1, 2):
                        continue
                    pol_ref = self.cf.CFDictionaryGetValue(entry, k_policy)
                    if not pol_ref:
                        has_unscoped = True
                        has_codesign = True
                        continue
                    oid_str = None
                    if self.cf.CFGetTypeID(pol_ref) == self.sec.SecPolicyGetTypeID():
                        props = self.sec.SecPolicyCopyProperties(pol_ref)
                        if props:
                            try:
                                oid_ref = self.cf.CFDictionaryGetValue(props, k_policy_oid)
                                oid_str = self._read_cf_string(oid_ref)
                            finally:
                                self.cf.CFRelease(props)
                    else:
                        oid_str = self._read_cf_string(pol_ref)
                    if oid_str == CODE_SIGNING_POLICY_OID:
                        app_ref = self.cf.CFDictionaryGetValue(entry, k_app)
                        pstr_ref = self.cf.CFDictionaryGetValue(entry, k_policy_str)
                        if not app_ref and not pstr_ref:
                            has_codesign = True
                return has_codesign, has_unscoped
            finally:
                for ref in (k_result, k_policy, k_app, k_policy_str):
                    if ref:
                        self.cf.CFRelease(ref)
        finally:
            if arr.value:
                self.cf.CFRelease(arr)

    def _evaluate(self, cert_array, policy):
        if not policy:
            return False
        trust = ctypes.c_void_p()
        try:
            if self.sec.SecTrustCreateWithCertificates(cert_array, policy, ctypes.byref(trust)) != 0 or not trust.value:
                return False
            err = ctypes.c_void_p()
            ok = bool(self.sec.SecTrustEvaluateWithError(trust, ctypes.byref(err)))
            if err.value:
                self.cf.CFRelease(err)
            return ok
        finally:
            if trust.value:
                self.cf.CFRelease(trust)

    def inspect(self, der_bytes):
        data = self.cf.CFDataCreate(None, der_bytes, len(der_bytes))
        if not data:
            raise ValueError("invalid DER certificate bytes")
        cert = self.sec.SecCertificateCreateWithData(None, data)
        self.cf.CFRelease(data)
        if not cert:
            raise ValueError("failed to parse X.509 certificate")
        try:
            subj = self.sec.SecCertificateCopyNormalizedSubjectSequence(cert)
            iss = self.sec.SecCertificateCopyNormalizedIssuerSequence(cert)
            self_signed = False
            if subj and iss:
                s_len = self.cf.CFDataGetLength(subj)
                i_len = self.cf.CFDataGetLength(iss)
                s_ptr = self.cf.CFDataGetBytePtr(subj)
                i_ptr = self.cf.CFDataGetBytePtr(iss)
                self_signed = s_len == i_len and ctypes.string_at(s_ptr, s_len) == ctypes.string_at(i_ptr, i_len)
            if subj:
                self.cf.CFRelease(subj)
            if iss:
                self.cf.CFRelease(iss)

            admin_cs, admin_unscoped = self._domain_trust(cert, TRUST_DOMAIN_ADMIN)
            user_cs, user_unscoped = self._domain_trust(cert, TRUST_DOMAIN_USER)

            callbacks = ctypes.addressof(ctypes.c_void_p.in_dll(self.cf, "kCFTypeArrayCallBacks"))
            certs = (ctypes.c_void_p * 1)(cert)
            cert_array = self.cf.CFArrayCreate(None, certs, 1, callbacks)
            try:
                cs_oid = ctypes.c_void_p.in_dll(self.sec, "kSecPolicyAppleCodeSigning")
                cs_pol = self.sec.SecPolicyCreateWithProperties(cs_oid, None)
                x509_pol = self.sec.SecPolicyCreateBasicX509()
                ssl_pol = self.sec.SecPolicyCreateSSL(1, None)
                try:
                    cs_ok = self._evaluate(cert_array, cs_pol)
                    x509_ok = self._evaluate(cert_array, x509_pol)
                    ssl_ok = self._evaluate(cert_array, ssl_pol)
                finally:
                    for pol in (cs_pol, x509_pol, ssl_pol):
                        if pol:
                            self.cf.CFRelease(pol)
            finally:
                if cert_array:
                    self.cf.CFRelease(cert_array)
            return {
                "self_signed": self_signed,
                "trusted_in_admin_domain": admin_cs,
                "trusted_in_user_domain": user_cs,
                "is_code_signing_trusted": cs_ok,
                "is_non_code_signing_blocked": (not x509_ok) and (not ssl_ok),
                "has_unscoped_trust": admin_unscoped or user_unscoped or x509_ok or ssl_ok,
            }
        finally:
            self.cf.CFRelease(cert)


def trust_status(app=None, cert=None, inspector=None):
    der_bytes = _resolve_cert_der(app=app, cert=cert)
    meta = _parse_x509_metadata(der_bytes)
    trust = (inspector or MacTrustInspector()).inspect(der_bytes)
    self_signed = bool(trust.get("self_signed", meta["self_signed"]))
    admin_trusted = bool(trust["trusted_in_admin_domain"])
    user_trusted = bool(trust["trusted_in_user_domain"])
    cs_trusted = bool(trust["is_code_signing_trusted"])
    non_cs_blocked = bool(trust["is_non_code_signing_blocked"])
    has_unscoped = bool(trust["has_unscoped_trust"])

    if not self_signed:
        mode = "non_self_signed"
    elif admin_trusted and cs_trusted:
        mode = "self_signed_admin_trusted"
    elif user_trusted and cs_trusted:
        mode = "self_signed_user_only_trusted"
    else:
        mode = "self_signed_untrusted"

    healthy = (
        mode == "self_signed_admin_trusted"
        and cs_trusted
        and non_cs_blocked
        and not has_unscoped
    )
    return {
        "certificate_cn": meta["common_name"],
        "certificate_sha1": meta["sha1"],
        "self_signed": self_signed,
        "is_ca": meta["is_ca"],
        "has_code_signing_eku": meta["has_code_signing_eku"],
        "trusted_in_admin_domain": admin_trusted,
        "trusted_in_user_domain": user_trusted,
        "is_code_signing_trusted": cs_trusted,
        "is_non_code_signing_blocked": non_cs_blocked,
        "has_unscoped_trust": has_unscoped,
        "mode": mode,
        "healthy": healthy,
    }


def install_trust(app=None, cert=None, user_only=False, inspector=None):
    if sys.platform != "darwin":
        raise ValueError("trust installation requires macOS")
    der_bytes = _resolve_cert_der(app=app, cert=cert)
    meta = _parse_x509_metadata(der_bytes)
    if not meta["self_signed"]:
        raise ValueError("refusing to install trustRoot for non-self-signed certificate (Subject != Issuer)")
    if not meta["has_code_signing_eku"]:
        raise ValueError("refusing to install trust for certificate without Code Signing extended key usage")
    if user_only:
        print(
            "Warning: user-domain trust (--user) does not persist Accessibility (tccd.system) "
            "or Gatekeeper across updates; omit --user to install Admin domain (-d) trust.",
            file=sys.stderr,
        )
    with tempfile.TemporaryDirectory(prefix="omg-trust-install-") as temp:
        der_path = Path(temp) / "release-signer.der"
        fd = os.open(der_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        try:
            os.write(fd, der_bytes)
        finally:
            os.close(fd)
        # CA:FALSE self-signed root requires -r trustRoot (-r trustAsRoot fails with errSecParam -50),
        # scoped strictly to Code Signing (-p codeSign).
        if user_only:
            keychain = Path.home() / "Library/Keychains/login.keychain-db"
            cmd = ["security", "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign", "-k", str(keychain), str(der_path)]
        else:
            cmd = ["security", "add-trusted-cert", "-d", "-r", "trustRoot", "-p", "codeSign", "-k", str(ADMIN_SYSTEM_KEYCHAIN), str(der_path)]
            if os.geteuid() != 0:
                cmd = ["sudo", *cmd]
        run(*cmd, capture_output=False)
    status = trust_status(app=app, cert=cert, inspector=inspector)
    if not status["is_code_signing_trusted"] or not status["is_non_code_signing_blocked"]:
        raise ValueError("post-install verification failed: CodeSigning must pass and SSL/X509 must stay blocked")
    if not user_only and (not status["trusted_in_admin_domain"] or status["has_unscoped_trust"]):
        raise ValueError("post-install verification failed: Admin domain CodeSigning-only trust not active")
    return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("policy")
    req = commands.add_parser("requirement")
    req.add_argument("--identifier", default=RELEASE_ID)
    commands.add_parser("store-password")
    commands.add_parser("unlock")
    check = commands.add_parser("verify")
    check.add_argument("app", type=Path)
    check.add_argument("--previous", type=Path)
    create = commands.add_parser("create")
    create.add_argument("directory", type=Path)
    t_status = commands.add_parser("trust-status")
    t_status.add_argument("--app", type=Path)
    t_status.add_argument("--cert", type=Path)
    t_status.add_argument("--json", action="store_true")
    t_install = commands.add_parser("install-trust")
    t_install.add_argument("--app", type=Path)
    t_install.add_argument("--cert", type=Path)
    t_install.add_argument("--user", action="store_true")
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
        elif args.command == "trust-status":
            status = trust_status(app=args.app, cert=args.cert)
            if args.json:
                print(json.dumps(status, indent=2))
            else:
                print(f"mode={status['mode']} healthy={status['healthy']} sha1={status['certificate_sha1']} "
                      f"admin={status['trusted_in_admin_domain']} user={status['trusted_in_user_domain']} "
                      f"codesign={status['is_code_signing_trusted']} non_codesign_blocked={status['is_non_code_signing_blocked']} "
                      f"unscoped={status['has_unscoped_trust']}")
            return 0 if status["healthy"] else 1
        elif args.command == "install-trust":
            status = install_trust(app=args.app, cert=args.cert, user_only=args.user)
            print(f"Installed CodeSigning-only trust: mode={status['mode']} sha1={status['certificate_sha1']}")
        else:
            mode, identity = policy()
            print(requirement(identity, args.identifier) if args.command == "requirement" else mode)
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
