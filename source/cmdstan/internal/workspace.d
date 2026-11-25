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
