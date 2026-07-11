/*
 * rmt: a drop-in replacement for rm(1) on macOS that moves files to the
 * Trash instead of unlinking them.
 *
 * Accepts the full BSD rm flag surface (-d -f -i -I -P -R -r -v -W -x, --)
 * and mirrors rm's error messages, prompts, and exit codes so it can be
 * aliased to rm without breaking scripts or muscle memory.
 *
 * Files are trashed via -[NSFileManager trashItemAtURL:], the same API
 * behind /usr/bin/trash: same-volume moves are a single rename, per-volume
 * trashes and name collisions are handled by the system.
 */

#import <Foundation/Foundation.h>

#include <dirent.h>
#include <errno.h>
#include <getopt.h>
#include <libgen.h>
#include <pwd.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static bool dflag, fflag, iflag, Iflag, rflag, vflag, Wflag, xflag;
static int eval; /* exit status: 0 ok, 1 if any operand failed */

static void usage(void) {
    fprintf(stderr, "usage: rm [-f | -i] [-dIPRrvWx] file ...\n");
    exit(1);
}

/* Read one line from stdin; true iff it starts with y/Y. Mirrors rm(1). */
static bool ask(void) {
    int ch = getchar();
    bool yes = (ch == 'y' || ch == 'Y');
    while (ch != '\n' && ch != EOF)
        ch = getchar();
    return yes;
}

static bool dir_is_empty(const char *path) {
    DIR *dp = opendir(path);
    if (dp == NULL)
        return false;
    const struct dirent *de;
    bool empty = true;
    while ((de = readdir(dp)) != NULL) {
        if (strcmp(de->d_name, ".") != 0 && strcmp(de->d_name, "..") != 0) {
            empty = false;
            break;
        }
    }
    closedir(dp);
    return empty;
}

/* rm refuses to operate on ".", "..", and "/" (POSIX). */
static bool checkdot(const char *path) {
    char buf[PATH_MAX];
    strlcpy(buf, path, sizeof(buf));
    const char *base = basename(buf);
    if (strcmp(base, ".") == 0 || strcmp(base, "..") == 0) {
        fprintf(stderr, "rm: \".\" and \"..\" may not be removed\n");
        eval = 1;
        return true;
    }
    char resolved[PATH_MAX];
    if (realpath(path, resolved) != NULL && strcmp(resolved, "/") == 0) {
        fprintf(stderr, "rm: \"/\" may not be removed\n");
        eval = 1;
        return true;
    }
    return false;
}

/* -I: one confirmation when removing >3 files or recursing into a dir. */
static bool check_batch(int argc, char *const argv[]) {
    int files = 0;
    struct stat sb;
    for (int i = 0; i < argc; i++) {
        if (rflag && lstat(argv[i], &sb) == 0 && S_ISDIR(sb.st_mode)) {
            fprintf(stderr, "recursively remove %s? ", argv[i]);
            if (!ask())
                return false;
        } else {
            files++;
        }
    }
    if (files > 3) {
        fprintf(stderr, "remove %d files? ", files);
        return ask();
    }
    return true;
}

/*
 * Fast path: for items on the same volume as ~/.Trash with no name
 * collision, a single atomic rename beats the full trashItemAtURL:
 * machinery by ~10ms per call. RENAME_EXCL guarantees we can never
 * overwrite something already in the Trash; any failure (collision,
 * cross-volume, missing Trash) falls back to the system API, which
 * uniquifies names and locates per-volume trashes.
 */
static char trash_dir[PATH_MAX];
static dev_t trash_dev;

static void init_fast_path(void) {
    const char *home = getenv("HOME");
    if (home == NULL || *home != '/') {
        const struct passwd *pw = getpwuid(getuid());
        home = pw != NULL ? pw->pw_dir : NULL;
    }
    struct stat sb;
    if (home != NULL &&
        snprintf(trash_dir, sizeof(trash_dir), "%s/.Trash", home) <
            (int)sizeof(trash_dir) &&
        lstat(trash_dir, &sb) == 0 && S_ISDIR(sb.st_mode))
        trash_dev = sb.st_dev;
    else
        trash_dir[0] = '\0';
}

static bool trash_fast(const char *path, const struct stat *sb) {
    if (trash_dir[0] == '\0' || sb->st_dev != trash_dev)
        return false;
    char namebuf[PATH_MAX], dst[PATH_MAX];
    strlcpy(namebuf, path, sizeof(namebuf));
    const char *name = basename(namebuf);
    if (snprintf(dst, sizeof(dst), "%s/%s", trash_dir, name) >=
        (int)sizeof(dst))
        return false;
    return renamex_np(path, dst, RENAME_EXCL) == 0;
}

static void trash_one(const char *path, bool stdin_tty) {
    struct stat sb;

    if (lstat(path, &sb) != 0) {
        /* -f silences only "file doesn't exist", like rm. */
        if (!fflag || errno != ENOENT) {
            fprintf(stderr, "rm: %s: %s\n", path, strerror(errno));
            eval = 1;
        }
        return;
    }

    if (S_ISDIR(sb.st_mode) && !rflag) {
        if (!dflag) {
            fprintf(stderr, "rm: %s: is a directory\n", path);
            eval = 1;
            return;
        }
        if (!dir_is_empty(path)) {
            fprintf(stderr, "rm: %s: Directory not empty\n", path);
            eval = 1;
            return;
        }
    }

    if (iflag) {
        fprintf(stderr, "remove %s? ", path);
        if (!ask())
            return;
    } else if (!fflag && stdin_tty && !S_ISLNK(sb.st_mode) &&
               access(path, W_OK) != 0 && errno == EACCES) {
        /* Write-protected and interactive: confirm, like rm does. */
        char mode[12];
        strmode(sb.st_mode, mode);
        fprintf(stderr, "override %s for %s? ", mode, path);
        if (!ask())
            return;
    }

    if (trash_fast(path, &sb)) {
        if (vflag)
            printf("%s\n", path);
        return;
    }

    @autoreleasepool {
        NSURL *url = [NSURL fileURLWithPath:@(path)
                                isDirectory:S_ISDIR(sb.st_mode)];
        NSError *err = nil;
        if ([[NSFileManager defaultManager] trashItemAtURL:url
                                          resultingItemURL:NULL
                                                     error:&err]) {
            if (vflag)
                printf("%s\n", path);
        } else {
            NSError *posix = err;
            while (posix != nil && ![posix.domain isEqualToString:NSPOSIXErrorDomain])
                posix = posix.userInfo[NSUnderlyingErrorKey];
            fprintf(stderr, "rm: %s: %s\n", path,
                    posix != nil ? strerror((int)posix.code)
                                 : err.localizedDescription.UTF8String);
            eval = 1;
        }
    }
}

int main(int argc, char *argv[]) {
    int ch;
    while ((ch = getopt(argc, argv, "dfiIPRrvWx")) != -1) {
        switch (ch) {
        case 'd': dflag = true; break;
        case 'f': fflag = true; iflag = false; break;
        case 'i': iflag = true; fflag = false; break;
        case 'I': Iflag = true; break;
        case 'P': break; /* no effect; kept for compatibility, as in rm(1) */
        case 'R':
        case 'r': rflag = true; break;
        case 'v': vflag = true; break;
        case 'W': Wflag = true; break;
        case 'x': xflag = true; break; /* accepted; trees are trashed whole */
        default: usage();
        }
    }
    argc -= optind;
    argv += optind;

    if (argc < 1) {
        if (fflag)
            return 0;
        usage();
    }

    if (Wflag) {
        /* rm -W undeletes whiteouts on union mounts; macOS has none. */
        for (int i = 0; i < argc; i++) {
            fprintf(stderr, "rm: %s: %s\n", argv[i], strerror(ENOTSUP));
        }
        return 1;
    }

    if (Iflag && !check_batch(argc, argv))
        return 1;

    init_fast_path();

    bool stdin_tty = isatty(STDIN_FILENO);
    for (int i = 0; i < argc; i++) {
        if (checkdot(argv[i]))
            continue;
        trash_one(argv[i], stdin_tty);
    }

    return eval;
}
