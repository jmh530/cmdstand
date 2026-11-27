/// Select an existing CmdStan installation and build Stan models.
module cmdstan.installation;

import cmdstan.internal.workspace;
import cmdstan.csv : SummaryTable, readSummaryCsv;
import cmdstan.model : CompiledModel;
import cmdstan.sampling : tail;
import std.algorithm : canFind, startsWith, endsWith;
import std.array : join, split;
import std.conv : to;
import std.exception : basicExceptionCtors, enforce;
import std.file;
import std.path : absolutePath, baseName, buildPath, dirName, expandTilde, extension;
import std.process : Config, ProcessException, environment, execute, spawnProcess, wait;
import std.stdio : File, stdin;
import std.string : splitLines, strip;

version (Windows) private enum suffix = ".exe";
else private enum suffix = "";

class InstallationException : Exception { mixin basicExceptionCtors; }
class SummaryException : Exception { mixin basicExceptionCtors; }
class DiagnoseException : Exception { mixin basicExceptionCtors; }
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
    /// Additional Stan include directories in search order, after the model's
    /// directory. Relative paths start at the caller's working directory.
    string[] includePaths;
    /// Request stanc's pedantic warnings during translation. Defaults to false.
    bool warnPedantic;
}

/// An existing CmdStan installation used to build models and run its command-line tools.
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
            source = Existing .stan file. Its directory is searched first for includes.
            options = Include directories, pedantic warnings, GNU Make and staging path overrides.
        Returns: A reusable compiled model. Call close when finished with it.
        Throws: CompilationException for invalid include directories or if
            translation or the upstream build fails. Additional directory paths
            must be representable in stanc's comma-separated search list.
    +/
    CompiledModel compile(string source, CompileOptions options = CompileOptions.init) const
    {
        import std.digest.sha : sha256Of;
        import std.digest : toHexString;
        import std.json : parseJSON;
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
            string[] paths = ["."];
            foreach (path; options.includePaths)
            {
                enforce!CompilationException(path.length, "Empty Stan include directory");
                // Let the filesystem resolve .. after following directory symlinks.
                auto resolved = absolutePath(path);
                enforce!CompilationException(exists(resolved) && isDir(resolved) && !resolved.canFind(','),
                    "Expected a Stan include directory with no comma in its path: " ~ resolved);
                paths ~= resolved;
            }
            auto includeFlag = "--include-paths=" ~ paths.join(",");
            void runStanc(string[] flags, string destination)
            {
                auto output = File(destination, "wb");
                auto err = File(log, "ab");
                auto status = wait(spawnProcess([stanc] ~ flags ~ [includeFlag, source],
                    stdin, output, err, null, Config.none, dirName(source)));
                enforce!CompilationException(status == 0, "stanc exited with code " ~ status.to!string);
            }
            runStanc(["--info"], infoPath);
            auto info = parseJSON(readText(infoPath));
            auto stem = modelStem(baseName(source)[0 .. $ - ".stan".length]);
            auto staged = buildPath(directory, stem ~ ".stan");
            if ("included_files" in info.object && info["included_files"].array.length)
                runStanc(["--auto-format", "--canonicalize=includes"], staged);
            else
                copy(source, staged);
            version (Windows) string make = "mingw32-make";
            else string make = "make";
            if (options.make.length) make = options.make;
            auto target = buildPath(directory, stem ~ suffix);
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
                string[] command = [make];
                if (options.warnPedantic)
                {
                    // Read this after CmdStan's makefile so installation flags are preserved.
                    auto flags = buildPath(directory, "pedantic.mk");
                    std.file.write(flags, "ifeq ($(filter --warn-pedantic,$(STANCFLAGS)),)\n" ~
                        "override STANCFLAGS += --warn-pedantic\nendif\n");
                    version (Windows) flags = flags.replace("\\", "/");
                    command ~= ["-f", "makefile", "-f", flags];
                }
                auto status = wait(spawnProcess(command ~ makeTarget, stdin, output, output, null,
                                                Config.none, root));
                enforce!CompilationException(status == 0 && exists(target),
                                              "GNU Make failed (exit " ~ status.to!string ~ ")");
            }
            return new CompiledModel(directory, target, source, root, release, log);
        }
        catch (Exception e)
        {
            auto error = new CompilationException(source ~ ": " ~ e.msg ~ "\nBuild directory: " ~ directory ~
                                                  (exists(log) ? "\n" ~ tail(log) : ""));
            error.directory = directory;
            throw error;
        }
    }

    /++ Params:
            csvPaths = One or more caller-owned CmdStan chain CSV files from one fit.
        Returns: The installed stansummary tool's default statistics across the
            supplied chains, with numeric output requested at 17 significant digits.
            Temporary summary and log files are removed before returning.
        Throws: SummaryException for missing or repeated input files, incomplete
            saved warmup, invalid warmup settings, or a tool failure.
            CsvException for malformed summary output. I/O exceptions for filesystem errors.
    +/
    SummaryTable summary(const(string)[] csvPaths...) const
    {
        enforce!SummaryException(root.length && csvPaths.length,
            "Expected a CmdStan installation and at least one chain CSV");
        auto program = buildPath(root, "bin", "stansummary" ~ suffix);
        enforce!SummaryException(exists(program) && isFile(program), "Missing stansummary: " ~ program);
        auto inputs = chainCsvInputs!SummaryException(csvPaths);
        auto directory = newDirectory(null, "cmdstand-summary-");
        scope (exit) removeArtifactDirectory(directory);
        auto csv = buildPath(directory, "summary.csv");
        auto log = buildPath(directory, "summary.log");
        int status;
        try
        {
            auto output = File(log, "wb");
            status = wait(spawnProcess([program, "--csv_filename=" ~ csv, "--sig_figs=17"] ~ inputs,
                stdin, output, output));
        }
        catch (ProcessException e)
        {
            throw new SummaryException(program ~ ": " ~ e.msg);
        }
        enforce!SummaryException(status == 0, "stansummary exited with code " ~ status.to!string ~ "\n" ~ tail(log));
        return readSummaryCsv(csv);
    }

    /++ Run CmdStan's sampler diagnostics on the saved chains from one HMC fit.

        The selected installation's `diagnose` executable checks the available
        sampler columns for divergences, transitions that hit maximum tree depth,
        and poor energy exploration (low E-BFMI). It also checks parameter draws
        for low effective sample size and high split R-hat.

        Params:
            csvPaths = Paths to one or more distinct CmdStan sampling CSV files.
                Pass the paths individually or as an array. Relative paths start
                at the current working directory. For a fit retained with
                `SampleOptions.outputDir`, use the CSV path from each entry in
                `fit.artifacts.chains`. The caller retains ownership of the files.
        Returns: The tool's human-readable report as a string, including any
            sampling problems it found. The report remains usable after the
            caller removes the chain files.
        Throws: `DiagnoseException` if no paths are supplied, an input is missing
            or repeated, or the saved warmup settings or boundary are invalid.
            It also indicates that the executable is unavailable, failed, or
            skipped a requested file. For a nonzero exit, the exception message
            includes the exit code and captured output. Filesystem errors may
            raise I/O exceptions.
    +/
    string diagnose(const(string)[] csvPaths...) const
    {
        enforce!DiagnoseException(root.length && csvPaths.length,
            "Expected a CmdStan installation and at least one chain CSV");
        auto program = buildPath(root, "bin", "diagnose" ~ suffix);
        enforce!DiagnoseException(exists(program) && isFile(program), "Missing diagnose: " ~ program);
        auto inputs = chainCsvInputs!DiagnoseException(csvPaths);
        try
        {
            auto result = execute([program] ~ inputs);
            enforce!DiagnoseException(result.status == 0,
                "diagnose exited with code " ~ result.status.to!string ~ "\n" ~ result.output);
            // Both supported releases report skipped files first and can exit zero
            // if another input was readable (e.g. a path disappeared after validation).
            enforce!DiagnoseException(!result.output.startsWith("File "), result.output);
            return result.output;
        }
        catch (ProcessException e)
        {
            throw new DiagnoseException(program ~ ": " ~ e.msg);
        }
    }

    ///
    unittest
    {
        // Run this after saving both chains from the same fit.
        void printDiagnostics(CmdStan stan, string firstChain, string secondChain)
        {
            import std.stdio : write;
            auto report = stan.diagnose(firstChain, secondChain);
            write(report);
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

private struct FileIdentity
{
    ulong device, index;
}

private FileIdentity fileIdentity(File file)
{
    version (Windows)
    {
        import core.sys.windows.winbase : BY_HANDLE_FILE_INFORMATION, GetFileInformationByHandle;
        import std.windows.syserror : wenforce;
        BY_HANDLE_FILE_INFORMATION info;
        wenforce(GetFileInformationByHandle(file.windowsHandle, &info), file.name);
        return FileIdentity(info.dwVolumeSerialNumber,
            (cast(ulong) info.nFileIndexHigh << 32) | info.nFileIndexLow);
    }
    else version (Posix)
    {
        import core.sys.posix.sys.stat : fstat, stat_t;
        import std.exception : errnoEnforce;
        stat_t info;
        errnoEnforce(fstat(file.fileno, &info) == 0, file.name);
        return FileIdentity(info.st_dev, info.st_ino);
    }
}

private string[] chainCsvInputs(E)(const(string)[] paths)
{
    string[] inputs;
    bool[FileIdentity] seen;
    foreach (path; paths)
    {
        enforce!E(path.length && exists(path) && isFile(path), "Missing chain CSV: " ~ path);
        auto file = File(path, "rb");
        if (paths.length > 1)
        {
            auto id = fileIdentity(file);
            enforce!E(id !in seen, "Repeated chain CSV: " ~ path);
            seen[id] = true;
        }
        checkWarmupBoundary!E(file);
        inputs ~= absolutePath(path);
    }
    return inputs;
}

private void checkWarmupBoundary(E)(File file)
{
    import std.conv : ConvException;
    import std.string : indexOf;
    bool headerRead, saved, hasWarmup, fixedParam;
    foreach (line; file.byLine())
    {
        // Upstream stops skipping saved warmup at a '#' in column one.
        if (headerRead)
        {
            if (line.startsWith("#")) return;
            continue;
        }
        if (!line.startsWith("#"))
        {
            if (!saved || !hasWarmup || fixedParam) return;
            headerRead = true;
            continue;
        }
        auto eq = line.indexOf('=');
        if (eq < 0) continue;
        auto key = line[1 .. eq].strip;
        auto value = line[eq + 1 .. $].strip;
        if (value.endsWith(" (Default)")) value = value[0 .. $ - " (Default)".length].strip;
        switch (key)
        {
            case "algorithm": fixedParam = value == "fixed_param"; break;
            case "save_warmup":
                enforce!E(["1", "0", "true", "false"].canFind(value),
                    file.name ~ ": invalid save_warmup");
                saved = value == "1" || value == "true";
                break;
            case "num_warmup":
                try { hasWarmup = value.to!ulong != 0; }
                catch (ConvException) { throw new E(file.name ~ ": invalid num_warmup"); }
                break;
            default: break;
        }
    }
    enforce!E(!headerRead, file.name ~ ": missing comment after saved warmup");
}

unittest
{
    import std.exception : assertThrown;
    auto root = newDirectory(null, "summary-inputs-");
    scope (exit) removeArtifactDirectory(root);
    auto path = buildPath(root, "chain.csv");
    enum saved = "# save_warmup = true (Default)\n# num_warmup = 10\n";
    write(path, saved ~ "lp__,x\n1,2\n  # not a boundary\n");
    assertThrown!SummaryException(chainCsvInputs!SummaryException([path]));
    write(path, saved ~ "lp__,x\n1,2\n# Adaptation terminated\n1,3\n");
    assert(chainCsvInputs!SummaryException([path]) == [path]);
    assertThrown!SummaryException(chainCsvInputs!SummaryException([path, path]));
    enum fixture = "tests/fixtures/bernoulli-2.39.0.csv";
    assertThrown!SummaryException(chainCsvInputs!SummaryException([fixture, absolutePath(fixture)]));
    version (Posix)
    {
        auto aliasPath = buildPath(root, "alias.csv");
        symlink(path, aliasPath);
        assertThrown!SummaryException(chainCsvInputs!SummaryException([path, aliasPath]));
    }
    foreach (setting; ["# num_warmup = 0\n", "# save_warmup = 0\n", "# algorithm = fixed_param\n"])
    {
        write(path, saved ~ setting ~ "lp__,x\n1,2\n");
        assert(chainCsvInputs!SummaryException([path]) == [path]);
    }
}

private string modelStem(string name)
{
    import std.ascii : isAlpha, isAlphaNum;
    import std.digest : toHexString;
    import std.digest.sha : sha256Of;
    bool valid = name.length && isAlpha(name[0]);
    foreach (c; name) valid = valid && (isAlphaNum(c) || c == '_');
    if (valid) return name;

    // Keep non-identifier filenames recognizable and distinguish e.g. "a-b" and "a b".
    string stem = "m_";
    foreach (c; name[0 .. (name.length > 160 ? 160 : name.length)])
        stem ~= isAlphaNum(c) ? c : '_';
    return stem ~ "_" ~ name.sha256Of.toHexString[0 .. 12].idup;
}

unittest
{
    assert(modelStem("bernoulli") == "bernoulli");
    assert(modelStem("a b") != modelStem("a-b"));
}
