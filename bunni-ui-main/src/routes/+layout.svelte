<script>
    import TitleBar from "../components/TitleBar.svelte";
    import "../app.css";
    import { attaching, keyverified } from "$lib/stores/global";
    import NotificationContainer from "../components/Notifications/NotificationContainer.svelte";
    import { onDestroy, onMount } from "svelte";
    import { loadTabs, saveTabs } from "$lib/restore";
    import { get } from "svelte/store";
    import KeyModal from "../components/KeyModal/KeyModal.svelte";
    import { fly, scale } from "svelte/transition";

    let { children } = $props();

    document.addEventListener("contextmenu", (e) => { e.preventDefault(); });

    onMount(() => loadTabs());
</script>

<main class="relative h-screen w-screen flex flex-col overflow-hidden">
    <div class={`absolute z-50 ${$keyverified ? "animate-none" : "animate-pulse"} top-[-200px] left-[-160px] size-64 bg-[#FBC470] rounded-full opacity-15 blur-3xl`}></div>

    {#if !$keyverified}
        <div
            in:fly={{y: -100, duration: 2000}} 
            class="absolute z-100 top-0 left-0 w-full h-full bg-black/50 backdrop-blur-sm rounded-lg ">
            <div
                data-tauri-drag-region
                class="aboslute top-0 left-0 h-14 flex px-1 gap-2 items-center justify-between z-110"
            ></div>

            <KeyModal />
        </div>
    {/if}

    <TitleBar />
    <NotificationContainer />
    <div class="flex-1 overflow-hidden">
        {@render children()}
    </div>
</main>