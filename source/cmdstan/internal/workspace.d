module cmdstan.internal.workspace;

import std.file : exists, mkdir, mkdirRecurse, tempDir;
import std.path : absolutePath, buildNormalizedPath, buildPath;
import std.uuid : randomUUID;

package(cmdstan) string fullPath(string path)
{
    return buildNormalizedPath(absolutePath(path));
}

// Resolve an existing directory through filesystem links, including Windows junctions.
package(cmdstan) string resolvedDirectory(string path)
{
    version (Windows)
    {
        import core.sys.windows.windows;
        import std.utf : toUTF16z, toUTF8;
        import std.windows.syserror : wenforce;
        auto handle = CreateFileW(path.toUTF16z, 0,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, null, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS, null);
        wenforce(handle != INVALID_HANDLE_VALUE, "Opening directory " ~ path);
        scope (exit) CloseHandle(handle);
        wchar[] buffer;
        for (;;)
        {
            auto length = GetFinalPathNameByHandleW(handle, buffer.ptr, cast(DWORD) buffer.length, 0);
            wenforce(length, "Resolving directory " ~ path);
            if (length < buffer.length) return toUTF8(buffer[0 .. length]);
            buffer.length = length;
        }
    }
    else version (Posix)
    {
        import core.stdc.stdlib : free;
        import core.sys.posix.stdlib : realpath;
        import std.exception : errnoEnforce;
        import std.string : fromStringz, toStringz;
        auto resolved = realpath(path.toStringz, null);
        errnoEnforce(resolved !is null, "Resolving directory " ~ path);
        scope (exit) free(resolved);
        return resolved.fromStringz.idup;
    }
}

package(cmdstan) string newDirectory(string parent, string prefix)
{
    parent = fullPath(parent.length ? parent : tempDir());
    mkdirRecurse(parent);
    auto path = buildPath(parent, prefix ~ randomUUID().toString);
    version (Posix)
    {
        import core.sys.posix.sys.stat : posixMkdir = mkdir;
        import std.exception : errnoEnforce;
        import std.string : toStringz;
        import std.conv : octal;
        errnoEnforce(posixMkdir(path.toStringz, octal!700) == 0, "Creating " ~ path);
    }
    else mkdir(path);
    return path;
}

// Removing a run or model can race a short-lived Windows file lock.
package(cmdstan) void removeArtifactDirectory(string path)
{
    import std.file : FileException, rmdirRecurse;
    version (Windows)
    {
        import core.sys.windows.winerror : ERROR_ACCESS_DENIED, ERROR_SHARING_VIOLATION;
        import core.thread : Thread;
        import core.time : msecs;
        for (int attempt = 0; ; ++attempt)
        {
            try { rmdirRecurse(path); return; }
            catch (FileException e)
            {
                if (attempt == 7 || (e.errno != ERROR_SHARING_VIOLATION && e.errno != ERROR_ACCESS_DENIED))
                    throw e;
                Thread.sleep((10 << attempt).msecs);
            }
        }
    }
    else rmdirRecurse(path);
}
