import cmdstan.csv : readSampleCsv;
import std.algorithm : sum;
import std.exception : enforce;
import std.stdio : stderr, writefln, writeln;

void main(string[] args)
{
    enforce(args.length == 2, "Usage: draw-traces <sampling CSV>");
    auto chain = readSampleCsv(args[1]);
    auto theta = chain.variable("theta").series();
    auto a = chain.variable("A");
    enforce(theta.length && a.shape == [theta.length, 2, 2],
            "Expected saved draws for scalar theta and matrix[2, 2] A");

    // Each slice follows one entry through all saved iterations.
    auto a00 = a.series(0, 0);
    auto a01 = a.series(0, 1);
    auto a10 = a.series(1, 0);
    auto a11 = a.series(1, 1);
    auto determinants = new double[theta.length];
    foreach (t, ref det; determinants)
        det = a00[t] * a11[t] - a01[t] * a10[t];

    stderr.writefln("Mean theta: %g; mean determinant: %g",
                    theta.sum / theta.length, determinants.sum / determinants.length);
    writeln("saved_draw,theta,determinant");
    foreach (t, det; determinants)
        writefln("%d,%.17g,%.17g", t + 1, theta[t], det);
}
