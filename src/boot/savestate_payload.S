/*
 * Experimental SummerCart64 in-game save-state payload.
 *
 * This code is copied by cheats.c into the Expansion Pak area and entered
 * directly from the exception hook when the SC64 cartridge interrupt fires.
 * It is deliberately position independent apart from one jump patched by the
 * installer for the post-DMA restore path.
 *
 * Prototype scope:
 *   - 8 MiB RDRAM
 *   - CPU GPRs, HI/LO, EPC, Status, Count, Compare
 *   - FPU register pairs when CU1 is enabled
 *   - SP DMEM + IMEM, SP PC/status (captured at an idle/halted boundary)
 *
 * RDP/VI/AI/SI internal state is not yet fully serialised. This is therefore
 * an experimental hardware state mechanism, not yet emulator-grade state.
 */

.set noreorder
.set noat
.set mips3

/* SC64 state storage. Physical 0x13000000 is 16 MiB above Majora's Mask's
 * 32 MiB ROM image. 0x13800000 is immediately after the 8 MiB RDRAM image. */
.equ SS_RDRAM_CART_PHYS,     0x13000000
.equ SS_META_CART_UC,        0xB3800000
.equ SS_SP_CART_UC,          0xB3801000
.equ SS_MAGIC_VALUE,         0x53533634      /* "SS64" */
.equ SS_VERSION_VALUE,       0x00000001

.equ SS_MAGIC,               0x000
.equ SS_MODE,                0x004           /* 0 = next bare press saves, 1 = loads */
.equ SS_VERSION,             0x008
.equ SS_FLAGS,               0x00C           /* bit 0 = FPU saved */
.equ SS_EPC,                 0x010
.equ SS_STATUS,              0x014
.equ SS_COUNT,               0x018
.equ SS_COMPARE,             0x01C
.equ SS_HI,                  0x020
.equ SS_LO,                  0x028
.equ SS_SP_STATUS,           0x030
.equ SS_SP_PC,               0x034
.equ SS_GPR_BASE,            0x040           /* 32 x 8 bytes */
.equ SS_FPR_BASE,            0x140           /* 16 x 8-byte even-register pairs */
.equ SS_FPCSR,               0x1C0

.equ SC64_IRQ_REG_UC,        0xBFFF0014
.equ SC64_BTN_IRQ_CLEAR,     0x80000000
.equ PI_REGS_UC,             0xA4600000
.equ PI_DRAM_ADDR,           0x00
.equ PI_CART_ADDR,           0x04
.equ PI_RD_LEN,              0x08            /* RDRAM -> cart */
.equ PI_WR_LEN,              0x0C            /* cart -> RDRAM */
.equ PI_STATUS,              0x10
.equ PI_BUSY_MASK,           0x03
.equ RDRAM_DMA_LEN_M1,       0x007FFFFF

.equ SP_MEM_UC,              0xA4000000
.equ SP_IMEM_UC,             0xA4001000
.equ SP_REGS_UC,             0xA4040000
.equ SP_STATUS_REG,          0x10
.equ SP_PC_REG_UC,           0xA4080000
.equ SP_STATUS_HALT,         0x0001
.equ SP_SET_HALT,            0x0002
.equ SP_MEM_BYTES,           0x2000

.equ DPC_REGS_UC,            0xA4100000
.equ DPC_STATUS_REG,         0x0C
.equ DPC_BUSY_MASK,          0x0170          /* TMEM/PIPE/CMD/DMA busy */
.equ DPC_SET_FREEZE,         0x0008

.equ CACHE_INDEX_INV_I,      0x00
.equ CACHE_INDEX_WB_INV_D,   0x01
.equ DCACHE_BYTES,           0x2000
.equ DCACHE_LINE,            0x10
.equ ICACHE_BYTES,           0x4000
.equ ICACHE_LINE,            0x20

.equ IDLE_WAIT_ITERATIONS_HI, 0x0010          /* 0x00100000 polls */

/* CPU Cause IP4, cartridge interrupt. */
.equ CAUSE_IP4,              0x1000
.equ STATUS_CU1,             0x20000000

/* Store a 64-bit GPR as two 32-bit words using only k1 as scratch. */
.macro SAVE_GPR reg, index
    sw      \reg, (SS_GPR_BASE + ((\index) * 8) + 4)($k0)
    dsra32  $k1, \reg, 0
    sw      $k1, (SS_GPR_BASE + ((\index) * 8))($k0)
.endm

/* Restore a 64-bit GPR. k0 remains the metadata base, k1 is scratch. */
.macro RESTORE_GPR reg, index
    lw      \reg, (SS_GPR_BASE + ((\index) * 8))($k0)
    dsll32  \reg, \reg, 0
    lwu     $k1, (SS_GPR_BASE + ((\index) * 8) + 4)($k0)
    or      \reg, \reg, $k1
.endm

/* Store the 64-bit value currently in k1 at a fixed metadata offset. */
.macro SAVE_K1_64 offset
    sw      $k1, ((\offset) + 4)($k0)
    dsra32  $k1, $k1, 0
    sw      $k1, (\offset)($k0)
.endm

/* Reconstruct a 64-bit metadata value into k1 using t9 as scratch.
 * Only used after the interrupted register state is no longer needed. */
.macro LOAD_K1_64 offset
    lw      $k1, (\offset)($k0)
    dsll32  $k1, $k1, 0
    lwu     $t9, ((\offset) + 4)($k0)
    or      $k1, $k1, $t9
.endm

.global savestate_payload_start
.global savestate_payload_end
.global savestate_restore_stub_start
.global savestate_restore_stub_end
.global savestate_restore_post_dma
.global savestate_restore_jump_patch
.global savestate_restore_src_start_patch
.global savestate_restore_src_end_patch

savestate_payload_start:
    /* Acknowledge the SC64 physical-button IRQ immediately. */
    lui     $k0, 0xBFFF
    lui     $k1, 0x8000
    sw      $k1, 0x0014($k0)
    nop

    /* v0.1 deliberately uses only the SC64 physical button. Touching PIF
     * RAM asynchronously is avoidable risk. First press saves, next press
     * loads, then the sequence repeats. An invalid state always means save. */
    lui     $k0, 0xB380
    lw      $k1, SS_MAGIC($k0)
    lui     $k0, 0x5353
    ori     $k0, $k0, 0x3634
    bne     $k1, $k0, savestate_save
    nop
    lui     $k0, 0xB380
    lw      $k1, SS_MODE($k0)
    beqz    $k1, savestate_save
    nop
    b       savestate_load
    nop

savestate_save:
    /* Metadata lives on the cartridge, outside the 8 MiB RDRAM image. */
    lui     $k0, 0xB380
    sw      $zero, SS_MAGIC($k0)      /* invalidate until the DMA completes */
    addiu   $k1, $zero, SS_VERSION_VALUE
    sw      $k1, SS_VERSION($k0)

    /* Save key CP0 state. Status already contains EXL=1, which is exactly
     * what the restore path wants immediately before ERET. */
    mfc0    $k1, $14                  /* EPC */
    sw      $k1, SS_EPC($k0)
    mfc0    $k1, $12                  /* Status */
    sw      $k1, SS_STATUS($k0)
    mfc0    $k1, $9                   /* Count */
    sw      $k1, SS_COUNT($k0)
    mfc0    $k1, $11                  /* Compare */
    sw      $k1, SS_COMPARE($k0)

    /* Save every application-visible integer register. k0/k1 are deliberately
     * excluded because the N64 exception ABI reserves them for the kernel. */
    SAVE_GPR $at, 1
    SAVE_GPR $v0, 2
    SAVE_GPR $v1, 3
    SAVE_GPR $a0, 4
    SAVE_GPR $a1, 5
    SAVE_GPR $a2, 6
    SAVE_GPR $a3, 7
    SAVE_GPR $t0, 8
    SAVE_GPR $t1, 9
    SAVE_GPR $t2, 10
    SAVE_GPR $t3, 11
    SAVE_GPR $t4, 12
    SAVE_GPR $t5, 13
    SAVE_GPR $t6, 14
    SAVE_GPR $t7, 15
    SAVE_GPR $s0, 16
    SAVE_GPR $s1, 17
    SAVE_GPR $s2, 18
    SAVE_GPR $s3, 19
    SAVE_GPR $s4, 20
    SAVE_GPR $s5, 21
    SAVE_GPR $s6, 22
    SAVE_GPR $s7, 23
    SAVE_GPR $t8, 24
    SAVE_GPR $t9, 25
    SAVE_GPR $gp, 28
    SAVE_GPR $sp, 29
    SAVE_GPR $fp, 30
    SAVE_GPR $ra, 31

    mfhi    $k1
    SAVE_K1_64 SS_HI
    mflo    $k1
    SAVE_K1_64 SS_LO

    /* Save the 16 standard 64-bit FPU register pairs when CU1 is active. */
    lw      $k1, SS_STATUS($k0)
    srl     $k1, $k1, 29
    andi    $k1, $k1, 1
    sw      $k1, SS_FLAGS($k0)
    beqz    $k1, 2f
    nop
    cfc1    $k1, $31
    nop
    sw      $k1, SS_FPCSR($k0)

    dmfc1   $k1, $f0
    SAVE_K1_64 (SS_FPR_BASE + 0x00)
    dmfc1   $k1, $f2
    SAVE_K1_64 (SS_FPR_BASE + 0x08)
    dmfc1   $k1, $f4
    SAVE_K1_64 (SS_FPR_BASE + 0x10)
    dmfc1   $k1, $f6
    SAVE_K1_64 (SS_FPR_BASE + 0x18)
    dmfc1   $k1, $f8
    SAVE_K1_64 (SS_FPR_BASE + 0x20)
    dmfc1   $k1, $f10
    SAVE_K1_64 (SS_FPR_BASE + 0x28)
    dmfc1   $k1, $f12
    SAVE_K1_64 (SS_FPR_BASE + 0x30)
    dmfc1   $k1, $f14
    SAVE_K1_64 (SS_FPR_BASE + 0x38)
    dmfc1   $k1, $f16
    SAVE_K1_64 (SS_FPR_BASE + 0x40)
    dmfc1   $k1, $f18
    SAVE_K1_64 (SS_FPR_BASE + 0x48)
    dmfc1   $k1, $f20
    SAVE_K1_64 (SS_FPR_BASE + 0x50)
    dmfc1   $k1, $f22
    SAVE_K1_64 (SS_FPR_BASE + 0x58)
    dmfc1   $k1, $f24
    SAVE_K1_64 (SS_FPR_BASE + 0x60)
    dmfc1   $k1, $f26
    SAVE_K1_64 (SS_FPR_BASE + 0x68)
    dmfc1   $k1, $f28
    SAVE_K1_64 (SS_FPR_BASE + 0x70)
    dmfc1   $k1, $f30
    SAVE_K1_64 (SS_FPR_BASE + 0x78)
2:

    /* Wait for an RSP idle boundary. This avoids needing to serialise the
     * RSP's internal vector registers/accumulator in the first prototype.
     * Abort this save rather than wedging the console if no idle boundary
     * arrives within a bounded polling window. */
    lui     $t0, 0xA404
    lui     $t3, IDLE_WAIT_ITERATIONS_HI
3:
    lw      $t1, SP_STATUS_REG($t0)
    andi    $t2, $t1, SP_STATUS_HALT
    bnez    $t2, 30f
    addiu   $t3, $t3, -1
    bnez    $t3, 3b
    nop
    b       savestate_restore_gprs_return
    nop
30:
    lui     $k0, 0xB380
    sw      $t1, SS_SP_STATUS($k0)
    lui     $t0, 0xA408
    lw      $t1, 0($t0)
    sw      $t1, SS_SP_PC($k0)

    /* Wait until the RDP command pipeline is quiescent too, with the same
     * fail-safe behaviour if it refuses to become idle. */
    lui     $t0, 0xA410
    lui     $t3, IDLE_WAIT_ITERATIONS_HI
4:
    lw      $t1, DPC_STATUS_REG($t0)
    andi    $t1, $t1, DPC_BUSY_MASK
    beqz    $t1, 40f
    addiu   $t3, $t3, -1
    bnez    $t3, 4b
    nop
    b       savestate_restore_gprs_return
    nop
40:

    /* Copy all 8 KiB of RSP DMEM+IMEM to SC64 SDRAM. */
    lui     $t0, 0xA400               /* source */
    lui     $t1, 0xB380
    ori     $t1, $t1, 0x1000          /* destination */
    addiu   $t2, $zero, SP_MEM_BYTES
5:
    lw      $t3, 0($t0)
    sw      $t3, 0($t1)
    addiu   $t0, $t0, 4
    addiu   $t1, $t1, 4
    addiu   $t2, $t2, -4
    bnez    $t2, 5b
    nop

    /* Flush all dirty CPU D-cache lines before PI sees RDRAM. */
    lui     $t0, 0x8000
    addiu   $t1, $t0, DCACHE_BYTES
6:
    cache   CACHE_INDEX_WB_INV_D, 0($t0)
    addiu   $t0, $t0, DCACHE_LINE
    bne     $t0, $t1, 6b
    nop

    /* PI DMA: all 8 MiB RDRAM -> SC64 SDRAM at physical 0x13000000. */
    lui     $t0, 0xA460
7:
    lw      $t1, PI_STATUS($t0)
    andi    $t1, $t1, PI_BUSY_MASK
    bnez    $t1, 7b
    nop
    sw      $zero, PI_DRAM_ADDR($t0)
    lui     $t1, 0x1300
    sw      $t1, PI_CART_ADDR($t0)
    lui     $t1, 0x0080
    addiu   $t1, $t1, -1
    sw      $t1, PI_RD_LEN($t0)
8:
    lw      $t1, PI_STATUS($t0)
    andi    $t1, $t1, PI_BUSY_MASK
    bnez    $t1, 8b
    nop

    /* Commit the state only after every byte is in cartridge SDRAM. */
    lui     $k0, 0xB380
    lui     $k1, 0x5353
    ori     $k1, $k1, 0x3634
    sw      $k1, SS_MAGIC($k0)
    addiu   $k1, $zero, 1
    sw      $k1, SS_MODE($k0)

    /* We used t0-t3 after capturing the state. Restore all application-visible
     * GPRs before returning directly from our cartridge interrupt. Timeout
     * aborts above also converge here while the state magic remains invalid. */
savestate_restore_gprs_return:
    lui     $k0, 0xB380
    RESTORE_GPR $at, 1
    RESTORE_GPR $v0, 2
    RESTORE_GPR $v1, 3
    RESTORE_GPR $a0, 4
    RESTORE_GPR $a1, 5
    RESTORE_GPR $a2, 6
    RESTORE_GPR $a3, 7
    RESTORE_GPR $t0, 8
    RESTORE_GPR $t1, 9
    RESTORE_GPR $t2, 10
    RESTORE_GPR $t3, 11
    RESTORE_GPR $t4, 12
    RESTORE_GPR $t5, 13
    RESTORE_GPR $t6, 14
    RESTORE_GPR $t7, 15
    RESTORE_GPR $s0, 16
    RESTORE_GPR $s1, 17
    RESTORE_GPR $s2, 18
    RESTORE_GPR $s3, 19
    RESTORE_GPR $s4, 20
    RESTORE_GPR $s5, 21
    RESTORE_GPR $s6, 22
    RESTORE_GPR $s7, 23
    RESTORE_GPR $t8, 24
    RESTORE_GPR $t9, 25
    RESTORE_GPR $gp, 28
    RESTORE_GPR $sp, 29
    RESTORE_GPR $fp, 30
    RESTORE_GPR $ra, 31

savestate_return_to_game:
    /* The SC64 IRQ is ours and has already been acknowledged. Return directly
     * to the interrupted EPC instead of making libultra process a synthetic
     * cartridge event. k0/k1 are reserved exception scratch registers. */
    eret
    nop

savestate_load:
    /* Mark bare-button mode as SAVE for the next press. */
    lui     $k0, 0xB380
    sw      $zero, SS_MODE($k0)

    /* Stop the RSP and freeze the RDP before RDRAM is rolled backwards. */
    lui     $t0, 0xA404
    addiu   $t1, $zero, SP_SET_HALT
    sw      $t1, SP_STATUS_REG($t0)
9:
    lw      $t1, SP_STATUS_REG($t0)
    andi    $t1, $t1, SP_STATUS_HALT
    beqz    $t1, 9b
    nop
    lui     $t0, 0xA410
19:
    lw      $t1, DPC_STATUS_REG($t0)
    andi    $t1, $t1, DPC_BUSY_MASK
    bnez    $t1, 19b
    nop
    addiu   $t1, $zero, DPC_SET_FREEZE
    sw      $t1, DPC_STATUS_REG($t0)

    /* Copy the small restore stub into SP IMEM. The main 8 MiB DMA will
     * overwrite the RDRAM code that invoked it. The source range is patched
     * by cheats.c after the payload's final in-game address is known. */
savestate_restore_src_start_patch:
    nop
    nop
savestate_restore_src_end_patch:
    nop
    nop
    lui     $t1, 0xA400
    ori     $t1, $t1, 0x1000
    move    $t4, $t1
11:
    lw      $t3, 0($t0)
    sw      $t3, 0($t1)
    addiu   $t0, $t0, 4
    addiu   $t1, $t1, 4
    bne     $t0, $t2, 11b
    nop
    sync
    jr      $t4
    nop

/* Runs uncached from SP IMEM while RDRAM is replaced. */
savestate_restore_stub_start:
    /* Remove every dirty D-cache line before the rollback. */
    lui     $t0, 0x8000
    addiu   $t1, $t0, DCACHE_BYTES
12:
    cache   CACHE_INDEX_WB_INV_D, 0($t0)
    addiu   $t0, $t0, DCACHE_LINE
    bne     $t0, $t1, 12b
    nop

    /* PI DMA: SC64 snapshot -> all 8 MiB RDRAM. */
    lui     $t0, 0xA460
13:
    lw      $t1, PI_STATUS($t0)
    andi    $t1, $t1, PI_BUSY_MASK
    bnez    $t1, 13b
    nop
    sw      $zero, PI_DRAM_ADDR($t0)
    lui     $t1, 0x1300
    sw      $t1, PI_CART_ADDR($t0)
    lui     $t1, 0x0080
    addiu   $t1, $t1, -1
    sw      $t1, PI_WR_LEN($t0)
14:
    lw      $t1, PI_STATUS($t0)
    andi    $t1, $t1, PI_BUSY_MASK
    bnez    $t1, 14b
    nop

    /* Discard stale instruction-cache lines before returning to restored code. */
    lui     $t0, 0x8000
    addiu   $t1, $t0, ICACHE_BYTES
15:
    cache   CACHE_INDEX_INV_I, 0($t0)
    addiu   $t0, $t0, ICACHE_LINE
    bne     $t0, $t1, 15b
    nop
    sync

savestate_restore_jump_patch:
    /* Patched by cheats.c to J to the uncached address of
     * savestate_restore_post_dma in the restored RDRAM image. */
    nop
    nop
savestate_restore_stub_end:

/* At this point the original RDRAM image, including this payload, is back. */
savestate_restore_post_dma:
    /* Restore RSP DMEM + IMEM now that execution is safely back in RDRAM. */
    lui     $t0, 0xB380
    ori     $t0, $t0, 0x1000
    lui     $t1, 0xA400
    addiu   $t2, $zero, SP_MEM_BYTES
16:
    lw      $t3, 0($t0)
    sw      $t3, 0($t1)
    addiu   $t0, $t0, 4
    addiu   $t1, $t1, 4
    addiu   $t2, $t2, -4
    bnez    $t2, 16b
    nop

    /* Restore the saved SP PC. Leave the SP halted for the moment; restoring
     * a fully live RSP task requires vector/accumulator serialisation, which is
     * deliberately outside this first prototype. */
    lui     $k0, 0xB380
    lw      $t1, SS_SP_PC($k0)
    lui     $t0, 0xA408
    sw      $t1, 0($t0)

    /* The RDP was frozen only to make rollback safe. The saved state was taken
     * at an idle RDP boundary, so release the freeze before resuming the CPU. */
    lui     $t0, 0xA410
    addiu   $t1, $zero, 4              /* DPC_CLR_FREEZE */
    sw      $t1, DPC_STATUS_REG($t0)

    /* Restore FPU state first while scratch registers are still disposable. */
    lw      $t1, SS_FLAGS($k0)
    beqz    $t1, 18f
    nop
    mfc0    $t1, $12
    lui     $t2, 0x2000
    or      $t1, $t1, $t2
    mtc0    $t1, $12
    nop
    nop

    LOAD_K1_64 (SS_FPR_BASE + 0x00)
    dmtc1   $k1, $f0
    LOAD_K1_64 (SS_FPR_BASE + 0x08)
    dmtc1   $k1, $f2
    LOAD_K1_64 (SS_FPR_BASE + 0x10)
    dmtc1   $k1, $f4
    LOAD_K1_64 (SS_FPR_BASE + 0x18)
    dmtc1   $k1, $f6
    LOAD_K1_64 (SS_FPR_BASE + 0x20)
    dmtc1   $k1, $f8
    LOAD_K1_64 (SS_FPR_BASE + 0x28)
    dmtc1   $k1, $f10
    LOAD_K1_64 (SS_FPR_BASE + 0x30)
    dmtc1   $k1, $f12
    LOAD_K1_64 (SS_FPR_BASE + 0x38)
    dmtc1   $k1, $f14
    LOAD_K1_64 (SS_FPR_BASE + 0x40)
    dmtc1   $k1, $f16
    LOAD_K1_64 (SS_FPR_BASE + 0x48)
    dmtc1   $k1, $f18
    LOAD_K1_64 (SS_FPR_BASE + 0x50)
    dmtc1   $k1, $f20
    LOAD_K1_64 (SS_FPR_BASE + 0x58)
    dmtc1   $k1, $f22
    LOAD_K1_64 (SS_FPR_BASE + 0x60)
    dmtc1   $k1, $f24
    LOAD_K1_64 (SS_FPR_BASE + 0x68)
    dmtc1   $k1, $f26
    LOAD_K1_64 (SS_FPR_BASE + 0x70)
    dmtc1   $k1, $f28
    LOAD_K1_64 (SS_FPR_BASE + 0x78)
    dmtc1   $k1, $f30
    lw      $k1, SS_FPCSR($k0)
    ctc1    $k1, $31
18:

    /* HI/LO and timer state. */
    LOAD_K1_64 SS_HI
    mthi     $k1
    LOAD_K1_64 SS_LO
    mtlo     $k1
    lw      $k1, SS_COUNT($k0)
    mtc0    $k1, $9
    lw      $k1, SS_COMPARE($k0)
    mtc0    $k1, $11
    lw      $k1, SS_EPC($k0)
    mtc0    $k1, $14

    /* Restore every application-visible GPR. t9 is restored last because the
     * LOAD_K1_64 helper used it above. */
    RESTORE_GPR $at, 1
    RESTORE_GPR $v0, 2
    RESTORE_GPR $v1, 3
    RESTORE_GPR $a0, 4
    RESTORE_GPR $a1, 5
    RESTORE_GPR $a2, 6
    RESTORE_GPR $a3, 7
    RESTORE_GPR $t0, 8
    RESTORE_GPR $t1, 9
    RESTORE_GPR $t2, 10
    RESTORE_GPR $t3, 11
    RESTORE_GPR $t4, 12
    RESTORE_GPR $t5, 13
    RESTORE_GPR $t6, 14
    RESTORE_GPR $t7, 15
    RESTORE_GPR $s0, 16
    RESTORE_GPR $s1, 17
    RESTORE_GPR $s2, 18
    RESTORE_GPR $s3, 19
    RESTORE_GPR $s4, 20
    RESTORE_GPR $s5, 21
    RESTORE_GPR $s6, 22
    RESTORE_GPR $s7, 23
    RESTORE_GPR $t8, 24
    RESTORE_GPR $gp, 28
    RESTORE_GPR $sp, 29
    RESTORE_GPR $fp, 30
    RESTORE_GPR $ra, 31
    RESTORE_GPR $t9, 25

    /* Restore saved exception Status last, then ERET resumes the exact EPC
     * captured on the save-button cartridge interrupt. */
    lw      $k1, SS_STATUS($k0)
    mtc0    $k1, $12
    nop
    nop
    eret
    nop

savestate_payload_end:
