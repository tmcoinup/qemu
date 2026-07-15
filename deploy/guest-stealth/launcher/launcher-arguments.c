#include "launcher-arguments.h"

/* 参数只含固定 ASCII 开关；自行折叠 A-Z，避免依赖 guest 当前区域设置。 */
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
    while (*argument && *expected) {
        if (ascii_lower(*argument) != ascii_lower(*expected)) {
            return 0;
        }
        argument++;
        expected++;
    }
    return *argument == L'\0' && *expected == L'\0';
}

static int is_firstlogon(const wchar_t *argument)
{
    return argument_equals(argument, L"--firstlogon") ||
           argument_equals(argument, L"-firstlogon") ||
           argument_equals(argument, L"/firstlogon");
}

static int is_no_confirm(const wchar_t *argument)
{
    return argument_equals(argument, L"--no-confirm") ||
           argument_equals(argument, L"-no-confirm") ||
           argument_equals(argument, L"/no-confirm") ||
           argument_equals(argument, L"--auto") ||
           argument_equals(argument, L"-auto") ||
           argument_equals(argument, L"/auto");
}

int launcher_arg_is_control(const wchar_t *argument)
{
    return is_firstlogon(argument) || is_no_confirm(argument);
}

int launcher_args_request_autorun(int count, wchar_t **arguments)
{
    int index;

    for (index = 1; index < count; index++) {
        if (launcher_arg_is_control(arguments[index])) {
            return 1;
        }
    }
    return 0;
}

int launcher_args_request_firstlogon(int count, wchar_t **arguments)
{
    int index;

    for (index = 1; index < count; index++) {
        if (is_firstlogon(arguments[index])) {
            return 1;
        }
    }
    return 0;
}
