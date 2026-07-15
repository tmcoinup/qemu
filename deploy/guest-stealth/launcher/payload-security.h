#ifndef RESPAWN_PAYLOAD_SECURITY_H
#define RESPAWN_PAYLOAD_SECURITY_H

#include <windows.h>
#include <stddef.h>

typedef struct EmbeddedPayload {
    const wchar_t *file_name;
    const unsigned char *data;
    DWORD size;
} EmbeddedPayload;

/*
 * 中文注释：创建或重新保护 payload 根目录。Owner 固定为 Administrators，
 * SYSTEM/Administrators 可写，普通用户只读执行；任何重解析点都会被拒绝。
 */
int payload_secure_directory(const wchar_t *path);

/*
 * 中文注释：同一 payload 根只允许一个 launcher 发布并执行。调用者必须持有
 * 返回句柄直到管理员 PowerShell 子进程退出。
 */
HANDLE payload_acquire_lock(const wchar_t *root_dir);

/*
 * 中文注释：先把整个 payload 集合写入唯一 staging 目录并逐字节复核，再把完整
 * 目录发布为稳定 work_dir。发布失败会恢复旧目录，绝不执行脚本/DLL 混版。
 */
int payload_publish_bundle(const wchar_t *root_dir,
                           const wchar_t *work_dir,
                           const EmbeddedPayload *payloads,
                           size_t payload_count);

#endif
