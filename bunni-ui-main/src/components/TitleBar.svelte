<script>
    import TabButtonContainer from "./TabButtonContainer.svelte";
    import Logo from "$lib/assets/pawa-logo.svg";
    import { Icon, Minus, Stop, XMark } from "svelte-hero-icons";
    import { getCurrentWindow } from "@tauri-apps/api/window";
    import { saveTabs } from "$lib/restore";
    const window = getCurrentWindow();
</script>

<div
    data-tauri-drag-region
    class="h-14 flex px-1 gap-2 items-center justify-between"
>
    <div class="flex flex-row items-center gap-6">
        <img src={Logo} alt="Pawa-Lite(Beta)V2" class="size-10 ml-4 invert" />
        <TabButtonContainer />
    </div>

    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div data-tauri-drag-region class="flex pr-4 justify-center items-center gap-1">
        <button onclick={() => window.minimize()} class="titlebar-button size-6 flex items-center justify-center hover:bg-zinc-500/8 rounded-md transition-all" id="titlebar-minimize">
            <Icon src={Minus} class="text-zinc-400 size-5" solid />
        </button>

        <button onclick={() => window.toggleMaximize()} class="titlebar-button size-6 flex items-center justify-center hover:bg-zinc-500/8 rounded-md transition-all" id="titlebar-maximise">
            <Icon src={Stop} class="text-zinc-500 size-5" />
        </button>

        <button onclick={() => {window.close(); saveTabs();}} class="titlebar-button size-6 flex items-center justify-center hover:bg-zinc-500/8 rounded-md transition-all" id="titlebar-close">
            <Icon src={XMark} class="text-zinc-500 size-5" solid />
        </button>
    </div>
</div>
