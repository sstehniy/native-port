"""Generate pipeline warmup inputs from the user's extracted shaders, without a reference capture."""
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess

from recomp_paths import D3DM_OUT, GRAPHICS_INCLUDES, ROOT

OUT = ROOT / 'build/recomp/pipelines'


def generate(recipe, inputs):
    def blob(key):
        if key is None:
            return ''
        if len(key) != 64 or any(c not in '0123456789abcdef' for c in key):
            raise ValueError('invalid shader identity')
        data = (inputs / (key + '.dxbc')).read_bytes()
        if hashlib.sha256(data).hexdigest() != key:
            raise ValueError('shader input differs from its content hash: ' + key)
        return data.hex()

    records = []
    for index, key in enumerate(recipe['roots']):
        records.append(dict(kind='root', result=0, object=index + 1, blob=blob(key)))
    for pipeline in recipe['pipelines']:
        state = recipe['states'][pipeline['state']]
        kind = pipeline['kind']
        expected = 56 if kind == 'compute' else 656
        if kind not in ('graphics', 'compute') or state['size'] != expected:
            raise ValueError('invalid D3D12 pipeline descriptor')
        raw = bytearray(expected)
        for word, value in state['words'].items():
            struct.pack_into('<I', raw, int(word) * 4, value)
        root = pipeline['root']
        if not 0 <= root < len(recipe['roots']):
            raise ValueError('invalid pipeline root')
        record = dict(kind=kind, result=0, root=root + 1, desc=raw.hex())
        if kind == 'compute':
            record['cs'] = blob(pipeline['cs'])
        else:
            record.update(vs=blob(pipeline['vs']), ps=blob(pipeline['ps']),
                          inputs=recipe['layouts'][pipeline['inputs']])
        records.append(record)
    return dict(records=records)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    recipe = json.loads((Path(__file__).with_name('pipelines.json')).read_text())
    reference = generate(recipe, ROOT / 'build/recomp/shaders/inputs')
    manifest = OUT / 'reference-summary.json'
    manifest.write_text(json.dumps(reference) + '\n')
    subprocess.run(['./d3d12-metal/build.sh'], cwd=ROOT, check=True)
    binary = OUT / 'pipeline-check'
    subprocess.run(['clang++', '-arch', 'arm64', '-std=c++20', '-fobjc-arc', '-fno-exceptions',
                    '-fno-rtti', '-O2', '-Wall', '-Wextra', '-Werror', *GRAPHICS_INCLUDES,
                    'runtime/shader_cache.mm', 'tools/recomp_pipeline_check.mm',
                    str(D3DM_OUT / 'libd3d12-metal.a'), '-framework', 'AppKit', '-framework', 'MetalFX',
                    '-framework', 'Metal', '-framework', 'QuartzCore', '-o', str(binary)], cwd=ROOT, check=True)
    env = dict(os.environ, SS_SHADER_CACHE=str(ROOT / 'build/recomp/shaders/cache'))
    subprocess.run([str(binary), str(manifest)], cwd=ROOT, env=env, check=True)


if __name__ == '__main__':
    main()
