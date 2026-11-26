# Running lent benchmarks

`tests/bench_columns.py` times lent queries over a column table and shows
where each query spends its time: lent's fold stages, the `barch.vec`
kernels, and the cursor reads. Use it to measure a change to
`lent/columns.luau` or to barch, and to compare two versions of either.

`tests/bench_vec.py` times the vector kernels on their own; see
[barch-vec.md](barch-vec.md#testing).

## Run it

From the repository root, with `redis` installed for Python, call the module
with a row count and a block size in bytes:

```bash
BARCHD=/home/test/barch/cmake-build-release/barchd FIRST=262144 \
    STEPS="reduced:2000:262144:524288" python -m tests.bench_columns 524288 65536
```

The bench starts its own `barchd` from `BARCHD`, installs lent, and loads
table `P` with ROWS rows. Each row holds `age = id % 100` and
`weight = id * 7919 % 1000`, both `int` fields. Loading takes most of the
run: 524,288 rows take about 35 s at 64 KB blocks and about 100 s at 256 KB.
Run long benchmarks in the background.

Use a release build of barch, and note its commit with the results, since
the figures change with the binary.

## Settings

| variable | default | meaning |
|---|---|---|
| `BARCHD` | required | the `barchd` binary to start |
| `STEPS` | `run,run` | steps to run, comma separated, each `name` or `name:arg:...` |
| `REPS` | `2000` | repetitions, passed to a step given without arguments |
| `FIRST` | `1` | the first id loaded |
| `RANGED` | range sharded | `0` makes the space hashed sharded |
| `AOT` | off | `1` installs the bench function with `SETF ... AOT` |

Set `FIRST=262144` to fill every block. Ids start at 1, so with the default
the first block has a hole at id 0 and the last block is partly empty, and
those blocks take the slower path for blocks with absent rows. 262144 lies on
a block boundary for every block size up to 256 KB.

Measure range sharded spaces. Hashed sharding suits write contention and is
not the target for scan speed.

`AOT` compiles only the bench function natively. `lent/columns.luau` starts
with `--!native` and is always compiled natively. To compile the other lent
modules natively as well, add `--!native` as the first line of each in a copy
of the checkout and run that copy.

## Steps

| step | arguments | what it prints |
|---|---|---|
| `run` | reps | each query's time, inside and outside a transaction, split into start, fold and finish, client and store time |
| `runat` | rows, reps | `run` with the in-place threshold set to `rows` bytes |
| `plain` | reps | each query's time and result |
| `vecprof` | query, reps | each vector kernel's calls and µs per query |
| `reduced` | reps, first, n | `age > 10 sum` as its kernels alone, then with each part of the fold added back |
| `curcost` | reps, first, n | µs per cursor read of a weight block, in several ways |
| `prims` | reps | single store reads and kernels on a presence block |
| `sizes` | reps | cursor, `getBufferAt` and `get` reads of values from 4 KB to 1 MB |
| `bigset` | none | whether values from 256 KB to 1 MB store whole |
| `vecsizes` | reps | ns per slot of each kernel as the chunk grows |
| `loop` | query, seconds | one query in a loop, for attaching a profiler after `ready` |
| `prof` | reps | time inside the fold, from a timed copy of lent |
| `fold5` | reps | time in each fold function and kernel, from a timed copy of lent |

A query argument is a name from the bench's `QUERIES` list, such as
`sum all`, `age > 10 sum` or `grouped sum`. For `reduced` and `curcost`,
pass the same `first` and `n` as `FIRST` and ROWS so the step covers the
loaded rows.

`sizes` and `bigset` write test keys under `zz.` in the bench's space.

### Read `reduced`

`reduced` starts from the two kernels that `age > 10 sum` needs and adds one
part of lent's work at each line, so each line's increase is that part's
cost. Each line prints µs per query, G rows/s and the sum, and every line
except 5 should print the query's sum:

| line | adds |
|---|---|
| `0` | `vec.compare` on age and `vec.foldBits` on weight, over blocks copied before timing |
| `1` | each int format's nil value |
| `2` | the presence header check that finds full blocks |
| `2b` | a presence compare and `bits("and")` on every block, the cost of blocks with absent rows |
| `2c`, `3c` | all age blocks, then all weight blocks, copied and read in place |
| `3` | blocks read in place through one cursor each for presence, age and weight |
| `4` | block keys encoded on every query |
| `5` | lent's `start_fold`, `fold` and `finish`; prints the number of spans |
| `6` | the full `c.P:query():where("age > 10"):sum("weight")` |

At 64 KB blocks, 524,288 rows, range sharded, with barch `05d5c09` and lent
`3fd5e3f`, line 0 ran at about 4.5 G rows/s, line 3 at 3.5, line 5 at 2.8
and line 6 at 2.6.

## Compare two versions

The bench loads lent from the checkout that holds it. To compare two
versions, export each to its own directory and run each copy's own
`tests/bench_columns.py` with the same settings:

```bash
git archive 590e6fd | tar -x -C /path/to/base
cd /path/to/base && BARCHD=... STEPS=... python -m tests.bench_columns 524288 65536
```

Run each version at least twice and alternate them. Figures move by up to
about 10% from run to run.

## Time inside the fold

`prof` and `fold5` read timer tables that `lent/columns.luau` fills only in a
timed copy. `fold5` reads `PROF` and `PN`, and `prof` reads `PROF`. To make
the copy, add these lines to a copy of `lent/columns.luau`, just before
`function fold(`. Each wrapped name is a local function defined above that
line:

```lua
PROF, PN = {}, {}
local function W(name: string, f: any): any
    return function(...)
        local t0 = barch.time()
        local a, b, c, d = f(...)
        PROF[name] = (PROF[name] or 0) + barch.time() - t0
        PN[name] = (PN[name] or 0) + 1
        return a, b, c, d
    end
end
load = W("load", load)
read_head = W("read_head", read_head)
fold_span = W("fold_span", fold_span)
-- and any other local function before this point
```

Each timer adds about 150 ns per call, and `fold5` prints that cost as
`one timed wrapper`. A query with many timed calls reads high by that amount
times the calls, so compare parts within one run.
