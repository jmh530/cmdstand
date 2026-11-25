module cmdstan.internal.workspace;

import std.file : exists, mkdir, mkdirRecurse, tempDir;
import std.path : absolutePath, buildNormalizedPath, buildPath;
import std.uuid : randomUUID;

package(cmdstan) string fullPath(string path)
{
    return buildNormalizedPath(absolutePath(path));
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
