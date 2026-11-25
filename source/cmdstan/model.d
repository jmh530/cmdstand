/// Reusable compiled model handle.
module cmdstan.model;

import cmdstan.json : JsonFile;
import cmdstan.sampling : SampleFit, SampleOptions, sampleData;
import std.exception : enforce;
import std.file : rmdirRecurse;

final class CompiledModel
{
    private string directory;
    immutable string executable, sourcePath, installationPath, cmdstanVersion;
    package this(string directory, string executable, string source, string root, string release)
    {
        this.directory = directory;
        this.executable = executable;
        sourcePath = source;
        installationPath = root;
        cmdstanVersion = release;
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
        return sampleData(executable, data, options);
    }

    /++ Returns: Releases the model's private build directory. Repeated calls are safe.
        Throws: A filesystem exception when files cannot be removed.
    +/
    void close()
    {
        if (directory.length)
        {
            rmdirRecurse(directory);
            directory = null;
        }
    }
}
