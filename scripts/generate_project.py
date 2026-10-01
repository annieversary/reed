#!/usr/bin/env python3
"""Regenerate the small Xcode project after adding source files."""
from pathlib import Path
import hashlib
import plistlib

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "Reed.xcodeproj"

def identifier(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

def ref(name):
    return identifier(name)

objects = {}

def put(key, **values):
    objects[ref(key)] = values
    return ref(key)

SHARE = ROOT / "Sources/ReedShare"
# The share extension only needs the inbox it writes to, not the rest of ReedCore.
share_sources = sorted(SHARE.glob("*.swift")) + [ROOT / "Sources/ReedCore/ShareInbox.swift"]
sources = sorted(path for path in ROOT.glob("Sources/**/*.swift") if SHARE not in path.parents)
resources = sorted((ROOT / "Sources/ReedCore/Resources").iterdir()) + [ROOT / "Sources/Reed/Assets.xcassets"]
children, source_builds, resource_builds, share_builds = [], [], [], []
for path in sorted(set(sources + resources + share_sources)):
    relative = path.relative_to(ROOT).as_posix()
    file_ref = put(relative, isa="PBXFileReference", path=relative, sourceTree="SOURCE_ROOT",
                   lastKnownFileType={".swift": "sourcecode.swift", ".xcassets": "folder.assetcatalog"}.get(path.suffix, "text"))
    children.append(file_ref)
    if path in sources or path in resources:
        build = put("build:" + relative, isa="PBXBuildFile", fileRef=file_ref)
        (source_builds if path in sources else resource_builds).append(build)
    if path in share_sources:
        share_builds.append(put("share-build:" + relative, isa="PBXBuildFile", fileRef=file_ref))

def phase(key, isa, files):
    return put(key, isa=isa, buildActionMask=2147483647, files=files, runOnlyForDeploymentPostprocessing=0)

product = put("product", isa="PBXFileReference", explicitFileType="wrapper.application", path="Reed.app", sourceTree="BUILT_PRODUCTS_DIR")
share_product = put("share-product", isa="PBXFileReference", explicitFileType="wrapper.app-extension", path="ReedShare.appex", sourceTree="BUILT_PRODUCTS_DIR")
products = put("products", isa="PBXGroup", children=[product, share_product], name="Products", sourceTree="<group>")
main = put("main", isa="PBXGroup", children=children + [products], sourceTree="<group>")
# FluidAudio runs Kokoro for narration. Keep the version in step with Package.swift.
fluid_package = put("package:FluidAudio", isa="XCRemoteSwiftPackageReference",
                    repositoryURL="https://github.com/FluidInference/FluidAudio.git",
                    requirement={"kind": "exactVersion", "version": "0.17.5"})
fluid_product = put("product:FluidAudio", isa="XCSwiftPackageProductDependency", package=fluid_package, productName="FluidAudio")
fluid_build = put("build:FluidAudio", isa="PBXBuildFile", productRef=fluid_product)

source_phase = phase("sources", "PBXSourcesBuildPhase", source_builds)
resource_phase = phase("resources", "PBXResourcesBuildPhase", resource_builds)
framework_phase = phase("frameworks", "PBXFrameworksBuildPhase", [fluid_build])
embed_build = put("build:ReedShare.appex", isa="PBXBuildFile", fileRef=share_product, settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
embed_phase = put("embed", isa="PBXCopyFilesBuildPhase", buildActionMask=2147483647, dstPath="", dstSubfolderSpec=13,
                  files=[embed_build], name="Embed Foundation Extensions", runOnlyForDeploymentPostprocessing=0)
share_phases = [phase("share-sources", "PBXSourcesBuildPhase", share_builds),
                phase("share-frameworks", "PBXFrameworksBuildPhase", []),
                phase("share-resources", "PBXResourcesBuildPhase", [])]

# Both targets sign with the team on every platform: App Groups need it, and on macOS the
# team-prefixed group needs no provisioning profile, so Mac builds stay offline.
signing = {
    "CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": "KR4TU3GTWZ",
    "CODE_SIGN_STYLE[sdk=macosx*]": "Manual", "CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development",
}

project_configs, target_configs, share_configs = [], [], []
for mode in ["Debug", "Release"]:
    project_settings = {
        "CLANG_ENABLE_MODULES": "YES", "SWIFT_VERSION": "6.0",
        "MACOSX_DEPLOYMENT_TARGET": "15.0", "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "SDKROOT": "auto", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG" if mode == "Debug" else "",
        "ENABLE_TESTABILITY": "YES" if mode == "Debug" else "NO",
        "ONLY_ACTIVE_ARCH": "YES" if mode == "Debug" else "NO",
        "DEBUG_INFORMATION_FORMAT": "dwarf" if mode == "Debug" else "dwarf-with-dsym",
    }
    target_settings = {
        "PRODUCT_NAME": "Reed", "PRODUCT_BUNDLE_IDENTIFIER": "town.versary.reed",
        "INFOPLIST_FILE": "Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE[sdk=macosx*]": "Info-macOS.plist",
        "CODE_SIGN_ENTITLEMENTS": "Reed-iOS.entitlements", "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]": "Reed-macOS.entitlements",
        **signing,
        "TARGETED_DEVICE_FAMILY": "1,2", "CURRENT_PROJECT_VERSION": "1",
        "MARKETING_VERSION": "0.1.0", "ENABLE_APP_SANDBOX": "NO",
        "COMBINE_HIDPI_IMAGES": "YES", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks @executable_path/Frameworks",
    }
    share_settings = {
        "PRODUCT_NAME": "ReedShare", "PRODUCT_BUNDLE_IDENTIFIER": "town.versary.reed.share",
        "INFOPLIST_FILE": "Sources/ReedShare/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
        "CODE_SIGN_ENTITLEMENTS": "Reed-iOS.entitlements",
        "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]": "Sources/ReedShare/ReedShare-macOS.entitlements",
        **signing,
        "TARGETED_DEVICE_FAMILY": "1,2", "CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "0.1.0",
        "APPLICATION_EXTENSION_API_ONLY": "YES", "SKIP_INSTALL": "YES",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks @executable_path/../../Frameworks",
        "LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]": "$(inherited) @executable_path/../Frameworks @executable_path/../../../../Frameworks",
    }
    project_configs.append(put("project:" + mode, isa="XCBuildConfiguration", name=mode, buildSettings=project_settings))
    target_configs.append(put("target:" + mode, isa="XCBuildConfiguration", name=mode, buildSettings=target_settings))
    share_configs.append(put("share:" + mode, isa="XCBuildConfiguration", name=mode, buildSettings=share_settings))

def config_list(key, configs):
    return put(key, isa="XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

project_list = config_list("projectConfigs", project_configs)
share_target = put("share-target", isa="PBXNativeTarget", name="ReedShare", productName="ReedShare", productReference=share_product,
                   productType="com.apple.product-type.app-extension", buildConfigurationList=config_list("shareConfigs", share_configs),
                   buildPhases=share_phases, buildRules=[], dependencies=[])
share_proxy = put("share-proxy", isa="PBXContainerItemProxy", containerPortal=ref("project"), proxyType="1",
                  remoteGlobalIDString=share_target, remoteInfo="ReedShare")
share_dependency = put("share-dependency", isa="PBXTargetDependency", target=share_target, targetProxy=share_proxy)
target = put("target", isa="PBXNativeTarget", name="Reed", productName="Reed", productReference=product,
             productType="com.apple.product-type.application", buildConfigurationList=config_list("targetConfigs", target_configs),
             buildPhases=[source_phase, framework_phase, resource_phase, embed_phase], buildRules=[], dependencies=[share_dependency],
             packageProductDependencies=[fluid_product])
project = put("project", isa="PBXProject", attributes={"LastUpgradeCheck": "2700", "BuildIndependentTargetsInParallel": "YES"},
              buildConfigurationList=project_list, compatibilityVersion="Xcode 14.0", developmentRegion="en",
              hasScannedForEncodings=0, knownRegions=["en", "Base"], mainGroup=main, productRefGroup=products,
              packageReferences=[fluid_package],
              projectDirPath="", projectRoot="", targets=[target, share_target])
PROJECT.mkdir(exist_ok=True)
(PROJECT / "project.pbxproj").write_bytes(plistlib.dumps({"archiveVersion": "1", "classes": {}, "objectVersion": "56", "objects": objects, "rootObject": project}, sort_keys=False))

scheme_dir = PROJECT / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
(scheme_dir / "Reed.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Reed.app" BlueprintName="Reed" ReferencedContainer="container:Reed.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Reed.app" BlueprintName="Reed" ReferencedContainer="container:Reed.xcodeproj"/></BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Reed.app" BlueprintName="Reed" ReferencedContainer="container:Reed.xcodeproj"/></BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print("Generated Reed.xcodeproj")

mac_info = plistlib.loads((ROOT / "Info.plist").read_bytes())
for key in ["UIApplicationSceneManifest", "UILaunchScreen", "UISupportedInterfaceOrientations", "UIBackgroundModes"]:
    mac_info.pop(key, None)
mac_info["NSPrincipalClass"] = "NSApplication"
(ROOT / "Info-macOS.plist").write_bytes(plistlib.dumps(mac_info, sort_keys=False))
