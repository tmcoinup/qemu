#include "launcher-arguments.h"

/* 开关只含固定 ASCII；自行折叠大小写，避免依赖 guest 当前区域设置。 */
static wchar_t ascii_lower(wchar_t value)
{
    if (value >= L'A' && value <= L'Z') {
        return value + (L'a' - L'A');
    }
    return value;
}

static int argument_equals(const wchar_t *argument, const wchar_t *expected)
{
    if (argument == NULL || expected == NULL) {
        return 0;
    }
    while (*argument != L'\0' && *expected != L'\0') {
        if (ascii_lower(*argument) != ascii_lower(*expected)) {
            return 0;
        }
        argument++;
        expected++;
    }
    return *argument == L'\0' && *expected == L'\0';
}

static int is_no_confirm(const wchar_t *argument)
{
    return argument_equals(argument, L"--no-confirm");
}

static int is_dry_run(const wchar_t *argument)
{
    return argument_equals(argument, L"--dry-run");
}

int dnf_args_valid(int count, wchar_t **arguments)
{
    int confirm_count = 0;
    int dry_run_count = 0;
    int index;

    for (index = 1; index < count; index++) {
        if (is_no_confirm(arguments[index])) {
            confirm_count++;
        } else if (is_dry_run(arguments[index])) {
            dry_run_count++;
        } else {
            return 0;
        }
    }
    return confirm_count <= 1 && dry_run_count <= 1;
}

int dnf_arg_is_control(const wchar_t *argument)
{
    return is_no_confirm(argument);
}

int dnf_args_skip_confirmation(int count, wchar_t **arguments)
{
    int index;

    for (index = 1; index < count; index++) {
        if (is_no_confirm(arguments[index])) {
            return 1;
        }
    }
    return 0;
}

const wchar_t *dnf_arg_forward_value(const wchar_t *argument)
{
    if (dnf_arg_is_control(argument)) {
        return NULL;
    }
    if (is_dry_run(argument)) {
        return L"-DryRun";
    }
    return NULL;
}
