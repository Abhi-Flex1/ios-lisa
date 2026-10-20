/*
 * The phone's own device tree, embedded in .rodata so the shim can parse it
 * even if ABL does not pass a usable pointer in x0.  build.sh copies the
 * selected DTB to out/dtb_blob.bin before assembling this file.
 */
	.section .rodata.dtb, "a"
	.balign 8
	.globl _dtb_blob_start
_dtb_blob_start:
	.incbin "out/dtb_blob.bin"
	.globl _dtb_blob_end
_dtb_blob_end:
	.balign 8
