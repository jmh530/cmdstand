import cmdstan;
import std.stdio : writeln;

void main(string[] args)
{
    struct Survey { int N; int[] y; }
    auto stan = CmdStan.discover();
    auto model = stan.compile(args.length > 1 ? args[1] : "bernoulli.stan");
    scope (exit) model.close();

    SampleOptions options;
    options.chains = options.parallelChains = 2;
    options.seed = 12345;
    auto fit = model.sample(Survey(10, [0, 1, 0, 0, 0, 0, 0, 0, 0, 1]), options);
    foreach (i; 0 .. fit.chainCount)
    {
        auto theta = fit.chain(i).column("theta");
        writeln("Chain ", fit.chain(i).chainId, ": ", theta.length, " draws, first theta = ", theta[0]);
    }
}
