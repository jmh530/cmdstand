import cmdstan.csv : readSampleCsv;
import cmdstan.mir : asSlice;
import std.algorithm : sum;
import std.exception : enforce;
import std.stdio : stderr, writefln, writeln;

void main(string[] args)
{
    enforce(args.length == 2, "Usage: mir-draw-traces <sampling CSV>");
    auto chain = readSampleCsv(args[1]);
    auto theta = chain.variable("theta").asSlice[0 .. $];
    auto a = chain.variable("A").asSlice;
    auto matrices = a[0 .. $, 0 .. $, 0 .. $];
    enforce(theta.length && matrices.shape == [theta.length, 2, 2],
            "Expected saved draws for scalar theta and matrix[2, 2] A");

    double[] determinants;
    determinants.reserve(theta.length);
    foreach (matrix; matrices)
    {
        determinants ~= matrix[0, 0] * matrix[1, 1] - matrix[0, 1] * matrix[1, 0];
    }
    stderr.writefln("Mean theta: %g; mean determinant: %g",
                    theta.sum / theta.length, determinants.sum / determinants.length);
    writeln("saved_draw,theta,determinant");
    foreach (t, det; determinants)
        writefln("%d,%.17g,%.17g", t + 1, theta[t], det);
}
