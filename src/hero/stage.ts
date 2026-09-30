// What both heroes share: a renderer on the hero canvas, a camera that puts
// the rabbit where the layout wants it, the pointer, and a render loop that
// runs only while the hero is on screen.

import { PerspectiveCamera, SRGBColorSpace, WebGLRenderer } from 'three';

export interface Placement {
  // Where the rabbit's centre goes and how tall it is, in CSS pixels of the
  // canvas.
  x: number;
  y: number;
  height: number;
}

export interface Pointer {
  // Smoothed, -1..1 across the canvas (y down); 0,0 when away.
  x: number;
  y: number;
  // Raw position in CSS pixels, and whether it is over the hero at all.
  px: number;
  py: number;
  inside: boolean;
}

export interface StageOptions {
  canvas: HTMLCanvasElement;
  reducedMotion: boolean;
  place: (w: number, h: number) => Placement;
  antialias?: boolean;
}

export interface Stage {
  renderer: WebGLRenderer;
  camera: PerspectiveCamera;
  pointer: Pointer;
  width: () => number;
  height: () => number;
  dpr: () => number;
  // Called every frame with seconds since start and the step.
  start(frame: (t: number, dt: number) => void, resized?: () => void): void;
  requestRender(): void;
  // Frames drawn in the last second; 0 while paused.
  fps(): number;
  dispose(): void;
}

const FOV = 30;

export function createStage(opts: StageOptions): Stage {
  const { canvas, reducedMotion } = opts;
  const small = window.matchMedia('(max-width: 700px)').matches;
  const renderer = new WebGLRenderer({ canvas, antialias: opts.antialias ?? true, alpha: false, powerPreference: 'high-performance' });
  renderer.outputColorSpace = SRGBColorSpace;
  renderer.setClearColor(0x07080a, 1);
  const maxDpr = small ? 1.5 : 2;
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, maxDpr));

  const camera = new PerspectiveCamera(FOV, 1, 0.1, 50);
  const pointer: Pointer = { x: 0, y: 0, px: -1e4, py: -1e4, inside: false };
  let tx = 0;
  let ty = 0;
  let w = 1;
  let h = 1;

  function place(): void {
    const p = opts.place(w, h);
    // Distance at which the 1-unit-tall rabbit is p.height pixels tall...
    const dist = h / (2 * p.height * Math.tan((FOV * Math.PI) / 360));
    camera.position.set(0, 0, dist);
    camera.lookAt(0, 0, 0);
    camera.aspect = w / h;
    // ...and a view offset that moves the centre of projection to (x, y).
    camera.setViewOffset(w, h, w / 2 - p.x, h / 2 - p.y, w, h);
    camera.updateProjectionMatrix();
  }

  const onMove = (e: PointerEvent) => {
    const r = canvas.getBoundingClientRect();
    pointer.px = e.clientX - r.left;
    pointer.py = e.clientY - r.top;
    pointer.inside = pointer.py >= 0 && pointer.py <= r.height;
    tx = (pointer.px / r.width) * 2 - 1;
    ty = (pointer.py / r.height) * 2 - 1;
  };
  const onLeave = () => {
    pointer.inside = false;
    pointer.px = pointer.py = -1e4;
    tx = ty = 0;
  };
  if (!reducedMotion) {
    window.addEventListener('pointermove', onMove, { passive: true });
    document.documentElement.addEventListener('pointerleave', onLeave);
  }

  let frameFn: (t: number, dt: number) => void = () => {};
  let resizedFn: () => void = () => {};
  let raf = 0;
  let running = false;
  let visible = true;
  const t0 = performance.now();
  let last = 0;
  let frames = 0;
  let fpsWindow = 0;
  let fpsValue = 0;

  function draw(): void {
    const t = (performance.now() - t0) / 1000;
    frames++;
    if (t - fpsWindow >= 1) {
      fpsValue = Math.round(frames / (t - fpsWindow));
      frames = 0;
      fpsWindow = t;
    }
    const dt = Math.min(0.1, t - last);
    last = t;
    const k = 1 - Math.exp(-dt * 4);
    pointer.x += (tx - pointer.x) * k;
    pointer.y += (ty - pointer.y) * k;
    frameFn(t, dt);
  }
  // Only the rAF callback clears `raf`: a direct draw() that did so would let
  // requestRender() queue a second callback beside the pending one, and two
  // chains would then draw every frame twice.
  function tick(): void {
    raf = 0;
    draw();
    if (running) raf = requestAnimationFrame(tick);
  }
  function requestRender(): void {
    if (!raf) raf = requestAnimationFrame(tick);
  }
  function sync(): void {
    const want = visible && !document.hidden && !reducedMotion;
    if (want === running) return;
    running = want;
    if (!running) fpsValue = 0;
    if (running) {
      last = fpsWindow = (performance.now() - t0) / 1000;
      frames = 0;
      requestRender();
    }
  }

  const io = new IntersectionObserver(([e]) => {
    visible = !!e?.isIntersecting;
    sync();
  });
  io.observe(canvas);
  document.addEventListener('visibilitychange', sync);

  function resize(): void {
    w = canvas.clientWidth;
    h = canvas.clientHeight;
    if (!w || !h) return;
    renderer.setSize(w, h, false);
    place();
    resizedFn();
    requestRender();
  }
  const ro = new ResizeObserver(resize);

  canvas.addEventListener('webglcontextlost', (e) => {
    e.preventDefault();
    running = false;
    canvas.classList.remove('is-ready');
  });

  return {
    renderer,
    camera,
    pointer,
    width: () => w,
    height: () => h,
    dpr: () => renderer.getPixelRatio(),
    start(fn, resized) {
      frameFn = fn;
      if (resized) resizedFn = resized;
      ro.observe(canvas);
      resize();
      // Draw now so the canvas has the rabbit on it before it fades in.
      draw();
      canvas.classList.add('is-ready');
      sync();
    },
    requestRender,
    fps: () => fpsValue,
    dispose() {
      running = false;
      if (raf) cancelAnimationFrame(raf);
      io.disconnect();
      ro.disconnect();
      document.removeEventListener('visibilitychange', sync);
      window.removeEventListener('pointermove', onMove);
      document.documentElement.removeEventListener('pointerleave', onLeave);
      renderer.dispose();
    },
  };
}
