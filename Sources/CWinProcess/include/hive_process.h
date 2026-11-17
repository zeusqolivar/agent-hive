#ifndef HIVE_PROCESS_H
#define HIVE_PROCESS_H

#include <wchar.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The command line of another process, read through
   NtQueryInformationProcess(ProcessCommandLineInformation), which Windows exposes but Swift's WinSDK module
   does not. Writes at most `capacity` UTF-16 units to `buffer`, always terminated when capacity > 0, and
   returns the length written (without the terminator). Returns -1 on failure, which is normal for elevated or
   protected processes: callers fall back to the executable name. */
int hive_process_command_line(unsigned long pid, wchar_t *buffer, int capacity);

#ifdef __cplusplus
}
#endif

#endif /* HIVE_PROCESS_H */
