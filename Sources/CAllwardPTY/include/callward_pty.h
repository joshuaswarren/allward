#ifndef CALLWARD_PTY_H
#define CALLWARD_PTY_H

#include <sys/ioctl.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

pid_t allward_pty_spawn(
    int *master,
    const struct winsize *ws,
    const char *shell,
    char *const argv[],
    char *const envp[],
    const char *cwd
);

#ifdef __cplusplus
}
#endif

#endif
