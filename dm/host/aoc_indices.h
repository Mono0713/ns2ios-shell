#pragma once

#include <dirent.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/stat.h>

// The DLC title ID stores its index in the low 12 bits.
enum { AOC_MAX_INDEX = 0xfff };

static inline int aoc_compare_indices(const void *a, const void *b) {
    return *(const int *)a - *(const int *)b;
}

static inline int aoc_read_indices(const char *path, int indices[AOC_MAX_INDEX]) {
    DIR *dir = opendir(path);
    if (!dir) return 0;

    int count = 0;
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (entry->d_name[0] < '1' || entry->d_name[0] > '9') continue;
        char *end;
        long index = strtol(entry->d_name, &end, 10);
        if (*end || index > AOC_MAX_INDEX) continue;

        struct stat st;
        if (fstatat(dirfd(dir), entry->d_name, &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISDIR(st.st_mode))
            indices[count++] = (int)index;
    }
    closedir(dir);
    qsort(indices, (size_t)count, sizeof *indices, aoc_compare_indices);
    return count;
}
