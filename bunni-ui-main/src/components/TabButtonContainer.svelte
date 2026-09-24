<script>
    import TabButton from "./TabButton.svelte";
    import { tabs, active } from "$lib/stores/tabs";
</script>

<div class="bg-zinc-800/30 h-9 rounded-tl-2xl rounded-bl-lg rounded-tr-lg rounded-br-2xl flex p-1 gap-1.5">
    {#each $tabs as tab}
        <TabButton 
            id={tab.id}
            label={tab.label}
            selected={$active === tab.id}
            icon={tab.icon}
            disabled={tab.disabled}
        />
    {/each}
</div>