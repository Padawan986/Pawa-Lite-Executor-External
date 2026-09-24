<script lang="ts">
    import { Icon, type IconSource } from "svelte-hero-icons";

    interface Props {
        icon: IconSource,
        label: string,
        action: () => void,
    }

    let { icon, label, action }: Props = $props();
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<!-- svelte-ignore a11y_click_events_have_key_events -->
<div onclick={action} class="cursor-pointer flex flex-row items-center gap-1.5 text-zinc-400 hover:text-zinc-300 active:text-zinc-300/80 transition-colors">
    <Icon src={icon} class="size-4" solid />
    <span class="text-sm font-inter">{label}</span>
</div>