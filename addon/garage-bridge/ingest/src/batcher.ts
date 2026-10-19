export interface BatcherOptions<T> {
  maxRows?: number;
  maxAgeMs?: number;
  maxBufferMs?: number;
  onFlush: (items: T[]) => Promise<void>;
}

export interface BatcherStats {
  pending: number;
  dropped: number;
  flushed: number;
}

interface Entry<T> {
  item: T;
  ts: number;
}

/**
 * Accumulates items with a push timestamp and flushes them in batches.
 * Pure/in-memory: no timers, no I/O — the caller decides when to call
 * `flushIfDue` (e.g. on every MQTT message and on a periodic tick) and
 * supplies `onFlush` to actually persist the batch. `flush()` is the
 * shutdown-time escape hatch: it waits for any flush already in flight and
 * then flushes everything pending, ignoring the maxRows/maxAgeMs due-checks.
 */
export class Batcher<T> {
  private buffer: Entry<T>[] = [];
  private readonly maxRows: number;
  private readonly maxAgeMs: number;
  private readonly maxBufferMs: number;
  private readonly onFlush: (items: T[]) => Promise<void>;

  private flushedCount = 0;
  private droppedCount = 0;
  private flushingPromise: Promise<void> | null = null;

  constructor(opts: BatcherOptions<T>) {
    this.maxRows = opts.maxRows ?? 200;
    this.maxAgeMs = opts.maxAgeMs ?? 2000;
    this.maxBufferMs = opts.maxBufferMs ?? 300_000;
    this.onFlush = opts.onFlush;
  }

  /** Adds an item to the pending buffer, stamped with `now` (defaults to Date.now()). */
  push(item: T, now: number = Date.now()): void {
    this.buffer.push({ item, ts: now });
  }

  /**
   * Drops stale entries, then flushes the whole pending buffer via `onFlush`
   * when due (buffer at/over `maxRows`, or the oldest pending item has aged
   * past `maxAgeMs`). On rejection, the attempted batch is put back ahead of
   * anything pushed meanwhile, to be retried on a later call.
   */
  async flushIfDue(now: number = Date.now()): Promise<void> {
    this.dropStale(now);

    if (this.flushingPromise) return;
    if (this.buffer.length === 0) return;
    if (!this.isDue(now)) return;

    await this.runFlush(now);
  }

  /**
   * Forces a flush of everything currently pending, regardless of
   * maxRows/maxAgeMs. Waits for a flush already in flight (from a concurrent
   * `flushIfDue` tick) to finish first, so a shutdown-time flush never races
   * a periodic one — it simply runs right after. Never throws: reports
   * `{ ok: false, error }` instead, so a shutdown sequence can log the
   * failure and still go on to flush other state (e.g. a pending patch)
   * rather than being aborted by an unhandled rejection.
   */
  async flush(): Promise<{ ok: boolean; error?: unknown }> {
    if (this.flushingPromise) {
      await this.flushingPromise.catch(() => {});
    }
    if (this.buffer.length === 0) return { ok: true };
    return await this.runFlush();
  }

  stats(): BatcherStats {
    return { pending: this.buffer.length, dropped: this.droppedCount, flushed: this.flushedCount };
  }

  private async runFlush(dropStaleAt?: number): Promise<{ ok: boolean; error?: unknown }> {
    const batch = this.buffer;
    this.buffer = [];
    let outcome: { ok: boolean; error?: unknown } = { ok: true };

    const task = (async () => {
      try {
        await this.onFlush(batch.map((e) => e.item));
        this.flushedCount += batch.length;
      } catch (err) {
        this.buffer = batch.concat(this.buffer);
        if (dropStaleAt !== undefined) this.dropStale(dropStaleAt);
        outcome = { ok: false, error: err };
      }
    })();

    this.flushingPromise = task;
    try {
      await task;
    } finally {
      // Only clear the pointer if it's still ours: a flush this call didn't
      // start (shouldn't happen given the single-flight design, but this
      // guards against ever clobbering a newer flush's in-flight marker).
      if (this.flushingPromise === task) this.flushingPromise = null;
    }
    return outcome;
  }

  private isDue(now: number): boolean {
    if (this.buffer.length >= this.maxRows) return true;
    const oldest = this.buffer[0];
    return oldest != null && now - oldest.ts >= this.maxAgeMs;
  }

  private dropStale(now: number): void {
    while (this.buffer.length > 0) {
      const oldest = this.buffer[0]!;
      if (now - oldest.ts > this.maxBufferMs) {
        this.buffer.shift();
        this.droppedCount++;
      } else {
        break;
      }
    }
  }
}
