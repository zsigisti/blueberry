/* main.c — path setup and command dispatch. */
#define _GNU_SOURCE
#include "bpm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

char *g_root, *g_db, *g_cache, *g_index, *g_conf, *g_prov, *g_dest;

void paths_init(void) {
    const char *env = getenv("BPM_ROOT");
    if (!env || !*env) env = "/";
    /* strip trailing slash; "/" becomes "" (good for path building) */
    char *root = xstrdup(env);
    size_t n = strlen(root);
    while (n > 1 && root[n-1] == '/') root[--n] = '\0';
    if (!strcmp(root, "/")) root[0] = '\0';
    g_root  = root;
    g_dest  = (*g_root) ? g_root : "/";        /* real fs target, never "" */
    g_db    = xasprintf("%s/var/lib/bpm/db", g_root);
    g_cache = xasprintf("%s/var/lib/bpm/cache", g_root);
    g_index = xasprintf("%s/var/lib/bpm/index", g_root);
    g_conf  = xasprintf("%s/etc/bpm/repos.conf", g_root);
    g_prov  = xasprintf("%s/etc/bpm/provided", g_root);
}

static void usage(void) {
    fputs(
"bpm " BPM_VERSION " — Blueberry Package Manager\n\n"
"  bpm install <name|file.pkg.tar.zst>...   install (resolve deps from repos)\n"
"  bpm remove  <name>...                    remove installed package(s)\n"
"  bpm update                               sync repo indices\n"
"  bpm upgrade                              upgrade all installed packages\n"
"  bpm search  <term>                       search the repo index\n"
"  bpm list                                 list installed packages\n"
"  bpm info    <name>                       show package metadata\n"
"  bpm files   <name>                       list files a package owns\n"
"  bpm owns    <path>                       which package owns a path\n\n"
"Env: BPM_ROOT=<dir> installs into a staging root instead of /.\n",
        stdout);
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(); return 1; }
    paths_init();

    const char *cmd = argv[1];
    int rest = argc - 2;
    char **args = argv + 2;

    if (!strcmp(cmd, "install") || !strcmp(cmd, "in"))   return cmd_install(rest, args);
    if (!strcmp(cmd, "remove")  || !strcmp(cmd, "rm"))   return cmd_remove(rest, args);
    if (!strcmp(cmd, "update")  || !strcmp(cmd, "up"))   return cmd_update(rest, args);
    if (!strcmp(cmd, "upgrade"))                          return cmd_upgrade(rest, args);
    if (!strcmp(cmd, "search")  || !strcmp(cmd, "se"))   return cmd_search(rest, args);
    if (!strcmp(cmd, "list")    || !strcmp(cmd, "ls"))   return cmd_list(rest, args);
    if (!strcmp(cmd, "info"))                             return cmd_info(rest, args);
    if (!strcmp(cmd, "files"))                            return cmd_files(rest, args);
    if (!strcmp(cmd, "owns"))                             return cmd_owns(rest, args);
    if (!strcmp(cmd, "-h") || !strcmp(cmd, "--help") || !strcmp(cmd, "help")) {
        usage(); return 0;
    }
    die("unknown command '%s' (try: bpm help)", cmd);
    return 1;
}
