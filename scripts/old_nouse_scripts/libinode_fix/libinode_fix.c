/*
 * libinode_fix.c — LD_PRELOAD fstat() interposer for APK inode masking.
 *
 * Problem:
 *   On arm64, fstat() is a bare syscall generated from bionic/SYSCALLS.TXT.
 *   Our do_fstatat() fixup (stat.cpp) only covers stat()/fstatat() — fstat()
 *   bypasses it entirely.  Modifying SYSCALLS.TXT causes boot loops (Round 3).
 *
 * Solution:
 *   LD_PRELOAD interposer that wraps fstat() and masks inode/dev for APK paths.
 *   - Resolves /proc/self/fd/<fd> to a real path
 *   - If the path is under /data/app/ or data/data/<pkg>/base.apk, replaces
 *     st_ino with a stable hash and st_dev with a known ext4 device id.
 *   - All other fstat() calls pass through unchanged.
 *
 * Build (on x86_64 host, cross-compiling for aarch64 Android):
 *   $NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android33-clang \
 *       -shared -fPIC -O2 -s -o libinode_fix.so libinode_fix.c
 *
 * Deploy:
 *   adb push libinode_fix.so /data/local/tmp/
 *   adb shell setprop wrap.com.zhenxi.hunter   'LD_PRELOAD=/data/local/tmp/libinode_fix.so'
 *   adb shell setprop wrap.com.xingin.xhs       'LD_PRELOAD=/data/local/tmp/libinode_fix.so'
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

/* ── FNV-1a 32-bit hash (simple, collision-resistant enough for our use) ── */
static uint32_t fnv1a_hash(const char* s) {
  uint32_t h = 0x811C9DC5u;
  while (*s) {
    h ^= (uint8_t)*s++;
    h *= 0x01000193u;
  }
  return h;
}

/* ── Read symlink target of /proc/self/fd/<fd> ── */
static int resolve_fd_path(int fd, char* buf, size_t bufsz) {
  char proclink[64];
  snprintf(proclink, sizeof(proclink), "/proc/self/fd/%d", fd);
  ssize_t n = readlink(proclink, buf, bufsz - 1);
  if (n <= 0) return -1;
  buf[n] = '\0';
  return 0;
}

/* ── Check if path lives under /data/app/ or /data/data/ (APK detection) ── */
static int is_apk_path(const char* path) {
  static const char* apk_prefixes[] = {
      "/data/app/",
      "/data/data/",
      "/data/user/0/",
      NULL
  };
  for (const char** p = apk_prefixes; *p; ++p) {
    if (strncmp(path, *p, strlen(*p)) == 0) return 1;
  }
  return 0;
}

/*
 * Interposed fstat()
 *
 * We use dlsym(RTLD_NEXT, "fstat") to reach the real implementation,
 * then overwrite st_ino and st_dev for files under /data/app/ etc.
 *
 * Inode replacement: 0xC0000000 | (fnv1a(path) & 0x0FFFFFFF)
 *   → high nibble marks as "fake", rest is path-derived (stable per file).
 * Device replacement: 8,43 — typical ext4 /data partition in Android.
 */
typedef int (*fstat_t)(int, struct stat*);

int fstat(int fd, struct stat* sb) {
  static fstat_t real_fstat = NULL;
  if (!real_fstat) {
    real_fstat = (fstat_t)dlsym(RTLD_NEXT, "fstat");
    if (!real_fstat) abort(); /* should never happen */
  }

  int r = real_fstat(fd, sb);
  if (r != 0 || sb == NULL) return r;

  /* Resolve fd → path and check if it's an APK in /data */
  char path[512];
  if (resolve_fd_path(fd, path, sizeof(path)) == 0 && is_apk_path(path)) {
    sb->st_ino = 0xC0000000u | (fnv1a_hash(path) & 0x0FFFFFFFu);
    sb->st_dev = makedev(8, 43); /* typical ext4 data partition */
  }

  return r;
}
