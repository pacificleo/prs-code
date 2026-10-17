#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static void get_cache_paths(char *dir, size_t dir_len, char *file, size_t file_len) {
    const char *xdg = getenv("XDG_STATE_HOME");
    if (xdg && *xdg) {
        snprintf(dir, dir_len, "%s/ghostty", xdg);
    } else {
        const char *home = getenv("HOME");
        if (!home) home = "";
        snprintf(dir, dir_len, "%s/.local/state/ghostty", home);
    }
    snprintf(file, file_len, "%s/ssh_cache", dir);
}

int main(int argc, char *argv[]) {
    if (argc < 2) return 1;
    if (strcmp(argv[1], "+ssh-cache") != 0) return 1;

    char dir[1024];
    char file[1024];
    get_cache_paths(dir, sizeof(dir), file, sizeof(file));

    if (argc == 2) {
        FILE *f = fopen(file, "r");
        if (f) {
            char line[1024];
            while (fgets(line, sizeof(line), f)) {
                fputs(line, stdout);
            }
            fclose(f);
        }
        return 0;
    }

    for (int i = 2; i < argc; i++) {
        const char *arg = argv[i];
        if (strncmp(arg, "--host=", 7) == 0) {
            const char *host = arg + 7;
            size_t host_len = strlen(host);
            FILE *f = fopen(file, "r");
            if (!f) return 1;
            char line[1024];
            int found = 0;
            while (fgets(line, sizeof(line), f)) {
                if (strncmp(line, host, host_len) == 0 && line[host_len] == '|') {
                    found = 1;
                    break;
                }
            }
            fclose(f);
            return found ? 0 : 1;
        } else if (strncmp(arg, "--add=", 6) == 0) {
            const char *host = arg + 6;
            size_t host_len = strlen(host);
            char cmd[1200];
            snprintf(cmd, sizeof(cmd), "mkdir -p \"%s\"", dir);
            (void)system(cmd);

            char temp_file[1050];
            snprintf(temp_file, sizeof(temp_file), "%s.tmp.%d", file, getpid());
            FILE *in = fopen(file, "r");
            FILE *out = fopen(temp_file, "w");
            if (out) {
                if (in) {
                    char line[1024];
                    while (fgets(line, sizeof(line), in)) {
                        if (strncmp(line, host, host_len) == 0 && line[host_len] == '|') {
                            continue;
                        }
                        fputs(line, out);
                    }
                    fclose(in);
                }
                fprintf(out, "%s|%ld|xterm-ghostty\n", host, (long)time(NULL));
                fclose(out);
                rename(temp_file, file);
                chmod(file, 0600);
            }
            return 0;
        } else if (strncmp(arg, "--remove=", 9) == 0) {
            const char *host = arg + 9;
            size_t host_len = strlen(host);
            char temp_file[1050];
            snprintf(temp_file, sizeof(temp_file), "%s.tmp.%d", file, getpid());
            FILE *in = fopen(file, "r");
            if (in) {
                FILE *out = fopen(temp_file, "w");
                if (out) {
                    char line[1024];
                    while (fgets(line, sizeof(line), in)) {
                        if (strncmp(line, host, host_len) == 0 && line[host_len] == '|') {
                            continue;
                        }
                        fputs(line, out);
                    }
                    fclose(out);
                    rename(temp_file, file);
                }
                fclose(in);
            }
            return 0;
        } else if (strcmp(arg, "--clear") == 0) {
            unlink(file);
            return 0;
        }
    }

    return 0;
}
