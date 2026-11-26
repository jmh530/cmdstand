/// Optional Mir ndslice adapter for per-chain CmdStan draws.
module cmdstan.mir;

import cmdstan.csv : CsvException, DrawView;
import mir.ndslice.slice : Slice, Universal;
import std.exception : enforce;
import std.meta : allSatisfy, Filter;
import std.traits : isIntegral;

version (unittest)
{
    private string fixturePath(string relativePath)
    {
        import std.path : buildNormalizedPath, dirName;
        // Resolve from mir/source/cmdstan even when DUB runs in the subpackage.
        return buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..", "..", "..", relativePath);
    }
}

/++ Params:
        view = Sampling or warmup view from one chain.
    Returns: A read-only handle for selecting Mir slices from the draw buffer.
        Supply one selector per axis, starting with saved iteration. Each range
        retains an axis in the result and each integer selects one position.
+/
IndexedDraws asSlice(DrawView view) @safe
{
    return IndexedDraws(view);
}

///
unittest
{
    import cmdstan.csv : readSampleCsv;
    auto a = readSampleCsv(fixturePath("mir/tests/groups.csv")).variable("A").asSlice;
    auto trace = a[0 .. $, 0, 1, 2];
    auto matrices = a[0 .. $, 0, 0 .. $, 0 .. $];
    assert(matrices.shape == [2, 2, 3]);
    assert(matrices[1][1, 2] == trace[1]);
}

private struct Interval { size_t lower, upper; }
private enum isInterval(T) = is(T == Interval);
private enum isSelector(T) = isIntegral!T || isInterval!T;

/// Runtime-rank draw view supporting D multidimensional indexing and slicing.
struct IndexedDraws
{
    private DrawView view;

    /++ Params:
            axis = Zero-based dimension supplied by D for a dollar expression.
        Returns: Length of this axis in the underlying view.
        Throws: CsvException if the axis does not exist.
    +/
    size_t opDollar(size_t axis)() const @safe
    {
        enforce!CsvException(axis < view.shape.length, "Draw axis out of bounds");
        return view.shape[axis];
    }

    /++ Params:
            axis = Dimension of the range in a bracket expression.
            lower = Inclusive lower bound.
            upper = Exclusive upper bound.
        Returns: Range selector for opIndex. Equal bounds select an empty range.
    +/
    auto opSlice(size_t axis)(size_t lower, size_t upper) const @safe
    {
        return Interval(lower, upper);
    }

    /++ Params:
            S = Integer and range selector types inferred from the bracket expression.
            selectors = One zero-based index or half-open range per input axis.
        Returns: A double for all-integer indexing. Otherwise, a read-only Mir
            slice with one axis per range, in the original axis order. Slices
            of chain data keep the GC-owned draw storage alive.
        Throws: CsvException for the wrong selector count, invalid indices or
            ranges, or a layout inconsistent with the backing storage.
    +/
    auto opIndex(S...)(S selectors) const @safe
        if (S.length && allSatisfy!(isSelector, S))
    {
        import std.conv : to;
        enforce!CsvException(view.shape.length == S.length && view.strides.length == S.length,
            "Expected one selector per axis for draw shape " ~ view.shape.to!string);
        enum rank = Filter!(isInterval, S).length;
        size_t[rank] lengths;
        ptrdiff_t[rank] strides;
        size_t retained, offset;
        size_t span = 1;
        bool empty;
        foreach (axis, selector; selectors)
        {
            auto extent = view.shape[axis];
            enforce!CsvException(view.strides[axis] == span && span <= ptrdiff_t.max &&
                (!extent || span <= view.data.length / extent), "Invalid dense draw layout");
            static if (isInterval!(typeof(selector)))
            {
                enforce!CsvException(selector.lower <= selector.upper && selector.upper <= extent,
                                     "Draw range out of bounds");
                lengths[retained] = selector.upper - selector.lower;
                strides[retained++] = cast(ptrdiff_t) span;
                empty = empty || selector.lower == selector.upper;
                offset += selector.lower * span;
            }
            else
            {
                enforce!CsvException(selector >= 0 && selector < extent, "Draw index out of bounds");
                offset += cast(size_t) selector * span;
            }
            span *= extent;
        }
        enforce!CsvException(span == view.data.length, "Draw shape differs from buffer length");
        static if (rank == 0)
            return view.data[offset];
        else
        {
            // Empty selections need no offset, including a range starting at $.
            auto tail = view.data[empty ? 0 : offset .. $];
            alias Result = Slice!(const(double)*, rank, Universal);
            return (() @trusted => Result(lengths, strides, tail.ptr))();
        }
    }
}

unittest
{
    import cmdstan.csv : readSampleCsv;
    import core.memory : GC;
    import std.exception : assertThrown;

    auto chain = readSampleCsv(fixturePath("mir/tests/groups.csv"));
    auto v = chain.variable("A");
    auto a = v.asSlice;
    auto draws = a[0 .. $, 0 .. $, 0 .. $, 0 .. $];
    assert(draws.shape == [2, 1, 2, 3] && draws.strides == [1, 2, 2, 4]);
    auto matrices = a[0 .. $, 0, 0 .. $, 0 .. $];
    size_t t;
    foreach (matrix; matrices)
    {
        foreach (r; 0 .. 2)
            foreach (c; 0 .. 3)
            {
                auto trace = a[0 .. $, 0, r, c];
                assert(&matrix[r, c] == &trace[t]);
                assert(&trace[t] == &v.series(0, r, c)[t]);
                assert(a[t, 0, r, c] == matrix[r, c]);
            }
        ++t;
    }
    assert(t == 2 && matrices[1][1, 0] == 121);
    static assert(!__traits(compiles, matrices[1, 0, 0] = 0));
    auto block = a[1 .. $, 0, 0 .. $, 1 .. 3];
    assert(block.shape == [1, 2, 2] && block[0, 1, 0] == 122);
    assert(a[$ .. $, 0, 1, 2].length == 0);
    auto w = chain.warmupVariable("A").asSlice;
    auto warm = w[0 .. $, 0 .. $, 0 .. $, 0 .. $];
    assert(warm.shape == [0, 1, 2, 3] && warm.strides == [1, 0, 0, 0]);
    auto x = chain.variable("x").asSlice;
    assert(x[$ - 1] == 2 && &x[0 .. $][1] == &chain.column("x")[1]);
    assertThrown!CsvException(a[0, 0]);
    assertThrown!CsvException(a[0, 0, 0, 0, 0 .. $]);
    assertThrown!CsvException(a[0, -1, 0, 0]);
    assertThrown!CsvException(a[0, 0, 0, 2 .. 1]);
    assertThrown!CsvException(a[0, 0, 0, 0 .. 4]);
    assertThrown!CsvException(w[0, 0, 0, 0]);
    assertThrown!CsvException(DrawView.init.asSlice[0]);
    assertThrown!CsvException(DrawView([size_t(2)], [size_t(1)], [0.0]).asSlice[0 .. $]);
    assertThrown!CsvException(DrawView([size_t(2)], [size_t(3)], [0.0, 1.0]).asSlice[0 .. $]);

    auto savedMatrix()
    {
        auto other = readSampleCsv(fixturePath("tests/fixtures/matrix.csv"));
        return other.warmupVariable("m").asSlice[0, 0 .. $, 0 .. $];
    }
    auto matrix = savedMatrix();
    GC.collect();
    assert(matrix[0, 2] == -13 && matrix[1, 0] == -21);
}
