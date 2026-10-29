# VECTORS

VECTORS is the `examples/hnsw` index with nk vectors in place of words.
`vectors.SET <name> <buffer>` stores a point; pass the vector as ONE argument:
a packed f32 buffer (dim*4 bytes, e.g. Python `struct.pack('<384f', *vec)`).
`vectors.CLOSEST <buffer> [k]` returns the nearest name, or name/distance
pairs when k is given. Do NOT pass one argument per component (the colon form
`vectors:SET` is parsed by the builtin SET first, which treats a third arg
as an EX/NX/GET option and refuses it before the function is reached).
Distance defaults to cosine. TUNE can switch it to `euclidean` and back
without a rebuild; TUNE also sets M/efConstruction/efSearch/heuristic, and
PARAMS reports them. Write through the dotted form in the space (`USE vectors`
first; the colon form writes a plain key). The barch-spaces console takes its command
list from that repository's `spaces/commands.json`; add the four VECTORS commands
there if its dropdown should offer them.
