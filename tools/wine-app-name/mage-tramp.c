#include <limits.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define POSIX_SPAWN_DISABLE_ASLR 0x0100

extern char **environ;

int main(int argc, char **argv)
{
    char self[PATH_MAX], target[PATH_MAX] = "", cfg[PATH_MAX + 16];
    uint32_t size = sizeof(self);
    cpu_type_t cpu = CPU_TYPE_X86_64;
    posix_spawnattr_t attr;
    size_t n;
    FILE *f;
    int err;

    if (_NSGetExecutablePath(self, &size)) return 127;
    snprintf(cfg, sizeof(cfg), "%s.bundle-loader", self);
    if ((f = fopen(cfg, "r")))
    {
        if (!fgets(target, sizeof(target), f)) target[0] = 0;
        fclose(f);
    }
    target[strcspn(target, "\n")] = 0;
    if (!target[0] || access(target, X_OK))
    {
        char *name = strrchr(self, '/');
        *name++ = 0;
        snprintf(target, sizeof(target), "%s/mage-plain/%s", self, name);
    }
    argv[0] = target;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETEXEC | POSIX_SPAWN_DISABLE_ASLR);
    posix_spawnattr_setbinpref_np(&attr, 1, &cpu, &n);
    err = posix_spawn(NULL, target, NULL, &attr, argv, environ);
    fprintf(stderr, "mage-tramp: %s: %s\n", target, strerror(err));
    return 127;
}
