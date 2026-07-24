#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s STAGED_PATH TARGET_PATH\n", argv[0]);
        return 64;
    }

    const char *staged = argv[1];
    const char *target = argv[2];

    if (access(staged, F_OK) != 0) {
        fprintf(stderr, "error: staged path is missing: %s\n", staged);
        return 1;
    }

    int result;
    if (access(target, F_OK) == 0) {
        result = renameatx_np(
            AT_FDCWD, staged, AT_FDCWD, target, RENAME_SWAP);
    } else {
        result = rename(staged, target);
    }

    if (result != 0) {
        fprintf(stderr, "error: atomic replacement failed: %s\n",
                strerror(errno));
        return 1;
    }

    return 0;
}
