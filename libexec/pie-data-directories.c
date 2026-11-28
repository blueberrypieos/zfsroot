/* SPDX-License-Identifier: BSD-2-Clause */
/* Copyright (c) 2026 The Blueberry Pie OS Authors */
/* usage: pie-data-directories ROOT OVERRIDES LABEL < PATHS */
#define _POSIX_C_SOURCE 200809L
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <errno.h>
#include <grp.h>
#include <inttypes.h>
#include <limits.h>
#include <pwd.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

#ifndef PIE_DATA_COMPAT
#define PIE_DATA_COMPAT "/usr/libexec/pie-data-directory-legacy"
#endif
#define PIE_ID_MAX ((uintmax_t)2147483647)

struct ownership {
    uid_t uid;
    gid_t gid;
    mode_t mode;
    bool found;
};

static const char *label;

static bool
plain(const char *value)
{
    for (const unsigned char *p = (const unsigned char *)value; *p; p++)
        if (*p < 32 || *p > 126 || *p == '\\')
            return false;
    return true;
}

static bool
account_text(const char *value)
{
    if (*value == '#')
        value++;
    if (!*value || *value == '-' || *value == '+')
        return false;
    for (const unsigned char *p = (const unsigned char *)value; *p; p++)
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
            (*p >= '0' && *p <= '9') || *p == '_' || *p == '.' || *p == '-'))
            return false;
    return true;
}

static bool
number(const char *text, uintmax_t maximum, uintmax_t *result)
{
    if (!*text)
        return false;
    for (const char *p = text; *p; p++)
        if (*p < '0' || *p > '9')
            return false;
    char *end;
    errno = 0;
    uintmax_t value = strtoumax(text, &end, 10);
    if (errno || *end || value > maximum)
        return false;
    *result = value;
    return true;
}

static bool
parse_owner(char **fields, struct ownership *owner)
{
    if (!account_text(fields[0]) || !account_text(fields[1]))
        return false;
    const char *user = fields[0] + (fields[0][0] == '#');
    const char *group = fields[1] + (fields[1][0] == '#');
    uintmax_t value;
    struct passwd *pw = getpwnam(user);
    if (pw)
        owner->uid = pw->pw_uid;
    else if (number(user, PIE_ID_MAX, &value))
        owner->uid = (uid_t)value;
    else
        return false;
    struct group *gr = getgrnam(group);
    if (gr)
        owner->gid = gr->gr_gid;
    else if (number(group, PIE_ID_MAX, &value))
        owner->gid = (gid_t)value;
    else
        return false;
    if (!*fields[2])
        return false;
    for (const char *p = fields[2]; *p; p++)
        if (*p < '0' || *p > '7')
            return false;
    char *end;
    errno = 0;
    value = strtoumax(fields[2], &end, 8);
    if (errno || *end || value > 07777)
        return false;
    owner->mode = (mode_t)value;
    owner->found = true;
    return true;
}

static bool
lookup(const char *database, const char *path, struct ownership *owner)
{
    FILE *file = fopen(database, "r");
    if (!file)
        return true;
    char *line = NULL;
    size_t capacity = 0;
    ssize_t length;
    bool supported = true;
    while ((length = getline(&line, &capacity, file)) >= 0) {
        if (memchr(line, 0, (size_t)length)) {
            supported = false;
            break;
        }
        if (length && line[length - 1] == '\n')
            line[--length] = 0;
        for (ssize_t i = 0; i < length; i++) {
            unsigned char ch = (unsigned char)line[i];
            if ((ch < 32 && ch != '\t') || ch > 126) {
                supported = false;
                break;
            }
        }
        if (!supported)
            break;
        char *fields[4], *p = line;
        unsigned count = 0;
        while (count < 4) {
            while (*p == ' ' || *p == '\t')
                p++;
            if (!*p)
                break;
            fields[count++] = p;
            while (*p && *p != ' ' && *p != '\t')
                p++;
            if (*p)
                *p++ = 0;
        }
        if (count == 4 && strcmp(fields[3], path) == 0) {
            supported = parse_owner(fields, owner);
            break;
        }
    }
    if (ferror(file))
        supported = false;
    free(line);
    fclose(file);
    return supported;
}

static int
legacy(const char *root, const char *database, const char *path)
{
    pid_t pid = fork();
    if (pid < 0) {
        fprintf(stderr, "%s: cannot start directory compatibility helper: %s\n", label, strerror(errno));
        return 1;
    }
    if (!pid) {
        int fd = open("/dev/null", O_RDONLY);
        if (fd < 0 || dup2(fd, STDIN_FILENO) < 0)
            _exit(127);
        if (fd != STDIN_FILENO)
            close(fd);
        execl("/bin/sh", "sh", PIE_DATA_COMPAT, root, database, label, path, (char *)NULL);
        _exit(127);
    }
    int status;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno == EINTR)
            continue;
        fprintf(stderr, "%s: cannot wait for directory compatibility helper: %s\n", label, strerror(errno));
        return 1;
    }
    return !WIFEXITED(status) || WEXITSTATUS(status) != 0;
}

static int
mkdir_parents(char *path)
{
    mode_t saved = umask(0);
    umask(saved);
    size_t length = strlen(path);
    while (length > 1 && path[length - 1] == '/')
        path[--length] = 0;
    int result = 0;
    for (char *p = path + (path[0] == '/'); ; p++) {
        if (*p && *p != '/')
            continue;
        bool last = *p == 0;
        char delimiter = *p;
        *p = 0;
        if (*path) {
            umask(last ? saved : saved & ~(S_IWUSR | S_IXUSR));
            if (mkdir(path, 0777) < 0) {
                int error = errno;
                struct stat state;
                if ((error != EEXIST && error != EISDIR) ||
                    stat(path, &state) < 0 || !S_ISDIR(state.st_mode)) {
                    if (error == EEXIST || error == EISDIR)
                        error = last ? EEXIST : ENOTDIR;
                    fprintf(stderr, "mkdir: %s: %s\n", path, strerror(error));
                    result = 1;
                }
            }
        }
        *p = delimiter;
        if (result || last)
            break;
    }
    umask(saved);
    return result;
}

static int
permissions(const char *path, uid_t uid, gid_t gid, mode_t mode)
{
    if (chown(path, uid, gid) < 0) {
        fprintf(stderr, "chown: %s: %s\n", path, strerror(errno));
        return 1;
    }
    if (chmod(path, mode) < 0) {
        fprintf(stderr, "chmod: %s: %s\n", path, strerror(errno));
        return 1;
    }
    return 0;
}

static int
repair(const char *root, const char *database, const char *path)
{
    if (strcmp(path, "/private/var/lib/dpkg") == 0 ||
        strncmp(path, "/private/var/lib/dpkg/", 22) == 0)
        return 0;
    size_t root_length = strlen(root), path_length = strlen(path);
    if (path[0] != '/' || !plain(path) || root_length >= PATH_MAX ||
        path_length >= PATH_MAX - root_length)
        return legacy(root, database, path);
    struct ownership owner = { 0 };
    if (!lookup(database, path, &owner))
        return legacy(root, database, path);
    char *target = malloc(root_length + path_length + 1);
    if (!target) {
        fprintf(stderr, "%s: cannot allocate directory path\n", label);
        return 1;
    }
    memcpy(target, root, root_length);
    memcpy(target + root_length, path, path_length + 1);
    struct stat state;
    bool exists = stat(target, &state) == 0;
    int result = 0;
    if (!exists || !S_ISDIR(state.st_mode)) {
        if (exists || mkdir_parents(target)) {
            fprintf(stderr, "%s: cannot make %s\n", label, target);
            free(target);
            return 1;
        }
        if (!owner.found)
            result = permissions(target, 0, 0, 0755);
    }
    if (owner.found)
        result = permissions(target, owner.uid, owner.gid, owner.mode);
    free(target);
    return result;
}

int
main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: pie-data-directories ROOT OVERRIDES LABEL\n");
        return 2;
    }
    label = argv[3];
    char *line = NULL;
    size_t capacity = 0;
    ssize_t length;
    int result = 0;
    while ((length = getline(&line, &capacity, stdin)) >= 0) {
        if (!length || line[length - 1] != '\n')
            continue;
        line[--length] = 0;
        if (memchr(line, 0, (size_t)length)) {
            fprintf(stderr, "%s: invalid directory path\n", label);
            result = 1;
            continue;
        }
        while (length && (line[length - 1] == ' ' || line[length - 1] == '\t'))
            line[--length] = 0;
        char *path = line;
        while (*path == ' ' || *path == '\t')
            path++;
        if (repair(argv[1], argv[2], path))
            result = 1;
    }
    if (ferror(stdin)) {
        fprintf(stderr, "%s: cannot read directory paths\n", label);
        result = 1;
    }
    free(line);
    return result;
}
