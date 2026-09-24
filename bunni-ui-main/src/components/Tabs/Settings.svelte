<script lang="ts">
    import { onMount } from "svelte";
    import { AdjustmentsHorizontal, Icon } from "svelte-hero-icons";
    import { fade } from "svelte/transition";
    import { notifs } from "$lib/stores/notification";
    import { invoke } from "@tauri-apps/api/core";

    import CategoryTabButtons from "../Settings/CategoryTabButtons.svelte";
    import General from "../Settings/Categories/General.svelte";
    import { changes, loadSettings, revert, saveSettings, settings, updateSetting, type Settings } from "$lib/settings";
    import { setActive } from "$lib/stores/tabs";

    let category = "General";
    interface Category {
        label: string,
        icon: any,
    }

    const categories: Category[] = [
        { label: "General", icon: AdjustmentsHorizontal }
    ];

    function setCategory(label: string) {
        category = label;
    }

    function handle(key: keyof Settings, value: any) {
        updateSetting(key, value);
    }

    onMount(async () => {
        await loadSettings();
    })
</script>

<main in:fade={{ duration: 250 }} class="flex flex-col p-2 gap-2.5 h-full w-full overflow-hidden">
    <h1 class="text-xl text-zinc-200 font-semibold">Settings</h1>

    <CategoryTabButtons 
        {categories}
        active={category}
        onSelect={setActive}
    />

    <div class="border border-zinc-800 rounded-lg p-4 flex-1 min-h-0 overflow-y-auto scrollbar">
        {#if category === "General"}
            <General
                onChange={handle}
            />
        {/if}
    </div>
    
    <div class="flex flex-row justify-end gap-3 mt-2 mb-2">
        {#if $changes}
            <button
                in:fade={{duration:200}}
                out:fade={{duration:200}}
                onclick={revert}
                class="px-3 py-1.5 bg-zinc-800 hover:bg-zinc-700 text-zinc-300 font-medium text-sm rounded-md transition-colors"
            >
                Cancel
            </button>
        {/if}
        <button 
            onclick={saveSettings}
            class="px-3 py-1.5 bg-[#FBC470]/30 hover:bg-[#FBC470]/37 text-[#FBC470] font-medium text-sm rounded-md transition-colors"
            disabled={!$changes}
        >
            Save Changes
        </button>
    </div>
</main>