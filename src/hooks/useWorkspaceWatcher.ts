import { watch } from "@tauri-apps/plugin-fs";
import { useEffect, useRef } from "react";

type Callbacks = {
  onCorklyConfigChange: () => void;
  onMdChange: () => void;
};

export function useWorkspaceWatcher(dir: string | null, callbacks: Callbacks) {
  const callbacksRef = useRef(callbacks);
  callbacksRef.current = callbacks;

  useEffect(() => {
    if (!dir) return;
    const watchPromise = watch(
      dir,
      (event) => {
        const hasCorklyConfig = event.paths.some(
          (p: string) => p.split(/[\\/]/).pop() === ".cork.json",
        );
        const hasMdFile = event.paths.some((p: string) => p.endsWith(".md"));
        if (hasCorklyConfig) {
          callbacksRef.current.onCorklyConfigChange();
        } else if (hasMdFile) {
          callbacksRef.current.onMdChange();
        }
      },
      { recursive: false, delayMs: 300 },
    );
    return () => {
      watchPromise.then((unwatch) => unwatch());
    };
  }, [dir]);
}
