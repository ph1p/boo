#ifndef PTY_HELPER_H
#define PTY_HELPER_H

#include <sys/types.h>
#include <libproc.h>

/// Fork a child process with a new PTY.
/// Returns the child PID (>0 in parent, 0 in child, -1 on error).
/// Sets *master_fd to the master PTY fd in the parent.
pid_t pty_fork(int *master_fd, unsigned short rows, unsigned short cols);

/// Exec a login shell in the child process (call only in child after pty_fork returns 0).
/// Does not return on success.
void pty_exec_shell(const char *shell_path, const char *working_dir);

#endif
