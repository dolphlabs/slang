// The rabbit as a glowing point cloud over a faint wireframe. Points are
// sampled from the detailed mesh's surface and take their brightness from
// its texture, so the eyes and ear rims read as gaps. Near the cursor the
// points part and turn lime; a few always glow, like tasks being run.
// Everything that moves per point happens in the vertex shader: the CPU
// sets a handful of uniforms per frame.

import {
  AdditiveBlending,
  BufferAttribute,
  BufferGeometry,
  Color,
  Group,
  LineBasicMaterial,
  LineSegments,
  Mesh,
  MeshBasicMaterial,
  Points,
  Scene,
  ShaderMaterial,
  Vector2,
  Vector3,
  WireframeGeometry,
  type Texture,
} from 'three';
import { MeshSurfaceSampler } from 'three/examples/jsm/math/MeshSurfaceSampler.js';

import type { Rabbit } from './model';
import type { Stage } from './stage';

const VERT = /* glsl */ `
attribute float aShade;
attribute float aRand;
uniform float uTime;
uniform float uSize;
uniform float uPixelRatio;
uniform float uAspect;
uniform float uRadius;
uniform float uActive;
uniform vec2 uMouse;
varying float vShade;
varying float vHot;
varying float vTask;

void main() {
  vec3 p = position;
  // A slow shimmer, different for every point.
  p += 0.0035 * vec3(sin(uTime * 1.7 + aRand * 40.0),
                     cos(uTime * 1.3 + aRand * 31.0),
                     sin(uTime * 1.1 + aRand * 17.0));
  vec4 mv = modelViewMatrix * vec4(p, 1.0);
  vec4 clip = projectionMatrix * mv;

  // Distance to the cursor on screen, in units of the canvas height.
  vec2 d = clip.xy / clip.w - uMouse;
  d.x *= uAspect;
  float f = uActive * smoothstep(uRadius, 0.0, length(d));
  vec2 push = normalize(d + 1e-5) * f * 0.07;
  push.x /= uAspect;
  clip.xy += push * clip.w;

  gl_Position = clip;
  gl_PointSize = uSize * uPixelRatio * (1.0 + f * 1.4) / -mv.z;
  vShade = aShade;
  vHot = f;
  vTask = step(0.975, aRand);
}
`;

const FRAG = /* glsl */ `
uniform vec3 uCream;
uniform vec3 uLime;
uniform float uTime;
varying float vShade;
varying float vHot;
varying float vTask;

void main() {
  float r = length(gl_PointCoord - 0.5);
  if (r > 0.5) discard;
  float soft = smoothstep(0.5, 0.0, r);
  float blink = vTask * (0.55 + 0.45 * sin(uTime * 3.0 + vShade * 60.0));
  float lime = max(vHot, blink);
  vec3 col = mix(uCream * (0.35 + 0.65 * vShade), uLime, lime);
  float a = soft * (0.3 + 0.9 * lime) * (0.25 + 0.75 * max(vShade, lime));
  gl_FragColor = vec4(col, a);
}
`;

// Brightness of the texture at each sampled uv: the eyes and ear rims are
// the dark parts of an otherwise pale map.
function shadeReader(map: Texture | null): ((u: number, v: number) => number) | null {
  const img = map?.image as (CanvasImageSource & { width: number; height: number }) | undefined;
  if (!img || !img.width) return null;
  const size = 256;
  const c = document.createElement('canvas');
  c.width = c.height = size;
  const g = c.getContext('2d', { willReadFrequently: true });
  if (!g) return null;
  g.drawImage(img, 0, 0, size, size);
  const data = g.getImageData(0, 0, size, size).data;
  // glTF uv has v pointing down the image, like the canvas.
  return (u, v) => {
    const x = Math.min(size - 1, Math.max(0, Math.floor((u - Math.floor(u)) * size)));
    const y = Math.min(size - 1, Math.max(0, Math.floor((v - Math.floor(v)) * size)));
    const i = (y * size + x) * 4;
    return ((data[i] ?? 0) * 0.299 + (data[i + 1] ?? 0) * 0.587 + (data[i + 2] ?? 0) * 0.114) / 255;
  };
}

export interface PointsHero {
  count: number;
  dispose(): void;
}

export function createPointsHero(stage: Stage, rabbit: Rabbit, reducedMotion: boolean): PointsHero {
  const scene = new Scene();
  const group = new Group();
  scene.add(group);

  const small = window.matchMedia('(max-width: 700px)').matches;
  const count = small ? 26_000 : 64_000;

  const sampler = new MeshSurfaceSampler(new Mesh(rabbit.hi, new MeshBasicMaterial())).build();
  const shade = shadeReader(rabbit.map);
  const pos = new Float32Array(count * 3);
  const shades = new Float32Array(count);
  const rands = new Float32Array(count);
  const p = new Vector3();
  const n = new Vector3();
  const c = new Color();
  const uv = new Vector2();
  for (let i = 0; i < count; i++) {
    sampler.sample(p, n, c, uv);
    pos[i * 3] = p.x;
    pos[i * 3 + 1] = p.y;
    pos[i * 3 + 2] = p.z;
    // Stretch the texture's range: pale body near 1, eyes near 0.
    const s = shade ? shade(uv.x, uv.y) : 0.8;
    shades[i] = Math.min(1, Math.max(0, (s - 0.2) / 0.6));
    rands[i] = Math.random();
  }
  const geo = new BufferGeometry();
  geo.setAttribute('position', new BufferAttribute(pos, 3));
  geo.setAttribute('aShade', new BufferAttribute(shades, 1));
  geo.setAttribute('aRand', new BufferAttribute(rands, 1));

  const uniforms = {
    uTime: { value: 0 },
    uSize: { value: 8 },
    uPixelRatio: { value: stage.dpr() },
    uAspect: { value: 1 },
    uRadius: { value: 0.16 },
    uActive: { value: 0 },
    uMouse: { value: new Vector2(10, 10) },
    uCream: { value: new Color('#f4f1ea') },
    uLime: { value: new Color('#d6f531') },
  };
  const mat = new ShaderMaterial({
    vertexShader: VERT,
    fragmentShader: FRAG,
    uniforms,
    transparent: true,
    depthWrite: false,
    blending: AdditiveBlending,
  });
  group.add(new Points(geo, mat));

  const wire = new LineSegments(
    new WireframeGeometry(rabbit.lo),
    new LineBasicMaterial({ color: 0xf4f1ea, transparent: true, opacity: 0.06, depthWrite: false, blending: AdditiveBlending }),
  );
  group.add(wire);

  stage.start(
    (t) => {
      const ptr = stage.pointer;
      uniforms.uTime.value = t;
      // Turn toward the cursor over a slow idle sway.
      const sway = reducedMotion ? 0 : Math.sin(t * 0.35) * 0.28;
      group.rotation.y = sway + ptr.x * 0.55;
      group.rotation.x = ptr.y * 0.18;
      uniforms.uActive.value += ((ptr.inside ? 1 : 0) - uniforms.uActive.value) * 0.1;
      uniforms.uMouse.value.set((ptr.px / stage.width()) * 2 - 1, 1 - (ptr.py / stage.height()) * 2);
      stage.renderer.render(scene, stage.camera);
    },
    () => {
      uniforms.uPixelRatio.value = stage.dpr();
      uniforms.uAspect.value = stage.width() / stage.height();
      // About 2 CSS px per point at the rabbit's depth, whatever its size.
      uniforms.uSize.value = 2.1 * stage.camera.position.z;
    },
  );

  return {
    count,
    dispose() {
      geo.dispose();
      mat.dispose();
      wire.geometry.dispose();
      stage.dispose();
    },
  };
}
