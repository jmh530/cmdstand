/// Serialize named data for CmdStan.
module cmdstan.json;

import std.algorithm : among;
import std.exception : basicExceptionCtors, enforce;
import std.format : formattedWrite;
import std.json : JSONType, JSONValue;
import std.math : isInfinity, isNaN;
import std.range.primitives : put;
import std.stdio : File;
import std.traits;

class StanDataException : Exception
{
    /// Inherit the standard exception constructors.
    mixin basicExceptionCtors;
}

/// An existing, caller-owned Stan JSON file.
struct JsonFile { string path; }

/++ Params:
        Sink = Character output range.
        T = Struct with named fields, string-keyed associative array, or JSONValue object.
        sink = Destination for the JSON characters.
        data = Named values. Numeric arrays must be rectangular.
    Returns: Writes a single JSON object to sink.
    Throws: StanDataException for unsupported JSON values or ragged arrays.
+/
void writeStanJson(Sink, T)(ref Sink sink, auto ref const T data)
if (!isSomeString!Sink)
{
    static if (is(T == JSONValue))
        enforce!StanDataException(data.type == JSONType.object, "Stan data requires a named object");
    else
        static assert(is(T == struct) || isAssociativeArray!T, "Stan data requires a named object");
    size_t[] shape;
    writeValue(sink, data, "$", shape, 0);
}

///
unittest
{
    import std.array : appender;
    struct Data { int N; double[] y; }
    auto sink = appender!string;
    writeStanJson(sink, Data(2, [1.0, -double.infinity]));
    assert(sink.data == `{"N":2,"y":[1,"-Inf"]}`);
}

unittest
{
    import std.array : appender;
    import std.exception : assertThrown;
    import std.json : parseJSON;
    auto outp = appender!string;
    auto obj = parseJSON(`{"m":[[1,2,3],[4,5,6]],"y":[]}`);
    writeStanJson(outp, obj);
    assert(parseJSON(outp.data) == obj);
    foreach (bad; [`{"x":[1,[2]]}`, `{"x":[[1],[]]}`, `{"x":null}`, "[]"])
        assertThrown!StanDataException(writeStanJson(outp, parseJSON(bad)));
}

/++ Params:
        T = Named data type accepted by the output-range overload.
        path = Destination file to create or replace after successful serialization.
        data = Named data to serialize.
    Returns: Writes the JSON object to the specified file.
    Throws: StanDataException for invalid data or a file exception on I/O failure.
+/
void writeStanJson(T)(string path, auto ref const T data)
{
    import cmdstan.internal.workspace : fullPath, newDirectory;
    import std.file : rename, rmdirRecurse;
    import std.path : buildPath, dirName;
    auto destination = fullPath(path);
    auto staging = newDirectory(dirName(destination), ".cmdstand-json-");
    scope (exit) rmdirRecurse(staging);
    auto temporary = buildPath(staging, "data.json");
    auto file = File(temporary, "wb");
    {
        auto writer = file.lockingTextWriter();
        writeStanJson(writer, data);
    }
    file.close();
    rename(temporary, destination);
}

unittest
{
    import cmdstan.internal.workspace : newDirectory;
    import std.exception : assertThrown;
    import std.file : readText, rmdirRecurse;
    import std.path : buildPath;
    auto directory = newDirectory(null, "stan-json-");
    scope (exit) rmdirRecurse(directory);
    auto path = buildPath(directory, "input.json");
    writeStanJson(path, ["x": [1, 2]]);
    assertThrown!StanDataException(writeStanJson(path, ["x": [[1], [2, 3]]]));
    assert(readText(path) == `{"x":[1,2]}`);
    writeStanJson(path, ["x": [3]]);
    assert(readText(path) == `{"x":[3]}`);
}

private void extent(ref size_t[] shape, size_t depth, size_t length, string path)
{
    if (shape.length == depth) shape ~= length;
    else enforce!StanDataException(shape[depth] == length, "Ragged array at " ~ path);
}

private void writeValue(S, T)(ref S sink, auto ref const T value, string path,
                               ref size_t[] shape, size_t depth)
{
    static if (is(Unqual!T == JSONValue))
    {
        final switch (value.type)
        {
            case JSONType.object:
                writeValue(sink, value.object, path, shape, depth); break;
            case JSONType.array:
                writeValue(sink, value.array, path, shape, depth); break;
            case JSONType.integer:
                writeValue(sink, value.integer, path, shape, depth); break;
            case JSONType.uinteger:
                writeValue(sink, value.uinteger, path, shape, depth); break;
            case JSONType.float_:
                writeValue(sink, value.floating, path, shape, depth); break;
            case JSONType.true_: case JSONType.false_:
                writeValue(sink, value.boolean, path, shape, depth); break;
            case JSONType.string:
                enforce!StanDataException(value.str.among!("Inf", "-Inf", "Infinity", "-Infinity", "NaN"),
                                          "Unsupported string at " ~ path);
                extent(shape, depth, size_t.max, path);
                put(sink, value.toString()); break;
            case JSONType.null_:
                throw new StanDataException("Null at " ~ path);
        }
    }
    else static if (isIntegral!T || isFloatingPoint!T || isBoolean!T)
    {
        extent(shape, depth, size_t.max, path); // A scalar leaf at this depth.
        static if (isBoolean!T) put(sink, value ? '1' : '0');
        else static if (isFloatingPoint!T)
        {
            if (isNaN(value)) put(sink, `"NaN"`);
            else if (isInfinity(value)) put(sink, value < 0 ? `"-Inf"` : `"Inf"`);
            else
            {
                enum roundTripDigits = 2 + T.mant_dig * 30103 / 100000;
                formattedWrite!("%.*g")(sink, roundTripDigits, value);
            }
        }
        else formattedWrite!("%d")(sink, value);
    }
    else static if (isArray!T && !isSomeString!T)
    {
        extent(shape, depth, value.length, path);
        put(sink, '[');
        foreach (i, ref item; value)
        {
            if (i) put(sink, ',');
            writeValue(sink, item, path, shape, depth + 1);
        }
        put(sink, ']');
    }
    else static if (is(T == struct) || isAssociativeArray!T)
    {
        enforce!StanDataException(depth == 0, "Unsupported object in array at " ~ path);
        put(sink, '{');
        bool first = true;
        void field(U)(string key, auto ref const U item)
        {
            if (!first) put(sink, ',');
            first = false;
            put(sink, JSONValue(key).toString());
            put(sink, ':');
            size_t[] fieldShape;
            writeValue(sink, item, path ~ "." ~ key, fieldShape, 0);
        }
        static if (isAssociativeArray!T)
        {
            static assert(is(Unqual!(KeyType!T) == string), "Expected string keys");
            foreach (key, ref item; value) field(key, item);
        }
        else static foreach (name; FieldNameTuple!T)
            field(name, __traits(getMember, value, name));
        put(sink, '}');
    }
    else static assert(false, "Unsupported Stan data type: " ~ T.stringof);
}
