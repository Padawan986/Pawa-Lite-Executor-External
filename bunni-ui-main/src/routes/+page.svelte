<script lang="ts">
    import { onMount } from "svelte";
    import { registerTabs } from "$lib/stores/register";
    import TabContent from "../components/TabContent.svelte";
    import { setActive } from "$lib/stores/tabs";
    import { VConsole } from "$lib/console";
    import { listen } from '@tauri-apps/api/event'
    import { invoke } from '@tauri-apps/api/core'


    onMount(() => {
        listen('ws_message', (event) => {
           const [logType, ...msgParts] = (event.payload as string).split('_');
           const message = msgParts.join('_');
            console.log(logType),
            console.log(message);
           if (logType == "INFO") {
            VConsole.info(message);
           } else if (logType == "WARNING") {
            VConsole.warn(message);
           } else if (logType == "ERROR") {
            VConsole.error(message);
           }
        });

        registerTabs();
        setActive("editor");

        // First-run bootstrap: Python, pip deps, Defender exclusion.
        // Idempotent - passes through in seconds when everything is ready.
        invoke<string>("setup_runtime")
            .then((msg) => {
                VConsole.success(msg);
                invoke<string>("check_updates")
                    .then((u) => VConsole.info(`Update: ${u}`))
                    .catch((e) => VConsole.error(`Update: ${e}`));
            })
            .catch((e) => VConsole.error(`Setup: ${e}`));
        // Silent app-update check (only speaks up when an update exists).
        import("$lib/stores/updater").then((m) => m.checkForUpdates(true));
    
        VConsole.clear();
        VConsole.warn("Pawa-Lite(Beta)V2, expect bugs.");
    });
</script>

<div class="px-4 py-2 h-full w-full flex flex-col overflow-hidden">
    <TabContent />
</div>