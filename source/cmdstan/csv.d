/// Read one CmdStan sampling CSV independently of a CmdStan installation.
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

/// Owned draws for one chain. Phase buffers store each column contiguously.
struct ChainDraws
{
    private string[] names;
    private size_t[string] indices;
    private double[] posterior, warmup;
    private string[] annotations;
    private size_t savedSamples, savedWarmup;
    private uint id;

    /// Returns: Original scalar column labels, in file order.
    @property const(string)[] columnNames() const @safe pure nothrow { return names; }
    /// Returns: Configuration, adaptation, and timing comments, in file order.
    @property const(string)[] comments() const @safe pure nothrow { return annotations; }
    /// Returns: CmdStan chain ID recorded in the file, or zero if absent.
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

    private const(double)[] values(string name, const(double)[] buffer, size_t count) const @safe
    {
        auto index = name in indices;
        enforce!CsvException(index !is null, "Unknown CmdStan column " ~ name);
        return buffer[*index * count .. (*index + 1) * count];
    }
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
            if (eq < 0) continue;
            auto value = comment[eq + 1 .. $].strip;
            if (value.endsWith("(Default)"))
                value = value[0 .. $ - "(Default)".length].strip;
            settings[comment[0 .. eq].strip] = value;
            continue;
        }
        if (!chain.names.length)
        {
            check(settings.get("method", "") == "sample", "expected method=sample");
            size_t thin = number("thin");
            check(thin > 0, "thin must be positive");
            size_t thinned(size_t count) { return count / thin + (count % thin != 0); }
            chain.savedSamples = thinned(number("num_samples"));
            auto save = settings.get("save_warmup", "");
            check(save == "0" || save == "1" || save == "false" || save == "true",
                  "invalid save_warmup");
            auto warm = number("num_warmup");
            if (save == "1" || save == "true") chain.savedWarmup = thinned(warm);
            if ("id" in settings)
            {
                auto id = number("id");
                check(id <= uint.max, "invalid chain id");
                chain.id = cast(uint) id;
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
