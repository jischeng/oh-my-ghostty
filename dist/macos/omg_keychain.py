"""Local macOS Keychain operations; credentials never leave this process."""

from contextlib import contextmanager
import ctypes
from pathlib import Path
import re
import sys

SERVICE = b"com.jischeng.omg.release-signing.unlock"
NOT_FOUND = -25300


class KeychainError(ValueError):
    pass


class MacKeychain:
    def __init__(self, interactive=False):
        if sys.platform != "darwin":
            raise KeychainError("automatic signing unlock requires macOS")
        self.security = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
        self.core = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        ref = ctypes.c_void_p
        u32 = ctypes.c_uint32
        signatures = {
            "SecKeychainOpen": [ctypes.c_char_p, ctypes.POINTER(ref)],
            "SecKeychainGetStatus": [ref, ctypes.POINTER(u32)],
            "SecKeychainLock": [ref],
            "SecKeychainUnlock": [ref, u32, ref, ctypes.c_ubyte],
            "SecKeychainSetUserInteractionAllowed": [ctypes.c_ubyte],
            "SecKeychainFindGenericPassword": [ref, u32, ctypes.c_char_p, u32, ctypes.c_char_p,
                                               ctypes.POINTER(u32), ctypes.POINTER(ref), ctypes.POINTER(ref)],
            "SecKeychainAddGenericPassword": [ref, u32, ctypes.c_char_p, u32, ctypes.c_char_p,
                                              u32, ref, ctypes.POINTER(ref)],
            "SecKeychainItemModifyAttributesAndData": [ref, ref, u32, ref],
            "SecKeychainItemDelete": [ref],
            "SecKeychainItemFreeContent": [ref, ref],
        }
        for name, arguments in signatures.items():
            function = getattr(self.security, name)
            function.argtypes = arguments
            function.restype = ctypes.c_int32
        self.core.CFRelease.argtypes = [ref]
        self.core.CFRelease.restype = None
        # This is process-local. Unattended release signing must not hang on GUI prompts.
        self.check(self.security.SecKeychainSetUserInteractionAllowed(interactive), "interaction policy")

    @staticmethod
    def check(status, operation):
        if status:
            raise KeychainError(f"{operation} failed (OSStatus {status}); unlock the login Keychain or run store-password interactively")

    @contextmanager
    def open(self, path):
        if not path.is_file():
            raise KeychainError("configured Keychain file does not exist")
        keychain = ctypes.c_void_p()
        self.check(self.security.SecKeychainOpen(str(path).encode(), ctypes.byref(keychain)), "Keychain open")
        try:
            yield keychain
        finally:
            self.core.CFRelease(keychain)

    def unlocked(self, keychain):
        status = ctypes.c_uint32()
        self.check(self.security.SecKeychainGetStatus(keychain, ctypes.byref(status)), "Keychain status")
        return bool(status.value & 1)

    def lock(self, keychain):
        self.check(self.security.SecKeychainLock(keychain), "signing Keychain lock")

    def unlock(self, keychain, length, pointer):
        self.check(self.security.SecKeychainUnlock(keychain, length, pointer, True), "signing Keychain unlock")

    def store(self, keychain, account, length, pointer):
        item = ctypes.c_void_p()
        status = self.security.SecKeychainFindGenericPassword(
            keychain, len(SERVICE), SERVICE, len(account), account, None, None, ctypes.byref(item))
        try:
            if status == NOT_FOUND:
                self.check(self.security.SecKeychainAddGenericPassword(
                    keychain, len(SERVICE), SERVICE, len(account), account,
                    length, pointer, ctypes.byref(item)), "credential creation")
            else:
                self.check(status, "credential lookup")
                self.check(self.security.SecKeychainItemModifyAttributesAndData(
                    item, None, length, pointer), "credential update")
        finally:
            if item.value:
                self.core.CFRelease(item)
        # Default access control trusts the creating executable, not every app.
        # Never create an allow-all (-A) access list or a synchronizable item.

    @contextmanager
    def password(self, keychain, account):
        length, pointer = ctypes.c_uint32(), ctypes.c_void_p()
        status = self.security.SecKeychainFindGenericPassword(
            keychain, len(SERVICE), SERVICE, len(account), account,
            ctypes.byref(length), ctypes.byref(pointer), None)
        try:
            if status == NOT_FOUND:
                raise KeychainError("no saved signing password; run store-password once in your terminal")
            self.check(status, "signing credential access")
            if not length.value or not pointer.value:
                raise KeychainError("saved signing password is empty")
            yield length.value, pointer
        finally:
            if pointer.value:
                ctypes.memset(pointer, 0, length.value)
                self.security.SecKeychainItemFreeContent(None, pointer)


def account_name(identity):
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", identity):
        raise KeychainError("saved signing credentials require a pinned certificate fingerprint")
    return identity.upper().encode("ascii")


def login_keychain():
    return Path.home() / "Library/Keychains/login.keychain-db"


def store_password(path, identity, password, api=None, credential_path=None):
    account = account_name(identity)
    if not password or "\0" in password or "\n" in password or "\r" in password:
        raise KeychainError("a non-empty single-line password is required")
    credential_path = login_keychain() if credential_path is None else credential_path
    if path.resolve() == credential_path.resolve():
        raise KeychainError("the signing Keychain must be separate from the login Keychain")
    api = MacKeychain(interactive=True) if api is None else api
    secret = ctypes.create_string_buffer(password.encode("utf-8"))
    length = ctypes.sizeof(secret) - 1
    try:
        with api.open(path) as signing:
            # Unlock on an already-unlocked Keychain can be a no-op. Lock our
            # private signing Keychain first so a typo cannot save a wrong password.
            api.lock(signing)
            api.unlock(signing, length, ctypes.cast(secret, ctypes.c_void_p))
        with api.open(credential_path) as credentials:
            api.store(credentials, account, length, ctypes.cast(secret, ctypes.c_void_p))
    finally:
        ctypes.memset(secret, 0, ctypes.sizeof(secret))


def unlock(path, identity, api=None, credential_path=None):
    account = account_name(identity)
    credential_path = login_keychain() if credential_path is None else credential_path
    if path.resolve() == credential_path.resolve():
        raise KeychainError("the signing Keychain must be separate from the login Keychain")
    api = MacKeychain(interactive=False) if api is None else api
    with api.open(path) as signing:
        if api.unlocked(signing):
            return "already-unlocked"
        with api.open(credential_path) as credentials:
            with api.password(credentials, account) as (length, pointer):
                api.unlock(signing, length, pointer)
        if not api.unlocked(signing):
            raise KeychainError("signing Keychain remained locked")
    return "unlocked"
