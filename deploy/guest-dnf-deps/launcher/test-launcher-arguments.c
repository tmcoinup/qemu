#include <assert.h>
#include <wchar.h>

#include "launcher-arguments.h"

int main(void)
{
    wchar_t *none[] = { L"dnf-fix-deps.exe" };
    wchar_t *manual[] = { L"dnf-fix-deps.exe", L"--dry-run" };
    wchar_t *automatic[] = {
        L"dnf-fix-deps.exe", L"--no-confirm", L"--dry-run"
    };
    wchar_t *reverse[] = {
        L"dnf-fix-deps.exe", L"--DRY-RUN", L"--NO-CONFIRM"
    };
    wchar_t *duplicate[] = {
        L"dnf-fix-deps.exe", L"--dry-run", L"--DRY-RUN"
    };
    wchar_t *unknown[] = { L"dnf-fix-deps.exe", L"-LogPath" };
    wchar_t *internal[] = { L"dnf-fix-deps.exe", L"-LauncherMode" };
    wchar_t *automatic_alias[] = {
        L"dnf-fix-deps.exe", L"--auto"
    };
    wchar_t *prefix[] = { L"dnf-fix-deps.exe", L"--dry" };
    wchar_t *assigned[] = {
        L"dnf-fix-deps.exe", L"--dry-run=true"
    };

    assert(dnf_args_valid(1, none));
    assert(dnf_args_valid(2, manual));
    assert(dnf_args_valid(3, automatic));
    assert(dnf_args_valid(3, reverse));
    assert(!dnf_args_valid(3, duplicate));
    assert(!dnf_args_valid(2, unknown));
    assert(!dnf_args_valid(2, internal));
    assert(!dnf_args_valid(2, automatic_alias));
    assert(!dnf_args_valid(2, prefix));
    assert(!dnf_args_valid(2, assigned));
    assert(!dnf_args_skip_confirmation(2, manual));
    assert(dnf_args_skip_confirmation(3, automatic));
    assert(dnf_args_skip_confirmation(3, reverse));
    assert(dnf_arg_is_control(L"--NO-CONFIRM"));
    assert(dnf_arg_forward_value(L"--no-confirm") == NULL);
    assert(wcscmp(dnf_arg_forward_value(L"--dry-run"), L"-DryRun") == 0);
    assert(wcscmp(dnf_arg_forward_value(L"--DRY-RUN"), L"-DryRun") == 0);
    assert(dnf_arg_forward_value(L"-LogPath") == NULL);
    assert(dnf_arg_forward_value(L"-LauncherMode") == NULL);
    return 0;
}
