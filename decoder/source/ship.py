#!/usr/bin/env python3
"""Helpers for build.sh, all driven by the loader's own tables (libav.SYSTEMS, EXPORTS, layout()), so the
library is built and checked against exactly what the add-on will read from it.

  ship.py systems                           the systems a decoder ships for, one a line (make.sh's default)
  ship.py target SYSTEM                     shell variables for one system (sourced by build.sh)
  ship.py layout-c SYSTEM OUT.c             a C file that fails to compile unless every offset matches
  ship.py exports SYSTEM FOLDER             the linker's export list (version script, .def or symbol list)
  ship.py check-exports SYSTEM LISTING      refuses unless the library exports exactly EXPORTS
  ship.py verify FILE SHA256                refuses unless the file has that sha256
  ship.py signed FILE SIGNATURE KEY FPR     refuses unless gpg finds FILE signed by the key with fingerprint FPR
  ship.py check-smoke FILMS.json RESULTS    refuses unless smoke.c decoded every film to its known bars
  ship.py manifest SYSTEM FOLDER LIBRARY    writes manifest.json beside the library
  ship.py built SYSTEM FOLDER               records the library's sha256 in built.json

Python 3.8 or later, standard library only (runs in the build image and on the NAS).
"""
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'addon', 'service.activeareasubtitles', 'resources', 'lib'))

from activearea import libav  # noqa: E402

PIN = os.path.join(HERE, 'pin.json')
BUILT = os.path.join(HERE, 'built.json')
# FFmpeg's release signing key (public), kept beside pin.json: make.sh verifies the archive's signature with it, and
# the signing key must be pin.json's "signed_by".
RELEASE_KEY = 'ffmpeg-devel.asc'

# What build.sh needs per system of libav.SYSTEMS, by its sys.platform and machine there: FFmpeg's target-os and arch,
# the toolchain, the threads option and the machine name layout() is computed for (every shipped system is 64-bit).
BUILDS = {
    ('linux', 'x86_64'): {'target_os': 'linux', 'arch': 'x86_64', 'toolchain': 'gcc', 'threads': 'pthreads',
                          'machine': 'x86_64'},
    ('win32', 'amd64'): {'target_os': 'mingw64', 'arch': 'x86_64', 'toolchain': 'mingw', 'threads': 'w32threads',
                         'machine': 'x86_64'},
    ('darwin', 'arm64'): {'target_os': 'darwin', 'arch': 'aarch64', 'toolchain': 'zig', 'threads': 'pthreads',
                          'machine': 'arm64', 'zig_target': 'aarch64-macos'},
    ('darwin', 'x86_64'): {'target_os': 'darwin', 'arch': 'x86_64', 'toolchain': 'zig', 'threads': 'pthreads',
                           'machine': 'x86_64', 'zig_target': 'x86_64-macos'},
}
TARGETS = {row.tag: BUILDS[row.platform, row.machine] for row in libav.SYSTEMS}

# Where each layout() key lives in FFmpeg's public headers: (structure, member as offsetof takes it).
MEMBERS = {
    'AVFormatContext.pb': ('AVFormatContext', 'pb'),
    'AVFormatContext.nb_streams': ('AVFormatContext', 'nb_streams'),
    'AVFormatContext.streams': ('AVFormatContext', 'streams'),
    'AVStream.codecpar': ('AVStream', 'codecpar'),
    'AVStream.disposition': ('AVStream', 'disposition'),
    'AVStream.discard': ('AVStream', 'discard'),
    'AVStream.metadata': ('AVStream', 'metadata'),
    'AVCodecParameters.codec_type': ('AVCodecParameters', 'codec_type'),
    'AVCodecParameters.codec_id': ('AVCodecParameters', 'codec_id'),
    'AVPacket.pts': ('AVPacket', 'pts'),
    'AVPacket.dts': ('AVPacket', 'dts'),
    'AVPacket.stream_index': ('AVPacket', 'stream_index'),
    'AVFrame.data': ('AVFrame', 'data'),
    'AVFrame.linesize': ('AVFrame', 'linesize'),
    'AVFrame.width': ('AVFrame', 'width'),
    'AVFrame.height': ('AVFrame', 'height'),
    'AVFrame.format': ('AVFrame', 'format'),
    'AVFrameSideData.data': ('AVFrameSideData', 'data'),
    'AVDictionaryEntry.value': ('AVDictionaryEntry', 'value'),
    'AVIOContext.buffer': ('AVIOContext', 'buffer'),
    'AVDOVIDmData.level': ('AVDOVIDmData', 'level'),
    'AVDOVIDmLevel5.left_offset': ('AVDOVIDmData', 'l5.left_offset'),
    'AVDOVIDmLevel5.right_offset': ('AVDOVIDmData', 'l5.right_offset'),
    'AVDOVIDmLevel5.top_offset': ('AVDOVIDmData', 'l5.top_offset'),
    'AVDOVIDmLevel5.bottom_offset': ('AVDOVIDmData', 'l5.bottom_offset'),
}
HEADERS = ('libavformat/avformat.h', 'libavformat/avio.h', 'libavcodec/avcodec.h', 'libavcodec/packet.h',
           'libavutil/frame.h', 'libavutil/dict.h', 'libavutil/dovi_meta.h')


def pin(path=PIN):
    with open(path, encoding='utf-8') as handle:
        return json.load(handle)


def file_name(system_name):
    library = libav.library_name(system_name)
    if library is None:
        raise SystemExit('no such system: %s' % system_name)
    return library


def macos_minimum(system_name):
    return next((row.macos_minimum for row in libav.SYSTEMS if row.tag == system_name), None) or ''


def target_layout(system_name):
    if system_name not in TARGETS:
        raise SystemExit('no build target for %s' % system_name)
    return libav.layout(8, TARGETS[system_name]['machine'])


def target_variables(system_name):
    """Shell assignments for build.sh: everything per system that is not the one shared configure line."""
    target = TARGETS.get(system_name)
    if target is None:
        raise SystemExit('no build target for %s' % system_name)
    pinned = pin()
    values = dict(target, library=file_name(system_name), ffmpeg=pinned['ffmpeg']['version'],
                  ffmpeg_url=pinned['ffmpeg']['url'], ffmpeg_sha256=pinned['ffmpeg']['sha256'],
                  macos_minimum=macos_minimum(system_name))
    values.setdefault('zig_target', '')
    return ''.join("%s='%s'\n" % (key.upper(), str(value).replace("'", '')) for key, value in sorted(values.items()))


def layout_c(system_name):
    """Compile-time asserts for every offset the loader reads, against the headers of the tree just built: the
    compile fails on any difference, for every target alike, with nothing run. main() prints the offsets as JSON
    where the program can run."""
    expected = target_layout(system_name)
    missing = sorted(set(expected) - set(MEMBERS))
    if missing:
        raise SystemExit('layout keys with no header member: %s' % missing)
    lines = ['/* Generated by ship.py layout-c %s; do not edit. */' % system_name, '#include <stddef.h>',
             '#include <stdio.h>']
    lines += ['#include <%s>' % header for header in HEADERS]
    for key in sorted(expected):
        structure, member = MEMBERS[key]
        lines.append('_Static_assert(offsetof(%s, %s) == %d, "%s");' % (structure, member, expected[key], key))
    lines.append('int main(void) {')
    lines.append('    printf("{");')
    for index, key in enumerate(sorted(expected)):
        structure, member = MEMBERS[key]
        lines.append('    printf("%s\\"%s\\": %%d", (int) offsetof(%s, %s));'
                     % (', ' if index else '', key, structure, member))
    lines.append('    printf("}\\n");')
    lines.append('    return 0;')
    lines.append('}')
    return '\n'.join(lines) + '\n'


def export_files(system_name):
    """{file name: content} the linker takes to export exactly EXPORTS, plus roots.txt: one -u per export, which
    makes the static link pull those objects (and only what they reach)."""
    toolchain = TARGETS[system_name]['toolchain']
    names = list(libav.EXPORTS)
    if toolchain == 'mingw':
        files = {'exports.def': 'EXPORTS\n' + ''.join('    %s\n' % name for name in names)}
        roots = names
    elif toolchain == 'zig':
        files = {'exports.list': ''.join('_%s\n' % name for name in names)}
        roots = ['_' + name for name in names]
    else:
        files = {'exports.map': '{\n  global:\n%s  local: *;\n};\n' % ''.join('    %s;\n' % name for name in names)}
        roots = names
    if toolchain == 'zig':
        files['roots.txt'] = ' '.join('-Wl,-u,%s' % root for root in roots) + '\n'
    else:
        files['roots.txt'] = ' '.join('-Wl,--undefined=%s' % root for root in roots) + '\n'
    return files


def exported_names(system_name, listing):
    """The function names a symbol listing says the library exports: `nm -D --defined-only` (Linux),
    `llvm-nm -gU` (macOS, leading underscore) or `objdump -p`'s export table (Windows)."""
    toolchain = TARGETS[system_name]['toolchain']
    names = set()
    if toolchain == 'mingw':
        inside = False
        for line in listing.splitlines():
            if line.strip().startswith('[Ordinal/Name Pointer] Table'):
                inside = True
                continue
            if inside:
                parts = line.split()
                if len(parts) >= 2 and parts[0].startswith('['):
                    names.add(parts[-1])
                elif line.strip() == '' and names:
                    inside = False
        return names
    for line in listing.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] in ('T', 'D', 'B', 'R', 'S'):
            name = parts[2]
            if toolchain == 'zig':
                if not name.startswith('_'):
                    continue
                name = name[1:]
            names.add(name.split('@')[0])
    return names


# FFmpeg's own symbol prefixes. zig's macOS linker takes no export list, so a macOS library also exports FFmpeg's
# internal functions: harmless there (macOS binds every symbol to the library it came from, the add-on loads the
# decoder privately, and Kodi builds FFmpeg into its own program on macOS), so only FFmpeg's own names may be extra.
FFMPEG_PREFIXES = ('av', 'ff')
FFMPEG_SUFFIXES = ('_neon', '_neon_wrapper', '_neon_dotprod')     # libavcodec/aarch64/me_cmp_neon.S, no prefix


def check_exports(system_name, listing):
    """None when the library exports exactly EXPORTS (on macOS: all of them, and nothing but FFmpeg's own names
    besides), else what differs."""
    found = exported_names(system_name, listing)
    wanted = set(libav.EXPORTS)
    missing, extra = sorted(wanted - found), sorted(found - wanted)
    if TARGETS[system_name]['toolchain'] == 'zig':
        extra = [name for name in extra if not name.startswith(FFMPEG_PREFIXES) and not name.endswith(FFMPEG_SUFFIXES)]
    if missing or extra:
        return 'missing %s, extra %s' % (missing[:10], extra[:10])
    return None


SMOKE_ROWS = 2        # rows of bar the smoke may read differently (the encoder blurs the edge a little)


def check_smoke(films, results):
    """None when every film in films ({name: {decoder, width, height, top, bottom}}) has a result line
    ("name {json}") with its decoder, size and bars, else what went wrong."""
    seen = {}
    for line in results.splitlines():
        name, _space, rest = line.partition(' ')
        try:
            seen[name] = json.loads(rest)
        except ValueError:
            seen[name] = None
    problems = []
    for name, expected in sorted(films.items()):
        found = seen.get(name)
        if not isinstance(found, dict):
            problems.append('%s: no result' % name)
            continue
        for key in ('decoder', 'width', 'height'):
            if found.get(key) != expected[key]:
                problems.append('%s: %s %r, expected %r' % (name, key, found.get(key), expected[key]))
        for key in ('top', 'bottom'):
            if not isinstance(found.get(key), int) or abs(found[key] - expected[key]) > SMOKE_ROWS:
                problems.append('%s: %s %r, expected %r' % (name, key, found.get(key), expected[key]))
        if found.get('functions') != len(libav.EXPORTS):
            problems.append('%s: %r functions resolved' % (name, found.get('functions')))
    return '; '.join(problems) or None


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def signature_problem(status, fingerprint):
    """None when gpg's status lines (--status-fd) say the signature is valid and made by the key with this
    fingerprint, else why not."""
    valid = [line.split()[2] for line in status.splitlines()
             if line.startswith('[GNUPG:] VALIDSIG ') and len(line.split()) > 2]
    if not valid:
        said = [line.split()[1] for line in status.splitlines() if line.startswith('[GNUPG:] ') and len(line.split()) > 1]
        return 'no valid signature (gpg said: %s)' % ', '.join(said[:4])
    if fingerprint.upper() not in [found.upper() for found in valid]:
        return 'signed by another key (%s), the pinned one is %s' % (valid[0], fingerprint)
    return None


def check_signature(archive, signature, key, fingerprint):
    """gpg's verdict on the archive's detached signature, in a throwaway key ring holding only the key file."""
    import subprocess
    import tempfile
    with tempfile.TemporaryDirectory(prefix='aas-gpg-') as home:
        try:
            subprocess.run(['gpg', '--batch', '--quiet', '--homedir', home, '--import', key], check=True,
                           capture_output=True)
            status = subprocess.run(['gpg', '--batch', '--homedir', home, '--status-fd', '1', '--verify', signature,
                                     archive], capture_output=True, text=True).stdout
        except (OSError, subprocess.CalledProcessError) as error:
            return 'gpg could not run (%s)' % error
    return signature_problem(status, fingerprint)


def write_manifest(system_name, folder, library_path, toolchain_versions=None):
    pinned = pin()
    data = libav.manifest(system_name, library_path, pinned['ffmpeg']['version'], pinned['ffmpeg']['avformat_major'],
                          layout=target_layout(system_name))
    data['source'] = {'archive': os.path.basename(pinned['ffmpeg']['url']), 'sha256': pinned['ffmpeg']['sha256']}
    data['toolchain'] = toolchain_versions or {}
    path = os.path.join(folder, libav.MANIFEST)
    with open(path, 'w', encoding='utf-8') as handle:
        json.dump(data, handle, indent=1, sort_keys=True)
        handle.write('\n')
    return path


def record_built(system_name, library_path, built_path=BUILT):
    """built.json: per FFmpeg version and system, the library's sha256. Refuses a different hash for the same pin
    (a build should give the same bytes every time) unless the old record is removed by hand."""
    version = pin()['ffmpeg']['version']
    try:
        with open(built_path, encoding='utf-8') as handle:
            built = json.load(handle)
    except OSError:
        built = {}
    digest = sha256(library_path)
    known = built.setdefault(version, {}).get(system_name)
    if known and known != digest:
        raise SystemExit('%s %s built before as %s, now %s: a build should give the same bytes'
                         % (system_name, version, known, digest))
    built[version][system_name] = digest
    with open(built_path, 'w', encoding='utf-8') as handle:
        json.dump(built, handle, indent=1, sort_keys=True)
        handle.write('\n')
    return digest


def main(argv):
    if argv[1:] == ['systems']:
        print('\n'.join(row.tag for row in libav.SYSTEMS))
        return
    if len(argv) < 3:
        raise SystemExit(__doc__)
    command, system_name = argv[1], argv[2]
    if command == 'target':
        sys.stdout.write(target_variables(system_name))
    elif command == 'layout-c':
        with open(argv[3], 'w', encoding='utf-8') as handle:
            handle.write(layout_c(system_name))
    elif command == 'exports':
        for name, content in export_files(system_name).items():
            with open(os.path.join(argv[3], name), 'w', encoding='utf-8') as handle:
                handle.write(content)
    elif command == 'check-exports':
        with open(argv[3], encoding='utf-8', errors='replace') as handle:
            problem = check_exports(system_name, handle.read())
        if problem:
            raise SystemExit('exports differ: ' + problem)
    elif command == 'verify':
        if sha256(system_name) != argv[3]:
            raise SystemExit('%s does not have the pinned sha256' % system_name)
    elif command == 'signed':
        problem = check_signature(system_name, argv[3], argv[4], argv[5])
        if problem:
            raise SystemExit('%s: %s' % (system_name, problem))
        print('signature: %s signed by %s' % (os.path.basename(system_name), argv[5]))
    elif command == 'check-smoke':
        with open(argv[2], encoding='utf-8') as handle:
            films = json.load(handle)
        with open(argv[3], encoding='utf-8', errors='replace') as handle:
            problem = check_smoke(films, handle.read())
        if problem:
            raise SystemExit('smoke failed: ' + problem)
        print('smoke: %d films decoded to their known bars' % len(films))
    elif command == 'manifest':
        versions = json.loads(argv[5]) if len(argv) > 5 else {}
        write_manifest(system_name, argv[3], argv[4], versions)
    elif command == 'built':
        print(record_built(system_name, os.path.join(argv[3], file_name(system_name))))
    else:
        raise SystemExit(__doc__)


if __name__ == '__main__':
    main(sys.argv)
