/// Reusable compiled model handle.
module cmdstan.model;

import cmdstan.json : JsonFile;
import cmdstan.internal.workspace : removeArtifactDirectory;
import cmdstan.sampling : SampleFit, SampleOptions, sampleData;
import std.exception : enforce;
import std.traits : isArray, isAssociativeArray, isSomeString;

final class CompiledModel
{
    private string directory;
    immutable string executable, sourcePath, installationPath, cmdstanVersion;
    /// Absolute path to the compiler and Make log. close() removes the file.
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
            T = Named Stan data or JsonFile.
            data = Values to serialize, or a borrowed JSON input.
            options = Typed sampling settings.
        Returns: Validated in-memory draws for every requested chain.
        Throws: Exception for a closed model, invalid data, failed run or invalid CSV.
    +/
    SampleFit sample(T)(auto ref const T data, SampleOptions options = SampleOptions.init)
    {
        enforce(directory.length, "Compiled model is closed");
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
        enforce(directory.length, "Compiled model is closed");
        return sampleData(executable, data, options, initial);
    }

    /++ Returns: Releases the model's private build directory. Repeated calls are safe.
        Throws: A filesystem exception when files cannot be removed.
    +/
    void close()
    {
        if (directory.length)
        {
            removeArtifactDirectory(directory);
            directory = null;
        }
    }
}
