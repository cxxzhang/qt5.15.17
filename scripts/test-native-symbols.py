#!/usr/bin/env python3
"""Exercise PE/PDB identities without depending on installed debugging tools."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('symbols', Path(__file__).with_name('native-symbols.py'))
symbols = importlib.util.module_from_spec(spec)
spec.loader.exec_module(symbols)


class PdbIdentity(unittest.TestCase):
    def test_information_stream_in_separate_msf_page(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'test.pdb'
            data = bytearray(4096 * 5)
            data[:32] = b'Microsoft C/C++ MSF 7.00\r\n\x1aDS\0\0\0'
            struct.pack_into('<6I', data, 32, 4096, 1, 5, 16, 0, 1)
            struct.pack_into('<I', data, 4096, 2)
            struct.pack_into('<4I', data, 8192, 2, 0, 28, 3)
            struct.pack_into('<3I', data, 12288, 20000404, 0, 7)
            data[12300:12316] = bytes(range(16))
            path.write_bytes(data)
            self.assertEqual(symbols.pdb_identity(path), dict(guid=bytes(range(16)).hex(), age=7))

    def test_rejects_non_pdb(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'bad.pdb'
            path.write_bytes(b'wrong file')
            with self.assertRaisesRegex(ValueError, 'Unsupported PDB'):
                symbols.pdb_identity(path)

    def test_rejects_invalid_pe(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'bad.dll'
            path.write_bytes(b'wrong file')
            with self.assertRaisesRegex(ValueError, 'Invalid PE'):
                symbols.pe_identity(path)


if __name__ == '__main__':
    unittest.main()
