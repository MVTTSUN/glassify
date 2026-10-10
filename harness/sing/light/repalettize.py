"""Glassify's light voice model: Karaoke's separator-ane.mlmodelc with its 6-bit palettes cut to 4 bits.

The model (Mel-Band RoFormer, KimberleyJensen's checkpoint, MIT; Vitrine's Neural Engine export, MIT) keeps every
weight as a constexpr_lut_to_dense: uint6 indices into a fp16 look-up table of 64 values per group of output channels.
This rewrites each table to 16 values, a weighted 1-D k-means over the 64 (weighted by how many weights use each), and
the indices to uint4, then writes a new weight.bin and model.mil beside the untouched coremldata.bin and metadata.json.
The graph, its shapes and its compute are the model's own; only the weights are coarser and a third smaller, and
Karaoke then loads one copy of it on the Neural Engine (Shared/Sing).

    python3 -I repalettize.py <separator-ane.mlmodelc> <out.mlmodelc> [--check]

--check re-encodes at 6 bits instead and asserts weight.bin comes out byte for byte, which proves the blob layout and
the bit packing this script assumes.

Blob storage (MIL weight.bin, version 2): a 64-byte header (uint32 count, uint32 version), then for each blob a 64-byte
metadata (uint32 0xDEADBEEF, uint32 dtype, uint64 size in bytes, uint64 data offset) at the offset model.mil names,
its data at the data offset, everything 64-byte aligned. Sub-byte values are packed least significant bit first.
"""
import re
import struct
import sys
from pathlib import Path

import numpy as np

SENTINEL = 0xDEADBEEF
ALIGN = 64
# MIL's BlobDataType for the two index widths (the 6-bit one is checked against the file).
DTYPE_UINT4, DTYPE_UINT6 = 11, 13

OP = re.compile(
    r'constexpr_lut_to_dense\(indices = tensor<uint6, \[([0-9, ]+)\]>\(BLOBFILE\(path = string\("@model_path/weights/weight\.bin"\), '
    r'offset = uint64\((\d+)\)\)\), lut = tensor<fp16, \[([0-9, ]+)\]>\(BLOBFILE\(path = string\("@model_path/weights/weight\.bin"\), '
    r'offset = uint64\((\d+)\)\)\)\)')
BLOB = re.compile(r'BLOBFILE\(path = string\("@model_path/weights/weight\.bin"\), offset = uint64\((\d+)\)\)')


def shape(text):
    return [int(x) for x in text.split(',')]


def read_blob(data, offset):
    sentinel, dtype, size, start = struct.unpack_from('<IIQQ', data, offset)
    assert sentinel == SENTINEL, f'no blob at {offset}'
    return dtype, data[start:start + size]


def unpack(raw, bits, count):
    """Sub-byte values packed least significant bit first."""
    b = np.unpackbits(np.frombuffer(raw, np.uint8), bitorder='little')[:count * bits]
    return (b.reshape(count, bits) * (1 << np.arange(bits))).sum(1).astype(np.uint8)


def pack(values, bits):
    b = ((values[:, None] >> np.arange(bits)) & 1).astype(np.uint8).ravel()
    return np.packbits(b, bitorder='little').tobytes()


def kmeans_1d(values, weights, k, iterations=60):
    """Weighted 1-D k-means of `values` into k centres; returns (centres, label of each value)."""
    order = np.argsort(values)
    v, w = values[order].astype(np.float64), weights[order].astype(np.float64) + 1e-9
    # Start at weighted quantiles, so busy regions of the palette keep their resolution.
    cw = np.cumsum(w) / w.sum()
    centres = np.interp((np.arange(k) + 0.5) / k, cw, v)
    for _ in range(iterations):
        labels = np.abs(v[:, None] - centres[None, :]).argmin(1)
        new = centres.copy()
        for j in range(k):
            m = labels == j
            if m.any():
                new[j] = (v[m] * w[m]).sum() / w[m].sum()
        if np.allclose(new, centres):
            break
        centres = new
    labels = np.abs(v[:, None] - centres[None, :]).argmin(1)
    out = np.empty_like(labels)
    out[order] = labels
    return centres, out


def main():
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    check = '--check' in sys.argv
    mil = (src / 'model.mil').read_text()
    data = (src / 'weights/weight.bin').read_bytes()

    count, version = struct.unpack_from('<II', data, 0)
    assert version == 2, version
    ops = {int(m.group(2)): m for m in OP.finditer(mil)}
    lut_offsets = {int(m.group(4)) for m in ops.values()}
    all_offsets = sorted({int(x) for x in BLOB.findall(mil)})
    assert len(all_offsets) == count, (len(all_offsets), count)

    bits = 6 if check else 4
    k = 1 << bits
    out = bytearray(ALIGN)
    struct.pack_into('<II', out, 0, count, version)
    moved = {}
    error_num = error_den = 0.0

    def append(dtype, payload):
        meta = len(out)
        start = meta + ALIGN
        header = bytearray(ALIGN)
        struct.pack_into('<IIQQ', header, 0, SENTINEL, dtype, len(payload), start)
        out.extend(header)
        out.extend(payload)
        out.extend(b'\0' * (-len(out) % ALIGN))
        return meta

    replaced_luts = {}
    for offset in all_offsets:
        if offset in lut_offsets:
            continue   # written with its indices
        dtype, payload = read_blob(data, offset)
        m = ops.get(offset)
        if not m:
            moved[offset] = append(dtype, bytes(payload))
            continue
        assert dtype == DTYPE_UINT6, f'indices at {offset} are dtype {dtype}'
        ishape, lshape = shape(m.group(1)), shape(m.group(3))
        n = int(np.prod(ishape))
        idx = unpack(payload, 6, n)
        _, lraw = read_blob(data, int(m.group(4)))
        lut = np.frombuffer(lraw, np.float16).reshape(lshape)
        groups = lshape[0]
        lut2 = lut.reshape(groups, 64)
        idx_g = idx.reshape(groups, -1)   # output channels grouped along the first axis
        if check:
            new_idx, new_lut = idx, lut.copy()
        else:
            new_lut = np.zeros((groups, k), np.float16)
            new_idx_g = np.empty_like(idx_g)
            for g in range(groups):
                counts = np.bincount(idx_g[g], minlength=64)
                centres, labels = kmeans_1d(lut2[g].astype(np.float32), counts, k)
                new_lut[g] = centres.astype(np.float16)
                new_idx_g[g] = labels[idx_g[g]]
                dense_old = lut2[g][idx_g[g]].astype(np.float64)
                dense_new = new_lut[g][new_idx_g[g]].astype(np.float64)
                error_num += ((dense_old - dense_new) ** 2).sum()
                error_den += (dense_old ** 2).sum()
            new_idx = new_idx_g.ravel()
            new_lut = new_lut.reshape(lshape[:-2] + [k, lshape[-1]])
        moved[offset] = append(DTYPE_UINT6 if check else DTYPE_UINT4, pack(new_idx, bits))
        replaced_luts[int(m.group(4))] = append(1, new_lut.astype(np.float16).tobytes())   # 1: fp16

    moved.update(replaced_luts)
    # The last blob's data ends the file, with no padding after it.
    while len(out) % ALIGN and out[-1] == 0:
        out.pop()
    last = max(moved.values())
    _, _, size, start = struct.unpack_from('<IIQQ', out, last)
    del out[start + size:]
    if check:
        assert bytes(out) == data, 'the re-encoded weight.bin differs: the layout or the packing is not understood'
        print(f'check passed: {len(ops)} palettized weights re-encode byte for byte')
        return

    def rewrite(m):
        ishape, lshape = m.group(1), shape(m.group(3))
        lshape[-2] = k
        return (f'constexpr_lut_to_dense(indices = tensor<uint4, [{ishape}]>(BLOBFILE(path = string("@model_path/weights/weight.bin"), '
                f'offset = uint64(@@{moved[int(m.group(2))]}@@))), lut = tensor<fp16, [{", ".join(map(str, lshape))}]>(BLOBFILE(path = '
                f'string("@model_path/weights/weight.bin"), offset = uint64(@@{moved[int(m.group(4))]}@@))))')
    mil = OP.sub(rewrite, mil)
    # The ops just rewritten carry their new offsets marked, so this pass moves only the other blobs.
    mil = BLOB.sub(lambda m: f'BLOBFILE(path = string("@model_path/weights/weight.bin"), offset = uint64({moved[int(m.group(1))]}))', mil)
    mil = re.sub(r'@@(\d+)@@', r'\1', mil)

    dst.mkdir(parents=True, exist_ok=True)
    (dst / 'weights').mkdir(exist_ok=True)
    (dst / 'analytics').mkdir(exist_ok=True)
    for name in ('coremldata.bin', 'metadata.json', 'analytics/coremldata.bin'):
        (dst / name).write_bytes((src / name).read_bytes())
    (dst / 'model.mil').write_text(mil)
    (dst / 'weights/weight.bin').write_bytes(bytes(out))
    print(f'{len(ops)} weights cut to {bits} bits: weight.bin {len(data) / 1e6:.1f} -> {len(out) / 1e6:.1f} MB, '
          f'relative weight error {np.sqrt(error_num / max(error_den, 1e-30)):.4f}')


if __name__ == '__main__':
    main()
