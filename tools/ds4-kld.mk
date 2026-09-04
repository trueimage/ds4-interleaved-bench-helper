# Builds ds4-kld inside a ds4 tree, reusing that tree's own Makefile for the
# core objects and link flags:
#
#     make -C <ds4 tree> -f Makefile -f <this file> ds4-kld
#
# The binary lands in the tree it was built in and must be run from there,
# because the Metal shaders are loaded from that tree's metal/ directory.

DS4_KLD_SRC ?= $(dir $(lastword $(MAKEFILE_LIST)))ds4-kld.c

# Present in ds4's Makefile; the fallback only matters for old commits.
QUALITY_CFLAGS ?= -O3 $(NATIVE_CPU_FLAG) -Wall -Wextra -std=c11

ds4-kld: $(DS4_KLD_SRC) ds4.h ds4_ssd.h $(CORE_OBJS)
	$(CC) $(QUALITY_CFLAGS) -I. -o $@ $(DS4_KLD_SRC) $(CORE_OBJS) $(METAL_LDLIBS)
