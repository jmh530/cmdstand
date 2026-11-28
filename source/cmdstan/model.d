/// Reusable compiled model handle.
module cmdstan.model;

import cmdstan.json : JsonFile;
import cmdstan.internal.workspace : removeArtifactDirectory, resolvedDirectory;
import cmdstan.sampling : SampleFit, SampleOptions, sampleData;
import std.exception : enforce;
import std.file : copy, exists, isFile, mkdir;
import std.path : absolutePath, baseName, buildPath, dirName;
import std.traits : isArray, isAssociativeArray, isSomeString;

final class CompiledModel
{
    private string directory;
    private bool closed;
    /// For reopened executables, the source, installation and version are unknown (empty).
    immutable string executable, sourcePath, installationPath, cmdstanVersion;
    /// Absolute path to the compiler and Make log until close. Empty for reopened executables.
    immutable string buildLogPath;
    package this(string directory, string executable, string source, string root, string release,
                 string log)
    {
        this.directory = directory;
        this.executable = executable;
        sourcePath = source;
        installationPath = root;
        cmdstanVersion = release;
        buildLogPath = log;
    }

    /++ Params:
            path = Path to a caller-owned CmdStan model executable. Relative paths
                are resolved in the current working directory.
        Returns: A model borrowing the executable. The caller keeps its runtime
            libraries available. Source and build metadata are empty.
        Throws: Exception if the path does not identify a regular file. Compatibility
            and execution permissions are checked by the operating system at launch.
    +/
    static CompiledModel open(string path)
    {
        enforce(path.length, "Empty model executable path");
        auto exe = absolutePath(path);
        enforce(exists(exe) && isFile(exe), "Expected a model executable: " ~ exe);
        return new CompiledModel(null, exe, null, null, null, null);
    }

    /++ Params:
            destination = New caller-owned directory in an existing parent, outside
                the model's temporary build directory.
        Returns: Absolute path to the saved executable. On Windows an adjacent
            CmdStan tbb.dll is copied too. Other system or installation libraries
            must remain available when the model runs.
        Throws: Exception for a closed model, an existing destination, a destination
            inside the private build directory (including through a link), or a file error.
    +/
    string save(string destination) const
    {
        import std.typecons : Yes;
        enforce(!closed, "Compiled model is closed");
        enforce(destination.length, "Empty model destination");
        auto folder = absolutePath(destination);
        if (directory.length)
        {
            import std.path : filenameCmp;
            auto owned = resolvedDirectory(directory);
            auto ancestor = resolvedDirectory(dirName(folder));
            for (;;)
            {
                enforce(filenameCmp(ancestor, owned) != 0,
                    "Cannot save inside the model's temporary build directory: " ~ folder);
                auto parent = dirName(ancestor);
                if (parent == ancestor) break;
                ancestor = parent;
            }
        }
        mkdir(folder);
        scope (failure) removeArtifactDirectory(folder);
        // Return a durable path even if the caller traversed a link from the build
        // directory to an outside location. Closing the model removes that link.
        if (directory.length) folder = resolvedDirectory(folder);
        version (Windows)
        {
            auto tbb = buildPath(dirName(executable), "tbb.dll");
            if (exists(tbb)) copy(tbb, buildPath(folder, "tbb.dll"));
        }
        auto saved = buildPath(folder, baseName(executable));
        copy(executable, saved, Yes.preserveAttributes);
        return saved;
    }

    unittest
    {
        import cmdstan.internal.workspace : newDirectory;
        import std.exception : assertThrown;
        import std.file : readText, remove, write;
        auto root = newDirectory(null, "cmdstand-save-");
        scope (exit) removeArtifactDirectory(root);
        auto exe = buildPath(root, "input model.exe");
        write(exe, "model fixture");
        version (Windows) write(buildPath(root, "tbb.dll"), "runtime fixture");
        assertThrown(CompiledModel.open(root));
        assertThrown(CompiledModel.open(buildPath(root, "missing")));
        auto borrowed = CompiledModel.open(exe);
        assert(!borrowed.buildLogPath.length && !borrowed.cmdstanVersion.length);
        auto folder = buildPath(root, "my model");
        auto saved = borrowed.save(folder);
        assert(readText(saved) == "model fixture");
        version (Windows) assert(readText(buildPath(folder, "tbb.dll")) == "runtime fixture");
        assertThrown(borrowed.save(folder));
        borrowed.close();
        borrowed.close();
        assertThrown(borrowed.save(buildPath(root, "another")));
        assertThrown(borrowed.sample(JsonFile("unused")));
        assert(exists(exe) && exists(saved));
        auto missing = CompiledModel.open(exe);
        remove(exe);
        auto incomplete = buildPath(root, "incomplete");
        assertThrown(missing.save(incomplete));
        assert(!exists(incomplete));
    }

    unittest
    {
        import cmdstan.internal.workspace : newDirectory;
        import std.exception : assertThrown;
        import std.file : readText, write;
        auto root = newDirectory(null, "cmdstand-save-owned-");
        scope (exit) removeArtifactDirectory(root);
        auto owned = buildPath(root, "build");
        auto nested = buildPath(owned, "nested");
        mkdir(owned);
        mkdir(nested);
        auto exe = buildPath(owned, "model.exe");
        write(exe, "model fixture");
        auto model = new CompiledModel(owned, exe, null, null, null, null);
        scope (exit) model.close();

        auto link = buildPath(root, "alias");
        version (Windows)
        {
            import std.process : Config, execute;
            auto result = execute(["cmd.exe", "/d", "/c", "mklink", "/J", "alias", "build\\nested"],
                null, Config.none, size_t.max, root);
            assert(result.status == 0, result.output);
        }
        else version (Posix)
        {
            import std.file : symlink;
            symlink(nested, link);
        }
        foreach (parent; [owned, nested, link])
        {
            auto destination = buildPath(parent, "saved");
            assertThrown(model.save(destination));
            assert(!exists(destination));
        }
        // The saved path must still work after the intermediate "build" is gone.
        auto saved = model.save(buildPath(owned, "..", "build-saved"));
        model.close();
        assert(readText(saved) == "model fixture");
    }

    /++ Params:
            T = Named Stan data or JsonFile.
            data = Values to serialize, or a borrowed JSON input.
            options = Typed sampling settings.
        Returns: Validated in-memory draws for every requested chain.
        Throws: Exception for a closed model, invalid data, failed run or invalid CSV.
    +/
    SampleFit sample(T)(auto ref const T data, SampleOptions options = SampleOptions.init)
    {
        enforce(!closed, "Compiled model is closed");
        return sampleData(executable, data, options, null);
    }

    /++ Params:
            T = Named Stan data type or JsonFile.
            I = Named initialization type, JsonFile, or an array of either.
            data = Named model data or a borrowed data file.
            options = Sampling settings. zeroInit must be false.
            initial = One named object or file shared by all chains, or one
                per chain in launch order. Parameter values use Stan's
                constrained scale. Existing files remain caller-owned.
        Returns: In-memory draws. Serialized initial values share the run's
            output lifetime, including retention when outputDir is supplied.
        Throws: Exception for a closed model, invalid inputs or a failed run.
    +/
    SampleFit sample(T, I)(auto ref const T data, SampleOptions options, auto ref const I initial)
        if (is(I == struct) || isAssociativeArray!I || (isArray!I && !isSomeString!I))
    {
        enforce(!closed, "Compiled model is closed");
        return sampleData(executable, data, options, initial);
    }

    /++ Returns: Closes the handle and releases any private build directory.
            Borrowed and saved files remain caller-owned. Repeated calls are safe.
        Throws: A filesystem exception when files cannot be removed.
    +/
    void close()
    {
        if (directory.length)
        {
            removeArtifactDirectory(directory);
            directory = null;
        }
        closed = true;
    }
}
