import { get } from "svelte/store"
import { editorStr, type File } from "./stores/editor"
import { appConfigDir, join } from "@tauri-apps/api/path";
import { exists, mkdir, readTextFile, writeTextFile } from "@tauri-apps/plugin-fs";
import { VConsole } from "./console";
import { notifs } from "./stores/notification";

// for tab saving
interface SFile extends Omit<File, "state"> {
    filepath?: string,
    state: {
        cursorPos?: { lineNumber: number, column: number },
        scrollPos?: { scrollTop: number, scrollLeft: number },
    },
};

interface RestoredOrSavedTabs {
    files: SFile[],
    active: string
};

export async function saveTabs(): Promise<boolean> {
    try {
        const editor = get(editorStr);
        const base = await appConfigDir();
        const bin = await join(base, "bin");
        if (!await exists(bin)) await mkdir(bin, { recursive: true });

        const temp = await join(bin, "temp");
        if (!await exists(temp)) await mkdir(temp, { recursive: true });

        const fss = await Promise.all(editor.files.map(async (f) => {
            let path = undefined;
            if (f.name.startsWith("untitled") || f.id.startsWith("file-")) {
                path = await join(temp, f.name);
                await writeTextFile(path, f.content);
            }

            return {
                id: f.id,
                name: f.name,
                content: f.content,
                state: {
                    cursorPos: f.state.cursorPos,
                    scrollPos: f.state.scrollPos,
                },
                filepath: path
            };
        }));

        const saved: RestoredOrSavedTabs = {
            files: fss,
            active: editor.active
        };

        const final = await join(bin, "tabs.json");
        await writeTextFile(final, JSON.stringify(saved, null, 4));

        VConsole.success("editor tabs saved successfully");
        return true;
    } catch (err) {
        console.error("Failed to save tabs:", err);
        notifs.error("Failed to save editor tabs", { title: "Editor" });
        return false;
    }
}

export async function loadTabs(): Promise<void> {
    try {
        const base = await appConfigDir();
        const tabs = await join(base, "bin", "tabs.json");

        if (!await exists(tabs)) return;

        const data = await readTextFile(tabs);
        const restored = JSON.parse(data) as RestoredOrSavedTabs;

        const fss: SFile[] = await Promise.all(restored.files.map(async (f) => {
            let content = f.content;

            if (f.filepath && await exists(f.filepath)) {
                try {
                    content = await readTextFile(f.filepath);
                } catch (e) {
                    VConsole.warn(`Failed to read file ${f.filepath}`);
                }
            }

            return {
                id: f.id,
                name: f.name,
                content: content,
                state: {
                    cursorPos: f.state.cursorPos,
                    scrollPos: f.state.scrollPos,
                    vstate: null
                }
            }
        }));

        if (fss.length > 0) editorStr.set({ files: fss, active: restored.active });
    } catch (err) {
        console.error("Failed to load tabs:", err);
        notifs.error("Failed to load editor tabs", { title: "Editor" });
    }
}

