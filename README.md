
WARNING: Spoilers for Void Stranger ahead!

---

A program that uses BFS to explore the state space of b053 for brand solutions.
Focused on proving (un)reachability of certain brands burdenless: <https://voidstranger.miraheze.org/wiki/Brand>.
Can also find some shortest-move sequences for brands with and without certain burdens.
Current implementation is based on <https://www.snellman.net/blog/archive/2018-07-23-optimizing-breadth-first-search/>

Requires `zig` 0.16 to run.

---

### Running a searcher

- Choose the searcher file for the specific brane you are interested in (e.g. `bfs_b053_tile.zig` or `bfs_b023.zig`)
- Edit the searcher's `goal_tile` to the brand you want to carve
- Edit the brand definition file (eg. `b023.zig` or `b223.zig`) to enable/disable burdens or the endless rod as desired
- Run with: `zig run <searcher> -O ReleaseFast`

---

### Performance

`bfs_b053_tile_v2.zig` is a resumable, undirected state space explorer that writes states to disk grouped by (tilecount, move depth).
(Note the bottom-right corner tile covered by the rock is not included in this count -- Tan's brand has a tilecount of 21 by this metric.)
It uses a simple variable-length diff compression that achieves an average of 4-5 bytes/state.
Running it to a minimum tilecount of 22 consumes about 38GB of disk space, finishing in around 3 hours.
Further running with a minimum tilecount of 21 consumes an additional 101GB disk space (for a total of 139GB) and finishes in around 12 hours.
Further running with a minimum tilecount of 20 consumes an additional 327GB disk space (for a total of 466GB) and finishes in around one week (>120 hours, only ~15% of which is spent executing instructions (user+sys)).

Since all unique reachable states are stored persistently in `b053-data/`,
they can then later be queried for certain properties like matching a certain brand.
This is done by `query_b053_data.zig`, which confirms Tan's brand is unreachable burdenless,
and `stairs.zig`, which collects and deduplicates all distinct brand carvings
(ignoring now-extraneous info like which tiles are glass or not).

### Performance (Old)

Running commit `b6552f6` under the following conditions:
- Algorithm: BFS (this searcher has since been moved to `bfs_move.zig`)
- Pruning (unchanged from the commit):
  - Minumum tiles at least as many as Tan's brand (21, when not including the tile under the egg)
  - Position never any of 0,3,4,5,10,11,16,29,34
    (corresponding to never entering the X tiles in the following diagram, though they may still be removed by the rod)
    ```
    X....X
    ......
    ......
    X....X
    X....X
    XX..XX
    ```
- Hardware:
  - Macbook with Apple M4 Pro CPU and 24GB RAM

A full exploration of the thusly-pruned state space ran in about **14.5** hours of wall-clock time,
reaching a depth of 199 moves and visiting a total of 14,437,812,425 unique states
(requiring 26 GB of compressed state data, as well as 14.4GB of uncompressed parent pointers),
using about 62 GB total RAM / working set size (including effects of OS compression)
and writing a total of about **7 TB** to disk (as swap) over the entire run.

Past the initial stages, time is vastly dominated by read/write/copy/swap caused by the merge process.

No solution for Tan's brand was found.

