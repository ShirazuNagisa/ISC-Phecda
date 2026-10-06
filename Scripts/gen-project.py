#!/usr/bin/env python3
"""生成 Phecda.xcodeproj。

# 为什么是"生成"而不是"手写"

工程文件是 Xcode 的私有格式：几千行、UUID 互相引用、冲突时几乎没法手工合。
本仓库没有 XcodeGen（也不想为它引入 Homebrew），因此把生成过程本身留在
脚本里 —— 它是可读的、可重跑的，而 pbxproj 只是它的产物。

重跑：python3 Scripts/gen-project.py
"""
import hashlib
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "Apps" / "Phecda"

def uid(*parts: str) -> str:
    """确定性的 24 位十六进制 UUID。

    确定性很重要：每跑一次都换一批 UUID 的话，git diff 里整个文件都会翻新，
    而"这次改了什么"就看不出来了。
    """
    return hashlib.sha1("|".join(parts).encode()).hexdigest()[:24].upper()

def main() -> int:
    swift_files = sorted(p.name for p in APP.glob("*.swift"))
    if not swift_files:
        print(f"❌ 在 {APP} 下没找到任何 .swift", file=sys.stderr)
        return 1

    prod = uid("product", "Phecda")
    tgt = uid("target", "Phecda")
    prj = uid("project")
    main_group = uid("group", "main")
    app_group = uid("group", "Apps/Phecda")
    products_group = uid("group", "Products")
    src_phase = uid("phase", "sources")
    embed_phase = uid("phase", "embed")
    runtimes_phase = uid("phase", "runtimes")
    dylib_fr = uid("fileref", "libisc")
    dylib_bf = uid("buildfile", "libisc")
    res_phase = uid("phase", "resources")
    fwk_phase = uid("phase", "frameworks")
    cfg_list_prj = uid("cfglist", "project")
    cfg_list_tgt = uid("cfglist", "target")

    file_refs, build_files = [], []
    for name in swift_files:
        fr, bf = uid("fileref", name), uid("buildfile", name)
        file_refs.append(
            f'\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = '
            f'sourcecode.swift; path = {name}; sourceTree = "<group>"; }};')
        build_files.append(
            f'\t\t{bf} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};')

    assets_fr, assets_bf = uid("fileref", "Assets"), uid("buildfile", "Assets")
    privacy_fr, privacy_bf = uid("fileref", "PrivacyInfo"), uid("buildfile", "PrivacyInfo")
    plist_fr = uid("fileref", "Info.plist")
    entitlements_fr = uid("fileref", "Phecda.entitlements")
    pkg_fr = uid("fileref", "Package.swift")
    pkg_dep = uid("pkgdep", "ISCCore")
    pkg_ref = uid("pkgref", "local")
    pkg_bf = uid("buildfile", "ISCCore")

    swift_names = "\n".join(f'\t\t\t\t{uid("buildfile", n)} /* {n} in Sources */,' for n in swift_files)
    fileref_lines = "\n".join(file_refs)
    buildfile_lines = "\n".join(build_files)
    group_children = "\n".join(f'\t\t\t\t{uid("fileref", n)} /* {n} */,' for n in swift_files)

    pbx = f'''// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 60;
	objects = {{

/* Begin PBXBuildFile section */
{buildfile_lines}
\t\t{assets_bf} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {assets_fr} /* Assets.xcassets */; }};
\t\t{privacy_bf} /* PrivacyInfo.xcprivacy in Resources */ = {{isa = PBXBuildFile; fileRef = {privacy_fr} /* PrivacyInfo.xcprivacy */; }};
\t\t{pkg_bf} /* ISCCore in Frameworks */ = {{isa = PBXBuildFile; productRef = {pkg_dep} /* ISCCore */; }};
\t\t{dylib_bf} /* libisc.dylib in Embed Libraries */ = {{isa = PBXBuildFile; fileRef = {dylib_fr} /* libisc.dylib */; settings = {{ATTRIBUTES = (CodeSignOnCopy, ); }}; }};
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
\t\t{prod} /* ISC Phecda.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "ISC Phecda.app"; sourceTree = BUILT_PRODUCTS_DIR; }};
{fileref_lines}
\t\t{assets_fr} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};
\t\t{privacy_fr} /* PrivacyInfo.xcprivacy */ = {{isa = PBXFileReference; lastKnownFileType = text.xml; name = PrivacyInfo.xcprivacy; path = Resources/PrivacyInfo.xcprivacy; sourceTree = "<group>"; }};
\t\t{plist_fr} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; name = Info.plist; path = Resources/Info.plist; sourceTree = "<group>"; }};
\t\t{entitlements_fr} /* Phecda.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Phecda.entitlements; sourceTree = "<group>"; }};
\t\t{pkg_fr} /* Package.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Package.swift; sourceTree = "<group>"; }};
\t\t{dylib_fr} /* libisc.dylib */ = {{isa = PBXFileReference; lastKnownFileType = "compiled.mach-o.dylib"; name = libisc.dylib; path = Vendor/ISC/libisc.dylib; sourceTree = "<group>"; }};
/* End PBXFileReference section */

/* Begin PBXShellScriptBuildPhase section */
\t\t{runtimes_phase} /* Bundle Runtimes */ = {{
\t\t\tisa = PBXShellScriptBuildPhase;
\t\t\talwaysOutOfDate = 1;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\tinputFileListPaths = (
\t\t\t);
\t\t\tinputPaths = (
\t\t\t);
\t\t\tname = "Bundle Runtimes";
\t\t\toutputFileListPaths = (
\t\t\t);
\t\t\toutputPaths = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t\tshellPath = /bin/sh;
\t\t\tshellScript = "\\"$SRCROOT/Scripts/xcode-bundle-runtimes.sh\\"\\n";
\t\t}};
/* End PBXShellScriptBuildPhase section */

/* Begin PBXCopyFilesBuildPhase section */
\t\t{embed_phase} /* Embed Libraries */ = {{
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "";
\t\t\tdstSubfolderSpec = 10;
\t\t\tfiles = (
\t\t\t\t{dylib_bf} /* libisc.dylib in Embed Libraries */,
\t\t\t);
\t\t\t// 内核库必须进 Contents/Frameworks 并**用与应用相同的身份签名**。
\t\t\t//
\t\t\t// 放在仓库里靠绝对 rpath 引用那条路在签名分发下走不通：库验证会
\t\t\t// 拒绝 Team ID 不同的 dylib（"mapping process and mapped file
\t\t\t// (non-platform) have different Team IDs"）。ad-hoc 签名没有 Team ID，
\t\t\t// 所以反而能加载 —— 这也是它一直看起来正常的原因。
\t\t\t//
\t\t\t// CodeSignOnCopy 让 Xcode 用当前签名身份重签它。
\t\t\tname = "Embed Libraries";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXCopyFilesBuildPhase section */

/* Begin PBXFrameworksBuildPhase section */
\t\t{fwk_phase} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{pkg_bf} /* ISCCore in Frameworks */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
\t\t{main_group} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{pkg_fr} /* Package.swift */,
\t\t\t\t{privacy_fr} /* PrivacyInfo.xcprivacy */,
\t\t\t\t{app_group} /* Phecda */,
\t\t\t\t{dylib_fr} /* libisc.dylib */,
\t\t\t\t{plist_fr} /* Info.plist */,
\t\t\t\t{entitlements_fr} /* Phecda.entitlements */,
\t\t\t\t{products_group} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{app_group} /* Phecda */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{group_children}
\t\t\t\t{assets_fr} /* Assets.xcassets */,
\t\t\t);
\t\t\tpath = Apps/Phecda;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{products_group} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{prod} /* ISC Phecda.app */,
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t{tgt} /* Phecda */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {cfg_list_tgt} /* Build configuration list for PBXNativeTarget "Phecda" */;
\t\t\tbuildPhases = (
\t\t\t\t{src_phase} /* Sources */,
\t\t\t\t{fwk_phase} /* Frameworks */,
\t\t\t\t{res_phase} /* Resources */,
\t\t\t\t{runtimes_phase} /* Bundle Runtimes */,
\t\t\t\t{embed_phase} /* Embed Libraries */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = Phecda;
\t\t\tpackageProductDependencies = (
\t\t\t\t{pkg_dep} /* ISCCore */,
\t\t\t);
\t\t\tproductName = Phecda;
\t\t\tproductReference = {prod} /* ISC Phecda.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{prj} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 2700;
\t\t\t\tLastUpgradeCheck = 2700;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{tgt} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 27.0;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {cfg_list_prj} /* Build configuration list for PBXProject "Phecda" */;
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\t"zh-Hans",
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {main_group};
\t\t\tpackageReferences = (
\t\t\t\t{pkg_ref} /* XCLocalSwiftPackageReference "." */,
\t\t\t);
\t\t\tproductRefGroup = {products_group} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{tgt} /* Phecda */,
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXShellScriptBuildPhase section */
/* Begin PBXResourcesBuildPhase section */
\t\t{res_phase} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{assets_bf} /* Assets.xcassets in Resources */,
\t\t\t\t{privacy_bf} /* PrivacyInfo.xcprivacy in Resources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
\t\t{src_phase} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{swift_names}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
\t\t{uid("cfg", "prj", "debug")} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ENABLE_OBJC_WEAK = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tENABLE_TESTABILITY = YES;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (
\t\t\t\t\t"DEBUG=1",
\t\t\t\t\t"$(inherited)",
\t\t\t\t);
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 27.0;
\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
\t\t\t\tSWIFT_VERSION = 6.0;
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{uid("cfg", "prj", "release")} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ENABLE_OBJC_WEAK = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tENABLE_NS_ASSERTIONS = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 27.0;
\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
\t\t\t\tSWIFT_VERSION = 6.0;
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t{uid("cfg", "tgt", "debug")} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = Phecda.entitlements;
\t\t\t\t// Debug 用 ad-hoc：本机不一定有该团队的开发证书，而日常构建
\t\t\t\t// 不该因为签名缺失而跑不起来。代价是**沙箱不生效**（ad-hoc 没有
\t\t\t\t// Team ID），所以本机测不到沙箱行为 —— 这一条写在
\t\t\t\t// Documentation/APPSTORE.md 里。
\t\t\t\tCODE_SIGN_IDENTITY = "-";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\t// 显式写团队，不让 Xcode 猜。
\t\t\t\t//
\t\t\t\t// 这台机器上有**两个** Team ID：9LS4DPCN7H（一张 Apple Development
\t\t\t\t// 证书，免费个人团队）与 5Q2A46685M（付费团队，能上架）。不写死的话
\t\t\t\t// Xcode 可能挑中前者，于是归档时签得上、上传时才发现这个团队没有
\t\t\t\t// 分发权限 —— 而报错在很久之后，与"挑错了团队"看不出关系。
\t\t\t\t//
\t\t\t\t// 团队 ID 不是秘密（每个签名过的应用里都有），写在这里是为了可复现。
\t\t\t\tDEVELOPMENT_TEAM = 5Q2A46685M;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\t// Xcode 16+ 在 Debug 下默认把代码放进 `ISC Phecda.debug.dylib`，
\t\t\t\t// 主二进制只剩一个 39 KB 的启动器。那个布局在 ad-hoc 签名时会
\t\t\t\t// 失败（"code object is not signed at all"），而它唯一的用途是
\t\t\t\t// SwiftUI 预览 —— 为一个预览保留一种会挡住构建的产物布局不值得。
\t\t\t\tENABLE_DEBUG_DYLIB = NO;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tENABLE_HARDENED_RUNTIME = YES;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = Resources/Info.plist;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 0.4.2;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = app.isc.phecda;
\t\t\t\tPRODUCT_NAME = "ISC Phecda";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\t// 这三条对应 Package.swift 里的 defaultIsolation 与
\t\t\t\t// NonisolatedNonsendingByDefault。漏掉它们的症状是几十条
\t\t\t\t// "sending ... risks causing data races" —— 而同一份代码在包里
\t\t\t\t// 编译得好好的，看起来像是搬工程搬坏了。
\t\t\t\tSWIFT_APPROACHABLE_CONCURRENCY = YES;
\t\t\t\tSWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
\t\t\t\tSWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT = YES;
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{uid("cfg", "tgt", "release")} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = Phecda.entitlements;
\t\t\t\t// Release **刻意不写 CODE_SIGN_IDENTITY**。
\t\t\t\t//
\t\t\t\t// 写了 "-" 就是强制 ad-hoc，而 ad-hoc 签出来的归档里没有团队
\t\t\t\t// （TeamIdentifier=not set），导出阶段会报 "No Team Found in
\t\t\t\t// Archive" —— 那个报错出现在归档**成功之后**，看起来像导出坏了。
\t\t\t\t//
\t\t\t\t// 留空则由自动签名按配置挑：Release 挑 Apple Distribution。
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\t// 显式写团队，不让 Xcode 猜。
\t\t\t\t//
\t\t\t\t// 这台机器上有**两个** Team ID：9LS4DPCN7H（一张 Apple Development
\t\t\t\t// 证书，免费个人团队）与 5Q2A46685M（付费团队，能上架）。不写死的话
\t\t\t\t// Xcode 可能挑中前者，于是归档时签得上、上传时才发现这个团队没有
\t\t\t\t// 分发权限 —— 而报错在很久之后，与"挑错了团队"看不出关系。
\t\t\t\t//
\t\t\t\t// 团队 ID 不是秘密（每个签名过的应用里都有），写在这里是为了可复现。
\t\t\t\tDEVELOPMENT_TEAM = 5Q2A46685M;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tENABLE_HARDENED_RUNTIME = YES;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = Resources/Info.plist;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 0.4.2;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = app.isc.phecda;
\t\t\t\tPRODUCT_NAME = "ISC Phecda";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\t// 这三条对应 Package.swift 里的 defaultIsolation 与
\t\t\t\t// NonisolatedNonsendingByDefault。漏掉它们的症状是几十条
\t\t\t\t// "sending ... risks causing data races" —— 而同一份代码在包里
\t\t\t\t// 编译得好好的，看起来像是搬工程搬坏了。
\t\t\t\tSWIFT_APPROACHABLE_CONCURRENCY = YES;
\t\t\t\tSWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
\t\t\t\tSWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT = YES;
\t\t\t}};
\t\t\tname = Release;
\t\t}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t{cfg_list_prj} /* Build configuration list for PBXProject "Phecda" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{uid("cfg", "prj", "debug")} /* Debug */,
\t\t\t\t{uid("cfg", "prj", "release")} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{cfg_list_tgt} /* Build configuration list for PBXNativeTarget "Phecda" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{uid("cfg", "tgt", "debug")} /* Debug */,
\t\t\t\t{uid("cfg", "tgt", "release")} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
\t\t{pkg_ref} /* XCLocalSwiftPackageReference "." */ = {{
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = .;
\t\t}};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
\t\t{pkg_dep} /* ISCCore */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tproductName = ISCCore;
\t\t}};
/* End XCSwiftPackageProductDependency section */
	}};
	rootObject = {prj} /* Project object */;
}}
'''
    out = ROOT / "Phecda.xcodeproj"
    out.mkdir(exist_ok=True)
    (out / "project.pbxproj").write_text(pbx)
    print(f"✅ 已生成 {out}（{len(swift_files)} 个源文件）")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
