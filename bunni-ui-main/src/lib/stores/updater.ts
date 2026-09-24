import { writable, get } from "svelte/store";
import { check } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";
import { VConsole } from "$lib/console";
import { notifs } from "$lib/stores/notification";

export interface UpdateState {
    checking: boolean;
    available: boolean;
    version: string;
    notes: string;
    downloading: boolean;
    progress: number;
    current: string;
}

const initial: UpdateState = {
    checking: false,
    available: false,
    version: "",
    notes: "",
    downloading: false,
    progress: 0,
    current: "0.2.0",
};

export const updateState = writable<UpdateState>({ ...initial });

// Holds the pending Update object between check and install (not in store:
// not serializable, lives only for this session).
let pending: Awaited<ReturnType<typeof check>> | null = null;

export async function checkForUpdates(silent: boolean): Promise<void> {
    if (get(updateState).checking || get(updateState).downloading) return;
    updateState.update((s) => ({ ...s, checking: true }));
    try {
        const update = await check();
        if (!update) {
            pending = null;
            updateState.update((s) => ({ ...s, available: false }));
            if (!silent) VConsole.success("App is up to date");
            return;
        }
        pending = update;
        updateState.update((s) => ({
            ...s,
            available: true,
            version: update.version,
            notes: update.body ?? "",
        }));
        VConsole.info(`Update available: v${update.version}`);
        notifs.success(`Update v${update.version} available`, { title: "Updater" });
    } catch (e) {
        if (!silent) VConsole.error(`Update check failed: ${e}`);
    } finally {
        updateState.update((s) => ({ ...s, checking: false }));
    }
}

export async function downloadAndInstall(): Promise<void> {
    const update = pending;
    if (!update) {
        VConsole.error("No update pending - check first");
        return;
    }
    updateState.update((s) => ({ ...s, downloading: true, progress: 0 }));
    try {
        await update.downloadAndInstall((event) => {
            if (event.event === "Started") {
                updateState.update((s) => ({ ...s, progress: 0 }));
            } else if (event.event === "Progress") {
                const done = event.data.chunkLength;
                updateState.update((s) => ({ ...s, progress: s.progress + done }));
            } else if (event.event === "Finished") {
                updateState.update((s) => ({ ...s, progress: 0 }));
            }
        });
        VConsole.success("Update installed - restarting...");
        await relaunch();
    } catch (e) {
        VConsole.error(`Update install failed: ${e}`);
        updateState.update((s) => ({ ...s, downloading: false }));
    }
}
