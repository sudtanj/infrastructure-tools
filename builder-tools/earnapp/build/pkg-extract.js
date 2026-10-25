// Unpacks the JavaScript from a pkg-built executable (EarnApp's client) into a
// directory, without running the executable. Usage:
//   node pkg-extract.js <binary> <outdir>
// pkg appends a prelude and a payload to a Node.js binary. The prelude ends
// with "\n,\n"-separated JSON: the file table, the entrypoint, symlinks, a
// path-segment dictionary and the compression mode (0 none, 1 gzip, 2 brotli).
'use strict';
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const [bin, out] = process.argv.slice(2);
if (!bin || !out) throw new Error('usage: pkg-extract.js <binary> <outdir>');
const b = fs.readFileSync(bin);
const text = b.toString('latin1');
const num = name => {
    const m = new RegExp(`var ${name} = '(\\d+) *' \\| 0;`).exec(text);
    if (!m) throw new Error(`${name} not found: not a pkg executable?`);
    return +m[1];
};
const payload = num('PAYLOAD_POSITION');
const prelude_pos = num('PRELUDE_POSITION');
const prelude = b.toString('utf8', prelude_pos, prelude_pos+num('PRELUDE_SIZE'));

// The JSON parts hold no raw newlines, so the last five "\n,\n" pieces are
// the file table (last line of its piece), entrypoint, symlinks, dictionary
// and compression mode.
const parts = prelude.split('\n,\n');
const [vfs_part, entry_part, links_part, dict_part, mode_part] = parts.slice(-5);
const vfs = JSON.parse(vfs_part.slice(vfs_part.lastIndexOf('\n')+1));
const dict = JSON.parse(dict_part);
const mode = parseInt(mode_part, 10);
const segs = {};
for (const k in dict)
    segs[dict[k]] = k;
const decode = p=>p.split('/').map(s=>s in segs ? segs[s] : s).join('/');
const root = path.resolve(out);
const dest = p=>{
    const rel = decode(p).replace(/^\/snapshot\//, '');
    const f = path.resolve(root, rel);
    if (!f.startsWith(root+path.sep))
        throw new Error(`path outside ${out}: ${decode(p)}`);
    return f;
};

let files = 0;
for (const k in vfs)
{
    const stores = vfs[k];
    // Store 1 is the file content, 0 is V8 bytecode (tied to pkg's Node.js).
    if (!stores[1])
    {
        if (stores[0])
            throw new Error(`${decode(k)} ships as bytecode only`);
        continue;
    }
    const [off, len] = stores[1];
    let data = b.subarray(payload+off, payload+off+len);
    if (mode==1)
        data = zlib.gunzipSync(data);
    else if (mode==2)
        data = zlib.brotliDecompressSync(data);
    const f = dest(k);
    fs.mkdirSync(path.dirname(f), {recursive: true});
    fs.writeFileSync(f, data);
    files++;
}
const links = JSON.parse(links_part);
for (const k in links)
{
    const f = dest(k);
    fs.mkdirSync(path.dirname(f), {recursive: true});
    fs.symlinkSync(path.relative(path.dirname(f), dest(links[k])), f);
}
console.log(`${files} files, ${Object.keys(links).length} symlinks, `
    +`entrypoint ${JSON.parse(entry_part).replace(/^\/snapshot\//, '')}`);
