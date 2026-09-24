<script lang="ts">
    import { notifs } from "$lib/stores/notification";
    import { invoke } from "@tauri-apps/api/core";

    interface Props {
        title: string,
        description: string,
        keybind: string,
    }

    let { 
        title,
        description,
        keybind = "HOME"
    }: Props = $props();

    let listening = $state(false);
    let label = $state(keybind);

    function start() {
        listening = true;
        label = "...";
    }

    function handle(event: KeyboardEvent) {
        if (!listening) return;

        event.preventDefault();

        let key = event.key.toUpperCase();
        if (event.key === " ") key = "SPACE";
        else if (event.key === "Escape") {
            listening = false;
            label = keybind;
        } 
        else if (key.length === 1) key = key;
        else key = event.key.toUpperCase();
        
        keybind = key;
        label = key;
        listening = false;

        try {
            invoke("on_keybind_set", { keybind: key });
        } catch (err) {
            console.error(`failed to set keybind: ${err}`);
            notifs.error("Failed to set keybind.", { title: "Settings" });
        }
    }

    $effect(() => {
        if (listening) window.addEventListener("keydown", handle);
        else window.removeEventListener("keydown", handle);

        return () => { window.removeEventListener("keydown", handle); };
    })
</script>

<div class="flex items-center justify-between">
    <div>
        <h3 class="text-zinc-200 font-medium">{title}</h3>
        <p class="text-xs text-zinc-400">{description}</p>
    </div>
    <!-- svelte-ignore a11y_label_has_associated_control -->
    <label class="relative inline-flex items-center cursor-pointer">
        <div 
            class="min-w-11 h-6 bg-zinc-800 hover:bg-zinc-700 rounded-md text-zinc-500 flex px-1.5 items-center justify-center cursor-pointer transition-colors"
            onclick={start}
            class:bg-zinc-700={listening}
            class:text-zinc-300={listening}
        >
            <span class="text-xs font-semibold">{label}</span>
        </div>
    </label>
</div>