#include "cmd_osinfo.h"
#include "output.h"
#include "bsonutil.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#ifdef __APPLE__
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/statvfs.h>
#include <mach/mach.h>
#endif

/*
 * -osinfo
 *
 * Host CPU, memory, disk and I/O metrics (macOS).
 *
 * Combines:
 *   sysctl      → CPU info, total RAM
 *   mach API    → VM statistics (free / active / inactive / wired pages)
 *   popen       → CPU usage from `top -l 1 -n 0`
 *   popen       → disk I/O from `iostat -d -c 2`
 *   statvfs     → filesystem usage of /
 *   MongoDB serverStatus → pid, uptime, version
 */

/* ── helpers ─────────────────────────────────────────────────────────────── */

#ifdef __APPLE__

static int64_t sysctl_int64(const char *name) {
    int64_t val = 0;
    size_t sz = sizeof(val);
    sysctlbyname(name, &val, &sz, NULL, 0);
    return val;
}

static void sysctl_str(const char *name, char *buf, size_t sz) {
    sysctlbyname(name, buf, &sz, NULL, 0);
}

static void print_cpu_info(void) {
    print_section("CPU");
    char brand[256] = "";
    sysctl_str("machdep.cpu.brand_string", brand, sizeof(brand));
    int64_t phys = sysctl_int64("hw.physicalcpu");
    int64_t log  = sysctl_int64("hw.logicalcpu");
    printf("  %-30s  %s\n",  "Model",          bu_or_dash(brand));
    printf("  %-30s  %lld\n","Physical cores",  (long long)phys);
    printf("  %-30s  %lld\n","Logical CPUs",    (long long)log);

    /* CPU usage from top */
    FILE *fp = popen("top -l 1 -n 0 | grep 'CPU usage'", "r");
    if (fp) {
        char line[256] = "";
        if (fgets(line, sizeof(line), fp)) {
            line[strcspn(line, "\n")] = '\0';
            printf("  %-30s  %s\n", "CPU usage", line);
        }
        pclose(fp);
    }
}

static void print_memory_info(void) {
    print_section("Memory");
    int64_t total_bytes = sysctl_int64("hw.memsize");
    printf("  %-30s  %.2f GB\n", "Total RAM",
           (double)total_bytes / 1024.0 / 1024.0 / 1024.0);

    /* VM stats via mach */
    mach_port_t host = mach_host_self();
    vm_size_t page_size = 0;
    host_page_size(host, &page_size);

    vm_statistics64_data_t vm_stat;
    mach_msg_type_number_t cnt = HOST_VM_INFO64_COUNT;
    if (host_statistics64(host, HOST_VM_INFO64,
                          (host_info64_t)&vm_stat, &cnt) == KERN_SUCCESS) {
        double ps = (double)page_size;
        double free_mb    = (double)vm_stat.free_count         * ps / 1048576.0;
        double active_mb  = (double)vm_stat.active_count       * ps / 1048576.0;
        double inactive_mb= (double)vm_stat.inactive_count     * ps / 1048576.0;
        double wired_mb   = (double)vm_stat.wire_count         * ps / 1048576.0;
        double compressed = (double)vm_stat.compressor_page_count * ps / 1048576.0;
        printf("  %-30s  %.0f MB\n", "Free",       free_mb);
        printf("  %-30s  %.0f MB\n", "Active",     active_mb);
        printf("  %-30s  %.0f MB\n", "Inactive",   inactive_mb);
        printf("  %-30s  %.0f MB\n", "Wired",      wired_mb);
        printf("  %-30s  %.0f MB\n", "Compressed", compressed);
    }
    mach_port_deallocate(mach_task_self(), host);
}

static void print_disk_info(void) {
    print_section("Disk / Filesystem");

    /* statvfs for / */
    struct statvfs sv;
    if (statvfs("/", &sv) == 0) {
        double total = (double)sv.f_blocks * (double)sv.f_frsize;
        double free  = (double)sv.f_bfree  * (double)sv.f_frsize;
        double used  = total - free;
        printf("  / (root)\n");
        printf("  %-30s  %.2f GB\n", "Total",     total / 1e9);
        printf("  %-30s  %.2f GB\n", "Used",      used  / 1e9);
        printf("  %-30s  %.2f GB\n", "Free",      free  / 1e9);
        printf("  %-30s  %.1f%%\n",  "Usage",     used / total * 100.0);
    }

    /* iostat for I/O rates */
    FILE *fp = popen("iostat -d -c 2 2>/dev/null | tail -1", "r");
    if (fp) {
        char line[512] = "";
        if (fgets(line, sizeof(line), fp)) {
            line[strcspn(line, "\n")] = '\0';
            printf("  %-30s  %s\n", "iostat (disk)", line);
        }
        pclose(fp);
    }
}

#else /* non-Apple stub */

static void print_cpu_info(void)    { print_warn("CPU info only available on macOS."); }
static void print_memory_info(void) { print_warn("Memory info only available on macOS."); }
static void print_disk_info(void)   { print_warn("Disk info only available on macOS."); }

#endif /* __APPLE__ */

/* ── process info from serverStatus ─────────────────────────────────────── */

static void print_process_info(Conn *c) {
    bson_t *cmd = BCON_NEW("serverStatus", BCON_INT32(1),
                           "metrics", BCON_INT32(0));
    bson_t reply; bson_error_t err;
    if (!conn_admin_cmd(c, cmd, &reply, &err)) {
        bson_destroy(cmd); return;
    }
    bson_destroy(cmd);

    print_section("mongod Process");
    char version[64] = "", host[256] = "";
    int64_t pid = 0, uptime = 0;
    bu_str(&reply,   "version",  version, sizeof(version));
    bu_str(&reply,   "host",     host,    sizeof(host));
    bu_int64(&reply, "pid",      &pid);
    bu_int64(&reply, "uptimeMillis", &uptime);

    printf("  %-30s  %s\n",   "Version",  bu_or_dash(version));
    printf("  %-30s  %s\n",   "Host",     bu_or_dash(host));
    printf("  %-30s  %lld\n", "PID",      (long long)pid);
    printf("  %-30s  %.1f h\n","Uptime",  (double)uptime / 1000.0 / 3600.0);

    /* MongoDB process CPU/memory via ps */
    if (pid > 0) {
        char ps_cmd[128];
        snprintf(ps_cmd, sizeof(ps_cmd),
                 "ps -p %lld -o pcpu=,pmem=,rss=,vsz= 2>/dev/null", (long long)pid);
        FILE *fp = popen(ps_cmd, "r");
        if (fp) {
            double pcpu = 0, pmem = 0;
            long long rss = 0, vsz = 0;
            if (fscanf(fp, "%lf %lf %lld %lld", &pcpu, &pmem, &rss, &vsz) == 4) {
                printf("  %-30s  %.1f%%\n", "CPU%",     pcpu);
                printf("  %-30s  %.1f%%\n", "MEM%",     pmem);
                printf("  %-30s  %.1f MB\n","RSS",      (double)rss / 1024.0);
                printf("  %-30s  %.1f MB\n","VSZ",      (double)vsz / 1024.0);
            }
            pclose(fp);
        }
    }

    bson_destroy(&reply);
}

/* ── entry point ─────────────────────────────────────────────────────────── */

void cmd_osinfo(Conn *c, const Args *a) {
    (void)a;
    print_header("OS and Host Metrics  [equiv: db2pd -osinfo]");
    print_cpu_info();
    print_memory_info();
    print_disk_info();
    print_process_info(c);
    print_footer();
}
