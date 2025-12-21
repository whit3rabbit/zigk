#!/bin/bash
set -e

# Compile VDSO
# -fPIC for position independent code
# -shared to make it a shared object
# -target x86_64-freestanding (or linux if needed for ABI, but freestanding is safer for no-libc)
# --name vdso
# We use -rdynamic to ensure symbols are exported? No, @export handles that.

zig build-lib tools/vdso_gen/vdso.zig -target x86_64-linux-none -dynamic -O ReleaseSmall -fstrip --name vdso -z max-page-size=16

# Check if libvdso.so exists
if [ -f "libvdso.so" ]; then
    mv libvdso.so tools/vdso_gen/vdso.so
else
    echo "Could not find output so file"
    exit 1
fi


# Convert to Zig file
echo "// Auto-generated VDSO blob" > src/kernel/vdso_blob.zig
echo "pub const vdso_image = [_]u8{" >> src/kernel/vdso_blob.zig
python3 -c "import sys; d=sys.stdin.buffer.read(); print(',\n'.join([', '.join(['0x{:02x}'.format(b) for b in d[i:i+16]]) for i in range(0, len(d), 16)]))" < tools/vdso_gen/vdso.so >> src/kernel/vdso_blob.zig
echo "};" >> src/kernel/vdso_blob.zig

rm tools/vdso_gen/vdso.so
