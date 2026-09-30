// Turns the 16 MB, 400k-triangle Tripo export of the S-rabbit into the two
// files the hero loads:
//
//   src/assets/models/rabbit.glb     the near rabbits: ~24k triangles, textured
//   src/assets/models/rabbit-lo.glb  the field: ~3k triangles, geometry only
//
// The field draws hundreds of rabbits from one InstancedMesh, so its
// triangle count is multiplied by the instance count; the textures are only
// shipped once, in rabbit.glb, and the page reuses that material for both.
//
// Usage: npm run model -- "/path/to/s-shaped bunny3d.glb"
//
// The source model is not committed: every `git clone` of the slang repo
// fetches every branch, so a 16 MB binary here would land on every machine
// that only wanted the compiler.

import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS, EXTMeshoptCompression } from '@gltf-transform/extensions';
import {
  dedup,
  prune,
  quantize,
  simplify,
  textureCompress,
  weld,
} from '@gltf-transform/functions';
import { MeshoptEncoder, MeshoptSimplifier } from 'meshoptimizer';
import sharp from 'sharp';
import { mkdir, stat } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = resolve(ROOT, 'src/assets/models');

const src = process.argv[2];
if (!src) {
  console.error('usage: npm run model -- <source.glb>');
  process.exit(2);
}

// Triangle budgets. HI is what a rabbit a third of the viewport tall needs to
// keep a clean silhouette; LO is the most a phone can afford times ~300.
// The error bound is relative to the mesh extent: 0.002 keeps the ear rims,
// the rabbit's most recognisable edge, sharp up close; the field rabbits are
// never more than ~60 px tall and can give more of it up.
const HI = { triangles: 24_000, error: 0.002 };
const LO = { triangles: 3_000, error: 0.01 };

await MeshoptSimplifier.ready;
await MeshoptEncoder.ready;

const io = new NodeIO()
  .registerExtensions(ALL_EXTENSIONS)
  .registerDependencies({ 'meshopt.encoder': MeshoptEncoder });

function triangles(doc) {
  let n = 0;
  for (const mesh of doc.getRoot().listMeshes()) {
    for (const prim of mesh.listPrimitives()) {
      const idx = prim.getIndices();
      n += (idx ? idx.getCount() : prim.getAttribute('POSITION').getCount()) / 3;
    }
  }
  return n;
}

async function load() {
  const doc = await io.read(src);
  const root = doc.getRoot();
  // Tripo writes KHR_materials_volume with no thickness (a no-op) and
  // FB_ngon_encoding, which three.js does not read. Drop both.
  for (const ext of root.listExtensionsUsed()) {
    if (ext.extensionName !== EXTMeshoptCompression.EXTENSION_NAME) ext.dispose();
  }
  return doc;
}

async function reduce(doc, { triangles: target, error }) {
  const before = triangles(doc);
  await doc.transform(
    weld(),
    simplify({ simplifier: MeshoptSimplifier, ratio: target / before, error }),
  );
  return before;
}

async function write(doc, name) {
  const root = doc.getRoot();
  // keepAttributes: the field mesh has no textures of its own but is drawn
  // with rabbit.glb's, so its UVs must survive the prune. The eyes and the
  // ear rims exist only in that texture.
  await doc.transform(dedup(), prune({ keepAttributes: true }), quantize());
  doc.createExtension(EXTMeshoptCompression)
    .setRequired(true)
    .setEncoderOptions({ method: EXTMeshoptCompression.EncoderMethod.QUANTIZE });
  const path = resolve(OUT, name);
  await io.write(path, doc);
  const { size } = await stat(path);
  console.log(`${name}: ${Math.round(triangles(doc))} triangles, ` +
    `${root.listTextures().length} textures, ${(size / 1024).toFixed(0)} KB`);
}

await mkdir(OUT, { recursive: true });

// Near rabbit: textured. The metallic-roughness map is nearly flat (metallic
// ~0.03 on average), so it becomes two factors instead of a 1.4 MB image.
// Roughness is set to the matte clay look of the reference render rather
// than the map's glossier ~0.3 average, which reads as plastic under the
// hero's rim light.
{
  const doc = await load();
  const before = await reduce(doc, HI);
  console.log(`source: ${Math.round(before)} triangles`);
  for (const mat of doc.getRoot().listMaterials()) {
    const mr = mat.getMetallicRoughnessTexture();
    mat.setMetallicRoughnessTexture(null);
    mr?.dispose();
    mat.setMetallicFactor(0).setRoughnessFactor(0.55);
    mat.setName('rabbit');
  }
  await doc.transform(
    textureCompress({ encoder: sharp, targetFormat: 'webp', resize: [1024, 1024], quality: 88 }),
  );
  await write(doc, 'rabbit.glb');
}

// Field rabbit: geometry and UVs only; the page gives it rabbit.glb's
// material.
{
  const doc = await load();
  await reduce(doc, LO);
  for (const mat of doc.getRoot().listMaterials()) {
    for (const tex of [mat.getBaseColorTexture(), mat.getNormalTexture(), mat.getMetallicRoughnessTexture()]) {
      tex?.dispose();
    }
  }
  await write(doc, 'rabbit-lo.glb');
}
