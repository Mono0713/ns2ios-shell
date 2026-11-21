#include "../aoc_indices.h"
#include <assert.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
    assert(argc == 2);
    const char *dir = argv[1];
    char path[4096];
    int indices[AOC_MAX_INDEX];
    assert(aoc_read_indices(dir, indices) == 0);
    assert(mkdir(dir, 0700) == 0);
    assert(aoc_read_indices(dir, indices) == 0);

    // 99 distinct add-ons, sparse and created in reverse order, including an index above 2000.
    for (int i = 99; i >= 1; i--) {
        int index = i == 99 ? AOC_MAX_INDEX : i * 3;
        snprintf(path, sizeof path, "%s/%d", dir, index);
        assert(mkdir(path, 0700) == 0);
    }
    snprintf(path, sizeof path, "%s/4096", dir);
    assert(mkdir(path, 0700) == 0);
    snprintf(path, sizeof path, "%s/003", dir);
    assert(mkdir(path, 0700) == 0);
    snprintf(path, sizeof path, "%s/undeclared", dir);
    assert(mkdir(path, 0700) == 0);
    snprintf(path, sizeof path, "%s/1", dir);
    FILE *invalid = fopen(path, "w");
    assert(invalid != NULL);
    fclose(invalid);

    assert(aoc_read_indices(dir, indices) == 99);
    for (int i = 0; i < 98; i++) assert(indices[i] == (i + 1) * 3);
    assert(indices[98] == AOC_MAX_INDEX);
    puts("AOC: all 99 add-ons discovered in order; invalid entries excluded");
    return 0;
}
