#pragma once
/*
 * Per-board constants for the bare-metal shim.
 *
 * Select with -DBOARD_LISA (default) or -DBOARD_SWEET.  Everything here is
 * read from the *stock* device tree of the board; see docs/lisa-hardware.md
 * for the lisa sources.  Keep this file free of code: it is included by both
 * the freestanding shim and the host-side console test.
 */

#if defined(BOARD_SWEET)
# define BOARD_LISA 0
#elif defined(BOARD_LISA)
# define BOARD_LISA 1
#else
# define BOARD_LISA 1
#endif

#if BOARD_LISA
/* Xiaomi 11 Lite 5G NE, Qualcomm SM7325 (Snapdragon 778G), "yupik" family. */
# define BOARD_NAME		"lisa"
# define BOARD_SOC		"sm7325"

/* ABL's continuous-splash framebuffer: reserved-memory cont_splash_region,
 * 0xe1000000 + 0x2300000.  UEFI's memory map calls the same range "Display
 * Reserved".  Same 1080x2400 panel geometry as sweet, so the console and the
 * iOS canvas (1125x2436) don't change. */
# define FB_BASE		0xe1000000UL
# define FB_W			1080
# define FB_H			2400
# define FB_STRIDE		(FB_W * 4)	/* a8r8g8b8 */

/* GICv3: identical addresses to sweet (Qualcomm keeps these fixed). */
# define GICD_BASE		0x17a00000UL
# define GICR_BASE		0x17a60000UL
# define GICR_SIZE		0x100000UL

/* arm,armv8-timer on lisa: <GIC_PPI 13/14/11/12>.  PPI 11 -> INTID 27 is
 * the EL1 virtual timer XNU uses; sweet's board wired it to PPI 3 (19). */
# define VTIMER_INTID		27
# define PTIMER_INTID		30	/* PPI 14, non-secure physical */

/* Internal UFS host, ufshc@1d84000 "ufs_mem"; same IP and address as sweet,
 * 2 lanes, UFS 2.2/3.1. */
# define BOARD_UFS_BASE		0x01d84000UL
# define BOARD_UFS_SIZE		0x3000UL

/* IMEM restart reason: msm-imem@146aa000 + 0x65c. */
# define IMEM_RESTART_REASON	0x146aa65cUL
# define PSHOLD			0x0c264000UL

/* Kosmetic CPU facts for the ADT.  lisa: 4x Cortex-A55 (MPIDR 0-3) and
 * 4x Cortex-A78 (MPIDR 4-7); XNU starts a prefix selected by cpus=N. */
# define BOARD_CPU_LITTLE_CLOCK	1804800000U
# define BOARD_CPU_BIG_CLOCK	2400000000U
# define BOARD_NR_CPUS		8

#else /* BOARD_SWEET -- the proven SM7150 baseline, kept for diffing. */
# define BOARD_NAME		"sweet"
# define BOARD_SOC		"sm7150"
# define FB_BASE		0x9c000000UL
# define FB_W			1080
# define FB_H			2400
# define FB_STRIDE		(FB_W * 4)
# define GICD_BASE		0x17a00000UL
# define GICR_BASE		0x17a60000UL
# define GICR_SIZE		0x100000UL
# define VTIMER_INTID		19	/* DT: <GIC_PPI 3 ...> */
# define PTIMER_INTID		18	/* DT: <GIC_PPI 2 ...> */
# define BOARD_UFS_BASE		0x01d84000UL
# define BOARD_UFS_SIZE		0x3000UL
# define IMEM_RESTART_REASON	0x146aa65cUL
# define PSHOLD			0x0c264000UL
# define BOARD_CPU_LITTLE_CLOCK	1804800000U
# define BOARD_CPU_BIG_CLOCK	2304000000U
# define BOARD_NR_CPUS		8
#endif
