<script lang="ts">
    import { fade } from "svelte/transition";
    import Toggle from "../Toggle.svelte";
    import Keybind from "../Keybind.svelte";
    import { settings, type Settings } from "$lib/settings";
    import { updateState, checkForUpdates, downloadAndInstall } from "$lib/stores/updater";

    interface Props {
        onChange: (key: keyof Settings, value: any) => void;
    };

    let {
        onChange
    }: Props = $props();
</script>

<div in:fade={{ duration: 150 }} class="space-y-4">
    <div class="space-y-3">
        <Toggle
            title="Auto Inject"
            description="Automatically inject when Roblox is detected"
            bind:checked={$settings.autoInject}
            onChange={(value) => onChange("autoInject", value)}
        />

        <Toggle
            title="Top Most"
            description="Toggle the top most functionality of the window."
            bind:checked={$settings.topMost}
            onChange={(value) => onChange("topMost", value)}
        />
        
        <Toggle
            title="Enable Minimap"
            description="Show code minimap in the editor"
            bind:checked={$settings.enableMinimap}
            onChange={(value) => onChange("enableMinimap", value)}
        />
        
        <Keybind
            title="Internal UI Hotkey"
            description="Set the hotkey for toggling the internal UI"
            keybind="HOME"
        />
        
        <Toggle
            title="Redirect Roblox Output"
            description="Show Roblox output in the console"
            bind:checked={$settings.redirectRobloxOutput}
            onChange={(value) => onChange("redirectRobloxOutput", value)}
        />

        <div class="rounded-xl border border-zinc-700/50 bg-zinc-900 p-3 flex flex-col gap-2">
            <span class="text-sm font-semibold text-zinc-200">App updates (v{$updateState.current})</span>
            {#if $updateState.available}
                <span class="text-xs text-zinc-400">v{$updateState.version} available{#if $updateState.notes} — {$updateState.notes}{/if}</span>
                <button
                    class="h-8 px-3 rounded-lg bg-[#FBC470] hover:bg-[#FBC470]/80 text-zinc-900 text-xs font-semibold cursor-pointer disabled:opacity-50"
                    disabled={$updateState.downloading}
                    on:click={downloadAndInstall}
                >{$updateState.downloading ? "Installing…" : "Download & restart"}</button>
            {:else}
                <span class="text-xs text-zinc-400">You're up to date.</span>
                <button
                    class="h-8 px-3 rounded-lg bg-zinc-800 hover:bg-zinc-700 text-zinc-200 text-xs cursor-pointer disabled:opacity-50 w-fit"
                    disabled={$updateState.checking}
                    on:click={() => checkForUpdates(false)}
                >{$updateState.checking ? "Checking…" : "Check for updates"}</button>
            {/if}
        </div>
    </div>
</div>