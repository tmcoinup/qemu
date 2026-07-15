#include <assert.h>
#include <wchar.h>

#include "launcher-arguments.h"

int main(void)
{
    wchar_t *manual[] = { L"respawn.exe", L"-NoReboot" };
    wchar_t *no_confirm[] = { L"respawn.exe", L"--no-confirm" };
    wchar_t *automatic[] = { L"respawn.exe", L"/AUTO" };
    wchar_t *firstlogon[] = { L"respawn.exe", L"--FIRSTLOGON" };

    assert(!launcher_args_request_autorun(2, manual));
    assert(!launcher_args_request_firstlogon(2, manual));
    assert(launcher_args_request_autorun(2, no_confirm));
    assert(!launcher_args_request_firstlogon(2, no_confirm));
    assert(launcher_args_request_autorun(2, automatic));
    assert(!launcher_args_request_firstlogon(2, automatic));
    assert(launcher_args_request_autorun(2, firstlogon));
    assert(launcher_args_request_firstlogon(2, firstlogon));
    assert(launcher_arg_is_control(L"-firstlogon"));
    assert(!launcher_arg_is_control(L"-NoReboot"));
    return 0;
}
