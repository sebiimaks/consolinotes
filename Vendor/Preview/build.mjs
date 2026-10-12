// Build the shipped offline diagram renderer and inventory every incorporated package.
import {build} from 'esbuild';
import {readFile, writeFile, readdir, mkdir, cp, rm} from 'node:fs/promises';
import {resolve, dirname, relative, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {inflateSync} from 'node:zlib';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const hash = value => createHash('sha256').update(value).digest('hex');
const readJSON = async file => JSON.parse(await readFile(file, 'utf8'));
const lock = await readJSON(join(here, 'package-lock.json'));
const output = 'Resources/MPreview.bundle/js/mermaid.min.js';
// Mermaid's npm core includes a complete js-yaml copy that npm overrides cannot
// replace. Its only exports are JSON_SCHEMA and load. Replace that exact chunk
// with the compatible patched package; fail closed when upstream bytes change.
const yamlChunk = 'node_modules/mermaid/dist/chunks/mermaid.core/chunk-LNGE3PJU.mjs';
const yamlChunkHash = '2cb4e5f8d5fd99daccb0135fda6a5583c91f39efb0bb845af9d968ed427efcb2';
if (hash(await readFile(join(here, yamlChunk))) !== yamlChunkHash) throw new Error('Review Mermaid embedded YAML chunk before updating');
const replaceYAML = {name: 'patched-embedded-yaml', setup(builder) {
  builder.onLoad({filter: /\/mermaid\/dist\/chunks\/mermaid\.core\/chunk-LNGE3PJU\.mjs$/}, () => ({
    contents: "export {JSON_SCHEMA, load} from 'js-yaml';", loader: 'js', resolveDir: here
  }));
}};
const result = await build({absWorkingDir: here, entryPoints: ['entry.js'], outfile: resolve(root, output),
  bundle: true, minify: true, platform: 'browser', format: 'iife', target: 'safari15',
  sourcemap: false, metafile: true, legalComments: 'inline', logLevel: 'warning', plugins: [replaceYAML]});
const embedded = new Map();
for (const input of Object.keys(result.metafile.inputs).filter(file => file.includes('mermaid/dist/'))) {
  let map;
  try { map = await readJSON(resolve(here, input + '.map')); } catch { continue; }
  for (const source of map.sources || []) {
    const match = source.match(/node_modules\/\.pnpm\/([^/]+)\/node_modules\//);
    if (!match) continue;
    const nameVersion = match[1].split('(')[0].split('_')[0];
    const split = nameVersion.lastIndexOf('@');
    const name = nameVersion.slice(0, split).replaceAll('+', '/'), version = nameVersion.slice(split + 1);
    const replacement = name === 'js-yaml' ? lock.packages['node_modules/js-yaml'].version : version;
    if (lock.packages['node_modules/' + name]?.version !== replacement) throw new Error(`Unreviewed embedded package: ${name}@${version}`);
    embedded.set(name, {name, upstream_embedded_version: version, shipped_version: replacement,
      ...(name === 'js-yaml' ? {replacement_chunk: yamlChunk, upstream_chunk_sha256: yamlChunkHash} : {})});
  }
}
await build({absWorkingDir: here, stdin: {contents: "import hljs from 'highlight.js'; window.hljs = hljs;", resolveDir: here},
  outfile: resolve(root, 'Resources/MPreview.bundle/js/highlight.min.js'), bundle: true, minify: true,
  platform: 'browser', format: 'iife', target: 'safari15', legalComments: 'inline'});
const math = resolve(root, 'Resources/MPreview.bundle/js/mathjax');
await rm(math, {recursive: true, force: true});
await mkdir(math, {recursive: true});
for (const resource of ['tex-mml-chtml.js', 'input/tex/extensions', 'output/chtml/fonts', 'ui/safe.js']) {
  await mkdir(dirname(join(math, resource)), {recursive: true});
  await cp(join(here, 'node_modules/mathjax/es5', resource), join(math, resource), {recursive: true});
}
const incorporated = new Map();
for (const input of Object.keys(result.metafile.inputs)) {
  let directory = dirname(resolve(here, input));
  while (directory.startsWith(join(here, 'node_modules'))) {
    try {
      const pkg = await readJSON(join(directory, 'package.json'));
      const key = relative(here, directory);
      if (pkg.name && pkg.version && lock.packages[key]) incorporated.set(key, {directory, pkg});
      if (pkg.name && pkg.version) break;
    } catch {}
    directory = dirname(directory);
  }
}
// Include all runtime package licences, even prebundled inputs invisible to esbuild.
for (const [key, pkg] of Object.entries(lock.packages)) {
  if (!key || pkg.dev || pkg.optional || key.includes('@types/')) continue;
  const directory = resolve(here, key);
  const metadata = await readJSON(join(directory, 'package.json'));
  incorporated.set(key, {directory, pkg: metadata});
}
const old = await readJSON(join(root, 'Licenses/web/components.json'));
const components = old.filter(item => !item.notes?.includes('Mermaid') && !['mermaid', 'MathJax TeX fonts'].includes(item.name));
const inventory = [];
for (const [key, {directory, pkg}] of [...incorporated].sort((a, b) => a[1].pkg.name.localeCompare(b[1].pkg.name))) {
  const files = (await readdir(directory)).filter(name => /^(licen[cs]e|copying|notice)(\.|$)/i.test(name)).sort();
  let text = (await Promise.all(files.map(async name => `${name}:\n\n${await readFile(join(directory, name), 'utf8')}`))).join('\n\n');
  if (!files.length) {
    const readme = await readFile(join(directory, 'README.md'), 'utf8');
    const section = readme.match(/^## Licen[cs]e\s*\n([\s\S]*?)(?=^## |$(?![\s\S]))/m)?.[1];
    if (!section?.includes('Permission is hereby granted') || !section.includes('THE SOFTWARE IS PROVIDED')) throw new Error(`Missing original licence text: ${pkg.name}`);
    text = 'README.md licence section:\n\n' + section.trim();
  }
  const filename = `Licenses/web/${pkg.name.replace(/^@/, '').replaceAll('/', '-')}-${pkg.version}.txt`;
  await writeFile(join(root, filename), text.trim() + '\n');
  const pinned = lock.packages[key];
  const displayName = ({mermaid: 'Mermaid', mathjax: 'MathJax'})[pkg.name] || pkg.name;
  const license = typeof pkg.license === 'string' ? pkg.license : ({khroma: 'MIT'})[pkg.name];
  if (!license) throw new Error(`Review missing licence declaration for ${pkg.name}`);
  components.push({name: displayName, version: pkg.version, license,
    source: pinned.resolved, file: filename,
    notes: 'Offline preview dependency; resolved by Vendor/Preview/package-lock.json. Includes runtime package notices for Mermaid 12.1.0 prebundled source as well as direct build inputs.'});
  inventory.push({name: pkg.name, version: pkg.version, archive: pinned.resolved, integrity: pinned.integrity, license_sha256: hash(text.trim() + '\n')});
}
// Preserve the original per-font copyright and Reserved Font Names embedded
// in upstream WOFF files, in addition to the complete SIL OFL text.
const fontNotices = new Set();
for (const file of await readdir(join(math, 'output/chtml/fonts/woff-v2'))) {
  if (!file.endsWith('.woff')) continue;
  const bytes = await readFile(join(math, 'output/chtml/fonts/woff-v2', file));
  for (let index = 0; index < bytes.readUInt16BE(12); index++) {
    const offset = 44 + index * 20;
    if (bytes.toString('ascii', offset, offset + 4) !== 'name') continue;
    const start = bytes.readUInt32BE(offset + 4), length = bytes.readUInt32BE(offset + 8);
    let table = bytes.subarray(start, start + length);
    if (length < bytes.readUInt32BE(offset + 12)) table = inflateSync(table);
    const base = table.readUInt16BE(4);
    for (let nameIndex = 0; nameIndex < table.readUInt16BE(2); nameIndex++) {
      const record = 6 + nameIndex * 12;
      if (table.readUInt16BE(record + 6) !== 13) continue;
      const platform = table.readUInt16BE(record), length = table.readUInt16BE(record + 8), start = table.readUInt16BE(record + 10);
      const text = Buffer.from(table.subarray(base + start, base + start + length));
      fontNotices.add([0, 3].includes(platform) ? text.swap16().toString('utf16le') : text.toString('latin1'));
    }
  }
}
if (!fontNotices.size) throw new Error('MathJax font notices missing');
const oflSource = await readFile(join(root, 'Resources/MPreview.bundle/fonts/SourceCodePro-OFL.txt'), 'utf8');
const ofl = oflSource.slice(oflSource.indexOf('SIL OPEN FONT LICENSE Version 1.1'));
const fontLicense = 'Licenses/web/mathjax-tex-fonts-3.2.2.txt';
await writeFile(join(root, fontLicense), [...fontNotices].sort().join('\n\n') + '\n\n' + ofl);
components.push({name: 'MathJax TeX fonts', version: '3.2.2', license: 'SIL-OFL-1.1',
  source: lock.packages['node_modules/mathjax'].resolved, file: fontLicense,
  notes: 'Original copyright and Reserved Font Names extracted from the published WOFF name tables. Fonts are copied without modification.'});
await writeFile(join(root, 'Licenses/web/components.json'), JSON.stringify(components, null, 2) + '\n');
const assets = {};
async function inventoryAssets(directory) {
  for (const file of await readdir(directory, {withFileTypes: true})) {
    const path = join(directory, file.name);
    if (file.isDirectory()) await inventoryAssets(path);
    else assets[relative(root, path)] = hash(await readFile(path));
  }
}
await inventoryAssets(math);
assets['Resources/MPreview.bundle/js/highlight.min.js'] = hash(await readFile(resolve(root, 'Resources/MPreview.bundle/js/highlight.min.js')));
await writeFile(join(root, 'Licenses/web/provenance.json'), JSON.stringify({mermaid_version: '12.1.0', bundle_path: output,
  bundle_sha256: hash(await readFile(resolve(root, output))), recipe: 'Vendor/Preview/build.mjs',
  recipe_sha256: hash(await readFile(fileURLToPath(import.meta.url))),
  lockfile: 'Vendor/Preview/package-lock.json', lockfile_sha256: hash(await readFile(join(here, 'package-lock.json'))),
  entry_sha256: hash(await readFile(join(here, 'entry.js'))), bundler: 'esbuild 0.28.2',
  embedded_packages: [...embedded.values()], assets, packages: inventory}, null, 2) + '\n');
console.log(`Bundled Mermaid 12.1.0 and retained ${inventory.length} runtime package notices.`);
