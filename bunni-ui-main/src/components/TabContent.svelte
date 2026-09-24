<script lang="ts">
    import { tabs, active, getTab } from "$lib/stores/tabs";
    import { fade } from "svelte/transition";
</script>

<div class="h-full w-full flex flex-col overflow-hidden">
    {#if $active}
        {#if $tabs.length > 0}
            {#each $tabs.filter(t => t.id === $active) as tab (tab.id)}
                <svelte:component this={tab.comp} />
            {/each}
        {/if}
    {:else}
        <p class="text-zinc-400">:D</p>
    {/if}
</div>