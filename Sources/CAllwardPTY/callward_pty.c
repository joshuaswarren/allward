#include "callward_pty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>
#include <util.h>
#include <sys/wait.h>

static int allward_configure_master(int master) {
    int status_flags = fcntl(master, F_GETFL);
    if (status_flags == -1 || fcntl(master, F_SETFL, status_flags | O_NONBLOCK) == -1) {
        return -1;
    }

    int descriptor_flags = fcntl(master, F_GETFD);
    if (descriptor_flags == -1 || fcntl(master, F_SETFD, descriptor_flags | FD_CLOEXEC) == -1) {
        return -1;
    }

    return 0;
}

pid_t allward_pty_spawn(
    int *master,
    const struct winsize *ws,
    const char *shell,
    char *const argv[],
    char *const envp[],
    const char *cwd
) {
    if (master == NULL || ws == NULL || shell == NULL || argv == NULL || envp == NULL) {
        errno = EINVAL;
        return -1;
    }

    struct winsize child_size = *ws;
    pid_t child = forkpty(master, NULL, NULL, &child_size);
    if (child == -1) {
        return -1;
    }

    if (child == 0) {
        if (cwd != NULL && chdir(cwd) == -1) {
            _exit(126);
        }
        execve(shell, argv, envp);
        _exit(127);
    }

    if (allward_configure_master(*master) == -1) {
        int saved_errno = errno;
        close(*master);
        kill(child, SIGKILL);
        while (waitpid(child, NULL, 0) == -1 && errno == EINTR) {
        }
        errno = saved_errno;
        return -1;
    }

    return child;
}
