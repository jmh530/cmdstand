"""Compare D-decoded columns to CmdStanPy's independent reader for the same run."""
import csv
import sys
from pathlib import Path

import cmdstanpy
import numpy as np

parent = Path(sys.argv[1])
run, = parent.glob("run-*")
paths = sorted(run.glob("chain-*/draws.csv"))
fit = cmdstanpy.from_csv([str(path) for path in paths])
draws = fit.draws(inc_warmup=False)
for chain, path in enumerate(paths):
    with (parent / f"parsed-{chain + 1}.csv").open(newline="") as stream:
        rows = csv.reader(stream)
        assert list(fit.column_names) == next(rows)
        parsed = np.array([[float(x) for x in row] for row in rows])
    np.testing.assert_array_equal(parsed, draws[:, chain, :])
print(f"Matched {draws.shape} draws/chain/column array with CmdStanPy {cmdstanpy.__version__}")
