/*
 * include/x86funcs.h
 *
 * Created by Simon Evans on 03/01/2016.
 * Copyright © 2016 Simon Evans. All rights reserved.
 *
 * Header file for x86 specific instructions. Most functions are one
 * instruction and by making them static inline Swift will include them
 * directly into the output making them inline assembly
 *
 * Larger functions are in kernel/klib/x86.asm as I find NASM format asm
 * easier to read/write then gas format
 *
 */

#ifndef __X86_FUNCS_H__
#define __X86_FUNCS_H__
#include "x86defs.h"


static inline void
cli()
{
        asm volatile ("cli" : : : "memory");
}


static inline void
sti()
{
        asm volatile ("sti" : : : "memory");
}


static inline void
hlt()
{
        asm volatile ("hlt" : : : "memory");
}

static inline void stop() __attribute__ ((noreturn));

static inline void
stop()
{
        cli();
        hlt();
        __builtin_unreachable();
}


static inline void
lgdt(const struct dt_info *gdt)
{
        asm volatile ("lgdt (%0)" : : "r" (gdt) : "memory");
}


static inline void
sgdt(struct dt_info *gdt)
{
        asm volatile ("sgdt (%0)" : : "r" (gdt) : "memory");
}


static inline void
lidt(const struct dt_info *gdt)
{
        asm volatile ("lidt (%0)" : : "r" (gdt) : "memory");
}

static inline void
sidt(struct dt_info *gdt)
{
        asm volatile ("sidt (%0)" : : "r" (gdt) : "memory");
}


static inline void
outb(uint16_t port, uint8_t data)
{
        asm volatile ("outb %0, %1" : : "a" (data), "d" (port));
}


static inline uint8_t
inb(uint16_t port)
{
        uint8_t data;
        asm volatile ("inb %1, %0" : "=a" (data) : "d" (port));
        return data;
}


static inline void
outw(uint16_t port, uint16_t data)
{
        asm volatile ("outw %0, %1" : : "a" (data), "d" (port));
}


static inline uint16_t
inw(uint16_t port)
{
        uint16_t data;
        asm volatile ("inw %1, %0" : "=a" (data) : "d" (port));
        return data;
}


static inline void
outl(uint16_t port, uint32_t data)
{
        asm volatile ("outl %0, %1" : : "a" (data), "d" (port));
}


static inline uint32_t
inl(uint16_t port)
{
        uint32_t data;
        asm volatile ("inl %1, %0" : "=a" (data) : "d" (port));
        return data;
}


// Returns a pointer to the char array for ease of converting to a String
static inline const char *
cpuid(const uint32_t function, struct cpuid_result *result)
{
        uint32_t eax, ebx, ecx, edx;
        asm volatile ("cpuid"
                      : "=a" (eax), "=b" (ebx), "=c" (ecx), "=d" (edx)
                      : "a" (function)
                      :);
        result->u.regs.eax = eax;
        result->u.regs.ebx = ebx;
        if (function == 0) {
                result->u.regs.ecx = edx;
                result->u.regs.edx = ecx;
        } else {
                result->u.regs.ecx = ecx;
                result->u.regs.edx = edx;
        }

        result->u.bytes[32] = '\0';

        return result->u.bytes;
}


static inline uintptr_t
getCR2()
{
        uintptr_t res;
        asm volatile ("mov %%cr2, %0" : "=r" (res) : : );
        return res;
}


static inline uint64_t
getCR3()
{
        uint64_t res;
        asm volatile ("mov %%cr3, %0" : "=r" (res) : : );
        return res;
}


static inline void
setCR3(uint64_t value)
{
        asm volatile ("mov %0, %%cr3" : : "r" (value) : );
}


static inline void
int3()
{
        asm volatile ("int $3" :::);
}


// kernel/klib/x86.asm functions
void reload_segments();
void test_breakpoint();

#endif  // __X86_FUNCS_H__