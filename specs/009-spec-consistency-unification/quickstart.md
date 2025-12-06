# Quickstart: Cross-Specification Consistency Unification

**Feature Branch**: `009-spec-consistency-unification`
**Date**: 2025-12-05

This guide provides a step-by-step process for applying all specification amendments.

---

## Overview

This is a **documentation-only** feature. No code changes are required. The goal is to update specification documents for consistency.

**Estimated Time**: 1-2 hours
**Prerequisites**: Access to all spec files, text editor

---

## Step 1: Create Authoritative Syscall Table

Create the new file `specs/syscall-table.md`:

```bash
# Navigate to specs directory
cd specs/

# Create the syscall table (copy from contracts/amendments.md)
```

Content to copy from `contracts/amendments.md` → "New Document: syscall-table.md" section.

**Verify**:
```bash
test -f specs/syscall-table.md && echo "PASS: syscall-table.md exists"
```

---

## Step 2: Update Spec 001 (Minimal Kernel)

**File**: `specs/001-minimal-kernel/spec.md`

**Find and Replace**:
- Find: `Zig 0.13.x/0.14.x` (or similar version references)
- Replace: `Zig 0.15.x (or current stable)`

**Add Reference**:
Add to requirements section:
```markdown
Syscall numbers follow Linux x86_64 ABI. See [syscall-table.md](../syscall-table.md).
```

**Verify**:
```bash
grep -c "0\.15" specs/001-minimal-kernel/spec.md  # Should be >= 1
grep -c "0\.13\|0\.14" specs/001-minimal-kernel/spec.md  # Should be 0
```

---

## Step 3: Update Spec 003 (Microkernel Networking)

**File**: `specs/003-microkernel-userland-networking/spec.md`

### 3.1 Fix Syscall Numbers

**Find**: Any custom syscall number definitions like:
```
SYS_READ = 2
SYS_WRITE = 1
```

**Replace with**:
```markdown
Syscall numbers follow Linux x86_64 ABI. See [syscall-table.md](../syscall-table.md).

Key syscalls for this spec:
- sys_read (0): Read from file descriptor
- sys_write (1): Write to file descriptor
```

### 3.2 Add Spinlock Section

**Add** the following section (see contracts/amendments.md for full text):

```markdown
## Spinlock Primitive

The kernel uses an IRQ-safe Spinlock for mutual exclusion...
[copy full section from contracts/amendments.md]
```

### 3.3 Add Endianness Section

**Add** to the Networking section:

```markdown
### Byte Order Requirements

ZigK runs on x86_64 (Little Endian). Network protocols use Big Endian.
[copy full section from contracts/amendments.md]
```

**Verify**:
```bash
grep -c "Spinlock" specs/003-microkernel-userland-networking/spec.md  # >= 1
grep -c "Byte Order\|Endianness" specs/003-microkernel-userland-networking/spec.md  # >= 1
grep "SYS_READ.*=.*2" specs/003-microkernel-userland-networking/spec.md  # Should be empty
```

---

## Step 4: Update Spec 006 (SysV ABI Init)

**File**: `specs/006-sysv-abi-init/spec.md`

**Add** crt0 section:

```markdown
## CRT0 Implementation

A crt0 (C runtime zero) implementation MUST be provided for userland programs.
[copy full section from contracts/amendments.md]
```

**Verify**:
```bash
grep -c "crt0\|CRT0" specs/006-sysv-abi-init/spec.md  # >= 1
grep -c "_start" specs/006-sysv-abi-init/spec.md  # >= 1
```

---

## Step 5: Update Spec 007 (Linux Compat Layer)

**File**: `specs/007-linux-compat-layer/spec.md`

**Add** VFS shim section:

```markdown
## VFS Device Shim

The kernel provides a minimal VFS shim for virtual device paths.
[copy full section from contracts/amendments.md]
```

**Verify**:
```bash
grep -c "/dev/null\|/dev/console" specs/007-linux-compat-layer/spec.md  # >= 1
grep -c "VFS.*shim\|VFS.*Shim" specs/007-linux-compat-layer/spec.md  # >= 1
```

---

## Step 6: Update CLAUDE.md

**File**: `CLAUDE.md` (repository root)

### 6.1 Update Zig Version

**Find**: References to `0.13.x` or `0.14.x`
**Replace**: `0.15.x`

### 6.2 Add Build Patterns Section

**Add**:

```markdown
## Build Patterns (Zig 0.15.x)

```zig
// Module creation (required for 0.15.x)
const kernel = b.addExecutable(.{
    .name = "kernel.elf",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .x86_64,
            .os_tag = .freestanding,
            .abi = .none,
        }),
        .optimize = optimize,
        .code_model = .kernel,  // Disables Red Zone
    }),
});

// Disable SIMD for simpler context switching
kernel.root_module.cpu_features_sub.add(.sse);
kernel.root_module.cpu_features_sub.add(.sse2);
kernel.root_module.cpu_features_sub.add(.mmx);
```
```

**Verify**:
```bash
grep -c "0\.15" CLAUDE.md  # >= 1
grep -c "root_module\|createModule" CLAUDE.md  # >= 1
```

---

## Step 7: Final Verification

Run all verification commands:

```bash
#!/bin/bash
# Save as verify-consistency.sh

echo "=== Syscall Table ==="
test -f specs/syscall-table.md && echo "PASS: syscall-table.md exists" || echo "FAIL"

echo ""
echo "=== Old Zig Versions ==="
count=$(grep -r "0\.13\|0\.14" specs/ CLAUDE.md 2>/dev/null | grep -v "syscall-table" | wc -l)
[ "$count" -eq 0 ] && echo "PASS: No old Zig versions" || echo "FAIL: Found $count references"

echo ""
echo "=== Custom Syscall Numbers ==="
count=$(grep -r "SYS_READ.*=.*2" specs/ 2>/dev/null | wc -l)
[ "$count" -eq 0 ] && echo "PASS: No custom syscall numbers" || echo "FAIL: Found $count"

echo ""
echo "=== Spinlock in 003 ==="
grep -q "Spinlock" specs/003-microkernel-userland-networking/spec.md 2>/dev/null && echo "PASS" || echo "FAIL"

echo ""
echo "=== Endianness in 003 ==="
grep -qi "byte order\|endian" specs/003-microkernel-userland-networking/spec.md 2>/dev/null && echo "PASS" || echo "FAIL"

echo ""
echo "=== crt0 in 006 ==="
grep -qi "crt0" specs/006-sysv-abi-init/spec.md 2>/dev/null && echo "PASS" || echo "FAIL"

echo ""
echo "=== VFS shim in 007 ==="
grep -qi "vfs.*shim\|/dev/" specs/007-linux-compat-layer/spec.md 2>/dev/null && echo "PASS" || echo "FAIL"

echo ""
echo "=== Zig 0.15 in CLAUDE.md ==="
grep -q "0\.15" CLAUDE.md 2>/dev/null && echo "PASS" || echo "FAIL"

echo ""
echo "=== Build patterns in CLAUDE.md ==="
grep -q "root_module\|createModule" CLAUDE.md 2>/dev/null && echo "PASS" || echo "FAIL"
```

---

## Troubleshooting

### "I can't find the section to modify"

Each spec has different structure. Look for:
- "Requirements" or "Technical Requirements" for version updates
- "Implementation" or "Kernel" for Spinlock
- "Networking" for Endianness
- "Process" or "Userland" for crt0
- "File Descriptors" or "Syscalls" for VFS shim

### "The grep verification fails"

1. Check exact spelling (case-sensitive vs case-insensitive)
2. Ensure you saved the file after editing
3. Check for typos in section headings

### "I'm not sure what to add"

Refer to `contracts/amendments.md` for exact text to copy.

---

## Commit Message

After all amendments:

```
docs: Unify cross-specification consistency

- Add specs/syscall-table.md as authoritative syscall reference
- Update all specs to Zig 0.15.x
- Add Spinlock primitive to spec 003
- Add endianness documentation to spec 003
- Add crt0 requirements to spec 006
- Add VFS device shim to spec 007
- Update CLAUDE.md with 0.15.x build patterns

Resolves cross-specification contradictions identified in spec 009.
```

---

## Next Steps

After completing this feature:

1. Run `/speckit.tasks` to generate task checklist
2. Create PR for documentation changes
3. Update dependent spec implementations if any code exists
4. Archive spec 009 as completed
