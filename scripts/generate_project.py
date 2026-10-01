#!/usr/bin/env python3
"""Regenerate the small, dependency-free Xcode project after adding source files."""
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

sources = sorted(ROOT.glob("Sources/**/*.swift"))
resources = sorted((ROOT / "Sources/ReedCore/Resources").iterdir())
children, source_builds, resource_builds = [], [], []
for path in sources + resources:
    relative = path.relative_to(ROOT).as_posix()
    file_ref = put(relative, isa="PBXFileReference", path=relative, sourceTree="SOURCE_ROOT",
                   lastKnownFileType="sourcecode.swift" if path.suffix == ".swift" else "text")
    children.append(file_ref)
    build = put("build:" + relative, isa="PBXBuildFile", fileRef=file_ref)
    (source_builds if path in sources else resource_builds).append(build)

product = put("product", isa="PBXFileReference", explicitFileType="wrapper.application", path="Reed.app", sourceTree="BUILT_PRODUCTS_DIR")
products = put("products", isa="PBXGroup", children=[product], name="Products", sourceTree="<group>")
main = put("main", isa="PBXGroup", children=children + [products], sourceTree="<group>")
source_phase = put("sources", isa="PBXSourcesBuildPhase", buildActionMask=2147483647, files=source_builds, runOnlyForDeploymentPostprocessing=0)
resource_phase = put("resources", isa="PBXResourcesBuildPhase", buildActionMask=2147483647, files=resource_builds, runOnlyForDeploymentPostprocessing=0)
framework_phase = put("frameworks", isa="PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)

project_configs, target_configs = [], []
for mode in ["Debug", "Release"]:
    project_settings = {
        "CLANG_ENABLE_MODULES": "YES", "SWIFT_VERSION": "6.0",
        "MACOSX_DEPLOYMENT_TARGET": "15.0", "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "SDKROOT": "auto", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG" if mode == "Debug" else "",
        "ENABLE_TESTABILITY": "YES" if mode == "Debug" else "NO",
        "DEBUG_INFORMATION_FORMAT": "dwarf" if mode == "Debug" else "dwarf-with-dsym",
    }
    target_settings = {
        "PRODUCT_NAME": "Reed", "PRODUCT_BUNDLE_IDENTIFIER": "town.versary.reed",
        "INFOPLIST_FILE": "Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE[sdk=macosx*]": "Info-macOS.plist",
        "CODE_SIGN_STYLE": "Automatic", "CODE_SIGN_IDENTITY[sdk=macosx*]": "-",
        "DEVELOPMENT_TEAM[sdk=iphoneos*]": "KR4TU3GTWZ",
        "TARGETED_DEVICE_FAMILY": "1,2", "CURRENT_PROJECT_VERSION": "1",
        "MARKETING_VERSION": "0.1.0", "ENABLE_APP_SANDBOX": "NO",
        "COMBINE_HIDPI_IMAGES": "YES", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks @executable_path/Frameworks",
    }
    project_configs.append(put("project:" + mode, isa="XCBuildConfiguration", name=mode, buildSettings=project_settings))
    target_configs.append(put("target:" + mode, isa="XCBuildConfiguration", name=mode, buildSettings=target_settings))
project_list = put("projectConfigs", isa="XCConfigurationList", buildConfigurations=project_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
target_list = put("targetConfigs", isa="XCConfigurationList", buildConfigurations=target_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
target = put("target", isa="PBXNativeTarget", name="Reed", productName="Reed", productReference=product,
             productType="com.apple.product-type.application", buildConfigurationList=target_list,
             buildPhases=[source_phase, framework_phase, resource_phase], buildRules=[], dependencies=[])
project = put("project", isa="PBXProject", attributes={"LastUpgradeCheck": "2700", "BuildIndependentTargetsInParallel": "YES"},
              buildConfigurationList=project_list, compatibilityVersion="Xcode 14.0", developmentRegion="en",
              hasScannedForEncodings=0, knownRegions=["en", "Base"], mainGroup=main, productRefGroup=products,
              projectDirPath="", projectRoot="", targets=[target])
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
for key in ["UIApplicationSceneManifest", "UILaunchScreen", "UISupportedInterfaceOrientations"]:
    mac_info.pop(key, None)
mac_info["NSPrincipalClass"] = "NSApplication"
(ROOT / "Info-macOS.plist").write_bytes(plistlib.dumps(mac_info, sort_keys=False))
