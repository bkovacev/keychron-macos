#!/usr/bin/env python3
"""Generate K10ProControls.xcodeproj.

Xcode is needed rather than a hand-assembled bundle: a Control Center control
lives in a WidgetKit app extension, and `pluginkit` would not register an
extension we built and signed by hand - most likely for want of the
provisioning Xcode attaches. Building through Xcode once is what makes the
control appear.

The project has two targets:

  K10ProBattery   the agent, from ../Sources/K10ProBattery
  K10ProControls  the Control Center extension, embedded in the agent

project.pbxproj is written as an XML property list. It is the same object graph
as the usual OpenStep format and Xcode reads it happily, rewriting it in its
own style on first save - which keeps this generator legible.
"""

import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE / "K10ProControls.xcodeproj"
AGENT_SOURCES = sorted((HERE.parent / "Sources" / "K10ProBattery").glob("*.swift"))
CONTROL_SOURCES = sorted((HERE / "Sources").glob("*.swift"))

def signing_identity() -> tuple[str, str] | None:
    """First Apple Development identity and its team, or None.

    Worth the trouble because of TCC: an ad-hoc signature gets a fresh code
    hash on every build, so macOS cannot match the rebuilt app to the Input
    Monitoring grant and silently drops it. Without that permission the agent
    can neither read the wireless beacon nor drive the keyboard's LEDs, so a
    rebuild would quietly break both until the user re-granted by hand.
    A real certificate keeps the identity stable across builds.

    Set K10PRO_TEAM_ID to choose a specific team; set it empty to force ad-hoc.
    """
    override = os.environ.get("K10PRO_TEAM_ID")
    if override == "":
        return None

    out = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        match = re.search(r'"(Apple Development: .*)"', line)
        if not match:
            continue
        name = match.group(1)
        cert = subprocess.run(["security", "find-certificate", "-c", name, "-p"],
                              capture_output=True, text=True).stdout
        subject = subprocess.run(["openssl", "x509", "-noout", "-subject"],
                                 input=cert, capture_output=True, text=True).stdout
        team = re.search(r"OU\s*=\s*([A-Z0-9]+)", subject)
        if team and (override is None or team.group(1) == override):
            return name, team.group(1)
    return None


APP_ID = "io.smartowl.k10pro-battery"
EXT_ID = f"{APP_ID}.controls"
DEPLOYMENT = "26.0"

_counter = 0


def uid(tag: str = "") -> str:
    """Xcode object IDs: 24 uppercase hex characters."""
    global _counter
    _counter += 1
    return f"{_counter:024X}"


objects: dict[str, dict] = {}


def add(obj: dict) -> str:
    key = uid()
    objects[key] = obj
    return key


def file_ref(path: Path, *, tree="SOURCE_ROOT") -> str:
    try:
        rel = path.relative_to(HERE)
    except ValueError:
        rel = Path("..") / path.relative_to(HERE.parent)
    return add({
        "isa": "PBXFileReference",
        "lastKnownFileType": "sourcecode.swift",
        "name": path.name,
        "path": str(rel),
        "sourceTree": tree,
    })


def build_file(ref: str) -> str:
    return add({"isa": "PBXBuildFile", "fileRef": ref})


def config_list(configs: dict[str, dict], default="Release") -> str:
    keys = []
    for name, settings in configs.items():
        keys.append(add({
            "isa": "XCBuildConfiguration",
            "name": name,
            "buildSettings": settings,
        }))
    return add({
        "isa": "XCConfigurationList",
        "buildConfigurations": keys,
        "defaultConfigurationIsVisible": "0",
        "defaultConfigurationName": default,
    })


# ---------------------------------------------------------------- settings

COMMON = {
    "SDKROOT": "macosx",
    "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT,
    "SWIFT_VERSION": "5.0",
    "CLANG_ENABLE_MODULES": "YES",
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "ENABLE_HARDENED_RUNTIME": "YES",
    "CODE_SIGN_STYLE": "Automatic",
}

IDENTITY = signing_identity()
if IDENTITY:
    COMMON |= {"CODE_SIGN_IDENTITY": "Apple Development", "DEVELOPMENT_TEAM": IDENTITY[1]}

APP_SETTINGS = COMMON | {
    "PRODUCT_NAME": "K10ProBattery",
    "PRODUCT_BUNDLE_IDENTIFIER": APP_ID,
    "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_KEY_LSUIElement": "YES",
    "INFOPLIST_KEY_CFBundleDisplayName": "K10 Pro Battery",
    "MARKETING_VERSION": "1.0",
    "CURRENT_PROJECT_VERSION": "1",
    # The agent talks to HID directly, so it must not be sandboxed.
    "ENABLE_APP_SANDBOX": "NO",
    "SWIFT_OBJC_BRIDGING_HEADER": "",
}

EXT_SETTINGS = COMMON | {
    "PRODUCT_NAME": "K10ProControls",
    "PRODUCT_BUNDLE_IDENTIFIER": EXT_ID,
    # A real Info.plist. NSExtensionPointIdentifier lives inside an NSExtension
    # dict, and INFOPLIST_KEY_* cannot express nested keys - it is silently
    # dropped, producing a bundle that installs but never registers.
    "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_FILE": "Controls-Info.plist",
    "INFOPLIST_KEY_CFBundleDisplayName": "K10 Pro Controls",
    "MARKETING_VERSION": "1.0",
    "CURRENT_PROJECT_VERSION": "1",
    "SKIP_INSTALL": "YES",
    # Extensions are sandboxed; this one only posts a Darwin notification,
    # which the sandbox permits, so it needs nothing else.
    "ENABLE_APP_SANDBOX": "YES",
}

# ---------------------------------------------------------------- products

app_product = add({
    "isa": "PBXFileReference",
    "explicitFileType": "wrapper.application",
    "includeInIndex": "0",
    "path": "K10ProBattery.app",
    "sourceTree": "BUILT_PRODUCTS_DIR",
})
ext_product = add({
    "isa": "PBXFileReference",
    "explicitFileType": "wrapper.app-extension",
    "includeInIndex": "0",
    "path": "K10ProControls.appex",
    "sourceTree": "BUILT_PRODUCTS_DIR",
})

# ---------------------------------------------------------------- groups

agent_refs = [file_ref(p) for p in AGENT_SOURCES]
control_refs = [file_ref(p) for p in CONTROL_SOURCES]

agent_group = add({"isa": "PBXGroup", "name": "Agent",
                   "children": agent_refs, "sourceTree": "<group>"})
control_group = add({"isa": "PBXGroup", "name": "Controls",
                     "children": control_refs, "sourceTree": "<group>"})
products_group = add({"isa": "PBXGroup", "name": "Products",
                      "children": [app_product, ext_product], "sourceTree": "<group>"})
root_group = add({"isa": "PBXGroup",
                  "children": [agent_group, control_group, products_group],
                  "sourceTree": "<group>"})

# ---------------------------------------------------------------- phases

app_sources = add({"isa": "PBXSourcesBuildPhase", "buildActionMask": "2147483647",
                   "files": [build_file(r) for r in agent_refs],
                   "runOnlyForDeploymentPostprocessing": "0"})
ext_sources = add({"isa": "PBXSourcesBuildPhase", "buildActionMask": "2147483647",
                   "files": [build_file(r) for r in control_refs],
                   "runOnlyForDeploymentPostprocessing": "0"})

# Embed the extension in the app's PlugIns directory (destination 13).
embed_ref = add({"isa": "PBXBuildFile", "fileRef": ext_product,
                 "settings": {"ATTRIBUTES": ["RemoveHeadersOnCopy"]}})
embed_phase = add({"isa": "PBXCopyFilesBuildPhase", "buildActionMask": "2147483647",
                   "dstPath": "", "dstSubfolderSpec": "13",
                   "files": [embed_ref], "name": "Embed Foundation Extensions",
                   "runOnlyForDeploymentPostprocessing": "0"})

# ---------------------------------------------------------------- targets

ext_target = add({
    "isa": "PBXNativeTarget",
    "name": "K10ProControls",
    "productName": "K10ProControls",
    "productReference": ext_product,
    "productType": "com.apple.product-type.app-extension",
    "buildConfigurationList": config_list({"Debug": EXT_SETTINGS, "Release": EXT_SETTINGS}),
    "buildPhases": [ext_sources],
    "buildRules": [],
    "dependencies": [],
})

project_key = uid()

proxy = add({
    "isa": "PBXContainerItemProxy",
    "containerPortal": project_key,
    "proxyType": "1",
    "remoteGlobalIDString": ext_target,
    "remoteInfo": "K10ProControls",
})
dependency = add({"isa": "PBXTargetDependency", "target": ext_target,
                  "targetProxy": proxy})

app_target = add({
    "isa": "PBXNativeTarget",
    "name": "K10ProBattery",
    "productName": "K10ProBattery",
    "productReference": app_product,
    "productType": "com.apple.product-type.application",
    "buildConfigurationList": config_list({"Debug": APP_SETTINGS, "Release": APP_SETTINGS}),
    "buildPhases": [app_sources, embed_phase],
    "buildRules": [],
    "dependencies": [dependency],
})

objects[project_key] = {
    "isa": "PBXProject",
    "attributes": {"LastUpgradeCheck": "2600", "BuildIndependentTargetsInParallel": "1"},
    "buildConfigurationList": config_list({
        "Debug": {"SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT,
                  "ONLY_ACTIVE_ARCH": "YES", "SWIFT_OPTIMIZATION_LEVEL": "-Onone"},
        "Release": {"SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT,
                    "SWIFT_OPTIMIZATION_LEVEL": "-O"},
    }),
    "compatibilityVersion": "Xcode 14.0",
    "developmentRegion": "en",
    "hasScannedForEncodings": "0",
    "knownRegions": ["en", "Base"],
    "mainGroup": root_group,
    "productRefGroup": products_group,
    "projectDirPath": "",
    "projectRoot": "",
    "targets": [app_target, ext_target],
}

pbxproj = {
    "archiveVersion": "1",
    "classes": {},
    "objectVersion": "56",
    "objects": objects,
    "rootObject": project_key,
}

PROJECT.mkdir(parents=True, exist_ok=True)
out = PROJECT / "project.pbxproj"
out.write_bytes(plistlib.dumps(pbxproj, fmt=plistlib.FMT_XML))
print(f"wrote {out.relative_to(HERE.parent.parent)}")
if IDENTITY:
    print(f"  signing as:      {IDENTITY[0]} (team {IDENTITY[1]})")
else:
    print("  signing:         ad-hoc - macOS will drop the Input Monitoring")
    print("                   grant on every rebuild; see signing_identity()")
print(f"  agent sources:   {len(AGENT_SOURCES)}")
print(f"  control sources: {len(CONTROL_SOURCES)}")

# Prove Xcode can read it.
r = subprocess.run(["xcodebuild", "-list", "-project", str(PROJECT)],
                   capture_output=True, text=True)
print(r.stdout.strip() or r.stderr.strip()[:400])
sys.exit(r.returncode)
