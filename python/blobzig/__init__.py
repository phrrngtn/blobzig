"""Shared ctypes plumbing for the blob* family.

Every blob* extension is the same shape — pure scalar functions over a fat C
library — so the Python side is the same three or four signatures each time:
bytes in, a malloc'd string out, plus a free. This module owns the two things
that are easy to get wrong, so eleven repos don't each get them wrong
separately.

**Artifact discovery.** `Artifacts` finds the cdylib and the two loadable
extensions in an installed wheel or an in-tree `zig-out/lib`, so tests never
hardcode a build directory.

**The c_void_p rule.** Any function returning a pointer YOU must free has to be
declared `restype = ctypes.c_void_p`, never `ctypes.c_char_p`. ctypes converts a
c_char_p result straight to `bytes` and discards the pointer, so there is
nothing left to hand to the free function and every call leaks. `returns_string`
declares it correctly; `take` decodes and frees in one step.
"""

from __future__ import annotations

import ctypes
import os
import pathlib
import sys

__all__ = ["Artifacts", "returns_string", "take", "Error"]


class Error(ValueError):
    """A failure reported by a blob* C ABI (message from its errmsg function).

    Subclasses ValueError deliberately: these failures are almost always about
    the value or the source text the caller passed, and nanobind's value_error
    surfaced as ValueError, so existing `pytest.raises(ValueError)` and caller
    code keep working across the port.
    """


def _dylib_names(stem: str) -> tuple[str, ...]:
    if sys.platform == "darwin":
        return (f"lib{stem}.dylib", f"{stem}.dylib")
    if sys.platform == "win32":
        return (f"{stem}.dll",)
    return (f"lib{stem}.so", f"{stem}.so")


class Artifacts:
    """Locate the build outputs for one blob* project.

    `package_dir` is the installed package (wheel layout); `repo_root` supplies
    the in-tree `zig-out/lib` fallback so a working copy needs no install step.
    Environment overrides are named `<PREFIX>_LIBRARY`,
    `<PREFIX>_DUCKDB_EXTENSION`, `<PREFIX>_SQLITE_EXTENSION`.
    """

    def __init__(self, name: str, package_dir: pathlib.Path, repo_root: pathlib.Path) -> None:
        self.name = name
        self.env_prefix = name.upper()
        self._dirs = (package_dir, repo_root / "zig-out" / "lib")

    def _find(self, env: str, names: tuple[str, ...]) -> str:
        override = os.environ.get(f"{self.env_prefix}_{env}")
        if override:
            return override
        for directory in self._dirs:
            for candidate in names:
                path = directory / candidate
                if path.exists():
                    return str(path)
        searched = ", ".join(str(d) for d in self._dirs)
        raise FileNotFoundError(
            f"{self.name}: none of {names} found in {searched} — "
            f"build with `zig build`, or set {self.env_prefix}_{env}"
        )

    def library(self) -> str:
        return self._find("LIBRARY", _dylib_names(self.name))

    def duckdb_extension(self) -> str:
        return self._find("DUCKDB_EXTENSION", (f"{self.name}.duckdb_extension",))

    def sqlite_extension(self) -> str:
        # Not the same file as library(): the SQLite extension is a separate
        # artifact embedding the core plus a sqlite3_<name>_init entrypoint.
        suffixes = (".dylib", ".so") if sys.platform == "darwin" else (".so",)
        return self._find("SQLITE_EXTENSION", tuple(f"{self.name}{s}" for s in suffixes))

    def load(self) -> ctypes.CDLL:
        return ctypes.CDLL(self.library())


def returns_string(fn, argtypes: list) -> None:
    """Declare a function returning a malloc'd string the caller must free.

    Uses c_void_p rather than c_char_p on purpose — see the module docstring.
    """
    fn.argtypes = argtypes
    fn.restype = ctypes.c_void_p


def take(lib: ctypes.CDLL, ptr: int | None, errmsg: str = "errmsg", free: str = "free") -> str:
    """Decode a malloc'd result and free it; raise `Error` if the call failed.

    `errmsg` and `free` are the unprefixed names of the project's error and free
    functions, resolved as `<name>_errmsg` / `<name>_free` by the caller passing
    already-prefixed names.
    """
    if not ptr:
        msg = getattr(lib, errmsg)()
        raise Error(msg.decode("utf-8", "replace") if msg else "unknown error")
    try:
        return ctypes.cast(ptr, ctypes.c_char_p).value.decode("utf-8")
    finally:
        getattr(lib, free)(ptr)
