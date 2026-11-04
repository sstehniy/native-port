"""Inspect the shipped shader-v63 payload layout recovered from 0x14019ef40 onward."""
import struct


def parse(data):
    position = 0

    def take(size):
        nonlocal position
        assert size <= len(data) - position
        result = data[position:position + size]
        position += size
        return result

    def read(fmt):
        return struct.unpack(fmt, take(struct.calcsize(fmt)))

    def string():
        n, = read('<H')
        return take(n).decode()

    prefix_length, shader_index, component_mask, shader_hash, stage_count = read('<BIBIB')
    pipeline = take(44)
    count, = read('<H')
    parameters = []
    for _ in range(count):
        record = take(48)
        array, offset, size = struct.unpack_from('<3i', record)
        kind, = struct.unpack_from('<Q', record, 16)
        default = take(16)
        text = [string() for _ in range(7)]
        parameters.append(dict(name=text[1], kind=kind, array_count=array, offset=offset, size=size,
                               default_hex=default.hex(), text=text, record_hex=record.hex()))
    counts = read('<6B')
    textures = [string() for _ in range(counts[0])]
    samplers = [read('<I')[0] for _ in range(counts[5])]
    count, = read('<H')
    resources = []
    for _ in range(count):
        hash_value, = read('<I')
        name = take(32).split(b'\0', 1)[0].decode()
        index, kind, array = read('<3Q')
        resources.append(dict(hash=hash_value, name=name, index=index, kind=kind, array_size=array))
    count, = read('<H')
    constants = [read('<IHHB3x') for _ in range(count)]
    size, = read('<I')
    default_constants = take(size)
    count, = read('<H')
    constant_map = [read('<IH') for _ in range(count)]
    dims = read('<3H')
    signature_offset = position
    signature = take(90936)
    count, = read('<H')
    asserts = []
    for _ in range(count):
        ident, = read('<I')
        main_file, file = string(), string()
        line, = read('<I')
        asserts.append(dict(id=ident, main_file=main_file, file=file, line=line))
    sizes = read('<4Q')
    bytecodes = []
    for size in sizes:
        offset = position
        blob = take(size)
        assert not blob or blob[:4] == b'DXBC'
        bytecodes.append(dict(offset=offset, size=size))
    size, = read('<Q')
    root_offset = position
    root = take(size)
    assert not root or root[:4] == b'DXBC'
    assert position == len(data), (position, len(data))
    return dict(prefix_length=prefix_length, shader_index=shader_index, component_mask=component_mask, shader_hash=shader_hash,
                stage_count=stage_count, pipeline_hex=pipeline.hex(), parameters=parameters, counts=counts,
                textures=textures, samplers=samplers, resources=resources, constants=constants,
                default_constants_hex=default_constants.hex(), constant_map=constant_map, compute_dims=dims,
                signature_offset=signature_offset, signature_bytes=len(signature), asserts=asserts, bytecodes=bytecodes,
                root_offset=root_offset, root_size=len(root))
