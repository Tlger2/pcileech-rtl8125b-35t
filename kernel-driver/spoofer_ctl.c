#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include "kernel_spoofer.h"

static HANDLE OpenDev(void)
{
    return CreateFileA(EACSPOOF_WIN32_NAME, GENERIC_READ | GENERIC_WRITE,
                       0, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
}

static int Ioctl(HANDLE h, DWORD code, void *in, DWORD inLen, void *out, DWORD outLen, DWORD *ret)
{
    return DeviceIoControl(h, code, in, inLen, out, outLen, ret, NULL) ? 0 : (int)GetLastError();
}

static void PrintMac(const unsigned char *m)
{
    printf("%02X:%02X:%02X:%02X:%02X:%02X", m[0], m[1], m[2], m[3], m[4], m[5]);
}

static void PrintStats(const EACSPOOF_STATS *s)
{
    printf("loaded=%u modules=0x%X\n", s->loaded, s->modulesLive);
    printf("  irpFiltered=%llu identify=%llu inquiry=%llu smbios=%llu\n",
           (unsigned long long)s->irpFiltered, (unsigned long long)s->identifyRewrites,
           (unsigned long long)s->inquiryRewrites, (unsigned long long)s->smbiosQueries);
    printf("  oid=%llu mac=%llu arp=%llu eacNotify=%llu stripped=%llu splice=%llu hide=%llu\n",
           (unsigned long long)s->oidIntercepts, (unsigned long long)s->macRewrites,
           (unsigned long long)s->arpRewrites, (unsigned long long)s->eacImageNotifies,
           (unsigned long long)s->callbacksStripped, (unsigned long long)s->integrityReadsSpliced,
           (unsigned long long)s->moduleListHides);
}

int main(int argc, char **argv)
{
    HANDLE h;
    DWORD ret = 0;
    EACSPOOF_STATS stats;
    EACSPOOF_CONFIG cfg;
    EACSPOOF_MODULE_OP op;
    const char *cmd;

    if (argc < 2) {
        printf("spoofer_ctl status|get|set-apply|on <mask>|off <mask>|randomize\n");
        printf("mask: storage=1 smbios=2 network=4 eac=8 all=15\n");
        return 1;
    }
    cmd = argv[1];
    h = OpenDev();
    if (h == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "open %s failed (%lu) — is EacSpoofer.sys loaded?\n",
                EACSPOOF_WIN32_NAME, GetLastError());
        return 2;
    }

    if (strcmp(cmd, "status") == 0) {
        if (Ioctl(h, IOCTL_EACSPOOF_GET_STATS, NULL, 0, &stats, sizeof(stats), &ret))
            fprintf(stderr, "ioctl failed %lu\n", GetLastError());
        else
            PrintStats(&stats);
    } else if (strcmp(cmd, "get") == 0) {
        if (Ioctl(h, IOCTL_EACSPOOF_GET_CONFIG, NULL, 0, &cfg, sizeof(cfg), &ret))
            fprintf(stderr, "ioctl failed %lu\n", GetLastError());
        else {
            printf("modules=0x%X disks=%u nics=%u\n", cfg.modules, cfg.diskCount, cfg.nicCount);
            printf("disk0 serial=%s model=%s\n", cfg.disks[0].serial, cfg.disks[0].model);
            printf("uuid serial=%s board=%s\n", cfg.smbios.sysSerial, cfg.smbios.boardSerial);
            printf("mac "); PrintMac(cfg.nics[0].currentMac); printf(" guid=%s\n", cfg.nics[0].adapterGuid);
        }
    } else if (strcmp(cmd, "set-apply") == 0) {
        if (Ioctl(h, IOCTL_EACSPOOF_GET_CONFIG, NULL, 0, &cfg, sizeof(cfg), &ret) == 0) {
            cfg.modules = EACSPOOF_MOD_ALL;
            Ioctl(h, IOCTL_EACSPOOF_SET_CONFIG, &cfg, sizeof(cfg), NULL, 0, &ret);
            if (Ioctl(h, IOCTL_EACSPOOF_APPLY, NULL, 0, NULL, 0, &ret))
                fprintf(stderr, "apply failed %lu\n", GetLastError());
            else
                printf("applied all modules\n");
        }
    } else if ((strcmp(cmd, "on") == 0 || strcmp(cmd, "off") == 0) && argc >= 3) {
        op.moduleMask = (ULONG)strtoul(argv[2], NULL, 0);
        if (Ioctl(h, strcmp(cmd, "on") == 0 ? IOCTL_EACSPOOF_MODULE_ON : IOCTL_EACSPOOF_MODULE_OFF,
                  &op, sizeof(op), NULL, 0, &ret))
            fprintf(stderr, "module ioctl failed %lu\n", GetLastError());
        else
            printf("%s 0x%X\n", cmd, op.moduleMask);
    } else if (strcmp(cmd, "randomize") == 0) {
        if (Ioctl(h, IOCTL_EACSPOOF_RANDOMIZE, NULL, 0, &cfg, sizeof(cfg), &ret))
            fprintf(stderr, "randomize failed %lu\n", GetLastError());
        else
            printf("seeded defaults, serial=%s\n", cfg.disks[0].serial);
    } else {
        fprintf(stderr, "unknown command %s\n", cmd);
        CloseHandle(h);
        return 1;
    }
    CloseHandle(h);
    return 0;
}
