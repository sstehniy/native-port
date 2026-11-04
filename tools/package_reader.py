"""Read the directory of a game asset package without shipping any asset bytes."""
import struct


def package_entries(path):
    with path.open('rb') as file:
        header = file.read(64)
        assert header[:8] == b'simp\x01\0\0\0'
        toc, = struct.unpack_from('<Q', header, 16)
        file.seek(toc)
        directory = file.read()
        assert directory[:8] == b'toc!\0\0\0\0'
        count, = struct.unpack_from('<Q', directory, 8)
        position, entries = 64, {}
        for _ in range(count):
            length, = struct.unpack_from('<I', directory, position)
            position += 4
            name = directory[position:position + length].decode()
            position += length
            flags, size, offset = struct.unpack_from('<BQQ', directory, position)
            position += 17
            assert flags == 0 and name not in entries and 64 <= offset <= toc and size <= toc - offset
            entries[name] = (offset, size)
        assert position == len(directory)
        return entries
