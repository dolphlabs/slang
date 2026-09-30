// The hero's one entry point: loads the rabbit and starts the chosen style.

import { createAsciiHero } from './ascii';
import { loadRabbit } from './model';
import { createPointsHero } from './points';
import { createStage, type Placement } from './stage';

export type HeroMode = 'points' | 'ascii';

export interface HeroOptions {
  canvas: HTMLCanvasElement;
  reducedMotion: boolean;
  mode: HeroMode;
  place: (w: number, h: number) => Placement;
}

export interface Hero {
  // What the corner readout shows, e.g. "64,000 points".
  label(): string;
  fps(): number;
}

export async function createHero(opts: HeroOptions): Promise<Hero> {
  const rabbit = await loadRabbit();
  const stage = createStage({ canvas: opts.canvas, reducedMotion: opts.reducedMotion, place: opts.place });
  if (opts.mode === 'ascii') {
    const hero = await createAsciiHero(stage, rabbit, opts.reducedMotion);
    return { label: () => `${hero.cells().toLocaleString('en')} cells`, fps: stage.fps };
  }
  const hero = createPointsHero(stage, rabbit, opts.reducedMotion);
  return { label: () => `${hero.count.toLocaleString('en')} points`, fps: stage.fps };
}
