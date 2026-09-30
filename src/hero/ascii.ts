// The rabbit as live ASCII. The lit, textured model is rendered into a
// target with one pixel per character cell; a full-screen shader then draws,
// in every cell, the glyph whose ink matches that pixel's brightness. Near
// the cursor the rabbit's cells turn lime and cycle through code glyphs,
// and the empty grid around it shows faintly, like a terminal under a lens.

import {
  CanvasTexture,
  Color,
  DirectionalLight,
  Group,
  HemisphereLight,
  LinearFilter,
  Mesh,
  MeshStandardMaterial,
  NearestFilter,
  OrthographicCamera,
  PlaneGeometry,
  Scene,
  ShaderMaterial,
  Vector2,
  WebGLRenderTarget,
} from 'three';

import type { Rabbit } from './model';
import type { Stage } from './stage';

// Darkest to brightest. No "$": at this size the rabbit's S already
// flirts with one.
const RAMP = ' .,:;-=+*xo#%@';
// What the cursor turns the rabbit into.
const CODE = '{}()<>[];:=+-*/&|!?01fnletspawnchan';

const VERT = /* glsl */ `
void main() { gl_Position = vec4(position.xy, 0.0, 1.0); }
`;

const FRAG = /* glsl */ `
uniform sampler2D uScene;
uniform sampler2D uGlyphs;
uniform vec2 uCells;
uniform vec2 uCell;
uniform float uRamp;
uniform float uCode;
uniform float uCols;
uniform vec2 uMouse;
uniform float uRadius;
uniform float uActive;
uniform float uTime;
uniform vec3 uCream;
uniform vec3 uLime;
uniform vec3 uDim;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void main() {
  vec2 cell = floor(gl_FragCoord.xy / uCell);
  if (cell.x >= uCells.x || cell.y >= uCells.y) discard;
  vec3 s = texture2D(uScene, (cell + 0.5) / uCells).rgb;
  // The target is linear; perceptual brightness picks the glyph.
  float lum = pow(clamp(dot(s, vec3(0.299, 0.587, 0.114)), 0.0, 1.0), 0.4545);
  // Stretch what the lit rabbit actually spans to the whole ramp.
  lum = clamp((lum - 0.12) / 0.62, 0.0, 1.0);
  float on = step(0.02, lum);

  float d = distance((cell + 0.5) * uCell, uMouse);
  float hot = uActive * smoothstep(uRadius, 0.0, d);

  float row;
  float idx;
  vec3 col;
  if (on > 0.5 && hot > 0.35) {
    // Under the cursor the rabbit becomes code, re-rolled a dozen times a second.
    row = 1.0;
    idx = floor(hash(cell + floor(uTime * 12.0)) * uCode);
    col = mix(uCream, uLime, hot);
  } else if (on > 0.5) {
    row = 0.0;
    idx = clamp(floor(lum * (uRamp - 1.0) + 0.5), 1.0, uRamp - 1.0);
    col = mix(uDim, uCream, smoothstep(0.1, 0.9, lum));
  } else {
    // Empty grid: a faint dot field, lit up near the cursor.
    row = 1.0;
    float h = hash(cell);
    idx = floor(hash(cell + floor(uTime * 4.0 + h * 8.0)) * uCode);
    float show = step(0.55, h) * hot * 0.5;
    if (show < 0.01) discard;
    col = uLime * show;
  }

  vec2 inCell = fract(gl_FragCoord.xy / uCell);
  vec2 uv = vec2((idx + inCell.x) / uCols, (1.0 - row) * 0.5 + inCell.y * 0.5);
  float ink = texture2D(uGlyphs, uv).r;
  if (ink < 0.02) discard;
  gl_FragColor = vec4(col * ink, 1.0);
}
`;

function glyphAtlas(cellW: number, cellH: number, font: string): { texture: CanvasTexture; cols: number } {
  const cols = Math.max(RAMP.length, CODE.length);
  const c = document.createElement('canvas');
  c.width = cols * cellW;
  c.height = cellH * 2;
  const g = c.getContext('2d');
  if (!g) throw new Error('2d canvas unavailable');
  g.fillStyle = '#000';
  g.fillRect(0, 0, c.width, c.height);
  g.fillStyle = '#fff';
  g.font = font;
  g.textAlign = 'center';
  g.textBaseline = 'middle';
  [RAMP, CODE].forEach((set, row) => {
    for (let i = 0; i < set.length; i++) {
      g.fillText(set.charAt(i), i * cellW + cellW / 2, row * cellH + cellH / 2);
    }
  });
  const texture = new CanvasTexture(c);
  texture.minFilter = LinearFilter;
  texture.magFilter = LinearFilter;
  texture.generateMipmaps = false;
  return { texture, cols };
}

export interface AsciiHero {
  cells: () => number;
  dispose(): void;
}

export async function createAsciiHero(stage: Stage, rabbit: Rabbit, reducedMotion: boolean): Promise<AsciiHero> {
  const small = window.matchMedia('(max-width: 700px)').matches;
  // CSS pixels per character cell.
  const cellW = small ? 7 : 8;
  const cellH = small ? 14 : 16;
  const family = "'Geist Mono Variable', ui-monospace, Menlo, monospace";
  // Draw the atlas only once the page's mono face is ready, or the glyphs
  // come out in a fallback font.
  try {
    await document.fonts.load(`${cellH}px 'Geist Mono Variable'`);
  } catch (err) {
    console.warn('mono font not ready; drawing glyphs in the fallback', err);
  }

  // The rabbit, lit so its shading spans the whole ramp.
  const scene = new Scene();
  const group = new Group();
  scene.add(group);
  const mat = new MeshStandardMaterial({ map: rabbit.map, color: 0xffffff, roughness: 0.7, metalness: 0 });
  group.add(new Mesh(rabbit.hi, mat));
  // Lit from the front, where the rabbit faces the viewer, with a rim from
  // behind: the head and ears need light to show their shape as glyphs.
  scene.add(new HemisphereLight(0xffffff, 0x202020, 0.7));
  const key = new DirectionalLight(0xffffff, 2.4);
  key.position.set(1, 2, 5);
  scene.add(key);
  const rim = new DirectionalLight(0xffffff, 1.4);
  rim.position.set(2, 2, -4);
  scene.add(rim);

  let target = new WebGLRenderTarget(1, 1, { minFilter: NearestFilter, magFilter: NearestFilter });
  let atlas = glyphAtlas(cellW * stage.dpr(), cellH * stage.dpr(), `${Math.round(cellH * stage.dpr() * 0.82)}px ${family}`);

  const uniforms = {
    uScene: { value: target.texture },
    uGlyphs: { value: atlas.texture },
    uCells: { value: new Vector2(1, 1) },
    uCell: { value: new Vector2(cellW, cellH) },
    uRamp: { value: RAMP.length },
    uCode: { value: CODE.length },
    uCols: { value: atlas.cols },
    uMouse: { value: new Vector2(-1e4, -1e4) },
    uRadius: { value: 150 },
    uActive: { value: 0 },
    uTime: { value: 0 },
    uCream: { value: new Color('#f4f1ea') },
    uLime: { value: new Color('#d6f531') },
    uDim: { value: new Color('#3a4048') },
  };
  const quad = new Mesh(
    new PlaneGeometry(2, 2),
    new ShaderMaterial({ vertexShader: VERT, fragmentShader: FRAG, uniforms, depthTest: false, depthWrite: false }),
  );
  const screen = new Scene();
  screen.add(quad);
  const flat = new OrthographicCamera(-1, 1, 1, -1, 0, 1);
  let cols = 1;
  let rows = 1;

  stage.start(
    (t) => {
      const ptr = stage.pointer;
      const dpr = stage.dpr();
      uniforms.uTime.value = t;
      const sway = reducedMotion ? 0 : Math.sin(t * 0.35) * 0.3;
      group.rotation.y = sway + ptr.x * 0.6;
      group.rotation.x = ptr.y * 0.2;
      uniforms.uActive.value += ((ptr.inside ? 1 : 0) - uniforms.uActive.value) * 0.1;
      uniforms.uMouse.value.set(ptr.px * dpr, (stage.height() - ptr.py) * dpr);

      const r = stage.renderer;
      r.setRenderTarget(target);
      r.setClearColor(0x000000, 1);
      r.render(scene, stage.camera);
      r.setRenderTarget(null);
      r.setClearColor(0x07080a, 1);
      r.render(screen, flat);
    },
    () => {
      const dpr = stage.dpr();
      cols = Math.max(1, Math.floor(stage.width() / cellW));
      rows = Math.max(1, Math.floor(stage.height() / cellH));
      target.dispose();
      target = new WebGLRenderTarget(cols, rows, { minFilter: NearestFilter, magFilter: NearestFilter });
      uniforms.uScene.value = target.texture;
      uniforms.uCells.value.set(cols, rows);
      uniforms.uCell.value.set(cellW * dpr, cellH * dpr);
      uniforms.uRadius.value = 150 * dpr;
      atlas.texture.dispose();
      atlas = glyphAtlas(cellW * dpr, cellH * dpr, `${Math.round(cellH * dpr * 0.82)}px ${family}`);
      uniforms.uGlyphs.value = atlas.texture;
    },
  );

  return {
    cells: () => cols * rows,
    dispose() {
      target.dispose();
      atlas.texture.dispose();
      mat.dispose();
      stage.dispose();
    },
  };
}
