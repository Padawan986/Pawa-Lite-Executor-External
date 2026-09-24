<script lang="ts">
    import { setActive } from "$lib/stores/tabs";
    import { Icon } from "svelte-hero-icons";

    interface Props {
        id: string,
        label: string,
        icon: string,
        selected: boolean,
        disabled: boolean,
    }

    let { id, label, icon, selected, disabled }: Props = $props();

    function handle() {
        if (!disabled) {
            setActive(id);
        }
    }
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<!-- svelte-ignore a11y_click_events_have_key_events -->
<div
    onclick={handle}
    class={`${disabled ? 'opacity-30' : 'cursor-pointer'} pl-1.5 pr-2 ${selected ? "bg-[#FBC470]/30 hover:bg-[#FBC470]/37" : disabled ? "" : "hover:bg-zinc-700/50"} rounded-tl-xl rounded-bl-md rounded-tr-md rounded-br-xl flex justify-center items-center gap-1.5 transition-colors`}
>
    <Icon 
        src={icon} 
        class={`${selected ? "text-[#FBC470]" : "text-zinc-300/70"} size-5`} 
        solid 
    />

    <span
        class={`${selected ? "text-[#FBC470]" : "text-zinc-300/70"} font-medium font-inter text-sm`}
    >{label}</span>
</div>