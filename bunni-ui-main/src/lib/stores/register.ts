// register tabs
import { register } from "./tabs";

import { CodeBracket, Cog6Tooth, Cube, User } from "svelte-hero-icons";

import Editor from "../../components/Tabs/Editor.svelte";
import Scripts from "../../components/Tabs/Scripts.svelte";
import Settings from "../../components/Tabs/Settings.svelte";
import Profile from "../../components/Tabs/Profile.svelte";

export function registerTabs() {
    register({
        id: "editor",
        label: "Editor",
        icon: CodeBracket,
        disabled: false,
        comp: Editor,
        pos: 1,
    });

    register({
        id: "scripts",
        label: "Scripts",
        icon: Cube,
        disabled: false,
        comp: Scripts,
        pos: 2,
    });

    register({
        id: "settings",
        label: "Settings",
        icon: Cog6Tooth,
        disabled: false,
        comp: Settings,
        pos: 3,
    });

    register({
        id: "profile",
        label: "Profile",
        icon: User,
        disabled: false,
        comp: Profile,
        pos: 4,
    });
}