# x86_64 memcpy/memset helpers for freestanding builds.
# Uses rep movsq/stosq with byte remainder.

.text

# void *zscapek_memcpy(void *dest, const void *src, size_t n)
.global zscapek_memcpy
.type zscapek_memcpy, @function
zscapek_memcpy:
    cld
    mov %rdi, %rax
    mov %rdx, %rcx
    shr $3, %rcx
    rep movsq
    mov %rdx, %rcx
    and $7, %rcx
    rep movsb
    ret

# void *zscapek_memset(void *dest, int c, size_t n)
.global zscapek_memset
.type zscapek_memset, @function
zscapek_memset:
    cld
    mov %rdi, %r11
    mov %rsi, %rax
    movzbq %al, %rax
    movabs $0x0101010101010101, %r10
    imulq %r10, %rax
    mov %rdx, %rcx
    shr $3, %rcx
    rep stosq
    mov %rdx, %rcx
    and $7, %rcx
    rep stosb
    mov %r11, %rax
    ret
