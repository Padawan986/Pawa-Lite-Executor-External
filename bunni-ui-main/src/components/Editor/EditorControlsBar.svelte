<script lang="ts">
    import { type IconSource, Document, FolderOpen, Icon, Link, PaperClip, Play, Trash } from "svelte-hero-icons";
    import ControlButton from "./ControlButton.svelte";
    import Console from "./Console.svelte";
    import { VConsole } from "$lib/console";
    import { api } from "$lib/editorapi";
    import { invoke } from "@tauri-apps/api/core";
    import { openFile, saveFile } from "$lib/controls";
    import { attaching } from "$lib/stores/global";
    import { bumpAttaches } from "$lib/stores/stats";
    import { get } from "svelte/store";
    import { notifs } from "$lib/stores/notification";

    interface Control {
        icon: IconSource,
        label: string,
        action: () => void,
    }

    const controls: Control[] = [
        {
            icon: Play,
            label: "Execute",
            action: () => {
                api.executeFile();
            }
        },

        {
            icon: Trash,
            label: "Clear",
            action: () => {
                const editor = api.getInstance();
                if (editor) {
                    editor.getModel()?.setValue("");
                }
            }
        },

        {
            icon: FolderOpen,
            label: "Open",
            action: async () => {
                try {
                    await openFile();
                } catch (e) {
                    VConsole.error(`An error occured while opening file: ${e}`);
                }
            }
        },

        {
            icon: Document,
            label: "Save",
            action: async () => {
                try {
                    await saveFile();
                } catch (e) {
                    VConsole.error(`An error occured while saving file: ${e}`);
                }
            }
        },

        {
            icon: PaperClip,
            label: "Attach",
            action: async () => {
                VConsole.info("Attaching...");
                notifs.warning("Attaching...", { title: "Injector" });
                attaching.set(true);

                try {
                    const result = await invoke<boolean>("attach");
                    if (result) {
                        bumpAttaches();
                        VConsole.success("Attached");
                        notifs.success("Attached", { title: "Injector" });
                    } else {
                        VConsole.error("Attach returned false");
                        notifs.warning("Attach failed", { title: "Injector" });
                    }
                } catch (error) {
                    VConsole.error(`An error occured while attaching: ${error}`);
                    notifs.warning("Attach failed", { title: "Injector" });
                } finally {
                    attaching.set(false);
                }
            }
        },
    ]
</script>

<div class="flex border rounded-bl-xl rounded-tr-md rounded-tl-md rounded-br-xl border-zinc-700/50 bg-zinc-900 overflow-x-auto gap-4 items-center h-10 px-3">
    {#each controls as control}
        {#if control.label === "Attach"}
            <!-- shitty method to put it to end but it doesnt matter :p -->
            <div class="w-full"></div>
        {/if}

        <ControlButton icon={control.icon} action={control.action} label={control.label} />
    {/each}    
</div>