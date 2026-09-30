// Loads the rabbit once for either hero: the detailed mesh (with the
// texture that carries the eyes and ear rims) and the low-poly one.

import { BufferAttribute, BufferGeometry, Mesh, MeshStandardMaterial, type Material, type Texture } from 'three';
import { GLTFLoader, type GLTF } from 'three/examples/jsm/loaders/GLTFLoader.js';
import { MeshoptDecoder } from 'three/examples/jsm/libs/meshopt_decoder.module.js';

import hiUrl from '../assets/models/rabbit.glb?url';
import loUrl from '../assets/models/rabbit-lo.glb?url';

export interface Rabbit {
  hi: BufferGeometry;
  lo: BufferGeometry;
  map: Texture | null;
}

function firstMesh(gltf: GLTF): Mesh {
  let found: Mesh | undefined;
  gltf.scene.updateMatrixWorld(true);
  gltf.scene.traverse((o) => {
    if (!found && (o as Mesh).isMesh) found = o as Mesh;
  });
  if (!found) throw new Error('rabbit model has no mesh');
  return found;
}

// The files are quantized (int16 positions, int8 normals) with the
// dequantizing transform on the node. Copy every attribute to float and
// bake that transform in: applying it to normalized ints would clamp.
function toFloatGeometry(mesh: Mesh): BufferGeometry {
  const src = mesh.geometry;
  const geo = new BufferGeometry();
  for (const name of ['position', 'normal', 'uv'] as const) {
    const a = src.getAttribute(name);
    if (!a) continue;
    const out = new Float32Array(a.count * a.itemSize);
    for (let i = 0; i < a.count; i++) {
      out[i * a.itemSize] = a.getX(i);
      if (a.itemSize > 1) out[i * a.itemSize + 1] = a.getY(i);
      if (a.itemSize > 2) out[i * a.itemSize + 2] = a.getZ(i);
    }
    geo.setAttribute(name, new BufferAttribute(out, a.itemSize));
  }
  const index = src.getIndex();
  if (index) geo.setIndex(new BufferAttribute(new Uint32Array(index.array), 1));
  geo.applyMatrix4(mesh.matrixWorld);
  // Centre it: the model stands on y = 0 and the heroes turn it about its
  // middle.
  geo.computeBoundingBox();
  const box = geo.boundingBox;
  if (box) geo.translate(-(box.min.x + box.max.x) / 2, -(box.min.y + box.max.y) / 2, -(box.min.z + box.max.z) / 2);
  geo.computeBoundingSphere();
  return geo;
}

export async function loadRabbit(): Promise<Rabbit> {
  const loader = new GLTFLoader();
  loader.setMeshoptDecoder(MeshoptDecoder);
  const [hi, lo] = await Promise.all([loader.loadAsync(hiUrl), loader.loadAsync(loUrl)]);
  const hiMesh = firstMesh(hi);
  const mat = hiMesh.material as Material;
  const map = mat instanceof MeshStandardMaterial ? mat.map : null;
  return { hi: toFloatGeometry(hiMesh), lo: toFloatGeometry(firstMesh(lo)), map };
}
