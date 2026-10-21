#!/usr/bin/env python3
"""Pinned Android/iOS dynamic audio stack. Run from any directory."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT / 'native/build/third_party'
OUT = ROOT / 'native/build/mobile'
MANIFEST = ROOT / 'tooling/native/sources.manifest.json'
NDK_VERSION = '28.2.13676358'
TARGETS = {
    'android-arm64': ('android', 'arm64-v8a', 'aarch64-linux-android', 'aarch64', 'aarch64-linux-android'),
    'android-x64': ('android', 'x86_64', 'x86_64-linux-android', 'x86_64', 'x86_64-linux-android'),
    'ios-arm64': ('ios', 'iphoneos', 'aarch64-apple-ios', 'aarch64', 'arm64'),
    'ios-sim-arm64': ('ios', 'iphonesimulator', 'aarch64-apple-ios-sim', 'aarch64', 'arm64'),
}
FRAMEWORKS = {'ff_media_core': 'FFMediaCore', 'avformat': 'AVFormat', 'avcodec': 'AVCodec', 'avutil': 'AVUtil', 'swresample': 'SWResample', 'soxr': 'SoXR'}

def run(args, cwd=None, env=None):
    print('+ ' + ' '.join(map(str,args)), flush=True)
    subprocess.run(list(map(str,args)), cwd=cwd, env=env, check=True)

def output(args):
    return subprocess.check_output(list(map(str,args)), text=True).strip()

def sdk_path(name):
    return output(['xcrun', '--sdk', name, '--show-sdk-path'])


def android_sdk_path(env=None):
    env = os.environ if env is None else env
    configured = env.get('ANDROID_SDK_ROOT') or env.get('ANDROID_HOME')
    if configured:
        return Path(configured)
    return Path.home() / ('Library/Android/sdk' if sys.platform == 'darwin' else 'Android/Sdk')


def android_ndk_path(env=None):
    env = os.environ if env is None else env
    return Path(env.get('ANDROID_NDK_HOME') or env.get('ANDROID_NDK_ROOT') or
                android_sdk_path(env) / 'ndk' / NDK_VERSION)


def android_toolchain_bin(env=None):
    hosts = {'linux': 'linux-x86_64', 'darwin': 'darwin-x86_64'}
    if sys.platform not in hosts:
        raise ValueError('Android native builds require Linux or macOS')
    return android_ndk_path(env) / 'toolchains/llvm/prebuilt' / hosts[sys.platform] / 'bin'


def configuration(key):
    platform, variant, target, arch, triple = TARGETS[key]
    prefix = OUT / key / 'prefix'
    env = os.environ.copy()
    if platform == 'android':
        tools = android_toolchain_bin(env)
        cc, ar = tools / f'{triple}24-clang', tools / 'llvm-ar'
        flags = '-fPIC'
        env.update(CXX=str(tools / f'{triple}24-clang++'))
        linker_flags = '-Wl,-z,max-page-size=16384'
    else:
        cc, ar = Path(output(['xcrun','--find','clang'])), Path(output(['xcrun','--find','ar']))
        sdk = sdk_path(variant)
        minimum = '14.0' if variant == 'iphonesimulator' else '13.0'
        apple_target = f'arm64-apple-ios{minimum}' + ('-simulator' if variant == 'iphonesimulator' else '')
        flags = f'-target {apple_target} -isysroot {sdk}'
        env.update(SDKROOT=sdk, IPHONEOS_DEPLOYMENT_TARGET=minimum, CXX=output(['xcrun','--find','clang++']))
        linker_flags = flags
    env.update(CC=str(cc), AR=str(ar), CFLAGS=flags, CXXFLAGS=flags, FF_CFLAGS=flags,
               FF_NATIVE_PREFIX=str(prefix), FF_MINIAUDIO_DIR=str(BASE / 'src/miniaudio-0.11.25'),
               CARGO_TARGET_DIR=str(OUT / 'cargo'))
    env[f'CARGO_TARGET_{target.upper().replace("-","_")}_LINKER'] = str(cc)
    env['RUSTFLAGS'] = ' '.join('-C link-arg=' + x for x in linker_flags.split())
    if platform == 'ios':
        env['RUSTFLAGS'] += ' -C link-arg=-Wl,-install_name,@rpath/FFMediaCore.framework/FFMediaCore'
    env['LDFLAGS'] = linker_flags
    return platform, variant, target, arch, prefix, env

def fetch():
    manifest = json.loads(MANIFEST.read_text())
    for name in ('ffmpeg','libsoxr','miniaudio'):
        source = manifest['sources'][name]
        archive = BASE / 'downloads' / source['downloadName']
        archive.parent.mkdir(parents=True, exist_ok=True)
        if not archive.exists():
            urllib.request.urlretrieve(source['urls'][0], archive)
        assert hashlib.sha256(archive.read_bytes()).hexdigest() == source['sha256'], f'{name} checksum mismatch'
        destination = BASE / 'src' / source['topDir']
        if not destination.exists():
            with tarfile.open(archive) as tar:
                tar.extractall(BASE / 'src', filter='data')

def components():
    flags=[]
    for line in (ROOT/'tooling/native/ffmpeg-components.txt').read_text().splitlines():
        if ':' not in line or line.lstrip().startswith('#'): continue
        kind, names=line.split(':',1)
        kind = 'protocol' if kind == 'protocol-base' else kind
        flags.append(f'--enable-{kind}=' + ','.join(names.split()))
    return flags

def build(key, jobs):
    platform, variant, target, arch, prefix, env = configuration(key)
    work = OUT / key
    prefix.mkdir(parents=True,exist_ok=True)
    manifest = json.loads(MANIFEST.read_text())
    soxr_build = work/'soxr-build'
    soxr_source = work/'soxr-source'
    if not soxr_source.exists():
        shutil.copytree(BASE/'src/soxr-0.1.3',soxr_source)
    if platform=='android':
        source_file=soxr_source/'src/CMakeLists.txt'
        text=source_file.read_text().replace('  VERSION "${SO_VERSION}"','').replace('  SOVERSION ${SO_VERSION_MAJOR}','')
        source_file.write_text(text)
    cmake=['cmake','-S',soxr_source,'-B',soxr_build,
           '-DCMAKE_POLICY_VERSION_MINIMUM=3.5','-DCMAKE_BUILD_TYPE=Release',f'-DCMAKE_INSTALL_PREFIX={prefix}',
           '-DBUILD_SHARED_LIBS=ON','-DBUILD_TESTS=OFF','-DBUILD_EXAMPLES=OFF','-DWITH_OPENMP=OFF',
           '-DWITH_AVFFT=OFF','-DWITH_LSR_BINDINGS=OFF','-DCMAKE_INSTALL_LIBDIR=lib']
    if platform=='android':
        ndk=Path(env['CC']).parents[5]
        cmake += [f'-DCMAKE_TOOLCHAIN_FILE={ndk}/build/cmake/android.toolchain.cmake',f'-DANDROID_ABI={variant}',
                  '-DANDROID_PLATFORM=android-24','-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON']
    else:
        cmake += ['-DCMAKE_SYSTEM_NAME=iOS', f'-DCMAKE_OSX_SYSROOT={env["SDKROOT"]}',
                  '-DCMAKE_OSX_ARCHITECTURES=arm64',f'-DCMAKE_OSX_DEPLOYMENT_TARGET={env["IPHONEOS_DEPLOYMENT_TARGET"]}']
    run(cmake,env=env)
    run(['cmake','--build',soxr_build,'--parallel',jobs],env=env)
    run(['cmake','--install',soxr_build],env=env)
    ffbuild=work/'ffmpeg';ffbuild.mkdir(exist_ok=True)
    args=[BASE/'src/ffmpeg-7.1.5/configure',f'--prefix={prefix}', '--enable-cross-compile',
          f'--arch={arch}', f'--target-os={"android" if platform=="android" else "darwin"}',
          f'--cc={env["CC"]}',f'--ar={env["AR"]}', '--disable-everything','--disable-autodetect',
          '--disable-programs','--disable-doc','--disable-debug','--disable-static','--enable-shared',
          '--disable-network','--disable-openssl','--disable-securetransport','--disable-schannel',
          '--disable-avdevice','--disable-avfilter','--disable-postproc','--disable-swscale', '--enable-libsoxr',
          f'--extra-cflags={env["FF_CFLAGS"]} -I{prefix}/include',
          f'--extra-ldflags={env["LDFLAGS"]} -L{prefix}/lib']+components()
    if platform=='android':
        tools=Path(env['CC']).parent
        args += [f'--ranlib={tools}/llvm-ranlib', f'--strip={tools}/llvm-strip', '--disable-symver']
    else:
        args += ['--disable-asm']
    env['PKG_CONFIG_LIBDIR']=str(prefix/'lib/pkgconfig');env['PKG_CONFIG_PATH']=''
    run(args,cwd=ffbuild,env=env)
    run(['make',f'-j{jobs}'],cwd=ffbuild,env=env)
    run(['make','install'],cwd=ffbuild,env=env)
    run(['cargo','build','--locked','--release','--target',target,'-p','fideflow-media-ffi'],cwd=ROOT/'native/media_core',env=env)
    host=OUT/'cargo'/target/'release'/('libff_media_core.so' if platform=='android' else 'libff_media_core.dylib')
    shutil.copy2(host,prefix/'lib'/host.name)
    license_dir=prefix/'licenses';license_dir.mkdir(exist_ok=True)
    for name in ('ffmpeg','libsoxr','miniaudio'):
        source=manifest['sources'][name]
        for license_file in source['licenseFiles']:
            shutil.copy2(BASE/'src'/source['topDir']/license_file,license_dir/f'{name}-{Path(license_file).name}')
    for name, sdk in manifest.get('linkedSdks', {}).items():
        source=ROOT/sdk['source']
        shutil.copy2(source/sdk['licenseFile'],license_dir/f'{sdk["crate"]}-LICENSE')
        patch=source/'HOST-PATCH.md'
        if patch.exists(): shutil.copy2(patch,license_dir/f'{name}-HOST-PATCH.md')
    if platform=='android':
        stage=OUT/'android/jniLibs'/variant;stage.mkdir(parents=True,exist_ok=True)
        for name in FRAMEWORKS:
            lib=prefix/'lib'/f'lib{name}.so'
            shutil.copy2(lib,stage/lib.name)
    else:
        frameworks=work/'frameworks';frameworks.mkdir(exist_ok=True)
        libraries={}
        for name,title in FRAMEWORKS.items():
            matches=[p for p in (prefix/'lib').glob(f'lib{name}*.dylib') if not p.is_symlink()]
            assert len(matches)==1,(name,matches)
            libraries[name]=(title,matches[0])
        for name,(title,lib) in libraries.items():
            fw=frameworks/f'{title}.framework';fw.mkdir(exist_ok=True);binary=fw/title
            shutil.copy2(lib,binary)
            (fw/'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':title,'CFBundleIdentifier':f'com.moetaku.fideflow.native.{title}',
                'CFBundleName':title,'CFBundlePackageType':'FMWK','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','MinimumOSVersion':env['IPHONEOS_DEPLOYMENT_TARGET'],
                'CFBundleSupportedPlatforms':['iPhoneOS' if variant=='iphoneos' else 'iPhoneSimulator']}))
            run(['install_name_tool','-id',f'@rpath/{title}.framework/{title}',binary])
            for line in output(['otool','-L',binary]).splitlines()[1:]:
                old=line.strip().split(' ',1)[0]
                for dependency,(dep_title,_) in libraries.items():
                    if Path(old).name.startswith(f'lib{dependency}.'):
                        run(['install_name_tool','-change',old,f'@rpath/{dep_title}.framework/{dep_title}',binary])
            run(['codesign','--force','--sign','-',fw])
    evidence={'target':target,'platform':platform,'minimum':'24' if platform=='android' else env['IPHONEOS_DEPLOYMENT_TARGET'],'network':'off',
              'sources':manifest['sources'],'compiler':output([env['CC'],'--version']).splitlines()[0], 'configure':list(map(str,args))}
    evidence['linkedSdks'] = manifest.get('linkedSdks', {})
    evidence['rustc'] = output(['rustc','--version'])
    evidence['cargoLockSha256'] = hashlib.sha256((ROOT/'native/media_core/Cargo.lock').read_bytes()).hexdigest()
    evidence['libraries'] = {p.name: {'bytes': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
                             for p in (prefix/'lib').glob('*') if p.is_file() and not p.is_symlink() and p.suffix in ('.so','.dylib')}
    evidence['soxrPackagingPatch'] = 'Android removes VERSION/SOVERSION so Gradle can package unversioned .so names' if platform=='android' else None
    (work/'build-manifest.json').write_text(json.dumps(evidence,indent=2)+'\n')
    if platform=='android':
        assets=OUT/'android/assets/native-audio'/variant
        assets.mkdir(parents=True,exist_ok=True)
        shutil.copytree(license_dir,assets/'licenses',dirs_exist_ok=True)
        shutil.copy2(work/'build-manifest.json',assets/'build-manifest.json')
    verify(key)

def refresh_rust(key):
    """Rebuild only the Rust FFI library and refresh its staged app artifact."""
    platform, variant, target, arch, prefix, env = configuration(key)
    if not (prefix/'lib').is_dir():
        raise SystemExit(f'Missing native dependency prefix for {key}; run build.py build --target {key} first.')
    for name in FRAMEWORKS:
        if not (prefix/'lib'/f'lib{name}.so').is_file() and platform == 'android':
            raise SystemExit(f'Missing {name} dependency for {key}; run build.py build --target {key} first.')
        if platform == 'ios' and not any(p.is_file() and not p.is_symlink() for p in (prefix/'lib').glob(f'lib{name}*.dylib')):
            raise SystemExit(f'Missing {name} dependency for {key}; run build.py build --target {key} first.')

    run(['cargo','build','--locked','--release','--target',target,'-p','fideflow-media-ffi'],cwd=ROOT/'native/media_core',env=env)
    host=OUT/'cargo'/target/'release'/('libff_media_core.so' if platform=='android' else 'libff_media_core.dylib')
    staged=prefix/'lib'/host.name
    shutil.copy2(host,staged)
    work=OUT/key
    manifest_path=work/'build-manifest.json'
    if manifest_path.is_file():
        evidence=json.loads(manifest_path.read_text())
    else:
        evidence={}
    evidence.update({'target':target,'platform':platform,'rustc':output(['rustc','--version']),
                     'cargoLockSha256':hashlib.sha256((ROOT/'native/media_core/Cargo.lock').read_bytes()).hexdigest()})
    evidence.setdefault('libraries',{})[staged.name]={'bytes':staged.stat().st_size,'sha256':hashlib.sha256(staged.read_bytes()).hexdigest()}
    manifest_path.write_text(json.dumps(evidence,indent=2)+'\n')

    if platform == 'android':
        stage=OUT/'android/jniLibs'/variant
        stage.mkdir(parents=True,exist_ok=True)
        shutil.copy2(staged,stage/staged.name)
        assets=OUT/'android/assets/native-audio'/variant
        assets.mkdir(parents=True,exist_ok=True)
        shutil.copy2(manifest_path,assets/'build-manifest.json')
        verify(key)
        print(f'Refreshed {stage/staged.name}',flush=True)
        return

    fw=work/'frameworks/FFMediaCore.framework'
    binary=fw/'FFMediaCore'
    if not binary.is_file():
        raise SystemExit(f'Missing {binary}; run build.py build --target {key} first.')
    shutil.copy2(staged,binary)
    run(['install_name_tool','-id','@rpath/FFMediaCore.framework/FFMediaCore',binary])
    for line in output(['otool','-L',binary]).splitlines()[1:]:
        old=line.strip().split(' ',1)[0]
        for name,title in FRAMEWORKS.items():
            if name != 'ff_media_core' and Path(old).name.startswith(f'lib{name}.'):
                run(['install_name_tool','-change',old,f'@rpath/{title}.framework/{title}',binary])
    run(['codesign','--force','--sign','-',fw])
    verify(key)
    print(f'Refreshed {fw}',flush=True)

def refresh(platform):
    keys=[key for key,value in TARGETS.items() if value[0] == platform]
    for key in keys:
        refresh_rust(key)
    if platform == 'ios':
        xcframeworks()

def verify(key):
    platform,variant,target,arch,prefix,env=configuration(key)
    config=(OUT/key/'ffmpeg/config.h').read_text() + (OUT/key/'ffmpeg/config_components.h').read_text()
    assert '#define CONFIG_NETWORK 0' in config
    for protocol in ('HTTP','HTTPS','TCP','TLS'):
        assert f'#define CONFIG_{protocol}_PROTOCOL 0' in config
    for flag in components():
        kind,names=flag.removeprefix('--enable-').split('=')
        for name in names.split(','):
            assert f'#define CONFIG_{name.upper()}_{kind.upper()} 1' in config
    if platform=='android':
        readelf=Path(env['CC']).parent/'llvm-readelf'
        stage=OUT/'android/jniLibs'/variant
        assert (stage/'libff_media_core.so').is_file()
        names={p.name for p in stage.glob('*.so*')}
        for lib in stage.glob('*.so*'):
            headers=output([readelf,'-lW',lib])
            for line in headers.splitlines():
                if line.strip().startswith('LOAD'): assert int(line.split()[-1],16)>=16384,(lib,line)
            dynamic=output([readelf,'-d',lib])
            for line in dynamic.splitlines():
                if '(NEEDED)' in line:
                    needed=line.split('[')[1].split(']')[0]
                    assert needed in names or needed in {'libc.so','libm.so','libdl.so','liblog.so','libandroid.so','libOpenSLES.so'},(lib,needed)
    else:
        for title in FRAMEWORKS.values():
            fw=OUT/key/'frameworks'/f'{title}.framework'
            assert output(['lipo','-archs',fw/title])=='arm64'
            load=output(['otool','-l',fw/title])
            assert any(f'platform {value}' in load for value in (('2','IOS') if variant=='iphoneos' else ('7','IOSSIMULATOR')))
            assert f'minos {env["IPHONEOS_DEPLOYMENT_TARGET"]}' in load
            for line in output(['otool','-L',fw/title]).splitlines()[1:]:
                dep=line.strip().split(' ',1)[0]
                assert dep.startswith(('@rpath/','/System/Library/','/usr/lib/')),dep
                if dep.startswith('@rpath/'):
                    assert dep in {f'@rpath/{name}.framework/{name}' for name in FRAMEWORKS.values()},dep
            run(['codesign','--verify','--strict',fw])
    print(f'Verified {key}',flush=True)

def xcframeworks():
    dest=OUT/'ios/xcframeworks';dest.mkdir(parents=True,exist_ok=True)
    for title in FRAMEWORKS.values():
        path=dest/f'{title}.xcframework'
        if path.exists(): shutil.rmtree(path)
        run(['xcodebuild','-create-xcframework','-framework',OUT/'ios-arm64/frameworks'/f'{title}.framework',
             '-framework',OUT/'ios-sim-arm64/frameworks'/f'{title}.framework','-output',path])

def embed_ios():
    # Xcode chooses the correct XCFramework platform variant; device and simulator
    # ARM64 binaries must never be selected by architecture alone.
    simulator=os.environ['PLATFORM_NAME']=='iphonesimulator'
    destination=Path(os.environ['TARGET_BUILD_DIR'])/os.environ['FRAMEWORKS_FOLDER_PATH']
    destination.mkdir(parents=True,exist_ok=True)
    resources=Path(os.environ['TARGET_BUILD_DIR'])/os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH']/'native-audio'
    resources.mkdir(parents=True,exist_ok=True)
    key='ios-sim-arm64' if simulator else 'ios-arm64'
    shutil.copytree(OUT/key/'prefix/licenses',resources/'licenses',dirs_exist_ok=True)
    shutil.copy2(OUT/key/'build-manifest.json',resources/'build-manifest.json')
    for title in FRAMEWORKS.values():
        xc=OUT/'ios/xcframeworks'/f'{title}.xcframework'
        info=plistlib.loads((xc/'Info.plist').read_bytes())
        entry=next(x for x in info['AvailableLibraries'] if (x.get('SupportedPlatformVariant')=='simulator')==simulator)
        fw=destination/f'{title}.framework'
        if fw.exists(): shutil.rmtree(fw)
        shutil.copytree(xc/entry['LibraryIdentifier']/entry['LibraryPath'],fw)
        identity=os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-'
        if os.environ.get('CODE_SIGNING_ALLOWED')!='NO': run(['codesign','--force','--sign',identity,fw])

def verify_apk(path):
    sdk=android_sdk_path()
    run([sdk/'build-tools/36.0.0/zipalign','-c','-P','16','4',path])
    resources=output([sdk/'build-tools/36.0.0/aapt2','dump','resources',path])
    for icon in ('play_arrow','pause','stop','skip_next','skip_previous'):
        assert f'drawable/audio_service_{icon}' in resources, f'missing MediaSession control icon: {icon}'
    tools=android_toolchain_bin()
    with zipfile.ZipFile(path) as archive, tempfile.TemporaryDirectory(prefix='ff-apk-verify-') as temp:
        entries={entry.filename for entry in archive.infolist()}
        abis={name.split('/')[1] for name in entries if name.startswith('lib/') and name.endswith('.so')}
        assert abis=={'arm64-v8a','x86_64'}, f'unexpected packaged ABIs: {abis}'
        for abi in ('arm64-v8a','x86_64'):
            for name in FRAMEWORKS:
                assert f'lib/{abi}/lib{name}.so' in entries,(abi,name)
        for entry in archive.infolist():
            if entry.filename.startswith('lib/') and entry.filename.endswith('.so'):
                file=Path(archive.extract(entry,temp))
                for line in output([tools/'llvm-readelf','-lW',file]).splitlines():
                    if line.strip().startswith('LOAD'):
                        assert int(line.split()[-1],16)>=16384,(entry.filename,line)
    print(f'All APK native libraries are 16 KB compatible: {path}')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode',choices=['deps','fetch','build','refresh','verify','embed-ios','xcframeworks','verify-apk'])
    parser.add_argument('--platform',choices=['android','ios','all'],default='all')
    parser.add_argument('--target',choices=TARGETS)
    parser.add_argument('--jobs',type=int,default=min(os.cpu_count() or 4,8))
    parser.add_argument('--apk',type=Path)
    args=parser.parse_args()
    if args.mode=='verify-apk':
        assert args.apk, '--apk is required'
        return verify_apk(args.apk)
    if args.mode=='embed-ios': return embed_ios()
    if args.mode=='fetch': return fetch()
    if args.mode=='xcframeworks': return xcframeworks()
    if args.mode=='refresh':
        if args.platform == 'all':
            refresh('android')
            refresh('ios')
        else:
            refresh(args.platform)
        return
    keys=[args.target] if args.target else [k for k,v in TARGETS.items() if args.platform in ('all',v[0])]
    for key in keys:
        if args.mode=='deps':
            _,_,target,_,_,env=configuration(key)
            run([env['CC'],'--version']);print(target)
        elif args.mode=='build': build(key,args.jobs)
        else: verify(key)
    if args.mode=='build' and args.platform in ('all','ios') and not args.target: xcframeworks()

if __name__=='__main__': main()
