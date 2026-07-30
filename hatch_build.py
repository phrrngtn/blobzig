"""Tag the wheel for the platform its bundled binaries were built for.

A wheel is a zip plus metadata: the platform tag is a string, not something
derived from the binaries. So the wheel for any target can be produced on any
host — the usual reason to build wheels on the target platform is that the
*compiler* has to run there, and `zig build -Dtarget=...` removes that reason.

    zig build -Dtarget=x86_64-linux-gnu.2.17
    BLOBJS_WHEEL_PLATFORM=manylinux_2_17_x86_64 uv build --wheel

With no override the tag is inferred from the host, which is correct for the
ordinary native build.

The tag is `py3-none-<platform>`: platform-specific because it carries a native
library, but ABI-agnostic because ctypes binds at runtime rather than against
the CPython C API. That is the concrete win over the nanobind build, which
needed a separate wheel per interpreter version.
"""

from __future__ import annotations

import os
import sysconfig

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


def _host_platform_tag() -> str:
    return sysconfig.get_platform().replace("-", "_").replace(".", "_")


class CustomBuildHook(BuildHookInterface):
    def initialize(self, version: str, build_data: dict) -> None:
        platform = os.environ.get("BLOBJS_WHEEL_PLATFORM") or _host_platform_tag()
        build_data["pure_python"] = False
        build_data["infer_tag"] = False
        build_data["tag"] = f"py3-none-{platform}"
