#!/usr/bin/env python3
"""生成 Phecda.xcodeproj。

# 为什么是"生成"而不是"手写"

工程文件是 Xcode 的私有格式：几千行、UUID 互相引用、冲突时几乎没法手工合。
本仓库没有 XcodeGen（也不想为它引入 Homebrew），因此把生成过程本身留在
脚本里 —— 它是可读的、可重跑的，而 pbxproj 只是它的产物。

它同时生成两个**共享 scheme**（Phecda / Phecda-Fresh）—— 理由是"我怎么
构建、怎么试"属于仓库，而不该只活在某个人的 xcuserdata 里。见 write_schemes。

重跑：python3 Scripts/gen-project.py
"""
import hashlib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "Apps" / "Phecda"
# 推送桥（闭源库 libiscap 的可选入口）。
#
# 它在 Sources/ 下，却**不是** SwiftPM 的 target —— 理由写在那个文件的开头：
# 能不能 `import CAp` 取决于**应用 target** 的编译标志（Release 才由
# Configs/Release.xcconfig 可选地给出来），而 SwiftPM 的 target 有自己的
# 一套标志，应用的设置传不进去。
BRIDGE = ROOT / "Sources" / "CAp"


def uid(*parts: str) -> str:
    """确定性的 24 位十六进制 UUID。

    确定性很重要：每跑一次都换一批 UUID 的话，git diff 里整个文件都会翻新，
    而"这次改了什么"就看不出来了。
    """
    return hashlib.sha1("|".join(parts).encode()).hexdigest()[:24].upper()


def source_entry(key: str, name: str) -> tuple[str, str]:
    """一个 .swift 文件的（PBXFileReference, PBXBuildFile）两行。

    key 只用来算 UUID，name 才是显示与路径。两者分开是为了让
    Sources/CAp 下的文件与 Apps/Phecda 下的同名文件不会撞 UUID。
    """
    fr, bf = uid("fileref", key), uid("buildfile", key)
    return (
        f'\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = '
        f'sourcecode.swift; path = {name}; sourceTree = "<group>"; }};',
        f'\t\t{bf} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};',
    )


def main() -> int:
    swift_files = sorted(p.name for p in APP.glob("*.swift"))
    if not swift_files:
        print(f"❌ 在 {APP} 下没找到任何 .swift", file=sys.stderr)
        return 1
    bridge_files = sorted(p.name for p in BRIDGE.glob("*.swift"))
    if not bridge_files:
        print(f"❌ 在 {BRIDGE} 下没找到任何 .swift", file=sys.stderr)
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
    ap_phase = uid("phase", "ap")
    dylib_fr = uid("fileref", "libisc")
    dylib_bf = uid("buildfile", "libisc")
    res_phase = uid("phase", "resources")
    fwk_phase = uid("phase", "frameworks")
    cfg_list_prj = uid("cfglist", "project")
    cfg_list_tgt = uid("cfglist", "target")

    # 应用 target 编译两组源文件：界面（Apps/Phecda）与推送桥（Sources/CAp）。
    file_refs, build_files = [], []
    for name in swift_files:
        file_refs.append(source_entry(name, name)[0])
        build_files.append(source_entry(name, name)[1])
    for name in bridge_files:
        key = f"CAp/{name}"
        file_refs.append(source_entry(key, name)[0])
        build_files.append(source_entry(key, name)[1])

    assets_fr, assets_bf = uid("fileref", "Assets"), uid("buildfile", "Assets")
    # Icon Composer 的 AppIcon.icon（见文件末尾的 write_app_icon_notes）。
    #
    # `folder.iconcomposer.icon` 这个类型名不是我编的：Xcode 自己的
    # StandardFileTypes.xcspec 里写着 `Identifier = folder.iconcomposer.icon`、
    # `BasedOn = folder.abstractassetcatalog`、`IsTransparent = NO`，而
    # AssetCatalogCompiler.xcspec 的 InputFileTypes 里也有它 —— 也就是说
    # 这个类型会让 Xcode 把 .icon **当成一个不透明包**交给 actool 编译，
    # 而不是拆开当散资源拷进包里（那是这条路最容易踩的坑：图标会静默消失）。
    icon_fr, icon_bf = uid("fileref", "AppIcon.icon"), uid("buildfile", "AppIcon.icon")
    privacy_fr, privacy_bf = uid("fileref", "PrivacyInfo"), uid("buildfile", "PrivacyInfo")
    plist_fr = uid("fileref", "Info.plist")
    entitlements_fr = uid("fileref", "Phecda.entitlements")
    # 上架版用的那份（带沙箱）。它**不在**任何配置的 CODE_SIGN_ENTITLEMENTS
    # 里 —— 归档时由 Scripts/archive.sh 显式覆盖选中。放进工程只为能在
    # Xcode 里看到它，避免"改了一份没被用到的文件"。
    appstore_entitlements_fr = uid("fileref", "Phecda-AppStore.entitlements")
    pkg_fr = uid("fileref", "Package.swift")
    pkg_dep = uid("pkgdep", "ISCCore")
    pkg_ref = uid("pkgref", "local")
    pkg_bf = uid("buildfile", "ISCCore")
    # Release 配置的基底。它内部用 `#include?` 可选地拉进 Vendor/AP 里的
    # 链接设置 —— 所以工程文件里没有任何指向闭源库的静态引用。
    ap_cfg_fr = uid("fileref", "Configs/Release.xcconfig")
    bridge_group = uid("group", "Sources/CAp")

    swift_names = "\n".join(
        f'\t\t\t\t{uid("buildfile", key)} /* {name} in Sources */,'
        for key, name in [(n, n) for n in swift_files] + [(f"CAp/{n}", n) for n in bridge_files])
    fileref_lines = "\n".join(file_refs)
    buildfile_lines = "\n".join(build_files)
    group_children = "\n".join(f'\t\t\t\t{uid("fileref", n)} /* {n} */,' for n in swift_files)
    bridge_children = "\n".join(
        f'\t\t\t\t{uid("fileref", f"CAp/{n}")} /* {n} */,' for n in bridge_files)

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
\t\t{icon_bf} /* AppIcon.icon in Resources */ = {{isa = PBXBuildFile; fileRef = {icon_fr} /* AppIcon.icon */; }};
\t\t{privacy_bf} /* PrivacyInfo.xcprivacy in Resources */ = {{isa = PBXBuildFile; fileRef = {privacy_fr} /* PrivacyInfo.xcprivacy */; }};
\t\t{pkg_bf} /* ISCCore in Frameworks */ = {{isa = PBXBuildFile; productRef = {pkg_dep} /* ISCCore */; }};
\t\t{dylib_bf} /* libisc.dylib in Embed Libraries */ = {{isa = PBXBuildFile; fileRef = {dylib_fr} /* libisc.dylib */; settings = {{ATTRIBUTES = (CodeSignOnCopy, ); }}; }};
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
\t\t{prod} /* ISC Phecda.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "ISC Phecda.app"; sourceTree = BUILT_PRODUCTS_DIR; }};
{fileref_lines}
\t\t{assets_fr} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};
\t\t{icon_fr} /* AppIcon.icon */ = {{isa = PBXFileReference; lastKnownFileType = folder.iconcomposer.icon; path = AppIcon.icon; sourceTree = "<group>"; }};
\t\t{privacy_fr} /* PrivacyInfo.xcprivacy */ = {{isa = PBXFileReference; lastKnownFileType = text.xml; name = PrivacyInfo.xcprivacy; path = Resources/PrivacyInfo.xcprivacy; sourceTree = "<group>"; }};
\t\t{plist_fr} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; name = Info.plist; path = Resources/Info.plist; sourceTree = "<group>"; }};
\t\t{entitlements_fr} /* Phecda.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Phecda.entitlements; sourceTree = "<group>"; }};
\t\t{appstore_entitlements_fr} /* Phecda-AppStore.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = "Phecda-AppStore.entitlements"; sourceTree = "<group>"; }};
\t\t{pkg_fr} /* Package.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Package.swift; sourceTree = "<group>"; }};
\t\t{ap_cfg_fr} /* Release.xcconfig */ = {{isa = PBXFileReference; lastKnownFileType = text.xcconfig; name = Release.xcconfig; path = Configs/Release.xcconfig; sourceTree = "<group>"; }};
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
\t\t{ap_phase} /* Bundle AP Library */ = {{
\t\t\tisa = PBXShellScriptBuildPhase;
\t\t\talwaysOutOfDate = 1;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\tinputFileListPaths = (
\t\t\t);
\t\t\tinputPaths = (
\t\t\t);
\t\t\tname = "Bundle AP Library";
\t\t\toutputFileListPaths = (
\t\t\t);
\t\t\toutputPaths = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t\tshellPath = /bin/sh;
\t\t\tshellScript = "\\"$SRCROOT/Scripts/xcode-bundle-ap.sh\\"\\n";
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
\t\t\t\t{ap_cfg_fr} /* Release.xcconfig */,
\t\t\t\t{privacy_fr} /* PrivacyInfo.xcprivacy */,
\t\t\t\t{app_group} /* Phecda */,
\t\t\t\t{bridge_group} /* CAp */,
\t\t\t\t{dylib_fr} /* libisc.dylib */,
\t\t\t\t{plist_fr} /* Info.plist */,
\t\t\t\t{entitlements_fr} /* Phecda.entitlements */,
\t\t\t\t{appstore_entitlements_fr} /* Phecda-AppStore.entitlements */,
\t\t\t\t{products_group} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{bridge_group} /* CAp */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{bridge_children}
\t\t\t);
\t\t\tpath = Sources/CAp;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{app_group} /* Phecda */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{group_children}
\t\t\t\t{assets_fr} /* Assets.xcassets */,
\t\t\t\t{icon_fr} /* AppIcon.icon */,
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
\t\t\t\t{ap_phase} /* Bundle AP Library */,
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
\t\t\t\t{icon_bf} /* AppIcon.icon in Resources */,
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
\t\t\t\t// 这份 entitlement **没有沙箱**，这是刻意的：沙箱进程的
\t\t\t\t// process-exec 只放行 /Applications 与系统目录，而本产品的核心
\t\t\t\t// 就是在用户机器上跑用户的工具链（含项目目录里的 .bin）。
\t\t\t\t// 上架那份走 Phecda-AppStore.entitlements，由 archive.sh 覆盖选中。
\t\t\t\t//
\t\t\t\t// Debug 另用 ad-hoc：本机不一定有该团队的开发证书，而日常构建
\t\t\t\t// 不该因为签名缺失而跑不起来。
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
\t\t\t\tMARKETING_VERSION = 0.4.5;
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
\t\t\t// Release 的基底配置。它内部用 `#include?` 可选地把 Vendor/AP 里的
\t\t\t// 链接设置拉进来 —— 库不在时那一行静默跳过，于是这个构建与
\t\t\t// "从 GitHub 拿源码自编译"的形态完全一致：没有推送能力，照样能构建。
\t\t\t//
\t\t\t// Debug **不挂**它：日常开发不需要这个闭源库，也不该被它挡住。
\t\t\tbaseConfigurationReference = {ap_cfg_fr} /* Release.xcconfig */;
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
\t\t\t\tMARKETING_VERSION = 0.4.5;
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
    if check_app_icon() != 0:
        return 1
    if check_fresh_env_names() != 0:
        return 1
    (out / "project.pbxproj").write_text(pbx)
    write_schemes(out, tgt)
    print(f"✅ 已生成 {out}（{len(swift_files)} 个源文件 + 2 个共享 scheme）")
    return 0


# 「每次运行都是全新的应用」这件事，靠环境变量开（见 Apps/Phecda/FreshRun.swift）。
#
# 它必须落在**共享 scheme** 里才能进仓库：`xcuserdata` 下的 scheme 是每人一份、
# 不进 git 的，而"我怎么构建、怎么试"是仓库该记住的事。这里生成两个：
#
#   Phecda        日常：真实数据目录，与安装版行为一致
#   Phecda-Fresh  每次 Run 都从零：临时数据目录 + 文件密钥后端
#
# 为什么不是"把日常那个也设成从零"：这个仓库构建出来的应用是**能真用**的
# （D26：GUI 就是内核的宿主）。把它默认设成一次性，等于某天想在开发构建里
# 看一眼真实站点时，数据已经没了。要一键从零的人选另一个 scheme —— 两个
# scheme 并存不会让任何一方变危险。
#
# 命令行那条路走 Scripts/fresh-run.sh：scheme 里的环境变量只在 Xcode **运行**
# 时生效，`xcodebuild build` 不读它。
def write_schemes(project: pathlib.Path, target_uuid: str) -> None:
    # 同一段 BuildableReference 要出现在三个地方，缩进各不相同（Xcode 自己的
    # 写法就是按嵌套层级缩进的）。生成时把缩进当参数传，免得提交上去的文件
    # 里有一段缩进是歪的 —— 那种歪斜会让人以为文件被手工改过。
    def ref(indent: int) -> str:
        pad, inner = " " * indent, " " * (indent + 3)
        return f'''{pad}<BuildableReference
{inner}BuildableIdentifier = "primary"
{inner}BlueprintIdentifier = "{target_uuid}"
{inner}BuildableName = "ISC Phecda.app"
{inner}BlueprintName = "Phecda"
{inner}ReferencedContainer = "container:Phecda.xcodeproj">
{pad}</BuildableReference>'''

    def scheme(name: str, fresh: bool) -> str:
        env = ""
        if fresh:
            env = '''
      <EnvironmentVariables>
         <EnvironmentVariable
            key = "ISC_PHECDA_FRESH"
            value = "1"
            isEnabled = "YES">
         </EnvironmentVariable>
         <EnvironmentVariable
            key = "ISC_SECRET_STORE"
            value = "file"
            isEnabled = "YES">
         </EnvironmentVariable>
      </EnvironmentVariables>'''
        # ignoresPersistentStateOnLaunch：从零的那份连 AppKit 的窗口状态恢复
        # 也一起去掉。留着它的话，"全新应用"会带着上一次的窗口位置与选中项
        # 启动 —— 那是唯一一处 State Restoration 会绕过临时数据目录的地方。
        ignore_state = "YES" if fresh else "NO"
        return f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2700"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
{ref(12)}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "{ignore_state}"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
{ref(9)}
      </BuildableProductRunnable>{env}
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
{ref(9)}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''

    directory = project / "xcshareddata" / "xcschemes"
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "Phecda.xcscheme").write_text(scheme("Phecda", fresh=False))
    (directory / "Phecda-Fresh.xcscheme").write_text(scheme("Phecda-Fresh", fresh=True))


# scheme 里那两个环境变量必须与源码里的常量一致。
#
# 不一致的症状是"scheme 看着没错，但从零模式就是不生效"—— 而没有人会去怀疑
# 一个 XML。两个名字在这里各写了一遍（gen-project.py 与 FreshRun.swift），
# 因此让**生成器**来守这条线：对不上就直接生成失败，而不是交付一份看着对、
# 实际不起作用的 scheme。
# AppIcon.icon 必须真的在，而且里面要说得出一个图层、图也要在。
#
# 这条守卫针对的失败是**静默**的：actool 找不到图标时不报错，只给一条
# warning，包里于是没有任何应用图标 —— 构建照样成功、测试照样全绿，症状要到
# Dock 或访达里才看得出来。深色模式没有对应图标也是从这条路上来的：旧写法把
# 深色图放在 appiconset 里，而 `--platform macosx` 没有那个槽位，于是 10 张
# 深色图被当成 "unassigned children" 静默丢掉。
def check_app_icon() -> int:
    bundle = APP / "AppIcon.icon"
    document = bundle / "icon.json"
    if not document.is_file():
        print(f"❌ 找不到 {document} —— AppIcon.icon 是应用图标的唯一来源，"
              f"缺了它包里将没有任何图标（actool 只给 warning，不会让构建失败）",
              file=sys.stderr)
        return 1
    try:
        data = json.loads(document.read_text())
    except json.JSONDecodeError as error:
        print(f"❌ {document} 不是合法 JSON：{error}", file=sys.stderr)
        return 1
    layers = [layer for group in data.get("groups", []) for layer in group.get("layers", [])]
    if not layers:
        print(f"❌ {document} 里一个图层都没有 —— 那样出来的图标只有一个底色方块",
              file=sys.stderr)
        return 1
    missing = [layer["image-name"] for layer in layers
               if layer.get("image-name") and not (bundle / "Assets" / layer["image-name"]).is_file()]
    if missing:
        print(f"❌ 图层引用的图不在 Assets 里：{'、'.join(missing)}", file=sys.stderr)
        return 1

    # 没被引用的图**不会进包**（actool 只编译引用到的那几张）。所以
    # "深色稿躺在 Assets 里但没人引用"意味着深色外观拿到的还是浅色稿 ——
    # 而这一点在构建、测试、产物里都看不出来，只有肉眼比外观才发现。
    # 这是提醒不是错误：只提供一套图是合法的。
    text = document.read_text()
    unused = sorted(item.name for item in (bundle / "Assets").iterdir()
                    if item.suffix.lower() in {".png", ".jpg", ".jpeg", ".svg", ".pdf"}
                    and item.name not in text)
    if unused:
        print(f"⚠️  AppIcon.icon/Assets 里这些图没有被 icon.json 引用：{'、'.join(unused)}")
        print("    没被引用就不会进包 —— 若那是某一种外观（例如深色）的图，")
        print("    说明那个外观现在用的是别的图。指派方式见 Documentation/ICONS.md。")
    return 0


def check_fresh_env_names() -> int:
    source = (APP / "FreshRun.swift").read_text()
    for key in ("ISC_PHECDA_FRESH", "ISC_SECRET_STORE"):
        if f'"{key}"' not in source:
            print(f"❌ FreshRun.swift 里找不到 {key} —— scheme 与代码已经不同步，"
                  f"改名前先改这里", file=sys.stderr)
            return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
