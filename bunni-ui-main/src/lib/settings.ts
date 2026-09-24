import { writable, derived, get } from "svelte/store";
import { invoke } from "@tauri-apps/api/core";
import { notifs } from "./stores/notification";
import { appConfigDir, join } from "@tauri-apps/api/path";
import { exists, mkdir, readTextFile, writeTextFile } from "@tauri-apps/plugin-fs";

export interface OutputTypes {
    warn: boolean,
    info: boolean,
    error: boolean,
    output: boolean,
};

export interface Settings {
    autoInject: boolean,
    topMost: boolean,
    enableMinimap: boolean,
    internalUIHotkey: string,
    redirectRobloxOutput: boolean,
    outputTypes: OutputTypes
};

const INITIAL_SETTINGS: Settings = {
    autoInject: true,
    topMost: false,
    enableMinimap: false,
    internalUIHotkey: "HOME",
    redirectRobloxOutput: false,
    outputTypes: {
        warn: true,
        info: true,
        error: true,
        output: true
    }
};

export const settings = writable<Settings>({ ...INITIAL_SETTINGS });
export const osettings = writable<Settings>({ ...INITIAL_SETTINGS });
export const changes = derived([settings, osettings], ([$settings, $osettings]) => { return JSON.stringify($settings) !== JSON.stringify($osettings) });

export async function loadSettings(): Promise<void> {
    try {
        const base = await appConfigDir();
        const bin = await join(base, "bin");
        const bExists = await exists(bin);
        if (!bExists) await mkdir(bin, { recursive: true });

        const settingsp = await join(bin, "settings.json");
        const sExists = await exists(settingsp);
        
        if (sExists) {
            const data = await readTextFile(settingsp);
            const loaded = JSON.parse(data) as Partial<Settings>;

            const final = { ...INITIAL_SETTINGS, ...loaded, outputTypes: {
                ...INITIAL_SETTINGS.outputTypes,
                ...(loaded.outputTypes || {})
            }};

            settings.set(final);
            osettings.set({ ...final });

            await invoke("set_autoinject", { value: final.autoInject });
            await invoke("set_topmost", { value: final.topMost });
            await invoke("set_hotkey", { value: final.internalUIHotkey });
            await invoke("set_redirect", { value: final.redirectRobloxOutput });
            await invoke("set_outputtypes", { value: final.outputTypes });
        } else {
            settings.set({ ...INITIAL_SETTINGS });
            osettings.set({ ...INITIAL_SETTINGS });

            await writeTextFile(settingsp, JSON.stringify(INITIAL_SETTINGS, null, 4));

            await invoke("set_autoinject", { value: INITIAL_SETTINGS.autoInject });
            await invoke("set_topmost", { value: INITIAL_SETTINGS.autoInject });
            await invoke("set_hotkey", { value: INITIAL_SETTINGS.internalUIHotkey });
            await invoke("set_redirect", { value: INITIAL_SETTINGS.redirectRobloxOutput });
            await invoke("set_outputtypes", { value: INITIAL_SETTINGS.outputTypes });
        }

    } catch (err) {
        console.error("failerd to load settings: ", err);
        notifs.error("Failed to load settings.", { title: "Settings" });
    
        settings.set({ ...INITIAL_SETTINGS  });
        osettings.set({ ...INITIAL_SETTINGS });
    }
}


export async function saveSettings(): Promise<boolean> {
    try {
        const cur = get(settings);
    
        await invoke("set_autoinject", { value: cur.autoInject });
        await invoke("set_topmost", { value: cur.topMost });
        await invoke("set_hotkey", { value: cur.internalUIHotkey });
        await invoke("set_redirect", { value: cur.redirectRobloxOutput });
        await invoke("set_outputtypes", { value: cur.outputTypes  });

        const base = await appConfigDir();
        const bin = await join(base, "bin");
        const bExists = await exists(bin);
        if (!bExists) await mkdir(bin, { recursive: true });

        const settingsp = await join(bin, "settings.json");
        await writeTextFile(settingsp, JSON.stringify(cur, null, 4));

        osettings.set({ ...cur });
        notifs.success("Saved settings.", { title: "Settings" });
        return true;
    } catch (err) {
        console.error("failerd to save settings: ", err);
        notifs.error("Failed to save settings.", { title: "Settings" });
        return false;
    }
}

export function revert(): void {
    const orig = get(osettings);
    settings.set({ ...orig });
}

export function reset(): void {
    settings.set({ ...INITIAL_SETTINGS });
}

export function updateSetting<K extends keyof Settings>(key: K, value: Settings[K]) {
    settings.update(s => ({ ...s, [key]: value }));
}

// this is because the output types is a seperate obj
export function updateOutputType(type: keyof OutputTypes, vlaue: boolean): void {
    settings.update(s => ({ ...s, outputTypes: { ...s.outputTypes, [type]: vlaue }}));
}
