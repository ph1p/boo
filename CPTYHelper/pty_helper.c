#include "pty_helper.h"
#include <util.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <errno.h>

pid_t pty_fork(int *master_fd, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = rows;
    ws.ws_col = cols;

    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) {
        return -1;
    }

    *master_fd = master;
    return pid;
}

void pty_exec_shell(const char *shell_path, const char *working_dir) {
    setsid();

    if (working_dir && working_dir[0] != '\0') {
        chdir(working_dir);
    }

    // Build shell name as login shell (prefix with -)
    const char *base = strrchr(shell_path, '/');
    base = base ? base + 1 : shell_path;

    char login_name[256];
    snprintf(login_name, sizeof(login_name), "-%s", base);

    // Set TERM
    setenv("TERM", "xterm-256color", 1);
    setenv("COLORTERM", "truecolor", 1);

    char *argv[] = { login_name, NULL };
    execv(shell_path, argv);
    _exit(1);
}
