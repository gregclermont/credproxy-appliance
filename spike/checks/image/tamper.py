#!/usr/bin/env python3
"""Changed copies of an appliance image, for fail-closed boot tests.

usage: tamper.py DIR KIND     change DIR/cpvm.raw or DIR/dkb/kernel.cmdline in
                              place (DIR is a copy), print what was changed
       tamper.py --expect KIND
                              print the console line (extended regex) that
                              proves the boot refused the change for the
                              expected reason
       tamper.py --list       print the kinds

The image: GPT, partition 1 the erofs root (the verity data), partition 2 its
veritysetup hash device (superblock in block 0, tree from block 1).
"""
import os
import struct
import sys
import uuid
import zlib

V = r'device-mapper: verity: [0-9:]+: '
F = r'cpvm-initramfs: FATAL: '
KINDS = {
    # verity data and tree: caught by dm-verity itself
    'start': ('1 MiB of random bytes at the start of partition 1', V + r'data block 0 is corrupted'),
    'mid': ('1 MiB of random bytes in the middle of partition 1', V + r'data block [0-9]+ is corrupted'),
    'hashblock': ('4 KiB of random bytes over hash block 1 (top of the tree)', V + r'metadata block [0-9]+ is corrupted'),
    'salt': ('one bit of the salt in the hash superblock', V + r'metadata block [0-9]+ is corrupted'),
    # hash superblock fields: checked by the initramfs
    'alg': ('hash algorithm sha1 in the superblock', F + r'/dev/vda2: hash algorithm is not sha256'),
    'version': ('superblock version 2', F + r'/dev/vda2: verity superblock version or hash type is not 1'),
    'dbs': ('data block size 8192 in the superblock', F + r'/dev/vda2: block sizes are not 4096'),
    'salt0': ('salt size 0 in the superblock', F + r'/dev/vda2: salt size 0( |$)'),
    'salt300': ('salt size 300 in the superblock', F + r'/dev/vda2: salt size 300( |$)'),
    'nb50': ('superblock data block count minus 50', F + r'verity covers [0-9]+ blocks, the root filesystem has [0-9]+'),
    'nb+1': ('superblock data block count plus 1', F + r'verity covers [0-9]+ blocks, the root filesystem has [0-9]+'),
    'nb+4096': ('superblock data block count plus 4096, partition 1 grown to hold them (GPT checksums updated)',
                F + r'verity covers [0-9]+ blocks, the root filesystem has [0-9]+'),
    # partition table
    'guid': ("one bit of partition 1's unique GUID (GPT checksums updated)", F + r'/dev/vda: partitions [0-9a-f]+ [0-9a-f]+ are not those of roothash='),
    'p1shift': ('partition 1 moved 8 sectors on (GPT checksums updated)', V + r'data block 0 is corrupted'),
    'p1shrink': ('partition 1 shrunk below the data block count (GPT checksums updated)', F + r'/dev/vda2: [0-9]+ data blocks do not fit /dev/vda1'),
    'p2overlap': ('partition 2 moved inside partition 1 (GPT checksums updated)', F + r'/dev/vda2: no verity superblock'),
    'p2shrink': ('partition 2 shrunk to its superblock (GPT checksums updated)', F + r'dm-verity table for /dev/vda1 /dev/vda2'),
    # the kernel falls back to the backup GPT only with "gpt" on its command
    # line: a broken primary leaves no partitions at all
    'gptbackup': ('primary GPT header checksum broken, backup GPT with partition 1 moved 8 sectors',
                  F + r'no block device /dev/vda1'),
    # without a protective MBR the kernel ignores the GPT and uses the MBR
    'mbr': ('the protective MBR replaced by an ordinary one, partition 1 moved 8 sectors',
            F + r'/dev/vda: partition 1 in use is not the one the primary GPT describes'),
    # kernel command line
    'roothash': ('last digit of roothash= changed', F + r'/dev/vda: partitions [0-9a-f]+ [0-9a-f]+ are not those of roothash='),
    'rh-guid': ('last digit of roothash= changed, partition 2 GUID made to match (GPT checksums updated)', V + r'metadata block [0-9]+ is corrupted'),
    'rh-none': ('the roothash= word renamed', F + r'need exactly one roothash= on the kernel command line, found 0'),
    'rh-empty': ('roothash= empty', F + r'roothash= has 0 hex digits, not 64'),
    'rh-short': ('roothash= with 63 digits', F + r'roothash= has 63 hex digits, not 64'),
    'rh-upper': ('roothash= in uppercase', F + r'roothash= is not lowercase hex'),
    'rh-dup': ('roothash= given twice', F + r'need exactly one roothash= on the kernel command line, found 2'),
}


class Disk:
    def __init__(self, path):
        self.f = open(path, 'r+b')
        self.size = os.fstat(self.f.fileno()).st_size

    def get(self, off, n):
        self.f.seek(off)
        return self.f.read(n)

    def put(self, off, b):
        self.f.seek(off)
        self.f.write(b)

    def gpt(self, hdr_lba=1):
        h = hdr_lba * 512
        elba, n, sz = struct.unpack('<QII', self.get(h + 72, 16))
        return h, elba * 512, n, sz

    def entry(self, i, hdr_lba=1):
        _, e, _, sz = self.gpt(hdr_lba)
        o = e + i * sz
        first, last = struct.unpack('<QQ', self.get(o + 32, 16))
        return o, first, last

    def set_extent(self, i, first, last, hdr_lba=1):
        o, _, _ = self.entry(i, hdr_lba)
        self.put(o + 32, struct.pack('<QQ', first, last))

    def fix_crcs(self, hdr_lba=1):
        h, e, n, sz = self.gpt(hdr_lba)
        self.put(h + 88, struct.pack('<I', zlib.crc32(self.get(e, n * sz))))
        hs = struct.unpack('<I', self.get(h + 12, 4))[0]
        self.put(h + 16, b'\0' * 4)
        self.put(h + 16, struct.pack('<I', zlib.crc32(self.get(h, hs))))

    def backup_lba(self):
        return struct.unpack('<Q', self.get(512 + 32, 8))[0]


def main():
    if sys.argv[1:2] == ['--list']:
        print(' '.join(KINDS))
        return
    if sys.argv[1:2] == ['--expect']:
        print(KINDS[sys.argv[2]][1])
        return
    d, k = sys.argv[1], sys.argv[2]
    if k not in KINDS:
        sys.exit(f'unknown kind {k}; kinds: {" ".join(KINDS)}')
    cl_path = os.path.join(d, 'dkb', 'kernel.cmdline')
    cl = open(cl_path).read().split()
    rh = next(a[9:] for a in cl if a.startswith('roothash='))
    disk = Disk(os.path.join(d, 'cpvm.raw'))
    _, s1, e1 = disk.entry(0)
    o2, s2, e2 = disk.entry(1)
    h = s2 * 512
    nb = struct.unpack('<Q', disk.get(h + 72, 8))[0]

    def cmdline(new):
        open(cl_path, 'w').write(' '.join(new) + '\n')

    def rh_other():
        return rh[:63] + ('1' if rh[63] == '0' else '0')

    if k == 'start':
        disk.put(s1 * 512, os.urandom(1 << 20))
    elif k == 'mid':
        disk.put((s1 + (e1 - s1 + 1) // 2) * 512, os.urandom(1 << 20))
    elif k == 'hashblock':
        disk.put(h + 4096, os.urandom(4096))
    elif k == 'salt':
        disk.put(h + 88, bytes([disk.get(h + 88, 1)[0] ^ 1]))
    elif k == 'alg':
        disk.put(h + 32, b'sha1'.ljust(32, b'\0'))
    elif k == 'version':
        disk.put(h + 8, struct.pack('<I', 2))
    elif k == 'dbs':
        disk.put(h + 64, struct.pack('<I', 8192))
    elif k == 'salt0':
        disk.put(h + 80, struct.pack('<H', 0))
    elif k == 'salt300':
        disk.put(h + 80, struct.pack('<H', 300))
    elif k in ('nb50', 'nb+1', 'nb+4096'):
        new = {'nb50': nb - 50, 'nb+1': nb + 1, 'nb+4096': nb + 4096}[k]
        disk.put(h + 72, struct.pack('<Q', new))
        if k == 'nb+4096':
            end = max(e1, s1 + new * 8 - 1)
            disk.set_extent(0, s1, end)
            disk.fix_crcs()
            if (end + 2048) * 512 > disk.size:
                disk.f.truncate((end + 2048) * 512)
        print(f'data blocks {nb} -> {new}')
    elif k == 'guid':
        o1, _, _ = disk.entry(0)
        disk.put(o1 + 16, bytes([disk.get(o1 + 16, 1)[0] ^ 1]))
        disk.fix_crcs()
    elif k == 'p1shift':
        disk.set_extent(0, s1 + 8, e1 + 8)
        disk.fix_crcs()
    elif k == 'p1shrink':
        disk.set_extent(0, s1, s1 + nb * 8 - 9)
        disk.fix_crcs()
    elif k == 'p2overlap':
        disk.set_extent(1, s1 + 2048, s1 + 2048 + (e2 - s2))
        disk.fix_crcs()
    elif k == 'p2shrink':
        disk.set_extent(1, s2, s2 + 7)
        disk.fix_crcs()
    elif k == 'gptbackup':
        b = disk.backup_lba()
        disk.set_extent(0, s1 + 8, e1 + 8, hdr_lba=b)
        disk.fix_crcs(hdr_lba=b)
        c = disk.get(512 + 16, 4)
        disk.put(512 + 16, bytes([c[0] ^ 1]) + c[1:])
        print(f'backup GPT at LBA {b}')
    elif k == 'mbr':
        def ent(start, n):
            return bytes([0, 0, 0, 0, 0x83, 0, 0, 0]) + struct.pack('<II', start, n)
        disk.put(446, ent(s1 + 8, e1 - s1 + 1) + ent(s2, e2 - s2 + 1) + b'\0' * 32 + b'\x55\xaa')
    elif k == 'roothash':
        cmdline([('roothash=' + rh_other()) if a.startswith('roothash=') else a for a in cl])
    elif k == 'rh-guid':
        r = rh_other()
        cmdline([('roothash=' + r) if a.startswith('roothash=') else a for a in cl])
        disk.put(o2 + 16, uuid.UUID(r[32:]).bytes_le)
        disk.fix_crcs()
    elif k == 'rh-none':
        cmdline([('x' + a) if a.startswith('roothash=') else a for a in cl])
    elif k == 'rh-empty':
        cmdline([('roothash=') if a.startswith('roothash=') else a for a in cl])
    elif k == 'rh-short':
        cmdline([('roothash=' + rh[1:]) if a.startswith('roothash=') else a for a in cl])
    elif k == 'rh-upper':
        cmdline([('roothash=' + rh.upper()) if a.startswith('roothash=') else a for a in cl])
    elif k == 'rh-dup':
        cmdline(cl + ['roothash=' + rh])
    disk.f.close()
    print(f'{k}: {KINDS[k][0]}')


main()
