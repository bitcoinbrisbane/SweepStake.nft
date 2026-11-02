import { useCallback, useEffect, useRef, useState } from "react";

/** Loads now and every `ms`, skipping ticks while the tab is hidden. Keeps the last good data if a load fails. */
export function usePoll<T>(load: () => Promise<T>, ms: number) {
  const [data, setData] = useState<T | null>(null);
  const [failed, setFailed] = useState(false);
  const latestRun = useRef(0);

  const refresh = useCallback(async () => {
    const run = ++latestRun.current;
    try {
      const value = await load();
      if (run === latestRun.current) {
        setData(value);
        setFailed(false);
      }
    } catch {
      if (run === latestRun.current) setFailed(true);
    }
  }, [load]);

  useEffect(() => {
    setData(null);
    void refresh();
    const timer = setInterval(() => {
      if (!document.hidden) void refresh();
    }, ms);
    return () => clearInterval(timer);
  }, [refresh, ms]);

  return { data, failed, refresh };
}

/** The current unix time in seconds, ticking once a second. */
export function useNow() {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const timer = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(timer);
  }, []);
  return now;
}
