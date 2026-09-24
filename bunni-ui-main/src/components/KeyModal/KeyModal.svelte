<script lang="ts">
    import { VConsole } from "$lib/console";
    import { keyverified } from "$lib/stores/global";
    import { notifs } from "$lib/stores/notification";
    import { invoke } from "@tauri-apps/api/core";

    let key: string = "";

    async function handle() {
        if (key !== "" || key) {
            try {

            const result = true;//await verifyKey('your-key-here');
            keyverified.set(result);

            } catch (error) {
                VConsole.error(`failed to authenticate key: ${error}`);
                keyverified.set(false);
                notifs.error("Failed to authenticate key.", { title: "Key" });
            }
        }
    }
</script>

<form class="bg-zinc-900 w-96 h-72 absolute top-1/2 left-1/2 transform -translate-x-1/2 -translate-y-1/2 rounded-2xl flex flex-col items-center gap-y-12 p-8">
    <div class="flex flex-col items-center gap-1">
        <span class="font-semibold text-zinc-300 text-xl">Pawa-Lite(Beta)V2 Key System</span>
        <span class="text-sm text-zinc-400 text-center w-4/5">Enter your Pawa-Lite(Beta)V2 key to continue.</span>
    </div>

    <div class="w-full flex flex-col items-center gap-2">
        <div class="w-full h-11 bg-zinc-800/50 rounded-lg">
            <input 
                type="password" 
                placeholder="Key" 
                class="w-full h-full align-middle overflow-hidden rounded-lg transition-colors px-4 placeholder-zinc-500 text-zinc-300 outline-1 outline-zinc-800 focus:outline-zinc-700" 
                bind:value={key}
            />
        </div>

        <button class="bg-[#FBC470] hover:bg-[#FBC470]/80 active:bg-[#FBC470]/70 cursor-pointer w-full h-11 rounded-lg font-semibold text-zinc-900" onclick={handle}>
            Continue
        </button>
    </div>
</form>