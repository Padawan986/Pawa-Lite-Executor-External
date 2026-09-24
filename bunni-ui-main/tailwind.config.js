/**@type {import("tailwindcss").Config} */
module.exports = {
    content: ["./src/**/*.{html,svelte,js,ts}"],
    theme: {
        extend: {
            fontFamily: {
                inter: ["Inter", "sans-serif"],
                mono: ["JetBrains Mono", "monospace"],
            },
            colors: {
                accent: {
                    DEFAULT: "#FB9866"
                }
            }
        },
    },
    plugins: []
};