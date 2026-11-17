#include "hive_process.h"

#include <windows.h>
#include <winternl.h>

/* ProcessCommandLineInformation. winternl.h does not declare it; the value is documented in the WDK. */
#define HIVE_CLASS_COMMAND_LINE ((PROCESSINFOCLASS)60)

typedef struct _HIVE_UNICODE_STRING {
    USHORT Length;
    USHORT MaximumLength;
    PWSTR Buffer;
} HIVE_UNICODE_STRING;

typedef struct _HIVE_COMMAND_LINE_INFO {
    HIVE_UNICODE_STRING CommandLine;
} HIVE_COMMAND_LINE_INFO;

typedef NTSTATUS(NTAPI *HiveNtQueryInformationProcess)(HANDLE, PROCESSINFOCLASS, PVOID, ULONG, PULONG);

static HiveNtQueryInformationProcess hive_query_information(void)
{
    static HiveNtQueryInformationProcess cached = NULL;
    if (cached == NULL) {
        HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
        if (ntdll == NULL) {
            return NULL;
        }
        cached = (HiveNtQueryInformationProcess)(void *)GetProcAddress(ntdll, "NtQueryInformationProcess");
    }
    return cached;
}

int hive_process_command_line(unsigned long pid, wchar_t *buffer, int capacity)
{
    if (buffer == NULL || capacity <= 0) {
        return -1;
    }
    buffer[0] = L'\0';

    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid);
    if (process == NULL) {
        return -1;
    }

    HiveNtQueryInformationProcess query = hive_query_information();
    if (query == NULL) {
        CloseHandle(process);
        return -1;
    }

    /* One call with the caller's room. A probe first would double the work for every process in the list, and
       the list is rebuilt every 2 seconds. Room for the header is added to the caller's characters. */
    SIZE_T room = (SIZE_T)capacity * sizeof(wchar_t) + sizeof(HIVE_COMMAND_LINE_INFO);
    BYTE *raw = (BYTE *)HeapAlloc(GetProcessHeap(), 0, room);
    if (raw == NULL) {
        CloseHandle(process);
        return -1;
    }

    ULONG needed = (ULONG)room;
    int written = -1;
    NTSTATUS status = query(process, HIVE_CLASS_COMMAND_LINE, raw, needed, &needed);
    if (status == 0) {
        HIVE_COMMAND_LINE_INFO *info = (HIVE_COMMAND_LINE_INFO *)raw;
        USHORT units = (USHORT)(info->CommandLine.Length / sizeof(wchar_t));
        if (units > 0 && info->CommandLine.Buffer != NULL) {
            int take = units < capacity - 1 ? (int)units : capacity - 1;
            wmemcpy(buffer, info->CommandLine.Buffer, (size_t)take);
            buffer[take] = L'\0';
            written = take;
        } else {
            written = 0;
        }
    }

    HeapFree(GetProcessHeap(), 0, raw);
    CloseHandle(process);
    return written;
}
