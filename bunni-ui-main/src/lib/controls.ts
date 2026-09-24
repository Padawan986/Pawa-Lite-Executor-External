import { invoke } from "@tauri-apps/api/core";
import { open, save } from "@tauri-apps/plugin-dialog";
import { readTextFile, writeTextFile, create, exists } from "@tauri-apps/plugin-fs";
import { appDataDir, BaseDirectory } from "@tauri-apps/api/path";
import { join } from "@tauri-apps/api/path";
import { VConsole } from "./console";
import { api } from "./editorapi";
import { notifs } from "./stores/notification";

async function verifyDirectories(): Promise<string> {
    try {
        const adata = await appDataDir();
        const scriptsDir = await join(adata, "scripts");

        const real = await exists(scriptsDir);
        if (!real) { await create(scriptsDir, { baseDir: BaseDirectory.AppData }); VConsole.info(`Created scripts dir @ ${scriptsDir}`); }

        return scriptsDir;
    } catch (err) {
        VConsole.error(`An error occured while verifying directories: ${err}`);
        throw err;
    }
}

export async function openFile() {
    try {
        const file = await open({
            multiple: false,
            filters: [{ name: "Lua Scripts", extensions: ["lua", "luau"] }]
        });

        if (!file || Array.isArray(file)) return; // no multiple files or null

        const path = file as string;
        const name = path.split(/[/\\]/).pop() || "undefined.lua";
        const content = await readTextFile(path);
        const id = api.createFile(name, content);
        
        api.setActive(id);
        return id;
    } catch (err) {
        VConsole.error(`An error occured while opening file: ${err}`);
    }
}

export async function saveFile() {
    try {
        const content = api.getContent();
        if (!content) return; // no content so save nothing

        const fname: string = api.getFiles().find(f => f.id === api.getActiveID())?.name || "untitled.lua";
        const path = await save({
            filters: [{ name: "Lua Scripts", extensions: ["lua", "luau"] }],
            defaultPath: fname,
        });

        if (!path) return; // cancelled?

        await writeTextFile(path, content);
        return path;
    } catch (err) {
        VConsole.error(`An error occured while saving a file: ${err}`);
    }
}