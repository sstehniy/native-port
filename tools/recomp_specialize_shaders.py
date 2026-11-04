"""Build content-keyed Very Performance variants selected from observed buffer uploads."""
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import urllib.request

from recomp_shaders import CONVERTER, OUT, ROOT, digest

# Exact input identities also pin the scene-buffer layout (b0, space0, byte 760).
SHADERS = (
    '93c89e21cd140f53e83e7bec528a65051e81476850c978953d1dfe66ed1649cd',
    'b88c79fec7ce5447d3f433dcd41180569b7db56e26fe39e792b2f997151a1dd9',
    '5e9f7c907f8c00be6fc4aad81313281cbc5b2c02a9c001bda8c746329bb57b2c',
    'c829b7e285488603765b627a33846ada0f7682e8e3f1bd8f612b89d52f163f3d',
    'bb01867e74a736cd38e5d8855a7ee4115b02b2830e0d61c88820728eac21ee30',
    '312de4b5e21170aea45c7529f4cbfd4a3cf6225ca822d106d5bb1c3334928966',
    '65702473ad356f7846dcd5c6ecbc7e06b500842b0be0a2f942ebfeeb88164956',
)


def specialize(text):
    handles = re.findall(r'  (%\d+) = call %dx.types.Handle @dx.op.annotateHandle\(i32 216, %dx.types.Handle (%\d+), %dx.types.ResourceProperties \{ i32 13, i32 1200 \}\)', text)
    assert len(handles) == 1, 'Unexpected scene constant buffer'
    scene, original = handles[0]
    assert re.search(re.escape(original) + r' = call .*@dx.op.createHandleFromBinding\(i32 217, %dx.types.ResBind \{ i32 0, i32 0, i32 0, i8 2 \}, i32 0, i1 false\)', text)
    loads = re.findall(r'  (%\d+) = call %dx.types.CBufRet.i32 @dx.op.cbufferLoadLegacy.i32\(i32 59, %dx.types.Handle ' + re.escape(scene) + r', i32 47\)', text)
    values = []
    for load in loads:
        values += re.findall(r'  (%\d+) = extractvalue %dx.types.CBufRet.i32 ' + re.escape(load) + r', 2\b', text)
    assert values, 'No quality value to specialize'
    lines = text.splitlines()
    for value in values:
        token = re.compile(re.escape(value) + r'(?![\d.])')
        lines = [line if line.startswith('  ' + value + ' =') else token.sub('1', line) for line in lines]
    return '\n'.join(lines) + '\n'


def build():
    headers = OUT / 'dxc';headers.mkdir(exist_ok=True)
    for name, expected in (
        ('dxcapi.h', '1855295d3e9ed604a8f2b9dbd415a9d8f39f9e78b386f2f46fd00615da2cdfee'),
        ('WinAdapter.h', '645600f7d2c5496a2ea187d218568f202f8661dc5150b1da665302196940267f'),
    ):
        path = headers / name
        if not path.exists():
            path.write_bytes(urllib.request.urlopen('https://raw.githubusercontent.com/microsoft/DirectXShaderCompiler/v1.8.2505.1/include/dxc/' + name, timeout=30).read())
        assert digest(path.read_bytes()) == expected, path
    helper = OUT / 'dxil'
    subprocess.run(['clang++', '-arch', 'x86_64', '-std=c++20', '-O2', '-Wall', '-Wextra', '-Werror', '-I' + str(headers),
                    str(ROOT / 'tools/recomp_dxil.cpp'), str(CONVERTER.parent / 'libdxcompiler.dylib'),
                    '-Wl,-rpath,' + str(CONVERTER.parent), '-o', str(helper)], check=True)
    jobs = {row[0]: row for line in (OUT / 'jobs.tsv').read_text().splitlines() if (row := line.split('\t'))}
    work = OUT / 'specialized';work.mkdir(exist_ok=True)
    cache = OUT / 'cache';report = []
    for key in SHADERS:
        row = jobs[key]
        source = subprocess.check_output([str(helper), 'disassemble', row[1]], text=True)
        modified = specialize(source)
        ll = work / (key + '.ll');ll.write_text(modified)
        dxbc = work / (key + '.dxbc')
        subprocess.run([str(helper), 'assemble', str(ll), str(dxbc)], check=True)
        variant = digest(bytes.fromhex(digest(Path(row[2]).read_bytes()) + digest(dxbc.read_bytes())) +
                         struct.pack('<II', int(row[3]), int(row[4])))
        subprocess.run([str(OUT / 'convert-shaders'), str(cache)],
                       input='\t'.join([variant, str(dxbc), *row[2:]]) + '\n', text=True, check=True)
        assert (cache / (variant + '.metallib')).read_bytes()[:4] == b'MTLB'
        reflection_path = cache / (key + '.json')
        reflection = json.loads(reflection_path.read_text())
        reflection.pop('specializedLibrary', None)
        reflection['specialization'] = dict(key=variant, parameter=0, index=31, offset=760, value=1)
        reflection_path.write_text(json.dumps(reflection, indent=2) + '\n')
        report.append(dict(original=key, variant=variant, original_bytes=(cache / (key + '.metallib')).stat().st_size,
                           variant_bytes=(cache / (variant + '.metallib')).stat().st_size))
    (work / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'Built {len(report)} guarded fragment variants')
    verify(helper, work)


def verify(helper, work):
    source = work / 'check.hlsl'
    source.write_text('cbuffer Scene : register(b0) { uint4 data[75]; };\n'
                      'float4 main(float4 p : SV_Position) : SV_Target { uint mode=data[47].z; '
                      'float4 color=asfloat(data[0]); if (mode==1) return color+float4(1,2,3,4); '
                      'return color+float4(float(mode),0,0,0); }\n')
    original = work / 'check.dxbc'
    subprocess.run([str(helper), 'compile', str(source), str(original)], check=True)
    text = subprocess.check_output([str(helper), 'disassemble', str(original)], text=True)
    guarded = work / 'check-guarded.ll';guarded.write_text(specialize(text))
    variant = work / 'check-guarded.dxbc'
    subprocess.run([str(helper), 'assemble', str(guarded), str(variant)], check=True)
    root = work / 'check-root.dxbc'
    words = [0x43425844, 0, 0, 0, 0, 1, 88, 1, 36, 0x30535452, 44, 1, 1, 24, 0, 44, 0, 2, 0, 36, 0, 0]
    root.write_bytes(struct.pack('<22I', *words))
    cache = work / 'check-cache';cache.mkdir(exist_ok=True)
    keys = [digest(p.read_bytes()) for p in (original, variant)]
    jobs = ''.join('\t'.join((key, str(p), str(root), '304', '0')) + '\n'
                   for key, p in zip(keys, (original, variant), strict=True))
    subprocess.run([str(OUT / 'convert-shaders'), str(cache)], input=jobs, text=True, check=True)
    check = work / 'check'
    subprocess.run(['clang++', '-arch', 'arm64', '-std=c++20', '-fobjc-arc', '-O2', '-Wall', '-Wextra', '-Werror',
                    str(ROOT / 'tools/recomp_specialize_check.mm'), '-framework', 'Metal', '-framework', 'Foundation', '-o', str(check)], check=True)
    subprocess.run([str(check), *(str(cache / key) for key in keys)], check=True,
                   env=dict(os.environ, MTL_DEBUG_LAYER='1', MTL_SHADER_VALIDATION='1', MTL_SHADER_VALIDATION_REPORT_TO_STDERR='1'))



if __name__ == '__main__':
    build()
