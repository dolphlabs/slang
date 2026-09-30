// The hero: a field of S-rabbits receding into the dark, one of them lit in
// lime. Each rabbit is a green task. Every so often one hops (a task being
// scheduled), and `spawn` hops a hundred more into the field.
//
// Plain three.js rather than @react-three/fiber: this is one canvas on an
// otherwise static page, and React would add a runtime and a reconciler to
// drive a few hundred matrices. <model-viewer> shows one model per element
// and cannot instance a field.

import {
  ACESFilmicToneMapping,
  AdditiveBlending,
  BufferAttribute,
  BufferGeometry,
  CanvasTexture,
  Color,
  DirectionalLight,
  DynamicDrawUsage,
  Fog,
  HemisphereLight,
  InstancedMesh,
  Matrix4,
  Mesh,
  MeshBasicMaterial,
  MeshStandardMaterial,
  PerspectiveCamera,
  PlaneGeometry,
  PointLight,
  Quaternion,
  Scene,
  SRGBColorSpace,
  Vector3,
  WebGLRenderer,
  type Material,
} from 'three';
import { GLTFLoader, type GLTF } from 'three/examples/jsm/loaders/GLTFLoader.js';
import { MeshoptDecoder } from 'three/examples/jsm/libs/meshopt_decoder.module.js';

import hiUrl from '../assets/models/rabbit.glb?url';
import loUrl from '../assets/models/rabbit-lo.glb?url';

export interface HeroOptions {
  canvas: HTMLCanvasElement;
  reducedMotion: boolean;
  // Where the horizon should sit, as a fraction of the canvas height from
  // the top: just under the page's own content, so the field fills the
  // space the layout leaves it on any screen.
  horizon?: () => number;
  onCount?: (n: number) => void;
}

export interface Hero {
  spawn(n: number): void;
  count(): number;
  dispose(): void;
}

const BG = new Color('#07080a');
const LIME = new Color('#d6f531');

// Field geometry, in rabbit heights (the model is 1 unit tall).
const BACK_Z = -40;
const NEAR_Z = -1; // rabbits in front of this use the detailed mesh
const ROW_GAP = 1.9;
const COL_GAP = 1.65;

// The camera stands at rabbit height and tilts up just enough to put the
// horizon where the page asks (see HeroOptions.horizon). Tilting up rather
// than raising the camera keeps the near rows big, which is what gives the
// field its depth.
const CAMERA_POS = new Vector3(0, 1.5, 14);
const CAMERA_LOOK = new Vector3(0, 1.5, 0);
const NEAREST = 7.5; // closest a rabbit may stand to the camera

interface Rabbit {
  pool: Pool;
  slot: number;
  shadow: number;
  x: number;
  z: number;
  yaw: number;
  scale: number;
  tint: number;
  hopAt: number; // seconds; -1 when not hopping
  hopDur: number;
  hopHeight: number;
  bornAt: number; // for the pop-in when spawned; -1 once settled
  spawned: boolean;
}

interface Pool {
  mesh: InstancedMesh;
  capacity: number;
  used: number;
}

function toFloatGeometry(gltf: GLTF): BufferGeometry {
  let found: Mesh | undefined;
  gltf.scene.updateMatrixWorld(true);
  gltf.scene.traverse((o) => {
    if (!found && (o as Mesh).isMesh) found = o as Mesh;
  });
  if (!found) throw new Error('rabbit model has no mesh');
  // The files are quantized (int16 positions, int8 normals) with the
  // dequantizing transform on the node. Instancing needs that transform in
  // the vertices, and applying it to normalized ints would clamp, so copy
  // every attribute to float first.
  const src = found.geometry;
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
  geo.applyMatrix4(found.matrixWorld);
  geo.computeBoundingSphere();
  return geo;
}

function rabbitMaterial(gltf: GLTF): MeshStandardMaterial {
  let mat: Material | undefined;
  gltf.scene.traverse((o) => {
    if (!mat && (o as Mesh).isMesh) mat = (o as Mesh).material as Material;
  });
  if (!(mat instanceof MeshStandardMaterial)) throw new Error('rabbit model has no standard material');
  return mat;
}

// A soft round shadow, drawn under every rabbit instead of real shadow maps:
// one small texture and one draw call for the whole field.
function blobTexture(core = 'rgba(0,0,0,0.75)'): CanvasTexture {
  const c = document.createElement('canvas');
  c.width = c.height = 64;
  const g = c.getContext('2d');
  if (!g) throw new Error('2d canvas unavailable');
  const grad = g.createRadialGradient(32, 32, 0, 32, 32, 32);
  grad.addColorStop(0, core);
  grad.addColorStop(1, core.replace(/[\d.]+\)$/, '0)'));
  g.fillStyle = grad;
  g.fillRect(0, 0, 64, 64);
  const t = new CanvasTexture(c);
  t.colorSpace = SRGBColorSpace;
  return t;
}

// Deterministic, so the field looks the same on every visit and in the
// poster image.
function rng(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export async function createHero(opts: HeroOptions): Promise<Hero> {
  const { canvas, reducedMotion } = opts;
  const small = window.matchMedia('(max-width: 700px)').matches;
  const cores = navigator.hardwareConcurrency || 4;
  const modest = small || cores <= 4;

  const loader = new GLTFLoader();
  loader.setMeshoptDecoder(MeshoptDecoder);
  const [hi, lo] = await Promise.all([loader.loadAsync(hiUrl), loader.loadAsync(loUrl)]);

  const hiGeo = toFloatGeometry(hi);
  const loGeo = toFloatGeometry(lo);
  const baseMat = rabbitMaterial(hi);

  const renderer = new WebGLRenderer({ canvas, antialias: !modest, powerPreference: 'high-performance' });
  renderer.setClearColor(BG, 1);
  renderer.toneMapping = ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.05;
  renderer.outputColorSpace = SRGBColorSpace;
  const maxDpr = modest ? 1.5 : 1.75;
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, maxDpr));

  const scene = new Scene();
  scene.background = BG;
  scene.fog = new Fog(BG, 18, 50);

  const camera = new PerspectiveCamera(30, 1, 0.1, 80);

  scene.add(new HemisphereLight(0xf1ede4, 0x0b0e08, 1.25));
  const key = new DirectionalLight(0xfff6ea, 2.9);
  key.position.set(5, 9, 7);
  scene.add(key);
  // A cool light from behind picks the silhouettes out of the dark.
  const rim = new DirectionalLight(0xbcd0ff, 1.6);
  rim.position.set(-4, 5, -9);
  scene.add(rim);

  const ground = new Mesh(
    new PlaneGeometry(240, 240),
    new MeshStandardMaterial({ color: 0x0c1009, roughness: 1, metalness: 0 }),
  );
  ground.rotation.x = -Math.PI / 2;
  scene.add(ground);

  // ---- the field -------------------------------------------------------

  const fieldMat = baseMat.clone();
  fieldMat.roughness = 0.6;

  const baseCount = modest ? 150 : 300;
  const spawnCapacity = modest ? 200 : 400;
  const totalCapacity = baseCount + spawnCapacity;

  const makePool = (geo: BufferGeometry, capacity: number): Pool => {
    const mesh = new InstancedMesh(geo, fieldMat, capacity);
    mesh.instanceMatrix.setUsage(DynamicDrawUsage);
    mesh.count = 0;
    mesh.frustumCulled = false; // instances span the whole field
    // Allocates instanceColor so every instance can carry its own tint.
    mesh.setColorAt(0, new Color(1, 1, 1));
    scene.add(mesh);
    return { mesh, capacity, used: 0 };
  };
  // Near rabbits are few (two or three rows), so the detailed pool is small.
  const near = makePool(hiGeo, modest ? 40 : 90);
  const far = makePool(loGeo, totalCapacity);

  const shadowMat = new MeshBasicMaterial({ map: blobTexture(), transparent: true, depthWrite: false, color: 0x000000 });
  const shadowGeo = new PlaneGeometry(1, 1).rotateX(-Math.PI / 2);
  const shadows = new InstancedMesh(shadowGeo, shadowMat, totalCapacity + 1);
  shadows.instanceMatrix.setUsage(DynamicDrawUsage);
  shadows.count = 0;
  shadows.frustumCulled = false;
  shadows.renderOrder = 1;
  scene.add(shadows);

  // The lit one.
  const limeMat = baseMat.clone();
  limeMat.color = LIME.clone();
  limeMat.emissive = LIME.clone();
  limeMat.emissiveIntensity = 0.6;
  limeMat.emissiveMap = baseMat.map; // eyes and ear rims stay dark
  limeMat.roughness = 0.45;
  const lime = new Mesh(hiGeo, limeMat);
  scene.add(lime);
  const limeGlow = new PointLight(LIME, 9, 6, 1.4);
  scene.add(limeGlow);
  // The pool of light it stands in, drawn additively on the ground.
  const halo = new Mesh(
    new PlaneGeometry(1, 1).rotateX(-Math.PI / 2),
    new MeshBasicMaterial({ map: blobTexture('rgba(214,245,49,0.55)'), transparent: true, depthWrite: false, blending: AdditiveBlending }),
  );
  halo.renderOrder = 2;
  scene.add(halo);

  const rabbits: Rabbit[] = [];
  let shadowUsed = 0;
  let limeX = 1.7;
  let limeZ = 3.2;
  let frontZ = 4.6;
  let limeHopAt = -1;
  let nextLimeHop = 2.4;
  let spawnedOrder: Rabbit[] = [];

  const m4 = new Matrix4();
  const q = new Quaternion();
  const pos = new Vector3();
  const scl = new Vector3();
  const up = new Vector3(0, 1, 0);
  const tint = new Color();

  function frustumHalfWidth(z: number): number {
    const dist = Math.max(0.1, CAMERA_POS.z - z);
    const halfH = Math.tan((camera.fov * Math.PI) / 360) * dist;
    return halfH * camera.aspect;
  }

  function place(r: Rabbit, x: number, z: number, rand: () => number): void {
    r.x = x;
    r.z = z;
    // Face right, as in the mark, with a little disorder.
    r.yaw = (rand() - 0.5) * 0.7;
    r.scale = 0.92 + rand() * 0.16;
    r.tint = 0.82 + rand() * 0.18;
  }

  function addRabbit(x: number, z: number, rand: () => number, spawned: boolean, now: number): Rabbit | null {
    const pool = z > NEAR_Z && near.used < near.capacity ? near : far;
    if (pool.used >= pool.capacity || shadowUsed >= totalCapacity) return null;
    const r: Rabbit = {
      pool,
      slot: pool.used++,
      shadow: shadowUsed++,
      x: 0, z: 0, yaw: 0, scale: 1, tint: 1,
      hopAt: -1, hopDur: 0.5, hopHeight: 0.4,
      bornAt: spawned && !reducedMotion ? now : -1,
      spawned,
    };
    place(r, x, z, rand);
    pool.mesh.count = pool.used;
    shadows.count = shadowUsed;
    tint.setScalar(r.tint);
    pool.mesh.setColorAt(r.slot, tint);
    if (pool.mesh.instanceColor) pool.mesh.instanceColor.needsUpdate = true;
    rabbits.push(r);
    return r;
  }

  function layout(): void {
    rabbits.length = 0;
    spawnedOrder = [];
    near.used = far.used = shadowUsed = 0;
    const rand = rng(0x51a9);
    // The lime rabbit sits right of centre on wide screens, where the
    // headline does not cover it; centred on a phone.
    limeX = camera.aspect > 1.2 ? frustumHalfWidth(limeZ) * 0.42 : frustumHalfWidth(limeZ) * 0.3;

    // Rows get sparser with distance so the far field reads as texture,
    // not a wall; the count is capped by the budget either way.
    const want = baseCount;
    let placed = 0;
    for (let z = frontZ, row = 0; z > BACK_Z && placed < want; z -= ROW_GAP * (1 + row * 0.018), row++) {
      const half = frustumHalfWidth(z) * 1.08;
      const gap = COL_GAP * (1 + Math.max(0, -z) * 0.02);
      const offset = (row % 2) * gap * 0.5;
      for (let x = -half + offset; x <= half && placed < want; x += gap) {
        const jx = x + (rand() - 0.5) * gap * 0.55;
        const jz = z + (rand() - 0.5) * ROW_GAP * 0.5;
        // Keep a clearing around the lime rabbit, and nothing between it and
        // the camera, so it reads as the one.
        if (Math.hypot(jx - limeX, (jz - limeZ) * 1.4) < 1.3) continue;
        if (jz > limeZ - 0.4 && Math.abs(jx - limeX) < 1.5) continue;
        // Leave the very front sparse: big rabbits there crowd the copy.
        if (jz > 3 && rand() < 0.45) continue;
        if (addRabbit(jx, jz, rand, false, 0)) placed++;
      }
    }
    opts.onCount?.(rabbits.length + 1);
  }

  const spawnRand = rng(0xbeef);

  function spawn(n: number): void {
    const now = clock();
    for (let i = 0; i < n; i++) {
      const z = frontZ - 0.6 - spawnRand() * 28;
      const half = frustumHalfWidth(z) * 0.95;
      const x = (spawnRand() * 2 - 1) * half;
      let r: Rabbit | null = null;
      const free = z > NEAR_Z ? near.used < near.capacity : far.used < far.capacity;
      if (free && rabbits.length < totalCapacity) {
        r = addRabbit(x, z, spawnRand, true, now);
      } else if (spawnedOrder.length) {
        // Full: the oldest spawned rabbit hops somewhere new, in its own
        // pool's depth range so its level of detail stays right.
        r = spawnedOrder.shift() ?? null;
        if (r) {
          const rz = r.pool === near ? NEAR_Z + spawnRand() * Math.max(0.5, frontZ - NEAR_Z - 1) : NEAR_Z - spawnRand() * 24;
          const rhalf = frustumHalfWidth(rz) * 0.95;
          place(r, (spawnRand() * 2 - 1) * rhalf, rz, spawnRand);
          r.bornAt = reducedMotion ? -1 : now;
        }
      }
      if (r) {
        // Stagger them, as a loop of spawns would.
        if (r.bornAt >= 0) r.bornAt = now + i * 0.012;
        spawnedOrder.push(r);
      }
    }
    opts.onCount?.(rabbits.length + 1);
    if (reducedMotion) requestRender();
  }

  // ---- animation -----------------------------------------------------------

  const t0 = performance.now();
  const clock = () => (performance.now() - t0) / 1000;

  const pointer = { x: 0, y: 0, tx: 0, ty: 0 };
  const onPointer = (e: PointerEvent) => {
    pointer.tx = (e.clientX / window.innerWidth) * 2 - 1;
    pointer.ty = (e.clientY / window.innerHeight) * 2 - 1;
  };
  if (!reducedMotion) window.addEventListener('pointermove', onPointer, { passive: true });

  let nextHop = 0.6;
  const hopRand = rng(0x40b);

  function update(t: number, dt: number): void {
    if (!reducedMotion) {
      const k = 1 - Math.exp(-dt * 2.5);
      pointer.x += (pointer.tx - pointer.x) * k;
      pointer.y += (pointer.ty - pointer.y) * k;

      // About five hops a second across the field: tasks being scheduled.
      while (t >= nextHop && rabbits.length) {
        const r = rabbits[Math.floor(hopRand() * rabbits.length)];
        if (r && r.hopAt < 0 && r.bornAt < 0) {
          r.hopAt = t;
          r.hopDur = 0.42 + hopRand() * 0.2;
          r.hopHeight = 0.22 + hopRand() * 0.3;
        }
        nextHop += 0.08 + hopRand() * 0.24;
      }
      if (t >= nextLimeHop) {
        limeHopAt = t;
        nextLimeHop = t + 3.2 + hopRand() * 1.6;
      }
    }

    camera.position.set(
      CAMERA_POS.x + pointer.x * 0.45,
      CAMERA_POS.y - pointer.y * 0.18,
      CAMERA_POS.z,
    );
    camera.lookAt(CAMERA_LOOK);

    // Rabbits turn a little toward the pointer, as if they heard it.
    const lean = pointer.x * 0.3;

    for (const r of rabbits) {
      let y = 0;
      let sx = 1;
      let sy = 1;
      let grow = 1;
      if (r.bornAt >= 0) {
        const p = (t - r.bornAt) / 0.55;
        if (p < 0) {
          grow = 0;
        } else if (p >= 1) {
          r.bornAt = -1;
        } else {
          // Pop out of the ground with a small overshoot.
          const c = 1.9;
          const e = 1 + (c + 1) * Math.pow(p - 1, 3) + c * Math.pow(p - 1, 2);
          grow = Math.max(0, e);
          y = Math.sin(Math.PI * p) * 0.5;
        }
      }
      if (r.hopAt >= 0) {
        const p = (t - r.hopAt) / r.hopDur;
        if (p >= 1) {
          r.hopAt = -1;
        } else {
          const s = Math.sin(Math.PI * p);
          y += 4 * r.hopHeight * p * (1 - p);
          sy = 1 + 0.09 * s;
          sx = 1 - 0.05 * s;
        }
      }
      const s = r.scale * grow;
      q.setFromAxisAngle(up, r.yaw + lean);
      pos.set(r.x, y, r.z);
      scl.set(s * sx, s * sy, s * sx);
      m4.compose(pos, q, scl);
      r.pool.mesh.setMatrixAt(r.slot, m4);

      // The shadow shrinks as the rabbit leaves the ground.
      const sh = s * (1 - Math.min(0.6, y * 0.9));
      q.identity();
      pos.set(r.x + 0.02, 0.004, r.z);
      scl.set(0.95 * sh, 1, 0.55 * sh);
      m4.compose(pos, q, scl);
      shadows.setMatrixAt(r.shadow, m4);
    }

    // The lime rabbit: a slow breath and a hop every few seconds.
    let ly = 0;
    let lsy = 1 + Math.sin(t * 1.6) * 0.012;
    if (limeHopAt >= 0) {
      const p = (t - limeHopAt) / 0.6;
      if (p >= 1) limeHopAt = -1;
      else {
        ly = 4 * 0.32 * p * (1 - p);
        lsy += 0.08 * Math.sin(Math.PI * p);
      }
    }
    lime.position.set(limeX, ly, limeZ);
    lime.rotation.set(0, lean * 1.6, 0);
    lime.scale.set(1.18, 1.18 * lsy, 1.18);
    limeGlow.position.set(limeX + 0.1, 0.9 + ly, limeZ + 0.6);
    halo.position.set(limeX, 0.006, limeZ);
    halo.scale.set(3.4, 1, 2.2);
    q.identity();
    pos.set(limeX + 0.02, 0.005, limeZ);
    const lsh = 1.18 * (1 - Math.min(0.6, ly * 0.9));
    scl.set(1.0 * lsh, 1, 0.6 * lsh);
    m4.compose(pos, q, scl);
    shadows.setMatrixAt(shadowUsed, m4);
    shadows.count = shadowUsed + 1;

    near.mesh.instanceMatrix.needsUpdate = true;
    far.mesh.instanceMatrix.needsUpdate = true;
    shadows.instanceMatrix.needsUpdate = true;
  }

  // ---- loop, visibility, resize --------------------------------------------

  let raf = 0;
  let visible = true;
  let last = clock();
  let running = false;

  function frame(): void {
    raf = 0;
    const t = clock();
    const dt = Math.min(0.1, t - last);
    last = t;
    update(t, dt);
    renderer.render(scene, camera);
    if (running) raf = requestAnimationFrame(frame);
  }

  function requestRender(): void {
    if (!raf) raf = requestAnimationFrame(frame);
  }

  function setRunning(on: boolean): void {
    const want = on && !reducedMotion;
    if (want === running) return;
    running = want;
    if (running) {
      last = clock();
      requestRender();
    }
  }

  const syncRunning = () => setRunning(visible && !document.hidden);

  const io = new IntersectionObserver(([entry]) => {
    visible = !!entry?.isIntersecting;
    syncRunning();
  });
  io.observe(canvas);
  document.addEventListener('visibilitychange', syncRunning);

  // Tilt so the horizon lands at the requested fraction of the height, then
  // stand the front row where the bottom edge meets the ground.
  let lastFront = 0;
  function aim(): void {
    const half = (camera.fov * Math.PI) / 360;
    const f = Math.min(0.85, Math.max(0.5, opts.horizon?.() ?? 0.66));
    const tilt = Math.atan((f - 0.5) * 2 * Math.tan(half));
    CAMERA_LOOK.set(0, CAMERA_POS.y + Math.tan(tilt) * CAMERA_POS.z, 0);
    const below = half - tilt; // bottom edge, below the horizontal
    const dMin = CAMERA_POS.y / Math.tan(Math.max(below, 0.02));
    frontZ = CAMERA_POS.z - Math.max(NEAREST, dMin * 0.9);
    limeZ = frontZ - 2.4;
  }

  let lastAspect = 0;
  function resize(): void {
    const w = canvas.clientWidth;
    const h = canvas.clientHeight;
    if (!w || !h) return;
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    // Narrow screens see less of the field side to side; widen the view
    // vertically so the rabbits are not cropped to a sliver.
    camera.fov = camera.aspect < 0.8 ? 44 : camera.aspect < 1.2 ? 36 : 30;
    camera.updateProjectionMatrix();
    aim();
    // Re-plant the field only when the shape changes enough to leave gaps
    // at the edges, not on every pixel of a drag.
    if (!lastAspect || Math.abs(camera.aspect - lastAspect) / lastAspect > 0.15 || Math.abs(frontZ - lastFront) > 0.8) {
      lastFront = frontZ;
      const spawned = spawnedOrder.length;
      lastAspect = camera.aspect;
      layout();
      if (spawned) spawn(spawned);
    }
    requestRender();
  }
  const ro = new ResizeObserver(resize);
  ro.observe(canvas);
  resize();

  canvas.addEventListener('webglcontextlost', (e) => {
    e.preventDefault();
    setRunning(false);
    canvas.classList.remove('is-ready');
  });

  // First frame, then reveal.
  update(0, 0);
  renderer.render(scene, camera);
  canvas.classList.add('is-ready');
  syncRunning();

  return {
    spawn,
    count: () => rabbits.length + 1,
    dispose() {
      setRunning(false);
      if (raf) cancelAnimationFrame(raf);
      io.disconnect();
      ro.disconnect();
      document.removeEventListener('visibilitychange', syncRunning);
      window.removeEventListener('pointermove', onPointer);
      renderer.dispose();
    },
  };
}
