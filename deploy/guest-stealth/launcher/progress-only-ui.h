#ifndef RESPAWN_STEALTH_PROGRESS_ONLY_UI_H
#define RESPAWN_STEALTH_PROGRESS_ONLY_UI_H

#include <windows.h>

int progress_only_ui_start(void);
void progress_only_ui_set_running(void);
void progress_only_ui_finish(int succeeded);
BOOL progress_only_create_process(
    const wchar_t *application,
    wchar_t *command_line,
    wchar_t *environment,
    const wchar_t *work_dir,
    PROCESS_INFORMATION *process);

#endif
