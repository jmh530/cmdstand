/// Read CmdStan sampling and summary CSV files independently of an installation.
module cmdstan.csv;

import std.algorithm : splitter, startsWith, endsWith;
import std.array : split;
import std.conv : to;
import std.exception : basicExceptionCtors, enforce;
import std.stdio : File;
import std.string : indexOf, strip;

class CsvException : Exception
{
    /// Inherit the standard exception constructors.
    mixin basicExceptionCtors;
}

/// A read-only view of one dense variable in one chain and sampling phase.
struct DrawView
{
    private const(size_t)[] extents, steps;
    private const(double)[] buffer;

    /// Returns: Saved iteration count followed by the extents in CSV index order.
    @property const(size_t)[] shape() const @safe pure nothrow { return extents; }
    /// Returns: Distance in doubles between consecutive elements on each axis.
    @property const(size_t)[] strides() const @safe pure nothrow { return steps; }
    /// Returns: Flat variable storage in CSV column order, with iterations contiguous.
    @property const(double)[] data() const @safe pure nothrow { return buffer; }

    /++ Params:
            coordinates = Zero-based variable indices, excluding the iteration axis.
                Pass no indices for a scalar.
        Returns: All saved iterations at the given coordinate, sharing the chain buffer.
            The slice is empty for a phase with zero saved iterations.
        Throws: CsvException for the wrong number of indices or an out-of-bounds coordinate.
    +/
    const(double)[] series(const(size_t)[] coordinates...) const @safe
    {
        enforce!CsvException(extents.length && coordinates.length == extents.length - 1,
                             "Wrong number of variable indices");
        size_t offset;
        foreach (i, coordinate; coordinates)
        {
            enforce!CsvException(coordinate < extents[i + 1], "Variable index out of bounds");
            offset += coordinate * steps[i + 1];
        }
        return buffer[offset .. offset + extents[0]];
    }
}

// Configuration fields that identify compatible draw layouts across chains.
package(cmdstan) struct SampleLayout
{
    string model, algorithm, engine;
    size_t samples, warmup, thin;
    bool saveWarmup;
}

/// Owned draws for one chain. Phase buffers store each column contiguously.
struct ChainDraws
{
    private string[] names;
    private size_t[string] indices;
    private double[] posterior, warmup;
    private string[] annotations;
    private size_t savedSamples, savedWarmup;
    package(cmdstan) uint id;
    package(cmdstan) bool hasRecordedId;
    package(cmdstan) uint nativeChainCount = 1;
    package(cmdstan) string outputFile;
    package(cmdstan) SampleLayout layout;
    package(cmdstan) string recordedSeed;

    /// Returns: Original scalar column labels, in file order.
    @property const(string)[] columnNames() const @safe pure nothrow { return names; }
    /// Returns: Configuration, adaptation, and timing comments, in file order.
    @property const(string)[] comments() const @safe pure nothrow { return annotations; }
    /// Returns: Recorded ID (zero if absent), or the individual chain ID
    /// resolved by readSampleFit for a native multi-chain run.
    @property uint chainId() const @safe pure nothrow { return id; }
    /// Returns: Number of sampling iterations saved after thinning.
    @property size_t sampleCount() const @safe pure nothrow { return savedSamples; }
    /// Returns: Number of saved warmup iterations after thinning.
    @property size_t warmupCount() const @safe pure nothrow { return savedWarmup; }

    /++ Params:
            name = Exact CSV label, including any one-based Stan indices.
        Returns: Contiguous read-only view of the sampling draws.
        Throws: CsvException for an unknown label.
    +/
    const(double)[] column(string name) const @safe
    {
        return values(name, posterior, savedSamples);
    }

    /++ Params:
            name = Exact CSV label.
        Returns: Contiguous saved warmup draws, empty when warmup was discarded.
        Throws: CsvException for an unknown label.
    +/
    const(double)[] warmupColumn(string name) const @safe
    {
        return values(name, warmup, savedWarmup);
    }

    /++ Params:
            name = Base CSV variable name without indices.
        Returns: A sampling view sharing the chain's numeric storage. Shape and
            element strides include the iteration axis first. The header must
            describe a scalar or a contiguous dense block of one-based numeric indices.
        Throws: CsvException for an unknown variable or unsupported layout.
    +/
    DrawView variable(string name) const @safe
    {
        return view(name, posterior, savedSamples);
    }

    ///
    unittest
    {
        auto chain = readSampleCsv("tests/fixtures/matrix.csv");
        auto m = chain.variable("m");
        assert(m.shape == [2, 2, 3] && m.strides == [1, 2, 4]);
        assert(m.series(1, 2) is chain.column("m.2.3"));
    }

    /++ Params:
            name = Base CSV variable name without indices.
        Returns: A shared read-only view with the same variable axes as variable().
            Its first extent is zero when warmup was discarded.
        Throws: CsvException for an unknown variable or unsupported layout.
    +/
    DrawView warmupVariable(string name) const @safe
    {
        return view(name, warmup, savedWarmup);
    }

    unittest
    {
        import std.exception : assertThrown;
        auto chain = readSampleCsv("tests/fixtures/matrix.csv");
        auto m = chain.variable("m");
        auto warm = chain.warmupVariable("m");
        assert(warm.shape == [1, 2, 3] && warm.strides == [1, 1, 2]);
        foreach (col; 0 .. 3)
            foreach (row; 0 .. 2)
            {
                auto label = "m." ~ (row + 1).to!string ~ "." ~ (col + 1).to!string;
                auto value = 10 * (row + 1) + col + 1;
                assert(m.series(row, col) is chain.column(label));
                assert(warm.series(row, col) is chain.warmupColumn(label));
                assert(m.series(row, col) == [value, value + 100]);
                assert(warm.series(row, col) == [-value]);
                assert(m.data[1 + row * m.strides[1] + col * m.strides[2]] == value + 100);
            }
        auto lp = chain.variable("lp__");
        assert(lp.shape == [2] && lp.strides == [1] && lp.series() is chain.column("lp__"));
        assertThrown!CsvException(m.series(0));
        assertThrown!CsvException(m.series(2, 0));
        assertThrown!CsvException(m.series(0, 3));
        assertThrown!CsvException(chain.variable("missing"));
        assertThrown!CsvException(chain.variable("m.1"));
    }

    private DrawView view(string name, const(double)[] buffer, size_t count) const @safe
    {
        enforce!CsvException(name.length && name.indexOf('.') < 0 && name.indexOf(':') < 0,
                             "Expected a base variable name: " ~ name);
        auto prefix = name ~ ".";
        size_t first = names.length, width;
        foreach (i, label; names)
        {
            if (label != name && !label.startsWith(prefix)) continue;
            if (!width) first = i;
            enforce!CsvException(i == first + width, "Noncontiguous columns for " ~ name);
            ++width;
        }
        enforce!CsvException(width, "Unknown CSV variable " ~ name);

        // In canonical order the last label contains the extents. Check the
        // observed width before using those extents in any stride arithmetic.
        auto suffix = names[first + width - 1][name.length .. $];
        size_t[] shape = [count];
        size_t remaining = width;
        while (suffix.length)
        {
            auto extent = readIndex(suffix);
            enforce!CsvException(remaining % extent == 0, "Incomplete variable layout for " ~ name);
            remaining /= extent;
            shape ~= extent;
        }
        enforce!CsvException(remaining == 1, "Incomplete variable layout for " ~ name);
        foreach (i, label; names[first .. first + width])
        {
            suffix = label[name.length .. $];
            size_t ordinal = i;
            foreach (extent; shape[1 .. $])
            {
                enforce!CsvException(readIndex(suffix) == 1 + ordinal % extent,
                                     "Unexpected CSV column " ~ label);
                ordinal /= extent;
            }
            enforce!CsvException(!suffix.length, "Unexpected CSV column " ~ label);
        }
        auto strides = new size_t[shape.length];
        strides[0] = 1;
        foreach (i; 1 .. shape.length)
            strides[i] = strides[i - 1] * shape[i - 1];
        return DrawView(shape, strides, buffer[first * count .. (first + width) * count]);
    }

    private const(double)[] values(string name, const(double)[] buffer, size_t count) const @safe
    {
        auto index = name in indices;
        enforce!CsvException(index !is null, "Unknown CmdStan column " ~ name);
        return buffer[*index * count .. (*index + 1) * count];
    }
}

// Consume one canonical, positive decimal index, including its leading dot.
private size_t readIndex(ref string suffix) @safe
{
    import std.ascii : isDigit;
    enforce!CsvException(suffix.length >= 2 && suffix[0] == '.' &&
                         suffix[1] >= '1' && suffix[1] <= '9', "Expected CSV index: " ~ suffix);
    size_t value, i = 1;
    while (i < suffix.length && isDigit(suffix[i]))
    {
        size_t digit = suffix[i++] - '0';
        enforce!CsvException(value <= (size_t.max - digit) / 10, "CSV index too large");
        value = value * 10 + digit;
    }
    suffix = suffix[i .. $];
    return value;
}

/++ Params:
        path = Path to one CmdStan sample-method CSV with configuration comments.
    Returns: An owned chain, including exact raw columns and saved warmup.
    Throws: CsvException for missing configuration, invalid numbers, inconsistent
        dimensions or truncated draws. File errors propagate from Phobos.
+/
ChainDraws readSampleCsv(string path)
{
    import std.file : getSize;
    auto input = File(path, "rb");
    return readChain(input, path, getSize(path));
}

unittest
{
    import std.exception : assertThrown;
    auto chain = readSampleCsv("tests/fixtures/matrix.csv");
    assert(chain.column("m.2.3") == [23, 123]);
    assert(chain.column("m.1.2") == [12, 112]);
    assert(chain.warmupColumn("m.2.3") == [-23]);
    assert(chain.chainId == 7);
    assertThrown!CsvException(chain.column("missing"));
    auto realChain = readSampleCsv("tests/fixtures/bernoulli-2.39.0.csv");
    assert(realChain.chainId == 1 && realChain.sampleCount == 16 && realChain.warmupCount == 50);
    assert(realChain.warmupColumn("theta")[0] == 0.5);
    assert(realChain.column("theta")[0] == 0.4112121588636225);
    assert(realChain.column("theta")[$ - 1] == 0.24015018699494711);
}

unittest
{
    import std.exception : assertThrown;
    import std.math : isNaN, signbit;
    import std.string : replace;
    enum config = "# method = sample\r\n# num_samples = 1\r\n# num_warmup = 0\r\n" ~
                  "# thin = 1\r\n# save_warmup = 0\r\n";
    ChainDraws fixture(string content)
    {
        auto file = File.tmpfile();
        file.write(content);
        file.rewind();
        return readChain(file, "fixture", content.length);
    }
    auto c = fixture(config ~ "z,small,hi,lo,n,theta\r\n-0,4.9406564584124654e-324,inf,-inf,nan,1.0000000000000002\r\n");
    assert(signbit(c.column("z")[0]));
    assert(c.column("small")[0] == double.min_normal * double.epsilon);
    assert(c.column("hi")[0] == double.infinity && c.column("lo")[0] == -double.infinity);
    assert(isNaN(c.column("n")[0]));
    assert(c.column("theta")[0] == 1 + double.epsilon && !c.warmupCount);
    auto vectorChain = fixture(config ~ "v.1,v.2,vv.1\n7,8,9");
    auto vector = vectorChain.variable("v");
    assert(vector.shape == [1, 2] && vector.strides == [1, 1]);
    assert(vector.series(1) is vectorChain.column("v.2"));
    assert(vectorChain.variable("vv").shape == [1, 1]);
    auto empty = vectorChain.warmupVariable("v");
    assert(empty.shape == [0, 2] && empty.strides == [1, 0]);
    assert(empty.data.length == 0 && empty.series(1).length == 0);
    assertThrown!CsvException(empty.series(2));
    // Hand-authored rank-four output with singleton axes and distinct phases.
    auto tensor = fixture(config.replace("num_warmup = 0", "num_warmup = 1")
        .replace("save_warmup = 0", "save_warmup = 1") ~
        "v.1.1.1.1,v.1.2.1.1,v.1.1.1.2,v.1.2.1.2\n-1,-2,-3,-4\n1,2,3,4");
    auto draws = tensor.variable("v");
    assert(draws.shape == [1, 1, 2, 1, 2] && draws.strides == [1, 1, 1, 2, 2]);
    auto warmDraws = tensor.warmupVariable("v");
    foreach (j; 0 .. 2)
        foreach (k; 0 .. 2)
        {
            auto label = "v.1." ~ (j + 1).to!string ~ ".1." ~ (k + 1).to!string;
            auto trace = draws.series(0, j, 0, k);
            auto warmTrace = warmDraws.series(0, j, 0, k);
            assert(trace is tensor.column(label) && warmTrace is tensor.warmupColumn(label));
            assert(trace[0] == 1 + j + 2 * k && warmTrace[0] == -trace[0]);
        }
    assertThrown!CsvException(draws.series(0, 1, 1, 0));
    foreach (labels; ["v.2,v.1", "v.1,v.3", "v,v.2", "v.1,v.2.1",
                      "v.1,x,v.2", "v.1.1,v.1.2,v.2.1,v.2.2", "v.1.1.1,v.1.2",
                      "v.1.1,v.1.1.2", "v.1.1.1,v.1.1.3", "v.4294967296.4294967296.1",
                      "v.0", "v.01", "v.real", "v.18446744073709551616"])
    {
        import std.array : replicate;
        auto fields = labels.split(",");
        auto raw = fixture(config ~ labels ~ "\n1" ~ ",1".replicate(fields.length - 1));
        assert(raw.column(fields[0])[0] == 1);
        assertThrown!CsvException(raw.variable("v"));
    }
    auto fixed = fixture("# method = sample\n# algorithm = fixed_param\n# num_samples = 3\n" ~
                         "# num_warmup = 100\n# save_warmup = true\n# thin = 2\nx\n4\n8\n");
    assert(fixed.column("x") == [4, 8] && !fixed.warmupColumn("x").length);
    foreach (bad; ["a,a\n1,2", "a,b\n1", "a\n1,2", "a\n", "a\n1oops",
                   "a\n1,", "a\n1\n2", "a\n0x1p0", "a\n1f", "a\n1_0"])
        assertThrown!CsvException(fixture(config ~ bad));
    assertThrown!CsvException(fixture(config.replace("num_samples = 1", "num_samples = 9999999999") ~ "a\n1"));
}

private ChainDraws readChain(File input, string path, ulong bytes)
{
    auto locale = numericLocale();
    enforce!CsvException(locale !is null, "Could not create C numeric locale");
    scope (exit) freeLocale(locale);
    ChainDraws chain;
    size_t lineNumber, row;
    string[string] settings;
    bool inOutput;

    void check(bool condition, lazy string detail)
    {
        if (!condition)
            throw new CsvException(path ~ "(" ~ lineNumber.to!string ~ "): " ~ detail);
    }
    size_t number(string key)
    {
        auto value = key in settings;
        check(value !is null, "missing " ~ key);
        try { return (*value).to!size_t; }
        catch (Exception) { throw new CsvException(path ~ ": invalid " ~ key); }
    }

    foreach (raw; input.byLine())
    {
        ++lineNumber;
        auto line = raw.strip;
        if (!line.length) continue;
        if (line[0] == '#')
        {
            string comment = line[1 .. $].strip.idup;
            chain.annotations ~= comment;
            if (chain.names.length) continue;
            auto eq = comment.indexOf('=');
            if (eq < 0)
            {
                inOutput = comment == "output";
                continue;
            }
            auto value = comment[eq + 1 .. $].strip;
            if (value.endsWith("(Default)"))
                value = value[0 .. $ - "(Default)".length].strip;
            auto key = comment[0 .. eq].strip;
            if (inOutput && key == "file") chain.outputFile = value;
            settings[key] = value;
            continue;
        }
        if (!chain.names.length)
        {
            check(settings.get("method", "") == "sample", "expected method=sample");
            size_t thin = number("thin");
            check(thin > 0, "thin must be positive");
            size_t thinned(size_t count) { return count / thin + (count % thin != 0); }
            auto samples = number("num_samples");
            chain.savedSamples = thinned(samples);
            auto save = settings.get("save_warmup", "");
            check(save == "0" || save == "1" || save == "false" || save == "true",
                  "invalid save_warmup");
            auto warm = number("num_warmup");
            chain.layout = SampleLayout(settings.get("model", ""), settings.get("algorithm", ""),
                settings.get("engine", ""), samples, warm, thin, save == "1" || save == "true");
            chain.recordedSeed = settings.get("seed", "");
            if ("num_chains" in settings)
            {
                auto count = number("num_chains");
                check(count > 0 && count <= uint.max, "invalid num_chains");
                chain.nativeChainCount = cast(uint) count;
            }
            if (chain.layout.saveWarmup && chain.layout.algorithm != "fixed_param")
                chain.savedWarmup = thinned(warm);
            if ("id" in settings)
            {
                auto id = number("id");
                check(id <= uint.max, "invalid chain id");
                chain.id = cast(uint) id;
                chain.hasRecordedId = true;
            }
            chain.names = line.idup.split(",");
            foreach (index, ref name; chain.names)
            {
                name = name.strip;
                check(name.length && name !in chain.indices, "empty or duplicate column " ~ name);
                chain.indices[name] = index;
            }
            // At least one byte per cell must exist even in the smallest valid CSV.
            size_t width = chain.names.length;
            ulong limit = bytes / width;
            check(chain.savedSamples <= limit && chain.savedWarmup <= limit - chain.savedSamples,
                  "declared draws exceed file size");
            check(chain.savedSamples <= size_t.max / double.sizeof / width &&
                  chain.savedWarmup <= size_t.max / double.sizeof / width, "draw buffer too large");
            chain.posterior.length = chain.savedSamples * width;
            chain.warmup.length = chain.savedWarmup * width;
            continue;
        }
        bool warming = row < chain.savedWarmup;
        auto count = warming ? chain.savedWarmup : chain.savedSamples;
        auto index = warming ? row : row - chain.savedWarmup;
        check(index < count, "extra draw row");
        auto target = warming ? chain.warmup : chain.posterior;
        size_t col;
        foreach (field; line.splitter(','))
        {
            check(col < chain.names.length, "extra column");
            auto token = field.strip;
            double value;
            try
            {
                value = parseCell(token, locale);
            }
            catch (Exception)
            {
                throw new CsvException(path ~ "(" ~ lineNumber.to!string ~ "): invalid value for " ~ chain.names[col]);
            }
            target[col++ * count + index] = value;
        }
        check(col == chain.names.length, "missing column");
        ++row;
    }
    check(chain.names.length != 0, "missing header");
    check(row == chain.savedSamples + chain.savedWarmup, "incomplete chain");
    return chain;
}

// Restrict conversion to the decimal grammar used by CmdStan CSV.
private double parseCell(const(char)[] token, NumericLocale locale)
{
    import std.ascii : isDigit;
    import std.string : icmp;
    size_t i;
    if (token.length && (token[0] == '+' || token[0] == '-')) ++i;
    auto unsigned = token[i .. $];
    if (icmp(unsigned, "nan") == 0) return double.nan;
    if (icmp(unsigned, "inf") == 0 || icmp(unsigned, "infinity") == 0)
        return token[0] == '-' ? -double.infinity : double.infinity;
    size_t digits()
    {
        size_t start = i;
        while (i < token.length && isDigit(token[i])) ++i;
        return i - start;
    }
    size_t count = digits();
    if (i < token.length && token[i] == '.')
    {
        ++i;
        count += digits();
    }
    enforce!CsvException(count, "Missing significand");
    if (i < token.length && (token[i] == 'e' || token[i] == 'E'))
    {
        ++i;
        if (i < token.length && (token[i] == '+' || token[i] == '-')) ++i;
        enforce!CsvException(digits(), "Missing exponent");
    }
    enforce!CsvException(i == token.length, "Unexpected character in number");
    // The C runtime converts directly to binary64, including halfway cases.
    // Keep ordinary fields on the stack and terminate them before the C call.
    char[64] scratch = void;
    char[] buffer = token.length < scratch.length ? scratch[] : new char[token.length + 1];
    buffer[0 .. token.length] = token;
    buffer[token.length] = 0;
    return parseDecimal(buffer.ptr, null, locale);
}

version (Windows)
{
    private alias NumericLocale = void*;
    private extern(C) NumericLocale _create_locale(int category, const(char)* name);
    private extern(C) void _free_locale(NumericLocale);
    private extern(C) double _strtod_l(const(char)*, char**, NumericLocale);
    private alias freeLocale = _free_locale;
    private alias parseDecimal = _strtod_l;
    private NumericLocale numericLocale()
    {
        import core.stdc.locale : LC_NUMERIC;
        return _create_locale(LC_NUMERIC, "C");
    }
}
else version (Posix)
{
    private import core.sys.posix.locale : NumericLocale = locale_t, newlocale,
        freeLocale = freelocale, LC_NUMERIC_MASK;
    private extern(C) double strtod_l(const(char)*, char**, NumericLocale);
    private alias parseDecimal = strtod_l;
    private NumericLocale numericLocale() { return newlocale(LC_NUMERIC_MASK, "C", null); }
}

/// Numeric stansummary output in upstream row and column order.
struct SummaryTable
{
    private string[] rows, columns;
    private size_t[string] rowIndex, columnIndex;
    private double[] values;

    /// Returns: Parameter elements and sampler fields in output order.
    @property const(string)[] rowNames() const { return rows; }
    /// Returns: Statistic labels, including percentile labels, in output order.
    @property const(string)[] columnNames() const { return columns; }

    /++ Params:
            name = Exact stansummary row name, such as theta or A[1,2].
            statistic = Case-sensitive column label, such as Mean or R_hat.
        Returns: The reported value, including any upstream NaN or infinity.
        Throws: CsvException if either label is absent.
    +/
    double opIndex(string name, string statistic) const
    {
        auto r = name in rowIndex;
        auto c = statistic in columnIndex;
        enforce!CsvException(r, "Unknown summary row: " ~ name);
        enforce!CsvException(c, "Unknown summary statistic: " ~ statistic);
        return values[*r * columns.length + *c];
    }
}

/++ Params:
        path = Path to the CSV written by CmdStan's stansummary tool.
    Returns: An in-memory table independent of the file. Comment lines are skipped.
    Throws: CsvException for malformed tables, or an I/O exception on read failure.
+/
SummaryTable readSummaryCsv(string path)
{
    import std.csv : csvReader;
    import std.array : array;

    SummaryTable result;
    auto locale = numericLocale();
    enforce!CsvException(locale !is null, "Cannot create numeric locale");
    scope (exit) freeLocale(locale);
    size_t number;
    foreach (line; File(path).byLineCopy())
    {
        ++number;
        auto record = line.strip;
        enforce!CsvException(record.indexOf('\r') < 0,
            path ~ "(" ~ number.to!string ~ "): unexpected carriage return");
        if (!record.length || record[0] == '#') continue;
        try
        {
            auto fields = csvReader!string(record).front.array;
            if (!result.columns.length)
            {
                enforce(fields.length > 1 && fields[0] == "name", "expected summary header");
                result.columns = fields[1 .. $];
                foreach (i, label; result.columns)
                {
                    enforce(label.length && label !in result.columnIndex, "empty or duplicate statistic");
                    result.columnIndex[label] = i;
                }
                continue;
            }
            enforce(fields.length == result.columns.length + 1, "unexpected number of fields");
            auto name = fields[0];
            enforce(name.length && name !in result.rowIndex, "empty or duplicate row name");
            result.rowIndex[name] = result.rows.length;
            result.rows ~= name;
            foreach (field; fields[1 .. $]) result.values ~= parseCell(field.strip, locale);
        }
        catch (Exception e)
        {
            throw new CsvException(path ~ "(" ~ number.to!string ~ "): " ~ e.msg);
        }
    }
    enforce!CsvException(result.rows.length, path ~ ": empty summary table");
    return result;
}

unittest
{
    import cmdstan.internal.workspace : newDirectory, removeArtifactDirectory;
    import std.exception : assertThrown;
    import std.file : write;
    import std.math : isNaN;
    import std.path : buildPath;
    auto root = newDirectory(null, "summary-test-");
    scope (exit) removeArtifactDirectory(root);
    auto path = buildPath(root, "summary.csv");
    // Hand-authored to exercise quoted matrix indices and non-finite statistics.
    write(path, "name,Mean,5%,R_hat\r\n\"A[1,2]\",1.25,-inf,nan\r\n# timing, data\r\n");
    auto t = readSummaryCsv(path);
    assert(t.rowNames == ["A[1,2]"] && t.columnNames == ["Mean", "5%", "R_hat"]);
    assert(t["A[1,2]", "Mean"] == 1.25 && t["A[1,2]", "5%"] == -double.infinity);
    assert(t["A[1,2]", "R_hat"].isNaN);
    assertThrown!CsvException(t["x", "Mean"]);
    assertThrown!CsvException(t["A[1,2]", "missing"]);
    foreach (bad; ["", "name,Mean\n", "bad,Mean\nx,1", "name,M,M\nx,1,2",
                   "name,M\nx,1\nx,2", "name,M\nx", "name,M\nx,1,2", "name,M\nx,3x",
                   "name,Mean\ntheta,1\rbeta,2\n", "name,Mean\ntheta,1\n# comment\rbeta,2\n"])
    {
        write(path, bad);
        assertThrown!CsvException(readSummaryCsv(path));
    }
}

unittest
{
    auto table = readSummaryCsv("tests/fixtures/bernoulli-summary-2.40.0.csv");
    assert(table["theta", "R_hat"] == 0.99533925665013223);
    assert(table["theta", "ESS_bulk"] == 14.683073348973082);
    assert(table["theta", "ESS_tail"] == 8);
}
