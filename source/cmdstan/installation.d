/// Select an existing CmdStan installation and build standalone models.
module cmdstan.installation;

import cmdstan.internal.workspace;
import cmdstan.model : CompiledModel;
import cmdstan.sampling : tail;
import std.algorithm : canFind, startsWith, endsWith;
import std.array : split;
import std.conv : to;
import std.exception : basicExceptionCtors, enforce;
import std.file;
import std.path : baseName, buildPath, dirName, expandTilde, extension;
import std.process : Config, environment, spawnProcess, wait;
import std.stdio : File, stdin;
import std.string : splitLines, strip;

version (Windows) private enum suffix = ".exe";
else private enum suffix = "";

class InstallationException : Exception { mixin basicExceptionCtors; }
class CompilationException : Exception
{
    /// Owned staging directory retained after a build attempt.
    string directory;
    mixin basicExceptionCtors;
}

struct CompileOptions
{
    /// Parent for unique build directories. GNU Make must accept this path.
    string stagingRoot;
    /// GNU Make executable path or command. Empty selects the platform default.
    string make;
}

struct CmdStan
{
    private string root, release;

    /// Returns: Absolute path of the selected installation.
    @property string path() const @safe pure nothrow { return root; }
    /// Returns: CmdStan version from the installation makefile.
    @property string versionString() const @safe pure nothrow { return release; }

    /++ Params:
            path = Existing CmdStan root containing makefile and bin/stanc.
        Returns: An installation bound to its absolute root.
        Throws: InstallationException if the installation is incomplete.
    +/
    static CmdStan at(string path)
    {
        enforce!InstallationException(path.length, "Empty CmdStan path");
        auto root = fullPath(path);
        auto manifest = buildPath(root, "makefile");
        auto stanc = buildPath(root, "bin", "stanc" ~ suffix);
        enforce!InstallationException(exists(manifest) && isFile(manifest) && exists(stanc) &&
            isFile(stanc), "Incomplete CmdStan installation: " ~ root);
        foreach (line; readText(manifest).splitLines)
        {
            auto kv = line.split(":=");
            if (kv.length == 2 && kv[0].strip == "CMDSTAN_VERSION")
            {
                auto release = kv[1].strip;
                enforce!InstallationException(release.length, "Missing CmdStan version: " ~ manifest);
                return CmdStan(root, release);
            }
        }
        throw new InstallationException("Missing CMDSTAN_VERSION: " ~ manifest);
    }

    /++ Returns: Installation specified by CMDSTAN or newest stable cmdstan-X.Y.Z
            installation under the user's ~/.cmdstan directory.
        Throws: InstallationException if no usable installation is found.
    +/
    static CmdStan discover()
    {
        if ("CMDSTAN" in environment) return at(environment["CMDSTAN"]);
        return findRelease(expandTilde("~/.cmdstan"));
    }

    /++ Params:
            source = Existing standalone .stan file.
            options = GNU Make and staging path overrides.
        Returns: A reusable compiled model. Call close when finished with it.
        Throws: CompilationException if translation or the upstream build fails.
    +/
    CompiledModel compile(string source, CompileOptions options = CompileOptions.init) const
    {
        import std.digest.sha : sha256Of;
        import std.digest : toHexString;
        import std.json : JSONType, parseJSON;
        source = fullPath(source);
        enforce!CompilationException(exists(source) && isFile(source) && extension(source) == ".stan",
                                     "Expected a Stan source file: " ~ source);
        auto directory = newDirectory(options.stagingRoot, "cmdstand-");
        auto log = buildPath(directory, "build.log");
        try
        {
            foreach (p; [root, directory])
                foreach (c; p)
                    enforce!CompilationException(c >= 32 && !" \t#$%&'()*;<>?[]^`{|}!\"".canFind(c),
                        "GNU Make requires a compatible installation and staging path: " ~ p);
            auto stanc = buildPath(root, "bin", "stanc" ~ suffix);
            auto infoPath = buildPath(directory, "model-info.json");
            {
                auto info = File(infoPath, "wb");
                auto err = File(log, "wb");
                auto status = wait(spawnProcess([stanc, "--info", "--include-paths=.", source],
                    stdin, info, err, null, Config.none, dirName(source)));
                enforce!CompilationException(status == 0, "stanc exited with code " ~ status.to!string);
            }
            auto info = parseJSON(readText(infoPath));
            if ("included_files" in info.object)
                enforce!CompilationException(info["included_files"].array.length == 0,
                                              "Compilation of Stan includes is not yet supported");
            auto staged = buildPath(directory, "model.stan");
            copy(source, staged);
            version (Windows) string make = "mingw32-make";
            else string make = "make";
            if (options.make.length) make = options.make;
            auto target = buildPath(directory, "model" ~ suffix);
            // Upstream Make may update shared installation objects even for a fresh target.
            synchronized
            {
                auto lockName = "cmdstand-build-" ~ root.sha256Of.toHexString.idup ~ ".lock";
                auto lockFile = File(buildPath(tempDir(), lockName), "a+b");
                lockFile.lock();
                auto output = File(log, "ab");
                import std.string : replace;
                auto makeTarget = target;
                version (Windows) makeTarget = target.replace("\\", "/");
                auto status = wait(spawnProcess([make, makeTarget], stdin, output, output, null,
                                                Config.none, root));
                enforce!CompilationException(status == 0 && exists(target),
                                              "GNU Make failed (exit " ~ status.to!string ~ ")");
            }
            return new CompiledModel(directory, target, source, root, release);
        }
        catch (Exception e)
        {
            auto error = new CompilationException(source ~ ": " ~ e.msg ~ "\nBuild directory: " ~ directory ~
                                                  (exists(log) ? "\n" ~ tail(log) : ""));
            error.directory = directory;
            throw error;
        }
    }

    private static CmdStan findRelease(string parent)
    {
        uint[] best;
        CmdStan selected;
        if (exists(parent) && isDir(parent))
            foreach (entry; dirEntries(parent, SpanMode.shallow))
            {
                auto name = baseName(entry.name);
                if (!entry.isDir || !name.startsWith("cmdstan-")) continue;
                auto parts = name[8 .. $].split(".");
                if (parts.length != 3) continue;
                try
                {
                    uint[] numbers;
                    foreach (part; parts) numbers ~= part.to!uint;
                    if (best.length && numbers <= best) continue;
                    auto candidate = at(entry.name);
                    if (candidate.versionString != name[8 .. $]) continue;
                    selected = candidate;
                    best = numbers;
                }
                catch (Exception) { continue; }
            }
        enforce!InstallationException(best.length, "Set CMDSTAN to an existing installation; searched " ~ parent);
        return selected;
    }

    unittest
    {
        import std.exception : assertThrown;
        auto parent = newDirectory(null, "discovery-");
        scope (exit) rmdirRecurse(parent);
        foreach (v; ["2.9.0", "2.40.0", "2.39.0", "2.99.0-rc1"])
        {
            auto p = buildPath(parent, "cmdstan-" ~ v);
            mkdirRecurse(buildPath(p, "bin"));
            write(buildPath(p, "makefile"), "CMDSTAN_VERSION := " ~ v);
            write(buildPath(p, "bin", "stanc" ~ suffix), "");
        }
        mkdir(buildPath(parent, "cmdstan-3.0.0"));
        assert(findRelease(parent).versionString == "2.40.0");
        assertThrown!InstallationException(at(buildPath(parent, "cmdstan-3.0.0")));
        auto previous = environment.get("CMDSTAN", null);
        bool wasSet = "CMDSTAN" in environment;
        scope (exit)
        {
            if (wasSet) environment["CMDSTAN"] = previous;
            else environment.remove("CMDSTAN");
        }
        environment["CMDSTAN"] = buildPath(parent, "cmdstan-2.9.0");
        assert(discover().versionString == "2.9.0");
        environment["CMDSTAN"] = buildPath(parent, "missing");
        assertThrown!InstallationException(discover());
    }
}
