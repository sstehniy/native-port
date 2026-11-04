"""Build-input checks using synthetic data, without game files or GPU execution."""
import hashlib
from pathlib import Path
import struct
import tempfile
import unittest

from package_reader import package_entries
from recomp_pipelines import generate


class BuildInputs(unittest.TestCase):
    def test_package_directory_and_bounds(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'assets.package'
            header = bytearray(64)
            header[:8] = b'simp\x01\0\0\0'
            struct.pack_into('<Q', header, 16, 67)
            directory = bytearray(64)
            directory[:8] = b'toc!\0\0\0\0'
            struct.pack_into('<Q', directory, 8, 1)
            entry = struct.pack('<I', 5) + b'asset' + struct.pack('<BQQ', 0, 3, 64)
            path.write_bytes(header + b'abc' + directory + entry)
            self.assertEqual(package_entries(path), {'asset': (64, 3)})
            invalid = bytearray(path.read_bytes())
            struct.pack_into('<Q', invalid, len(invalid) - 8, 1)
            path.write_bytes(invalid)
            with self.assertRaises(AssertionError):
                package_entries(path)

    def test_pipeline_rebuild_and_corrupt_shader(self):
        with tempfile.TemporaryDirectory() as folder:
            inputs = Path(folder)
            root = b'synthetic root signature'
            shader = b'synthetic compute shader'
            keys = [hashlib.sha256(data).hexdigest() for data in (root, shader)]
            for key, data in zip(keys, (root, shader), strict=True):
                (inputs / (key + '.dxbc')).write_bytes(data)
            recipe = {'roots': [keys[0]], 'states': [{'size': 56, 'words': {'12': 7}}],
                      'pipelines': [{'kind': 'compute', 'root': 0, 'state': 0, 'cs': keys[1]}]}
            rows = generate(recipe, inputs)['records']
            self.assertEqual(bytes.fromhex(rows[0]['blob']), root)
            self.assertEqual(rows[1]['root'], rows[0]['object'])
            self.assertEqual(bytes.fromhex(rows[1]['cs']), shader)
            self.assertEqual(struct.unpack_from('<I', bytes.fromhex(rows[1]['desc']), 48), (7,))
            (inputs / (keys[1] + '.dxbc')).write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'content hash'):
                generate(recipe, inputs)

    def test_invalid_pipeline_layout(self):
        recipe = {'roots': [], 'states': [{'size': 12, 'words': {}}],
                  'pipelines': [{'kind': 'compute', 'state': 0, 'root': 0}]}
        with self.assertRaisesRegex(ValueError, 'descriptor'):
            generate(recipe, Path('/unused'))


if __name__ == '__main__':
    unittest.main()
