// Copyright (c) 2026 sebiimaks. Distributed under the MIT license.
#pragma once
@import ZipArchive;

// The pinned ZipArchive exports these minizip compatibility symbols and its
// public 64-bit metadata types, but does not expose the function declarations.
// Keep declarations aligned with ZipArchive 2.6.0's minizip/mz_compat.h.
typedef void *unzFile;
#define UNZ_OK 0
#define UNZ_END_OF_LIST_OF_FILE (-100)
unzFile unzOpen64(const void *path);
int unzClose(unzFile file);
int unzGetGlobalInfo64(unzFile file, unz_global_info64 *info);
int unzGetCurrentFileInfo64(unzFile file, unz_file_info64 *info, char *filename,
    unsigned long filename_size, void *extra, unsigned long extra_size,
    char *comment, unsigned long comment_size);
int unzGoToFirstFile(unzFile file);
int unzGoToNextFile(unzFile file);
int unzOpenCurrentFile(unzFile file);
int unzReadCurrentFile(unzFile file, void *buffer, uint32_t length);
int unzCloseCurrentFile(unzFile file);

// Read-only in-memory streams. unzClose owns/deletes a successfully opened
// stream; read mode never frees or modifies the caller-owned Data buffer.
void *mz_stream_mem_create(void **stream);
void mz_stream_mem_delete(void **stream);
void mz_stream_mem_set_buffer(void *stream, void *buffer, int32_t size);
int32_t mz_stream_mem_open(void *stream, const char *path, int32_t mode);
unzFile unzOpen_MZ(void *stream);
#include <zlib.h>
