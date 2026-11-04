"""Build the native shader catalog from every shipped package entry. Outputs stay ignored."""
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import ctypes
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess

from recomp_paths import GAME_EXE, ROOT
from shader_layout import parse
from package_reader import package_entries

OUT=ROOT/'build/recomp/shaders'
PACKAGE=GAME_EXE.parent/'data/shaders.package'
CONVERTER=Path(os.environ.get('SS_METAL_CONVERTER', '/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64/apple_gptk/external/D3DMetal.framework/Versions/A/Resources/libmetalirconverter.dylib'))
FLAGS=0x130


def digest(data):
    return hashlib.sha256(data).hexdigest()


def extract():
    entries=package_entries(PACKAGE)
    package=PACKAGE.read_bytes()
    lz4=ctypes.CDLL('/opt/homebrew/lib/liblz4.dylib').LZ4_decompress_safe
    lz4.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_int,ctypes.c_int];lz4.restype=ctypes.c_int
    inputs=OUT/'inputs';inputs.mkdir(parents=True,exist_ok=True)
    jobs={};catalog=[]
    for name,(offset,size) in entries.items():
        raw=package[offset:offset+size]
        kind,version,flags,header,decoded=struct.unpack_from('<4HI',raw)
        assert kind==2 and version==63 and header==24 and flags&1,(name,raw[:24].hex())
        assert 24<=decoded<=16*1024*1024
        target=ctypes.create_string_buffer(decoded-24)
        assert lz4(raw[24:],target,size-24,decoded-24)==decoded-24,name
        payload=target.raw
        metadata=parse(payload)
        root=payload[metadata['root_offset']:metadata['root_offset']+metadata['root_size']]
        assert not root or root[:4]==b'DXBC',name
        root_hash=digest(root);root_path=inputs/(root_hash+'.dxbc')
        if root:root_path.write_bytes(root)
        stages=[]
        for stage,blob in zip(('vertex','pixel','compute','geometry'),metadata['bytecodes']):
            if not blob['size']:continue
            assert root,name
            data=payload[blob['offset']:blob['offset']+blob['size']]
            assert stage!='geometry' and data[:4]==b'DXBC',(name,stage)
            shader_hash=digest(data);shader_path=inputs/(shader_hash+'.dxbc');shader_path.write_bytes(data)
            variants={}
            for mask in ((0,1) if stage=='pixel' else (0,)):
                key=digest(bytes.fromhex(root_hash+shader_hash)+struct.pack('<II',FLAGS,mask))
                jobs[key]=(key,str(shader_path),str(root_path),str(FLAGS),str(mask))
                variants[str(mask)]=key
            stages.append({'stage':stage,'shader_sha256':shader_hash,'variants':variants})
        catalog.append({'name':name,'root_sha256':root_hash,'threads':metadata['compute_dims'],'stages':stages})
    assert catalog and len(catalog)==len(entries) and any(row['stages'] for row in catalog)
    result={'version':1,'package_sha256':digest(package),'converter_sha256':digest(CONVERTER.read_bytes()),
            'gpu_family':1007,'deployment':'26.0.0','compatibility_flags':FLAGS,'entries':catalog}
    (OUT/'catalog.json').write_text(json.dumps(result,indent=2)+'\n')
    (OUT/'jobs.tsv').write_text(''.join('\t'.join(row)+'\n' for row in jobs.values()))
    print('Extracted',len(catalog),'entries,',sum(len(row['stages']) for row in catalog),'shader stages,',len(jobs),'unique conversions',flush=True)
    return result,list(jobs.values())


def convert(jobs):
    binary=OUT/'convert-shaders';cache=OUT/'cache';cache.mkdir(exist_ok=True)
    subprocess.run(['clang++','-arch','x86_64','-std=c++20','-O2','-Wall','-Wextra','-Werror',
                    str(ROOT/'tools/recomp_convert_shaders.cpp'),str(CONVERTER),'-Wl,-rpath,'+str(CONVERTER.parent),'-o',str(binary)],check=True)
    def batch(rows):
        result=subprocess.run([str(binary),str(cache)],input=''.join('\t'.join(row)+'\n' for row in rows),capture_output=True,text=True)
        records=[line.split('\t') for line in result.stdout.splitlines()]
        assert len(records)==len(rows),(result.returncode,result.stderr[-3000:])
        return records,result.stderr
    chunks=[jobs[i:i+32] for i in range(0,len(jobs),32)]
    results=[]
    with ThreadPoolExecutor(max_workers=4) as pool:
        for records,errors in pool.map(batch,chunks):
            results.extend(records)
            with (OUT/'converter.log').open('a') as log:log.write(errors)
            print('Converted',len(results),'/',len(jobs),dict(Counter(row[1] for row in results)),flush=True)
    (OUT/'status.json').write_text(json.dumps(results,indent=2)+'\n')
    assert len(results)==len(jobs) and all(row[1]=='ok' for row in results),Counter(row[1] for row in results)
    for key,status,error in results:
        assert (cache/(key+'.metallib')).read_bytes()[:4]==b'MTLB',key
        reflection=json.loads((cache/(key+'.json')).read_text())
        assert reflection,key
    return results


def verify(jobs):
    from recomp_paths import GRAPHICS_INCLUDES
    roots=sorted({row[2] for row in jobs})
    oracle=OUT/'root-oracle'
    subprocess.run(['clang++','-arch','x86_64','-std=c++20','-O2','-Wall','-Wextra','-Werror',str(ROOT/'tools/recomp_root_signature_oracle.cpp'),str(CONVERTER),'-Wl,-rpath,'+str(CONVERTER.parent),'-o',str(oracle)],check=True)
    output=subprocess.check_output([str(oracle),*roots],text=True,timeout=120)
    (OUT/'root-layouts.jsonl').write_text(output)
    layouts=dict(zip(roots,[json.loads(line)['resources'] for line in output.splitlines()],strict=True))
    types=('Table','Constant','CBV','SRV','UAV','Sampler','Invalid')
    for key,shader,root,flags,mask in jobs:
        reflection=json.loads((OUT/'cache'/(key+'.json')).read_text())
        actual=[(r['Type'],r['Space'],r['Slot'],r['EltOffset'],r['Size']) for r in reflection['TopLevelArgumentBuffer']]
        expected=[(types[r['type']],r['space'],r['slot'],r['offset'],r['bytes']) for r in layouts[root]]
        assert actual==expected,key
    binary=OUT/'shader-check'
    subprocess.run(['clang++','-arch','arm64','-std=c++20','-fobjc-arc','-fno-exceptions','-fno-rtti','-O1','-Wall','-Wextra','-Werror',*GRAPHICS_INCLUDES,str(ROOT/'runtime/shader_cache.mm'),str(ROOT/'tools/recomp_shader_check.mm'),'-framework','Metal','-framework','Foundation','-o',str(binary)],check=True)
    with (OUT/'native-check.log').open('w') as log:
        result=subprocess.run([str(binary),str(OUT/'jobs.tsv')],env=dict(os.environ,SS_SHADER_CACHE=str(OUT/'cache'),MTL_DEBUG_LAYER='1'),stdout=log,stderr=subprocess.STDOUT,timeout=180)
    assert result.returncode==0,(OUT/'native-check.log').read_text()[-3000:]
    summary={'passed':True,'unique_root_layouts':len(roots),'reflection_layouts':len(jobs),'native_libraries':len(jobs),'file_descriptor_budget':256,'runtime_shader_compiler':False}
    (OUT/'verification.json').write_text(json.dumps(summary,indent=2)+'\n')
    print('Shader libraries, entry points and independent root layouts passed',flush=True)


if __name__=='__main__':
    assert __debug__,'Run without -O'
    OUT.mkdir(parents=True,exist_ok=True)
    catalog,jobs=extract();convert(jobs)
    from recomp_specialize_shaders import build
    build();verify(jobs)
